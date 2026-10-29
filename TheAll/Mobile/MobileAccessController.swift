import AppKit
import Foundation
import Observation

@Observable
final class MobileAccessController {
    enum Entry: String, CaseIterable { case preview, lan, relay }
    enum LANMode: String, CaseIterable { case quick, encrypted }
    private(set) var isEnabled = false
    private(set) var isListening = false
    private(set) var error: String?
    private(set) var pairingURL: String?
    private(set) var pairingExpires: Date?
    private(set) var pairingEntry: Entry?
    private(set) var devices: [MobilePairingStore.Device] = []
    private(set) var pairedDevice: MobilePairingStore.Device?
    private(set) var onlineDeviceIDs: Set<UUID> = []
    private(set) var invitationAccess = MobilePairingStore.Access()
    var shareWorkspaces: [Workspace] { registry.workspaces.workspaces }
    private(set) var relayConnected = false
    private(set) var relayError: String?
    private(set) var publicKey = ""
    private(set) var isLANListening = false
    private(set) var lanURL: String?
    private(set) var lanError: String?
    private(set) var lanAddresses: [MobileLANAddress] = []
    private(set) var lanCertificateName = ""
    private(set) var lanCertificateFingerprint = ""
    var useRelay: Bool
    var publicURL: String
    private(set) var useLAN: Bool
    private(set) var lanAddress: String
    private(set) var lanMode: LANMode
    private(set) var isPreparingLANInvitation = false
    let port: UInt16
    let lanPort: UInt16
    var localURL: String { "http://127.0.0.1:\(port)" }
    var canExportLANCertificate: Bool { lanMaterial != nil }
    @ObservationIgnored private let registry: AIChatSessionRegistry
    @ObservationIgnored private let pairing: MobilePairingStore
    @ObservationIgnored private let server = MobileHTTPServer()
    @ObservationIgnored private let lanServer = MobileHTTPServer()
    @ObservationIgnored private let relay = MobileRelayClient()
    @ObservationIgnored private let relayIdentity: MobileRelayIdentity
    @ObservationIgnored private let lanIdentity: MobileLANIdentity
    @ObservationIgnored private let listAddresses: () -> [MobileLANAddress]
    @ObservationIgnored private var nextLANRenewal = Date.distantFuture
    @ObservationIgnored private var lanMaterial: MobileLANIdentity.Material?
    @ObservationIgnored private var pendingLANInvitation: MobilePairingStore.Access?
    @ObservationIgnored private let notifications: MobileNotificationService
    @ObservationIgnored private let api: MobileChatAPI
    @ObservationIgnored private lazy var events: MobileEventHub = {
        let hub = MobileEventHub(registry: registry, bootID: api.bootID)
        hub.onPresence = { [weak self] in self?.onlineDeviceIDs = $0 }
        return hub
    }()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var configuredOrigin: String?
    @ObservationIgnored private var enableGeneration = UUID()
    @ObservationIgnored private var lanGeneration = UUID()
    @ObservationIgnored private var relayGeneration = UUID()
    @ObservationIgnored private var addressTimer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var termination: NSObjectProtocol?

    init(registry: AIChatSessionRegistry, pairing: MobilePairingStore = MobilePairingStore(),
         defaults: UserDefaults = .standard, port: UInt16? = nil, lanPort: UInt16? = nil,
         relayIdentity: MobileRelayIdentity = MobileRelayIdentity(),
         lanIdentity: MobileLANIdentity = MobileLANIdentity(),
         notifications: MobileNotificationService = MobileNotificationService(),
         listAddresses: @escaping () -> [MobileLANAddress] = MobileLANAddress.available) {
        self.registry = registry; self.pairing = pairing; self.defaults = defaults; self.notifications = notifications
        self.relayIdentity = relayIdentity; self.lanIdentity = lanIdentity; self.listAddresses = listAddresses
        #if DEBUG
        self.port = port ?? 49832; self.lanPort = lanPort ?? 49834
        #else
        self.port = port ?? 49831; self.lanPort = lanPort ?? 49833
        #endif
        publicURL = defaults.string(forKey: "theall.mobile.publicURL") ?? ""
        useRelay = defaults.object(forKey: "theall.mobile.useRelay") as? Bool ?? true
        useLAN = defaults.bool(forKey: "theall.mobile.useLAN")
        lanAddress = defaults.string(forKey: "theall.mobile.lanAddress") ?? ""
        // Existing enabled HTTPS installations retain their transport until the
        // user chooses quick connect. New installations default to QR-only setup.
        lanMode = defaults.string(forKey: "theall.mobile.lanMode").flatMap(LANMode.init(rawValue:)) ??
            (defaults.bool(forKey: "theall.mobile.useLAN") ? .encrypted : .quick)
        api = MobileChatAPI(registry: registry)
        devices = pairing.devices
        notifications.isAuthorized = { [weak self] record, chatID in
            guard let self, self.isEnabled,
                  let device = self.pairing.devices.first(where: { $0.id == record.deviceID }),
                  device.expiresAt > Date(), device.origin == record.origin, self.scopeExists(device),
                  Entry.allCases.contains(where: { self.origins(for: $0).contains(record.origin) }) else { return false }
            guard let chatID else { return true }
            guard let owner = self.shareWorkspaces.first(where: { workspace in
                workspace.tabs.contains { $0.layout.allTerminalIds().contains(chatID) }
            }) else { return false }
            return device.access.allows(workspaceID: owner.id)
        }
        registry.onTurnCompleted = { [weak self] chatID, eventID in
            guard let self, self.isEnabled else { return }
            let epoch = self.enableGeneration
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.enableGeneration == epoch else { return }
                self.notifications.completed(chatID: chatID, eventID: eventID)
            }
        }
        server.handler = { [weak self] request in
            await self?.handle(request, via: .preview) ?? .error("Unavailable", status: 503)
        }
        lanServer.handler = { [weak self] request in
            await self?.handle(request, via: .lan) ?? .error("Unavailable", status: 503)
        }
        relay.handler = { [weak self] request in
            await self?.handle(request, via: .relay) ?? .error("Unavailable", status: 503)
        }
        server.eventHandler = { [weak self] request, channel in
            guard let self else { return .error("Unavailable", status: 503) }
            return self.openEvents(request, channel: channel, via: .preview)
        }
        lanServer.eventHandler = { [weak self] request, channel in
            guard let self else { return .error("Unavailable", status: 503) }
            return self.openEvents(request, channel: channel, via: .lan)
        }
        relay.eventHandler = { [weak self] request, channel in
            guard let self else { return .error("Unavailable", status: 503) }
            return self.openEvents(request, channel: channel, via: .relay)
        }
        server.onState = { [weak self] ready, error in
            guard let self, self.isEnabled else { return }
            self.isListening = ready; self.error = error
        }
        lanServer.onState = { [weak self] ready, error in
            guard let self, self.isEnabled, self.useLAN else { return }
            self.isLANListening = ready
            if ready, let access = self.pendingLANInvitation {
                self.pendingLANInvitation = nil; self.isPreparingLANInvitation = false
                self.createInvitation(via: .lan, access: access)
            } else if !ready {
                self.pendingLANInvitation = nil; self.isPreparingLANInvitation = false
            }
            if !ready, let error { self.stopLAN(); self.lanError = error }
        }
        relay.onState = { [weak self] connected, error in
            guard let self, self.isEnabled, self.useRelay else { return }
            // A reconnect is a new authorization epoch. Requests waiting for
            // backend readiness/model changes must not execute after link loss.
            if self.relayConnected && !connected { self.relayGeneration = UUID(); self.notifications.cancelPending() }
            self.relayConnected = connected; self.relayError = error
            if !connected { self.events.validate() }
        }
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.notifications.cancelPending(); self?.registry.flush(); self?.server.stop(); self?.lanServer.stop(); self?.relay.stop()
            }
        refreshLANAddresses()
    }

    func restoreEnabledState() {
        guard !didRestore else { return }; didRestore = true
        if defaults.bool(forKey: "theall.mobile.enabled") { enable() }
    }
    func enable() {
        guard !isEnabled else { return }
        error = nil; enableGeneration = UUID(); isEnabled = true
        defaults.set(true, forKey: "theall.mobile.enabled")
        do { try server.start(port: port) }
        catch { self.error = L10n.string("mobile.error.listen") }
        startRelay()
        refreshLANAddresses()
        addressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshLANAddresses() }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "TheAll mobile access")
    }
    func disable() {
        isEnabled = false; isListening = false; enableGeneration = UUID()
        notifications.cancelPending()
        defaults.set(false, forKey: "theall.mobile.enabled")
        cancelInvitation()
        addressTimer?.invalidate(); addressTimer = nil
        server.stop(); stopLAN(); stopRelay()
        events.validate()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    func setLANEnabled(_ value: Bool) {
        useLAN = value; defaults.set(value, forKey: "theall.mobile.useLAN")
        if !value { stopLAN() } else if isEnabled { refreshLANAddresses(); if lanURL == nil { startLAN() } }
    }
    func setLANMode(_ value: LANMode) {
        guard value != lanMode else { return }
        stopLAN(); lanMode = value; defaults.set(value.rawValue, forKey: "theall.mobile.lanMode")
        if isEnabled, useLAN { startLAN() }
    }
    /// One action enables the local listener and creates a QR as soon as ready.
    /// Choosing this action explicitly selects certificate-free LAN access.
    func connectPhone(access: MobilePairingStore.Access = .init()) {
        guard access.workspaceID == nil || shareWorkspaces.contains(where: { $0.id == access.workspaceID }) else {
            error = L10n.string("mobile.error.scope"); return
        }
        cancelInvitation()
        setLANMode(.quick)
        setLANEnabled(true)
        enable()
        refreshLANAddresses()
        guard lanAddresses.contains(where: { $0.address == lanAddress }), lanError == nil else { return }
        if canPair(via: .lan) { createInvitation(via: .lan, access: access) }
        else { pendingLANInvitation = access; isPreparingLANInvitation = true }
    }
    func setRelayEnabled(_ value: Bool) {
        useRelay = value; defaults.set(value, forKey: "theall.mobile.useRelay")
        if isEnabled { startRelay() }
    }
    func selectLANAddress(_ value: String) {
        guard value != lanAddress, lanAddresses.contains(where: { $0.address == value }) else { return }
        stopLAN(); lanAddress = value; defaults.set(value, forKey: "theall.mobile.lanAddress")
        if isEnabled, useLAN { startLAN() }
    }
    func refreshLANAddresses() {
        lanAddresses = listAddresses()
        if lanAddress.isEmpty || (lanMode == .quick && !lanAddresses.contains(where: { $0.address == lanAddress })) {
            if let address = MobileLANAddress.preferred(in: lanAddresses) {
                if lanAddress != address.address { stopLAN(); lanAddress = address.address }
            }
        }
        guard isEnabled, useLAN else { return }
        if !lanAddresses.contains(where: { $0.address == lanAddress }) {
            stopLAN(); lanError = L10n.string("mobile.lan.unavailable")
        } else if lanURL == nil || Date() >= nextLANRenewal { startLAN() }
    }
    private func startLAN() {
        guard isEnabled, useLAN else { return }
        stopLAN(); lanError = nil
        guard lanAddresses.contains(where: { $0.address == lanAddress }) else {
            lanError = L10n.string("mobile.lan.unavailable"); return
        }
        do {
            if lanMode == .quick {
                // No certificate or private-key preparation is needed for quick pairing.
                nextLANRenewal = .distantFuture
                try lanServer.start(port: lanPort, host: lanAddress, localNetworkOnly: true, allowLANHTTP: true)
                lanURL = "http://\(lanAddress):\(lanPort)"
            } else {
                let material = try lanIdentity.prepare(address: lanAddress)
                lanMaterial = material
                // Renew long-running listeners well before the 90-day leaf expires.
                nextLANRenewal = min(Date().addingTimeInterval(30 * 86400),
                                     max(Date().addingTimeInterval(60), material.expiresAt.addingTimeInterval(-86400)))
                lanCertificateName = material.authorityName; lanCertificateFingerprint = material.fingerprint
                try lanServer.start(port: lanPort, host: lanAddress, identity: material.identity, localNetworkOnly: true)
                lanURL = "https://\(lanAddress):\(lanPort)"
            }
            defaults.set(lanAddress, forKey: "theall.mobile.lanAddress")
        } catch { lanError = L10n.string(lanMode == .quick ? "mobile.error.listen" : "mobile.lan.failed") }
    }
    private func stopLAN() {
        notifications.cancelPending()
        lanGeneration = UUID(); lanServer.stop(); isLANListening = false; lanURL = nil
        pendingLANInvitation = nil; isPreparingLANInvitation = false
        if pairingEntry == .lan { cancelInvitation() }
        events.validate()
    }
    private func startRelay() {
        stopRelay(); relayError = nil
        defaults.set(useRelay, forKey: "theall.mobile.useRelay")
        defaults.set(publicURL, forKey: "theall.mobile.publicURL")
        guard !publicURL.isEmpty else { return } // Loopback preview works without a relay.
        do {
            configuredOrigin = try Self.origin(publicURL)
            publicURL = configuredOrigin!
            if useRelay { try relay.start(origin: publicURL, identity: relayIdentity) }
        } catch { configuredOrigin = nil; relayError = L10n.string("mobile.error.url") }
    }
    private func stopRelay() {
        notifications.cancelPending()
        relayGeneration = UUID(); relay.stop(); relayConnected = false; configuredOrigin = nil
        if pairingEntry == .relay { cancelInvitation() }
        events.validate()
    }
    func canPair(via entry: Entry) -> Bool {
        guard isEnabled else { return false }
        switch entry {
        case .preview: return isListening
        case .lan: return isLANListening
        case .relay: return useRelay && relayConnected
        }
    }
    func createInvitation(via entry: Entry? = nil, access: MobilePairingStore.Access = .init()) {
        pendingLANInvitation = nil; isPreparingLANInvitation = false
        let entry = entry ?? (canPair(via: .lan) ? .lan : canPair(via: .relay) ? .relay : .preview)
        guard canPair(via: entry), let origin = origins(for: entry).first else { return }
        guard access.workspaceID == nil || shareWorkspaces.contains(where: { $0.id == access.workspaceID }) else {
            error = L10n.string("mobile.error.scope"); return
        }
        do {
            pairingURL = origin + "/#pair=" + (try pairing.invite(origin: origin, access: access))
            pairingExpires = Date().addingTimeInterval(300); pairingEntry = entry
            invitationAccess = access; pairedDevice = nil
            error = nil
        } catch { self.error = L10n.string("mobile.error.storage") }
    }
    private func cancelInvitation() {
        pairing.cancelInvitation(); pairingURL = nil; pairingExpires = nil; pairingEntry = nil
    }
    /// Export only public trust material. The CA private key never leaves the Mac.
    func certificateExport(iOS: Bool) -> Data? {
        guard let lanMaterial else { return nil }
        return iOS ? lanMaterial.mobileConfiguration : lanMaterial.authorityDER
    }
    func prepareIdentity() {
        do { publicKey = try relayIdentity.key().publicKey.rawRepresentation.base64EncodedString() }
        catch { self.error = L10n.string("mobile.error.identity") }
    }
    func revoke(_ id: UUID) {
        do {
            try pairing.revoke(id); devices = pairing.devices; error = nil
            if pairedDevice?.id == id { pairedDevice = nil }
            events.revoke(id)
            try notifications.unsubscribe(deviceID: id)
        }
        catch { self.error = L10n.string("mobile.error.storage") }
    }
    private func origins(for entry: Entry) -> [String] {
        guard isEnabled else { return [] }
        switch entry {
        case .preview:
            // Optional pre-existing HTTPS reverse proxy reaches loopback only.
            return [localURL, "http://localhost:\(port)"] + ((!useRelay ? configuredOrigin : nil).map { [$0] } ?? [])
        case .lan: return useLAN && isLANListening ? lanURL.map { [$0] } ?? [] : []
        case .relay: return useRelay && relayConnected ? configuredOrigin.map { [$0] } ?? [] : []
        }
    }
    private func generation(for entry: Entry) -> UUID {
        switch entry { case .preview: return enableGeneration; case .lan: return lanGeneration; case .relay: return relayGeneration }
    }

    @MainActor
    private func openEvents(_ request: MobileHTTPRequest, channel: MobileEventChannel, via entry: Entry) -> MobileHTTPResponse? {
        guard isEnabled, canPair(via: entry) else { return .error(L10n.string("mobile.error.disabled"), status: 503) }
        guard request.method == "GET", request.target == "/api/events",
              let host = request.headers["host"]?.lowercased(),
              let origin = origins(for: entry).first(where: { $0.components(separatedBy: "://").last == host }),
              request.headers["origin"] == origin, request.headers["sec-fetch-site"] != "cross-site"
        else { return .error(L10n.string("mobile.error.origin"), status: 403) }
        guard let token = sessionToken(request, origin: origin, via: entry), let device = pairing.authenticate(token, origin: origin), scopeExists(device) else {
            return .error(L10n.string("mobile.error.authorization"), status: 401)
        }
        let current = generation(for: entry), enabled = enableGeneration
        return events.connect(channel, device: device) { [weak self] in
            guard let self else { return false }
            return self.isEnabled && self.enableGeneration == enabled && self.generation(for: entry) == current &&
                self.origins(for: entry).contains(origin) && self.scopeExists(device) && self.pairing.authenticate(token, origin: origin) != nil
        }
    }

    private func scopeExists(_ device: MobilePairingStore.Device) -> Bool {
        device.access.workspaceID == nil || shareWorkspaces.contains(where: { $0.id == device.access.workspaceID })
    }

    static func origin(_ value: String) throws -> String {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.scheme == "https" || (components.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)),
              components.port == nil || (1...65535).contains(components.port!)
        else { throw URLError(.badURL) }
        return components.scheme! + "://" + host + (components.port.flatMap { ($0 == 443 && components.scheme == "https") || ($0 == 80 && components.scheme == "http") ? nil : ":\($0)" } ?? "")
    }

    @MainActor
    func handle(_ request: MobileHTTPRequest, via entry: Entry = .preview) async -> MobileHTTPResponse {
        guard isEnabled else { return .error(L10n.string("mobile.error.disabled"), status: 503) }
        let origins = origins(for: entry)
        guard !origins.isEmpty else { return .error(L10n.string("mobile.error.disabled"), status: 503) }
        guard let host = request.headers["host"]?.lowercased(),
              let origin = origins.first(where: { $0.components(separatedBy: "://").last == host }),
              request.headers["sec-fetch-site"] != "cross-site",
              request.headers["origin"].map({ $0 == origin }) ?? true
        else { return .error(L10n.string("mobile.error.origin"), status: 403) }
        if request.method == "POST" {
            guard request.headers["origin"] == origin,
                  request.headers["x-theall-client"] == "1",
                  request.headers["content-type"]?.split(separator: ";").first == "application/json"
            else { return .error(L10n.string("mobile.error.origin"), status: 403) }
        }
        let secure = origin.hasPrefix("https://")
        if request.method == "POST", request.path == "/api/pair" {
            do {
                guard let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                      let token = body["token"] as? String, let name = body["deviceName"] as? String
                else { return .error(L10n.string("mobile.error.request"), status: 400) }
                let (accessToken, device) = try pairing.pair(token: token, name: name, origin: origin)
                devices = pairing.devices; pairingURL = nil; pairingExpires = nil; pairingEntry = nil
                pairedDevice = device
                var response = MobileHTTPResponse.json(["deviceName": device.name, "bootID": api.bootID, "access": device.access.json])
                response.headers["Set-Cookie"] = cookie(accessToken, secure: secure, via: entry)
                return response
            } catch MobilePairingStore.PairingError.limited { return .error(L10n.string("mobile.error.rate"), status: 429) }
            catch { return .error(L10n.string("mobile.error.pair"), status: 401) }
        }
        if !request.path.hasPrefix("/api/") { return staticFile(request) }
        guard let token = sessionToken(request, origin: origin, via: entry), let device = pairing.authenticate(token, origin: origin) else {
            return .error(L10n.string("mobile.error.authorization"), status: 401)
        }
        if request.path == "/api/session", request.method == "GET" {
            guard scopeExists(device) else { return .error(L10n.string("mobile.error.scope"), status: 403) }
            return .json(["deviceName": device.name, "bootID": api.bootID, "access": device.access.json])
        }
        if request.path == "/api/logout", request.method == "POST" {
            do { try pairing.revoke(device.id); devices = pairing.devices; events.revoke(device.id); try notifications.unsubscribe(deviceID: device.id) }
            catch { return .error(L10n.string("mobile.error.storage"), status: 500) }
            var response = MobileHTTPResponse.json(["ok": true])
            response.headers["Set-Cookie"] = cookie("", secure: secure, via: entry, maxAge: 0)
            return response
        }
        if request.path == "/api/notifications" || request.path.hasPrefix("/api/notifications/") {
            guard scopeExists(device) else { return .error(L10n.string("mobile.error.scope"), status: 403) }
            return await notificationResponse(request, device: device, origin: origin)
        }
        let generation = generation(for: entry)
        let enabledGeneration = enableGeneration
        return await api.handle(request, device: device, stillAuthorized: { [weak self] in
            guard let self else { return false }
            return self.isEnabled && self.enableGeneration == enabledGeneration && self.generation(for: entry) == generation &&
                self.origins(for: entry).contains(origin) && self.pairing.authenticate(token, origin: origin) != nil
        })
    }

    @MainActor
    private func notificationResponse(_ request: MobileHTTPRequest, device: MobilePairingStore.Device, origin: String) async -> MobileHTTPResponse {
        do {
            if request.method == "GET", request.path == "/api/notifications" {
                return .json(try notifications.state(deviceID: device.id, origin: origin))
            }
            guard request.method == "POST", ["/api/notifications/subscribe", "/api/notifications/unsubscribe", "/api/notifications/test"].contains(request.path)
            else { return .error("Not found", status: 404) }
            guard MobilePushStore.secureOrigin(origin) else {
                return .json(["available": false, "enabled": false, "reason": "https_required"], status: 400)
            }
            guard request.body.count <= 16384, let body = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            else { return .error(L10n.string("mobile.error.request"), status: 400) }
            switch request.path {
            case "/api/notifications/subscribe":
                try notifications.subscribe(deviceID: device.id, origin: origin, body: body)
                return .json(["enabled": true])
            case "/api/notifications/unsubscribe":
                try notifications.unsubscribe(deviceID: device.id)
                return .json(["enabled": false])
            default:
                try await notifications.test(deviceID: device.id, origin: origin)
                return .json(["ok": true])
            }
        } catch let error as MobileWebPush.PushError {
            let status: Int
            switch error { case .storage: status = 500; case .unavailable: status = 503; default: status = 400 }
            return .error(error.localizedDescription, status: status)
        } catch is CancellationError { return .error(L10n.string("mobile.error.authorization"), status: 401) }
        catch { return .error(L10n.string("mobile.error.request"), status: 400) }
    }

    private func cookieName(secure: Bool, via entry: Entry) -> String {
        // Cookies are shared across ports. Never overwrite a pre-existing Secure
        // HTTPS cookie from the certificate-free listener on the same IP.
        entry == .lan && !secure ? "TheAllLANSession" : "TheAllMobileSession"
    }
    private func sessionToken(_ request: MobileHTTPRequest, origin: String, via entry: Entry) -> String? {
        let prefix = cookieName(secure: origin.hasPrefix("https://"), via: entry) + "="
        let values = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
        guard values.count == 1 else { return nil }
        return String(values[0].dropFirst(prefix.count))
    }
    private func cookie(_ token: String, secure: Bool, via entry: Entry, maxAge: Int = 30 * 86400) -> String {
        cookieName(secure: secure, via: entry) + "=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(maxAge)" + (secure ? "; Secure" : "")
    }
    private func staticFile(_ request: MobileHTTPRequest) -> MobileHTTPResponse {
        guard request.method == "GET" else { return .error("Not found", status: 404) }
        let path = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        let types = ["html": "text/html; charset=utf-8", "js": "application/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                     "webmanifest": "application/manifest+json", "png": "image/png", "svg": "image/svg+xml"]
        // Exact allowlist rather than exposing the bundle's arbitrary filesystem.
        let allowed: Set<String> = ["index.html", "app.js", "core.js", "live.js", "photos.js", "files.js", "i18n.js", "notifications.js", "timing.js", "effort.js", "styles.css", "manifest.webmanifest", "sw.js",
                                   "icons/icon-192.png", "icons/icon-512.png", "icons/apple-touch-icon.png"]
        guard allowed.contains(path), let root = Bundle.main.url(forResource: "MobileWeb", withExtension: "bundle"),
              let type = types[URL(fileURLWithPath: path).pathExtension],
              let data = try? Data(contentsOf: root.appendingPathComponent(path))
        else { return .error("Not found", status: 404) }
        return MobileHTTPResponse(status: 200, headers: ["Content-Type": type], body: data)
    }
    deinit {
        addressTimer?.invalidate()
        if let termination { NotificationCenter.default.removeObserver(termination) }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
