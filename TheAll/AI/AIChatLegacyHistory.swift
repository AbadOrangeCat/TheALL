import Foundation

/// Older builds saved the backend transcript but not its terminal UUID. These
/// are candidates for explicit import, never automatic matches to a workspace.
struct AIChatLegacyConversation: Identifiable {
    let id: String
    let title: String
    let directory: String
    let updatedAt: Date
    let messages: [AIChatMessage]
}

enum AIChatLegacyHistory {
    /// `root` must be the app-owned CLAUDE_CONFIG_DIR. Do not search shared CLI
    /// homes: there is no reliable way to associate those chats with this app.
    static func conversations(root: URL) throws -> [AIChatLegacyConversation] {
        let manager = FileManager.default
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: projects.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw CocoaError(.fileReadCorruptFile) }
        // A linked projects folder could escape the supplied app-owned root.
        guard try projects.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return [] }
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: projects,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw CocoaError(.fileReadUnknown) }
        var files: [(url: URL, modified: Date)] = []
        for case let url as URL in enumerator {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            if attributes.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            // Main transcripts are projects/<encoded cwd>/<session UUID>.jsonl.
            // Nested agent/subagent logs must never appear as independent chats.
            // URL paths may gain /private while traversing /var on macOS.
            // The enumerator's depth is relative to its root in either case.
            let depth = enumerator.level
            if depth >= 2, attributes.isRegularFile != true { enumerator.skipDescendants() }
            guard depth == 2, attributes.isRegularFile == true,
                  url.pathExtension == "jsonl", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            else { continue }
            files.append((url, attributes.contentModificationDate ?? .distantPast))
        }
        if let enumerationError { throw enumerationError }

        var builders: [String: Builder] = [:]
        for file in files.sorted(by: {
            $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified < $1.modified
        }) {
            let id = file.url.deletingPathExtension().lastPathComponent.lowercased()
            var builder = builders[id] ?? Builder(id: id)
            let data = try Data(contentsOf: file.url, options: .mappedIfSafe)
            for line in data.split(separator: 10) {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                builder.consume(row, fallbackDate: file.modified)
            }
            builders[id] = builder
        }
        return builders.values.compactMap(\.conversation).sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    private struct Builder {
        let id: String
        var directory = ""
        var updatedAt = Date.distantPast
        var customTitle: String?
        var aiTitle: String?
        var customTitleDate = Date.distantPast
        var aiTitleDate = Date.distantPast
        var records: [Record] = []
        var recordIndices: [String: Int] = [:]

        mutating func consume(_ row: [String: Any], fallbackDate: Date) {
            guard row["isSidechain"] as? Bool != true,
                  let sessionID = row["sessionId"] as? String, sessionID.lowercased() == id else { return }
            let date = timestamp(row["timestamp"] as? String) ?? fallbackDate
            if date >= updatedAt {
                updatedAt = date
                if let cwd = row["cwd"] as? String, cwd.hasPrefix("/") { directory = cwd }
            } else if directory.isEmpty, let cwd = row["cwd"] as? String, cwd.hasPrefix("/") {
                directory = cwd
            }
            switch row["type"] as? String {
            case "custom-title":
                if date >= customTitleDate { customTitle = row["customTitle"] as? String; customTitleDate = date }
                return
            case "ai-title":
                if date >= aiTitleDate { aiTitle = row["aiTitle"] as? String; aiTitleDate = date }
                return
            default: break
            }
            guard row["isMeta"] as? Bool != true, row["isCompactSummary"] as? Bool != true,
                  let uuid = row["uuid"] as? String, !uuid.isEmpty,
                  let message = row["message"] as? [String: Any],
                  let type = row["type"] as? String, ["user", "assistant"].contains(type)
            else { return }
            let model = message["model"] as? String ?? ""
            let content: [[String: Any]]
            if let text = message["content"] as? String { content = [["type": "text", "text": text]] }
            else { content = message["content"] as? [[String: Any]] ?? [] }
            var messages: [AIChatMessage] = []
            for (index, block) in content.enumerated() {
                let messageID = "legacy-\(uuid)-\(index)"
                switch block["type"] as? String {
                case "text":
                    guard let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          type != "user" || !isInternalUserText(text) else { continue }
                    messages.append(AIChatMessage(id: messageID, role: type == "user" ? .user : .assistant,
                        text: text, model: model))
                case "thinking" where type == "assistant":
                    guard let text = block["thinking"] as? String, !text.isEmpty else { continue }
                    messages.append(AIChatMessage(id: messageID, role: .thinking, text: text, model: model))
                case "tool_result" where type == "user":
                    guard block["is_error"] as? Bool == true else { continue }
                    let text = textContent(block["content"])
                    guard !text.isEmpty else { continue }
                    messages.append(AIChatMessage(id: messageID, role: .tool, text: text, isError: true))
                default: break
                }
            }
            guard !messages.isEmpty else { return }
            let record = Record(id: uuid, date: date, messages: messages)
            // Claude may repeat a row while flushing/resuming. Keep its final
            // version without duplicating text; assistant blocks can share an
            // API message ID, so the transcript row UUID is the identity here.
            if let index = recordIndices[uuid] {
                if date >= records[index].date { records[index] = record }
            }
            else { recordIndices[uuid] = records.count; records.append(record) }
        }

        var conversation: AIChatLegacyConversation? {
            let messages = records.enumerated().sorted {
                $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
            }.flatMap { $0.element.messages }
            guard !directory.isEmpty, let question = messages.first(where: { $0.role == .user }) else { return nil }
            let title = [customTitle, aiTitle, question.text].compactMap { value -> String? in
                guard let value else { return nil }
                let cleaned = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
            }.first ?? "Claude Code"
            return AIChatLegacyConversation(id: id, title: title, directory: directory,
                updatedAt: updatedAt, messages: messages)
        }
    }

    private struct Record {
        let id: String
        let date: Date
        let messages: [AIChatMessage]
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func isInternalUserText(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<command-", "<local-command-", "<system-reminder>", "<task-notification>",
                "<ide_opened_file>", "<ide_selection>", "<session-start-hook>", "<user-prompt-submit-hook>"]
            .contains { text.hasPrefix($0) }
    }

    private static func textContent(_ content: Any?) -> String {
        if let text = content as? String { return text }
        return (content as? [[String: Any]] ?? []).compactMap { block in
            block["type"] as? String == "text" ? block["text"] as? String : nil
        }.joined(separator: "\n")
    }
}
