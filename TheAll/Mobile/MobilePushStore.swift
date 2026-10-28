import Foundation
import CryptoKit
import Darwin

/// App-owned secrets never enter the login Keychain. Invalid existing material
/// is preserved so an update cannot silently change the VAPID identity.
final class MobilePushStore {
    struct Record: Codable, Equatable {
        let id: UUID
        let deviceID: UUID
        let origin: String
        let language: String
        let subscription: MobileWebPush.Subscription
    }
    private struct Archive: Codable { let version: Int; let records: [Record] }
    let directory: URL
    private var cachedRecords: [Record]?
    static let languages: Set<String> = ["en", "zh-Hans", "fr", "ja", "ko"]

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("MobileAccess")) { self.directory = directory }

    func signingKey() throws -> P256.Signing.PrivateKey {
        do {
            try prepareDirectory()
            let path = directory.appendingPathComponent("notification-vapid.key")
            if let data = try read(path, limit: 32) {
                guard data.count == 32 else { throw MobileWebPush.PushError.storage }
                return try P256.Signing.PrivateKey(rawRepresentation: data)
            }
            let key = P256.Signing.PrivateKey()
            try write(key.rawRepresentation, to: path, exclusive: true)
            guard let data = try read(path, limit: 32), data.count == 32 else { throw MobileWebPush.PushError.storage }
            return try P256.Signing.PrivateKey(rawRepresentation: data)
        } catch { throw MobileWebPush.PushError.storage }
    }

    func records() throws -> [Record] {
        if let cachedRecords { return cachedRecords }
        do {
            let path = directory.appendingPathComponent("notification-subscriptions.json")
            guard let data = try read(path, limit: 131_072) else { cachedRecords = []; return [] }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, archive.records.count <= 20,
                  Set(archive.records.map(\.deviceID)).count == archive.records.count,
                  Set(archive.records.map { $0.subscription.endpoint }).count == archive.records.count
            else { throw MobileWebPush.PushError.storage }
            for record in archive.records {
                guard Self.secureOrigin(record.origin), Self.languages.contains(record.language) else { throw MobileWebPush.PushError.storage }
                try record.subscription.validate()
            }
            cachedRecords = archive.records; return archive.records
        } catch { throw MobileWebPush.PushError.storage }
    }

    func subscribe(deviceID: UUID, origin: String, language: String, subscription: MobileWebPush.Subscription, now: Date = Date()) throws -> Record {
        guard Self.secureOrigin(origin), Self.languages.contains(language) else { throw MobileWebPush.PushError.invalidSubscription }
        try subscription.validate()
        var records = try records()
        // A browser can reuse its PushSubscription after pairing under a narrower
        // grant. Never leave its endpoint attached to the previous wider grant.
        records.removeAll { $0.deviceID == deviceID || $0.subscription.endpoint == subscription.endpoint || $0.subscription.isExpired(at: now) }
        guard records.count < 20 else { throw MobileWebPush.PushError.invalidSubscription }
        let record = Record(id: UUID(), deviceID: deviceID, origin: origin, language: language, subscription: subscription)
        records.append(record); try save(records); return record
    }

    func remove(deviceID: UUID, recordID: UUID? = nil) throws {
        let existing = try records()
        let updated = existing.filter { !($0.deviceID == deviceID && (recordID == nil || $0.id == recordID)) }
        if existing != updated { try save(updated) }
    }

    static func secureOrigin(_ origin: String) -> Bool {
        guard let value = URLComponents(string: origin), let host = value.host,
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              value.path.isEmpty, value.port == nil || (1...65535).contains(value.port!) else { return false }
        return value.scheme == "https" || (value.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host))
    }

    private func save(_ records: [Record]) throws {
        do {
            try prepareDirectory()
            try write(JSONEncoder().encode(Archive(version: 1, records: records)),
                      to: directory.appendingPathComponent("notification-subscriptions.json"), exclusive: false)
            cachedRecords = records
        } catch { throw MobileWebPush.PushError.storage }
    }

    private func prepareDirectory() throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { throw MobileWebPush.PushError.storage }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(directory.path, 0o700) == 0 else { throw MobileWebPush.PushError.storage }
    }

    private func read(_ path: URL, limit: Int) throws -> Data? {
        // Validate the immediate directory before traversing an existing path.
        var folder = stat()
        if lstat(directory.path, &folder) != 0 {
            guard errno == ENOENT else { throw MobileWebPush.PushError.storage }
            return nil
        }
        guard folder.st_mode & S_IFMT == S_IFDIR, folder.st_uid == getuid() else { throw MobileWebPush.PushError.storage }
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            var info = stat()
            if errno == ENOENT, lstat(path.path, &info) != 0, errno == ENOENT { return nil }
            throw MobileWebPush.PushError.storage
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size > 0, info.st_size <= limit, fchmod(descriptor, 0o600) == 0
        else { throw MobileWebPush.PushError.storage }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        try bytes.withUnsafeMutableBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let count = Darwin.read(descriptor, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MobileWebPush.PushError.storage }
                offset += count
            }
        }
        return Data(bytes)
    }

    private func write(_ data: Data, to path: URL, exclusive: Bool) throws {
        // Refuse symlinks/corrupt file types instead of replacing them.
        _ = try read(path, limit: 131_072)
        let temporary = directory.appendingPathComponent(".notification-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MobileWebPush.PushError.storage }
        defer { close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < pointer.count {
                let count = Darwin.write(descriptor, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw MobileWebPush.PushError.storage }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw MobileWebPush.PushError.storage }
        if renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, path.path, exclusive ? UInt32(RENAME_EXCL) : 0) != 0 {
            guard exclusive && errno == EEXIST else { throw MobileWebPush.PushError.storage }
        }
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if folder >= 0 { _ = fsync(folder); close(folder) }
    }
}
