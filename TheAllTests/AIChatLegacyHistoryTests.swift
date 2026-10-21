import Foundation
import XCTest
@testable import TheAll

final class AIChatLegacyHistoryTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllLegacyHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func row(_ sessionID: String, _ uuid: String, type: String, content: Any,
                     timestamp: String = "2026-10-23T09:00:00.000Z", extra: [String: Any] = [:]) -> [String: Any] {
        ["type": type, "sessionId": sessionID, "uuid": uuid, "cwd": "/tmp/legacy-project",
         "timestamp": timestamp, "message": ["id": "shared-api-message", "model": "fixture-model",
         "role": type, "content": content] as [String: Any]]
            .merging(extra) { _, new in new }
    }

    @discardableResult
    private func write(_ rows: [[String: Any]], to root: URL, path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(10)
        }
        try data.write(to: url)
        return url
    }

    func testParsesUserThinkingFinalAndToolErrorsWithoutDuplicatingRowsOrImportingInternalPrompts() throws {
        let root = try root(), id = UUID().uuidString
        let user = row(id, "user", type: "user", content: "  Inspect this project\nplease  ")
        let final = row(id, "final", type: "assistant", content: [["type": "text", "text": "Final answer"]])
        let url = try write([
            user, user,
            row(id, "meta", type: "user", content: "injected metadata", extra: ["isMeta": true]),
            row(id, "summary", type: "user", content: "compacted prompt", extra: ["isCompactSummary": true]),
            row(id, "command", type: "user", content: "<command-name>/resume</command-name>"),
            row(id, "notification", type: "user", content: "<task-notification>background result</task-notification>"),
            row(id, "sidechain", type: "assistant", content: "child agent", extra: ["isSidechain": true]),
            row(UUID().uuidString, "foreign", type: "assistant", content: "different session"),
            row(id, "thinking", type: "assistant", content: [["type": "thinking", "thinking": "Inspecting files", "signature": "opaque"]]),
            row(id, "progress", type: "assistant", content: [["type": "text", "text": "Checking tests"]]),
            row(id, "tools", type: "user", content: [["type": "tool_result", "content": "normal output"],
                ["type": "tool_result", "is_error": true, "content": [["type": "text", "text": "Test failed"]]]]),
            final, final,
        ], to: root, path: "projects/project/\(id).jsonl")
        // A partial final disk write must not hide earlier complete records.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"unfinished\":".utf8))
        try handle.close()
        let original = try Data(contentsOf: url)

        let conversations = try AIChatLegacyHistory.conversations(root: root)
        let chat = try XCTUnwrap(conversations.first)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(chat.id, id.lowercased())
        XCTAssertEqual(chat.title, "Inspect this project please")
        XCTAssertEqual(chat.directory, "/tmp/legacy-project")
        XCTAssertEqual(chat.messages.map(\.text), ["  Inspect this project\nplease  ", "Inspecting files", "Checking tests", "Test failed", "Final answer"])
        XCTAssertEqual(chat.messages.map(\.role), [.user, .thinking, .assistant, .tool, .assistant])
        XCTAssertTrue(chat.messages[3].isError)
        XCTAssertFalse(chat.messages.last!.isIntermediate)
        XCTAssertEqual(Set(chat.messages.map(\.id)).count, chat.messages.count)
        XCTAssertEqual(try Data(contentsOf: url), original, "Recovery must only read the backend transcript")
    }

    func testCandidatesAreExplicitIndependentSessionsAndExcludeSubagentsAndLinkedFiles() throws {
        let root = try root(), first = UUID().uuidString, second = UUID().uuidString, child = UUID().uuidString
        try write([row(first, "q1", type: "user", content: "First")], to: root, path: "projects/project/\(first).jsonl")
        try write([row(second, "q2", type: "user", content: [["type": "text", "text": "Second"]],
                       timestamp: "2026-10-23T10:00:00Z")], to: root, path: "projects/project/\(second).jsonl")
        try write([row(child, "q3", type: "user", content: "Nested agent")], to: root,
                  path: "projects/project/\(first)/subagents/\(child).jsonl")
        try write([row(child, "q4", type: "user", content: "Agent file")], to: root,
                  path: "projects/project/agent-\(child).jsonl")
        let outside = try self.root(), linked = UUID().uuidString
        let source = try write([row(linked, "q5", type: "user", content: "Outside")], to: outside, path: "\(linked).jsonl")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("projects/project/\(linked).jsonl"), withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("projects/linked-project"), withDestinationURL: outside)

        let candidates = try AIChatLegacyHistory.conversations(root: root)
        XCTAssertEqual(candidates.map(\.id), [second.lowercased(), first.lowercased()])
        XCTAssertEqual(candidates.map(\.title), ["Second", "First"])
        XCTAssertEqual(try AIChatLegacyHistory.conversations(root: try self.root()).count, 0)
    }

    func testMergesSameSessionAcrossDirectoriesAndKeepsLatestTitleAndFinalAnswer() throws {
        let root = try root(), id = UUID().uuidString
        let user = row(id, "user", type: "user", content: "Original question")
        try write([user, row(id, "answer", type: "assistant", content: "Partial")], to: root,
                  path: "projects/old-project/\(id).jsonl")
        try write([user,
            row(id, "answer", type: "assistant", content: "Full original answer", timestamp: "2026-10-23T09:00:01Z"),
            row(id, "next", type: "user", content: "Follow up", timestamp: "2026-10-23T09:05:00Z", extra: ["cwd": "/tmp/new-project"]),
            ["type": "ai-title", "sessionId": id, "aiTitle": "AI title", "timestamp": "2026-10-23T09:06:00Z"],
            ["type": "custom-title", "sessionId": id, "customTitle": "My chosen title", "timestamp": "2026-10-23T09:07:00Z"],
        ], to: root, path: "projects/new-project/\(id).jsonl")

        let candidates = try AIChatLegacyHistory.conversations(root: root)
        let chat = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(chat.directory, "/tmp/new-project")
        XCTAssertEqual(chat.title, "My chosen title")
        XCTAssertEqual(chat.messages.map(\.text), ["Original question", "Full original answer", "Follow up"])
    }

    func testMissingOrInvalidMetadataDoesNotCreateMisleadingRecoverableChats() throws {
        let root = try root(), id = UUID().uuidString
        try write([
            row(id, "assistant-only", type: "assistant", content: "No user question"),
            row(id, "internal-only", type: "user", content: "<system-reminder>instruction</system-reminder>"),
        ], to: root, path: "projects/project/\(id).jsonl")
        let missingCWD = UUID().uuidString
        try write([row(missingCWD, "user", type: "user", content: "Question", extra: ["cwd": "relative/path"])],
                  to: root, path: "projects/project/\(missingCWD).jsonl")
        XCTAssertTrue(try AIChatLegacyHistory.conversations(root: root).isEmpty)
    }
}
