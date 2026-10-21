import Foundation
import CryptoKit
import Security

/// Only hashes of device bearer tokens reach disk. Pairing invitations are
/// single-use, short-lived, and exist only in memory on the Mac.
final class MobilePairingStore {
    /// A nil workspace grants access to all workspaces, including future ones.
    struct Access: Codable, Equatable {
        let workspaceID: UUID?
        let writable: Bool

        init(workspaceID: UUID? = nil, writable: Bool = true) {
            self.workspaceID = workspaceID
            self.writable = writable
        }
        func allows(workspaceID: UUID) -> Bool { self.workspaceID == nil || self.workspaceID == workspaceID }
        var json: [String: Any] { ["workspaceId": workspaceID.map { $0.uuidString as Any } ?? NSNull(), "writable": writable] }
    }

    struct Device: Codable, Identifiable {
        let id: UUID
        let name: String
        let tokenHash: String
        let createdAt: Date
        let expiresAt: Date
        var origin: String? = nil
        var access: Access = Access()

        init(id: UUID, name: String, tokenHash: String, createdAt: Date, expiresAt: Date,
             origin: String? = nil, access: Access = Access()) {
            self.id = id; self.name = name; self.tokenHash = tokenHash
            self.createdAt = createdAt; self.expiresAt = expiresAt
            self.origin = origin; self.access = access
        }
        private enum CodingKeys: String, CodingKey { case id, name, tokenHash, createdAt, expiresAt, origin, access }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(UUID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
            tokenHash = try values.decode(String.self, forKey: .tokenHash)
            createdAt = try values.decode(Date.self, forKey: .createdAt)
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
            origin = try values.decodeIfPresent(String.self, forKey: .origin)
            // Only absence is legacy. A present but invalid grant fails closed.
            access = values.contains(.access) ? try values.decode(Access.self, forKey: .access) : Access()
        }
    }
    private(set) var devices: [Device] = []
    private var invitation: (hash: String, expires: Date, origin: String?, access: Access)?
    private var attempts: [Date] = []
    private let file: URL
    private let now: () -> Date
    private var loadFailed = false

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("MobileAccess/devices.json"), now: @escaping () -> Date = Date.init) {
        self.file = file; self.now = now
        if FileManager.default.fileExists(atPath: file.path) {
            do { devices = try JSONDecoder().decode([Device].self, from: Data(contentsOf: file)) }
            catch { loadFailed = true }
        }
    }

    func invite(origin: String? = nil, access: Access = Access()) throws -> String {
        guard !loadFailed else { throw PairingError.storage }
        let token = try Self.randomToken()
        invitation = (Self.hash(token), now().addingTimeInterval(300), origin, access)
        return token
    }
    func cancelInvitation() { invitation = nil }

    func pair(token: String, name: String, origin: String? = nil) throws -> (String, Device) {
        attempts.removeAll { now().timeIntervalSince($0) > 60 }
        guard attempts.count < 20 else { throw PairingError.limited }
        attempts.append(now())
        guard !loadFailed, token.utf8.count <= 128, let invitation, invitation.expires > now(),
              (invitation.origin == nil || invitation.origin == origin),
              Self.equal(Self.hash(token), invitation.hash) else { throw PairingError.invalid }
        guard devices.filter({ $0.expiresAt > now() }).count < 20 else { throw PairingError.deviceLimit }
        let access = try Self.randomToken()
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let device = Device(id: UUID(), name: clean.isEmpty ? "Phone" : clean, tokenHash: Self.hash(access),
                            createdAt: now(), expiresAt: now().addingTimeInterval(30 * 86400), origin: origin, access: invitation.access)
        let updated = devices.filter { $0.expiresAt > now() } + [device]
        try persist(updated)
        devices = updated
        self.invitation = nil
        return (access, device)
    }

    func authenticate(_ token: String, origin: String? = nil) -> Device? {
        guard !loadFailed, token.utf8.count <= 128 else { return nil }
        let hash = Self.hash(token)
        return devices.first { $0.expiresAt > now() && (origin == nil || $0.origin == nil || $0.origin == origin) && Self.equal(hash, $0.tokenHash) }
    }
    func revoke(_ id: UUID) throws {
        let updated = devices.filter { $0.id != id }
        try persist(updated); devices = updated
    }

    private func persist(_ value: [Device]) throws {
        guard !loadFailed else { throw PairingError.storage }
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func equal(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw PairingError.storage }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    enum PairingError: Error { case invalid, limited, storage, deviceLimit }
}
