import Foundation
import Observation

/// Pushes only change notifications. History and actions retain the HTTP API's
/// authorization, pagination and idempotency rules; no draft enters this stream.
final class MobileEventHub {
    private final class Client {
        let channel: MobileEventChannel
        let device: MobilePairingStore.Device
        let authorized: () -> Bool
        var signature: [String] = []
        var lastSeen = Date()
        var lastInput = Date.distantPast
        var notification: DispatchWorkItem?
        init(channel: MobileEventChannel, device: MobilePairingStore.Device, authorized: @escaping () -> Bool) {
            self.channel = channel; self.device = device; self.authorized = authorized
        }
    }
    private let registry: AIChatSessionRegistry
    private let bootID: String
    private var clients: [UUID: Client] = [:]
    private var timer: Timer?
    var onPresence: ((Set<UUID>) -> Void)?

    init(registry: AIChatSessionRegistry, bootID: String) { self.registry = registry; self.bootID = bootID }

    func connect(_ channel: MobileEventChannel, device: MobilePairingStore.Device,
                 authorized: @escaping () -> Bool) -> MobileHTTPResponse? {
        guard clients.count < 32 else { return .error(L10n.string("mobile.error.capacity"), status: 429) }
        guard authorized() else { return .error(L10n.string("mobile.error.authorization"), status: 401) }
        let id = UUID(), client = Client(channel: channel, device: device, authorized: authorized)
        clients[id] = client
        channel.onClose = { [weak self] in self?.remove(id) }
        channel.onText = { [weak self] text in self?.receive(text, id: id) }
        send(["type": "hello", "bootID": bootID, "access": device.access.json], client)
        observe(id, initial: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.validate() }
            }
        }
        updatePresence()
        return nil
    }

    /// Revalidate immediately on revoke, listener stop, relay loss or master off.
    func validate() {
        for (id, client) in Array(clients) {
            if !client.authorized() {
                client.channel.close(); remove(id)
            } else if Date().timeIntervalSince(client.lastSeen) > 55 {
                client.channel.close(); remove(id)
            }
        }
    }

    func revoke(_ deviceID: UUID) {
        for (id, client) in Array(clients) where client.device.id == deviceID {
            send(["type": "revoked"], client); client.channel.close(); remove(id)
        }
    }

    private func receive(_ text: String, id: UUID) {
        guard let client = clients[id] else { return }
        guard client.authorized() else { validate(); return }
        guard text.utf8.count <= 1024,
              Date().timeIntervalSince(client.lastInput) >= 0.1,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "ping"
        else { client.channel.close(); remove(id); return }
        client.lastInput = Date(); client.lastSeen = Date()
        send(["type": "pong"], client)
    }

    private func observe(_ id: UUID, initial: Bool = false) {
        guard let client = clients[id] else { return }
        guard client.authorized() else { validate(); return }
        let signature = withObservationTracking {
            visibleSignature(client.device.access)
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observe(id) }
        }
        let changed = signature != client.signature
        client.signature = signature
        guard !initial, changed, client.notification == nil else { return }
        let notification = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client, self.clients[id] === client else { return }
            client.notification = nil
            guard client.authorized() else { self.validate(); return }
            self.send(["type": "changed", "bootID": self.bootID], client)
        }
        client.notification = notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: notification)
    }

    private func visibleSignature(_ access: MobilePairingStore.Access) -> [String] {
        var values: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for workspace in registry.workspaces.workspaces where access.allows(workspaceID: workspace.id) {
            values.append(String(decoding: (try? encoder.encode(workspace)) ?? Data(), as: UTF8.self))
            for id in workspace.tabs.flatMap({ $0.layout.allTerminalIds() }) {
                values.append(registry.directories.pwd(for: id) ?? "")
                guard let session = registry.sessions[id] else { values.append("inactive"); continue }
                values += [session.provider?.rawValue ?? "", session.directory, session.historyError ?? "", session.errorMessage ?? ""]
                values += session.models.flatMap { [$0.id, $0.title] }
                if let chat = session.chat {
                    values += [String(ObjectIdentifier(chat).hashValue), String(chat.revision), chat.model, chat.directory,
                               String(chat.isBusy), String(chat.isReady), String(chat.canInterrupt), chat.errorMessage ?? ""]
                    values += chat.approvals.flatMap { [$0.id, $0.title] }
                }
            }
        }
        return values
    }

    private func send(_ value: [String: Any], _ client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return }
        client.channel.send(text)
    }
    private func remove(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.notification?.cancel()
        client.channel.onClose = nil; client.channel.onText = nil
        if clients.isEmpty { timer?.invalidate(); timer = nil }
        updatePresence()
    }
    private func updatePresence() { onPresence?(Set(clients.values.map { $0.device.id })) }
    deinit { timer?.invalidate() }
}
