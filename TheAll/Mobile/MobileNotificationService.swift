import Foundation

/// Owns subscriptions independently of browser/WS lifetimes. Access is checked
/// again on the main actor immediately before handing a request to URLSession.
final class MobileNotificationService {
    typealias Sender = (URLRequest) async throws -> Int
    var isAuthorized: (MobilePushStore.Record, UUID?) -> Bool = { _, _ in false }
    private let store: MobilePushStore
    private let sender: Sender
    private let now: () -> Date
    private var pending: [UUID: (device: UUID, task: Task<Void, Error>)] = [:]
    private var completedEvents: [UUID] = []
    private var recentTests: [UUID: Date] = [:]

    init(store: MobilePushStore = MobilePushStore(), now: @escaping () -> Date = Date.init, sender: Sender? = nil) {
        self.store = store; self.now = now
        let transport = MobileWebPushSender()
        self.sender = sender ?? { try await transport.send($0) }
    }

    func state(deviceID: UUID, origin: String) throws -> [String: Any] {
        guard MobilePushStore.secureOrigin(origin) else {
            return ["available": false, "enabled": false, "reason": "https_required"]
        }
        let enabled = try store.records().contains { $0.deviceID == deviceID && $0.origin == origin &&
            !$0.subscription.isExpired(at: now()) && isAuthorized($0, nil) }
        return ["available": true, "enabled": enabled,
                "publicKey": MobileWebPush.encode(try store.signingKey().publicKey.x963Representation)]
    }

    func subscribe(deviceID: UUID, origin: String, body: [String: Any]) throws {
        guard MobilePushStore.secureOrigin(origin), let json = body["subscription"] as? [String: Any],
              let language = body["language"] as? String, MobilePushStore.languages.contains(language),
              body["deviceID"] == nil, body["deviceId"] == nil
        else { throw MobileWebPush.PushError.invalidSubscription }
        let subscription = try MobileWebPush.Subscription(json: json, now: now())
        _ = try store.signingKey()
        for record in try store.records() where record.subscription.isExpired(at: now()) || !isAuthorized(record, nil) {
            cancel(deviceID: record.deviceID)
            try store.remove(deviceID: record.deviceID, recordID: record.id)
        }
        // Cancel previous deliveries before endpoint ownership can change.
        for record in try store.records() where record.deviceID == deviceID || record.subscription.endpoint == subscription.endpoint {
            cancel(deviceID: record.deviceID)
        }
        _ = try store.subscribe(deviceID: deviceID, origin: origin, language: language, subscription: subscription, now: now())
    }

    func unsubscribe(deviceID: UUID) throws {
        cancel(deviceID: deviceID)
        try store.remove(deviceID: deviceID)
        recentTests.removeValue(forKey: deviceID)
    }

    func cancelPending() {
        pending.values.forEach { $0.task.cancel() }; pending.removeAll()
    }

    private func cancel(deviceID: UUID) {
        for id in Array(pending.keys) where pending[id]?.device == deviceID {
            pending.removeValue(forKey: id)?.task.cancel()
        }
    }

    @MainActor
    func test(deviceID: UUID, origin: String) async throws {
        guard MobilePushStore.secureOrigin(origin),
              let record = try store.records().first(where: { $0.deviceID == deviceID && $0.origin == origin }),
              valid(record, chatID: nil), pending.count < 40,
              recentTests[deviceID].map({ now().timeIntervalSince($0) >= 10 }) ?? true
        else { throw MobileWebPush.PushError.unavailable }
        recentTests[deviceID] = now()
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.deliver(record, eventID: id, chatID: nil)
        }
        pending[id] = (deviceID, task)
        defer { pending.removeValue(forKey: id) }
        try await task.value
    }

    @MainActor
    func completed(chatID: UUID, eventID: UUID) {
        guard !completedEvents.contains(eventID) else { return }
        completedEvents.append(eventID)
        if completedEvents.count > 256 { completedEvents.removeFirst(completedEvents.count - 256) }
        guard let records = try? store.records() else { return }
        for record in records where valid(record, chatID: chatID) {
            guard pending.count < 40 else { break }
            let job = UUID()
            let task = Task<Void, Error> { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pending.removeValue(forKey: job) }
                try await self.deliver(record, eventID: eventID, chatID: chatID)
            }
            pending[job] = (record.deviceID, task)
        }
    }

    private func valid(_ record: MobilePushStore.Record, chatID: UUID?) -> Bool {
        !record.subscription.isExpired(at: now()) && isAuthorized(record, chatID) &&
            ((try? store.records().contains(where: { $0.id == record.id })) == true)
    }

    @MainActor
    private func deliver(_ record: MobilePushStore.Record, eventID: UUID, chatID: UUID?) async throws {
        try Task.checkCancellation()
        guard valid(record, chatID: chatID) else { throw CancellationError() }
        let payload = try Self.payload(eventID: eventID, chatID: chatID, language: record.language)
        let request = try MobileWebPush.request(payload: payload, subscription: record.subscription,
                                               signingKey: store.signingKey(), now: now())
        try Task.checkCancellation()
        guard valid(record, chatID: chatID) else { throw CancellationError() }
        let status = try await sender(request)
        if status == 404 || status == 410 { try store.remove(deviceID: record.deviceID, recordID: record.id) }
        guard (200..<300).contains(status) else { throw MobileWebPush.PushError.unavailable }
    }

    static func payload(eventID: UUID, chatID: UUID?, language: String) throws -> Data {
        let completion = ["en": "Your task is complete. Open TheAll to view the result.", "zh-Hans": "任务已完成，打开 TheAll 查看结果。",
                          "fr": "Votre tâche est terminée. Ouvrez TheAll pour voir le résultat.",
                          "ja": "タスクが完了しました。TheAll を開いて結果を確認できます。", "ko": "작업이 완료되었습니다. TheAll에서 결과를 확인하세요."]
        let test = ["en": "TheAll notifications are working.", "zh-Hans": "TheAll 提醒已连接。", "fr": "Les notifications TheAll fonctionnent.",
                    "ja": "TheAll の通知が有効です。", "ko": "TheAll 알림이 연결되었습니다."]
        var payload: [String: Any] = ["version": 1, "id": eventID.uuidString, "type": chatID == nil ? "test" : "completed",
            "title": "TheAll", "body": (chatID == nil ? test : completion)[language] ?? (chatID == nil ? test : completion)["en"]!,
            "url": chatID.map { "/?chat=" + $0.uuidString } ?? "/"]
        if let chatID { payload["chatId"] = chatID.uuidString }
        return try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
    }
}
