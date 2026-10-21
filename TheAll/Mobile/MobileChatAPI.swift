import Foundation

/// Main-thread operations on the same sessions used by desktop windows.
final class MobileChatAPI {
    let registry: AIChatSessionRegistry
    private struct Receipt { let fingerprint: String; let response: MobileHTTPResponse; let conversationID: UUID? }
    private var receipts: [String: Receipt] = [:]
    private var pending: Set<String> = []
    let bootID = UUID().uuidString

    init(registry: AIChatSessionRegistry) { self.registry = registry }

    @MainActor
    func handle(_ request: MobileHTTPRequest, device: MobilePairingStore.Device,
                stillAuthorized: @escaping () -> Bool) async -> MobileHTTPResponse {
        do {
            guard stillAuthorized() else { throw APIError(401, "mobile.error.authorization") }
            if request.method == "GET", request.path == "/api/workspaces" { return try workspaces(access: device.access) }
            let parts = request.path.split(separator: "/").map(String.init)
            if request.method == "GET", parts.count == 3, parts[0] == "api", parts[1] == "chats",
               let id = UUID(uuidString: parts[2]) { return try conversation(id, request: request, access: device.access) }
            if request.method == "POST", !device.access.writable { throw APIError(403, "mobile.error.readOnly") }
            guard request.method == "POST", let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let requestID = body["requestId"] as? String, UUID(uuidString: requestID) != nil
            else { throw APIError(400, "mobile.error.request") }
            // Authorize the current target before consulting receipts, credentials,
            // session restoration, or any other resource-specific state.
            if request.path == "/api/chats" { _ = try createWorkspaceID(body, access: device.access) }
            else if parts.count == 4, parts[0] == "api", parts[1] == "chats",
                    let id = UUID(uuidString: parts[2]), ["send", "interrupt", "answer"].contains(parts[3]) {
                _ = try authorizeConversation(id, access: device.access)
            } else { throw APIError(404, "mobile.error.notFound") }
            guard body["bootID"] as? String == bootID else { throw APIError(409, "mobile.error.restarted") }
            let key = device.id.uuidString + ":" + requestID
            let canonical = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            let fingerprint = MobilePairingStore.hash(request.path + String(decoding: canonical, as: UTF8.self))
            if let cached = receipts[key] {
                guard cached.fingerprint == fingerprint else { throw APIError(409, "mobile.error.requestReuse") }
                if let id = cached.conversationID { _ = try authorizeConversation(id, access: device.access) }
                return cached.response
            }
            guard !pending.contains(key) else {
                return .json(["error": L10n.string("mobile.error.pending"), "code": "request_pending"], status: 409)
            }
            // Bound memory without evicting accepted IDs: a full ledger requires
            // an app restart, rather than silently executing an old retry again.
            guard receipts.count < 10000 else { throw APIError(429, "mobile.error.capacity") }
            pending.insert(key)
            defer { pending.remove(key) }
            let response: MobileHTTPResponse
            do {
                if request.path == "/api/chats" { response = try create(body, access: device.access) }
                else if parts.count == 4, parts[0] == "api", parts[1] == "chats", let id = UUID(uuidString: parts[2]) {
                    response = try await act(parts[3], id: id, body: body, access: device.access, stillAuthorized: stillAuthorized)
                } else { throw APIError(404, "mobile.error.notFound") }
            } catch let error as APIError {
                response = .json(["error": L10n.string(error.key), "code": "operation_failed"], status: error.status)
            }
            // Retain successes and failures: an explicit new action uses a new ID.
            let createdID: UUID?
            if request.path == "/api/chats", response.status == 201,
               let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
               let rawID = value["id"] as? String { createdID = UUID(uuidString: rawID) }
            else { createdID = nil }
            receipts[key] = Receipt(fingerprint: fingerprint, response: response, conversationID: createdID)
            return response
        } catch let error as APIError { return .error(L10n.string(error.key), status: error.status) }
        catch { return .error(L10n.string("mobile.error.history"), status: 500) }
    }

    private func workspaces(access: MobilePairingStore.Access) throws -> MobileHTTPResponse {
        let items: [[String: Any]] = registry.workspaces.workspaces.filter { access.allows(workspaceID: $0.id) }.map { workspace in
            let chats: [[String: Any]] = workspace.tabs.flatMap { tab in
                tab.layout.allTerminalIds().enumerated().map { offset, id in
                    var historyError: String?
                    let snapshot: AIChatSnapshot?
                    do { snapshot = try registry.snapshot(for: id) }
                    catch { snapshot = nil; historyError = L10n.string("mobile.error.history") }
                    let active = registry.sessions[id]?.chat
                    let status = active.map { !$0.approvals.isEmpty ? "needsInput" : ($0.isBusy ? "running" : ($0.isReady ? "idle" : "offline")) }
                        ?? (snapshot == nil ? "setup" : "offline")
                    var value: [String: Any] = ["id": id.uuidString, "workspaceId": workspace.id.uuidString, "tabId": tab.id.uuidString,
                        "title": tab.title + (tab.layout.allTerminalIds().count > 1 ? " · \(offset + 1)" : ""),
                        "directory": snapshot?.directory ?? registry.directories.pwd(for: id) ?? NSHomeDirectory(),
                        "model": snapshot?.model ?? "", "status": status, "messageCount": snapshot?.messages.count ?? 0]
                    if let provider = snapshot?.provider ?? registry.sessions[id]?.provider { value["provider"] = provider.rawValue }
                    if let historyError { value["error"] = historyError; value["status"] = "offline" }
                    return value
                }
            }
            return ["id": workspace.id.uuidString, "name": workspace.name, "conversations": chats]
        }
        return .json(["workspaces": items, "bootID": bootID, "access": access.json])
    }

    private func conversation(_ id: UUID, request: MobileHTTPRequest, access: MobilePairingStore.Access) throws -> MobileHTTPResponse {
        let workspaceID = try authorizeConversation(id, access: access)
        let snapshot = try registry.snapshot(for: id)
        let session = registry.sessions[id], chat = session?.chat
        let messages = snapshot?.messages.filter(\.isVisibleInTranscript) ?? []
        let query = request.components?.queryItems ?? []
        func number(_ key: String, fallback: Int) throws -> Int {
            guard let raw = query.first(where: { $0.name == key })?.value else { return fallback }
            guard let n = Int(raw), n >= 0 else { throw APIError(400, "mobile.error.request") }
            return n
        }
        let end = min(try number("before", fallback: messages.count), messages.count)
        let limit = min(max(try number("limit", fallback: 100), 1), 250)
        let start = max(end - limit, 0)
        let encoded = try JSONEncoder().encode(Array(messages[start..<end]))
        var value: [String: Any] = ["id": id.uuidString, "workspaceId": workspaceID.uuidString, "access": access.json,
            "provider": (snapshot?.provider ?? session?.provider)?.rawValue ?? "",
            "model": snapshot?.model ?? "", "directory": snapshot?.directory ?? registry.directories.pwd(for: id) ?? NSHomeDirectory(),
            "messages": try JSONSerialization.jsonObject(with: encoded), "start": start, "total": messages.count,
            "isReady": chat?.isReady ?? false, "isBusy": chat?.isBusy ?? false, "canInterrupt": access.writable && (chat?.canInterrupt ?? false),
            "canResume": access.writable && snapshot != nil && chat == nil,
            "models": session?.models.map { ["id": $0.id, "title": $0.title] } ?? [],
            "questions": chat?.approvals.map { approval -> [String: Any] in
                ["id": approval.id, "title": approval.title, "questions": approval.questions.map {
                    ["id": $0.id, "prompt": $0.prompt, "options": $0.options, "multiple": $0.multiple, "secret": $0.secret] as [String: Any]
                }]
            } ?? [], "bootID": bootID]
        if let error = session?.historyError ?? chat?.errorMessage ?? session?.errorMessage { value["error"] = error }
        return .json(value)
    }

    private func create(_ body: [String: Any], access: MobilePairingStore.Access) throws -> MobileHTTPResponse {
        let targetWorkspaceID = try createWorkspaceID(body, access: access)
        guard let raw = body["provider"] as? String, let provider = AIProvider(rawValue: raw) else { throw APIError(400, "mobile.error.request") }
        let directory = (body["directory"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), directory.utf8.count < 4096,
              FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw APIError(400, "mobile.error.directory") }
        let model = try selectedModel(body)
        do { try registry.validateConnection(for: provider) }
        catch { throw APIError(409, "mobile.error.connection") }
        let id: UUID
        if let workspaceID = targetWorkspaceID {
            guard let added = registry.workspaces.addTab(to: workspaceID) else { throw APIError(404, "mobile.error.notFound") }
            id = added.terminalId
        } else { id = registry.workspaces.createWorkspace(name: "Default") }
        registry.directories.setPwd(directory, for: id)
        guard let session = registry.session(for: id) else { throw APIError(500, "mobile.error.request") }
        session.choose(provider)
        if let model { session.chat?.model = model }
        session.refreshModels()
        session.flushHistory()
        let owner = registry.workspaces.workspaces.first { $0.tabs.contains { $0.layout.allTerminalIds().contains(id) } }!
        return .json(["id": id.uuidString, "workspaceId": owner.id.uuidString, "access": access.json], status: 201)
    }

    @MainActor
    private func act(_ action: String, id: UUID, body: [String: Any], access: MobilePairingStore.Access,
                     stillAuthorized: @escaping () -> Bool) async throws -> MobileHTTPResponse {
        guard stillAuthorized() else { throw APIError(401, "mobile.error.authorization") }
        _ = try authorizeConversation(id, access: access)
        guard ["send", "interrupt", "answer"].contains(action) else { throw APIError(404, "mobile.error.notFound") }
        if action == "send" {
            guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 128 * 1024 else { throw APIError(400, "mobile.error.request") }
            let model = try selectedModel(body)
            guard let session = registry.session(for: id), let chat = session.chat else { throw APIError(409, "mobile.error.connection") }
            // A newly restored backend needs its protocol handshake. No prompt
            // is queued while disconnected; authorization is checked again after await.
            if !chat.isReady, !chat.isBusy, chat.errorMessage == nil {
                for _ in 0..<100 {
                    if chat.isReady || chat.errorMessage != nil || !stillAuthorized()
                        || (try? authorizeConversation(id, access: access)) == nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard stillAuthorized() else { throw APIError(401, "mobile.error.authorization") }
            _ = try authorizeConversation(id, access: access)
            guard registry.sessions[id]?.chat === chat else { throw APIError(409, "mobile.error.changed") }
            guard chat.isReady else { throw APIError(409, "mobile.error.notReady") }
            guard !chat.isBusy, chat.approvals.isEmpty else { throw APIError(409, "mobile.error.busy") }
            let submitted = await withCheckedContinuation { continuation in
                chat.sendRemote(text, model: model, stillAuthorized: { [weak self, weak chat] in
                    guard let self, let chat else { return false }
                    return stillAuthorized() && (try? self.authorizeConversation(id, access: access)) != nil
                        && self.registry.sessions[id]?.chat === chat
                }) { continuation.resume(returning: $0) }
            }
            guard stillAuthorized() else { throw APIError(401, "mobile.error.authorization") }
            _ = try authorizeConversation(id, access: access)
            guard registry.sessions[id]?.chat === chat else { throw APIError(409, "mobile.error.changed") }
            session.flushHistory()
            switch submitted {
            case .accepted: break
            case .rejected: throw APIError(503, "mobile.error.notReady")
            case .uncertain:
                return .json(["error": L10n.string("mobile.error.pending"), "code": "outcome_unknown"], status: 503)
            }
        } else {
            guard let chat = registry.sessions[id]?.chat else { throw APIError(409, "mobile.error.notReady") }
            if action == "interrupt" {
                guard chat.canInterrupt else { throw APIError(409, "mobile.error.busy") }
                guard chat.interrupt() else { throw APIError(503, "mobile.error.notReady") }
            } else {
                guard let questionID = body["questionId"] as? String,
                      let approval = chat.approvals.first(where: { $0.id == questionID }),
                      let answers = body["answers"] as? [String: [String]], body["allow"] as? Bool == true,
                      Set(answers.keys).isSubset(of: Set(approval.questions.map(\.id)))
                else { throw APIError(409, "mobile.error.question") }
                for question in approval.questions {
                    guard let values = answers[question.id], !values.isEmpty,
                          question.multiple || values.count == 1,
                          values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 16384 })
                    else { throw APIError(400, "mobile.error.question") }
                }
                guard chat.answerApproval(questionID, allow: true, answers: answers) else { throw APIError(503, "mobile.error.notReady") }
            }
        }
        return .json(["id": id.uuidString, "access": access.json])
    }

    /// Recompute ownership each time: tabs can be moved or removed while a CLI
    /// handshake or model change is pending. Do not cache a conversation's grant.
    private func authorizeConversation(_ id: UUID, access: MobilePairingStore.Access) throws -> UUID {
        guard let owner = registry.workspaces.workspaces.first(where: { workspace in
            workspace.tabs.contains { $0.layout.allTerminalIds().contains(id) }
        }) else { throw APIError(404, "mobile.error.notFound") }
        guard access.allows(workspaceID: owner.id) else { throw APIError(403, "mobile.error.scope") }
        return owner.id
    }

    private func createWorkspaceID(_ body: [String: Any], access: MobilePairingStore.Access) throws -> UUID? {
        guard access.writable else { throw APIError(403, "mobile.error.readOnly") }
        let workspaceID: UUID?
        if let raw = body["workspaceId"] {
            guard let text = raw as? String, let parsed = UUID(uuidString: text) else {
                throw APIError(400, "mobile.error.request")
            }
            workspaceID = parsed
        } else { workspaceID = nil }
        if let allowedID = access.workspaceID, workspaceID != allowedID {
            throw APIError(403, "mobile.error.scope")
        }
        if let workspaceID, !registry.workspaces.workspaces.contains(where: { $0.id == workspaceID }) {
            throw APIError(404, "mobile.error.notFound")
        }
        return workspaceID
    }

    private func selectedModel(_ body: [String: Any]) throws -> String? {
        guard let value = body["model"] else { return nil }
        guard let model = value as? String, model.utf8.count <= 200,
              !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw APIError(400, "mobile.error.request") }
        return model
    }
    private struct APIError: Error { let status: Int; let key: String; init(_ status: Int, _ key: String) { self.status = status; self.key = key } }
}
