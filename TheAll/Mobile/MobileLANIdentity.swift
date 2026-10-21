import Foundation
import CryptoKit
import Security
import Darwin

/// A private, per-installation LAN authority. Keys never enter the login
/// Keychain: the TLS identity is assembled in memory with public Security APIs.
final class MobileLANIdentity {
    struct Material {
        let identity: sec_identity_t
        let certificate: SecCertificate
        let authorityCertificate: SecCertificate
        let authorityDER: Data
        let fingerprint: String
        let authorityName: String
        let mobileConfiguration: Data
        let expiresAt: Date
    }

    enum IdentityError: LocalizedError {
        case invalidAddress, invalidStore, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidAddress: return "Choose a private IPv4 address for the local connection."
            case .invalidStore: return "The saved local certificate cannot be read or verified. It has not been replaced."
            case .unavailable: return "The local connection certificate could not be prepared."
            }
        }
    }

    private struct Record: Codable {
        let version: Int
        let id: UUID
        let createdAt: Int64
        let key: Data
        let certificate: Data
    }
    private let file: URL
    private let now: () -> Date
    private static let rootLifetime: TimeInterval = 10 * 365 * 86400
    private static let leafLifetime: TimeInterval = 90 * 86400
    private static let signatureAlgorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))

    init(file: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("MobileAccess/LANIdentity.json"), now: @escaping () -> Date = Date.init) {
        self.file = file
        self.now = now
    }

    func prepare(address: String) throws -> Material {
        let ip = try Self.privateIPv4(address)
        let record = try loadOrCreate()
        let authorityKey = try P256.Signing.PrivateKey(rawRepresentation: record.key)
        let authorityName = "TheAll Local " + record.id.uuidString.prefix(8)
        let subject = Self.name(authorityName)
        let authority = SecCertificateCreateWithData(nil, record.certificate as CFData)!
        let leafKey = P256.Signing.PrivateKey()
        let issuedAt = now().addingTimeInterval(-300)
        let expiry = min(now().addingTimeInterval(Self.leafLifetime),
                         Date(timeIntervalSince1970: TimeInterval(record.createdAt)).addingTimeInterval(Self.rootLifetime))
        let authorityKeyID = Self.keyIdentifier(authorityKey.publicKey)
        let leafExtensions = [
            Self.extensionValue([2, 5, 29, 19], critical: true, value: DER.sequence(Data())),
            Self.extensionValue([2, 5, 29, 15], critical: true, value: DER.bitString(Data([0x80]), unusedBits: 7)),
            Self.extensionValue([2, 5, 29, 37], value: DER.sequence(DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))),
            Self.extensionValue([2, 5, 29, 17], value: DER.sequence(DER.value(0x87, ip))),
            Self.extensionValue([2, 5, 29, 14], value: DER.value(0x04, Self.keyIdentifier(leafKey.publicKey))),
            Self.extensionValue([2, 5, 29, 35], value: DER.sequence(DER.value(0x80, authorityKeyID)))
        ]
        let leafTBS = Self.tbs(serial: Self.randomSerial(), issuer: subject,
            subject: Self.name("TheAll Local Connection"), publicKey: leafKey.publicKey,
            notBefore: issuedAt, notAfter: expiry, extensions: leafExtensions)
        let leafDER = try Self.sign(leafTBS, with: authorityKey)
        guard let certificate = SecCertificateCreateWithData(nil, leafDER as CFData),
              let privateKey = SecKeyCreateWithData(leafKey.x963Representation as CFData, [
                kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits: 256
              ] as CFDictionary, nil),
              let securityIdentity = SecIdentityCreate(nil, certificate, privateKey),
              let identity = sec_identity_create_with_certificates(securityIdentity, [authority] as CFArray)
        else { throw IdentityError.unavailable }
        let fingerprint = SHA256.hash(data: record.certificate).map { String(format: "%02X", $0) }.joined(separator: ":")
        return Material(identity: identity, certificate: certificate, authorityCertificate: authority,
            authorityDER: record.certificate, fingerprint: fingerprint, authorityName: authorityName,
            mobileConfiguration: try Self.profile(record: record, name: authorityName), expiresAt: expiry)
    }

    private func loadOrCreate() throws -> Record {
        let folder = file.deletingLastPathComponent()
        var info = stat()
        if lstat(folder.path, &info) != 0 {
            guard errno == ENOENT else { throw IdentityError.invalidStore }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), chmod(folder.path, 0o700) == 0 else { throw IdentityError.invalidStore }
        if let record = try readRecord() { return record }
        let key = P256.Signing.PrivateKey()
        let id = UUID()
        let createdAt = Int64(now().timeIntervalSince1970.rounded(.down))
        let certificate = try Self.sign(Self.rootTBS(id: id, createdAt: createdAt, publicKey: key.publicKey), with: key)
        let record = Record(version: 1, id: id, createdAt: createdAt, key: key.rawRepresentation, certificate: certificate)
        let data = try JSONEncoder().encode(record)
        // Publish a complete, fsync'd record with an exclusive atomic rename. An
        // interrupted write or a second process cannot replace an existing CA.
        let temporary = folder.appendingPathComponent(".LANIdentity-" + UUID().uuidString + ".tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw IdentityError.invalidStore }
        defer { close(descriptor); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw IdentityError.invalidStore }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw IdentityError.invalidStore }
        if renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, file.path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST, let existing = try readRecord() else { throw IdentityError.invalidStore }
            return existing
        }
        let folderDescriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if folderDescriptor >= 0 { _ = fsync(folderDescriptor); close(folderDescriptor) }
        return try validated(record)
    }

    private func readRecord() throws -> Record? {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT {
                var info = stat()
                guard lstat(file.path, &info) != 0, errno == ENOENT else { throw IdentityError.invalidStore }
                return nil
            }
            throw IdentityError.invalidStore
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_size > 0, info.st_size <= 16_384,
              fchmod(descriptor, 0o600) == 0 else { throw IdentityError.invalidStore }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { pointer -> Int in
            var offset = 0
            while offset < pointer.count {
                let readCount = read(descriptor, pointer.baseAddress!.advanced(by: offset), pointer.count - offset)
                if readCount < 0, errno == EINTR { continue }
                if readCount <= 0 { return -1 }
                offset += readCount
            }
            return offset
        }
        guard count == bytes.count else { throw IdentityError.invalidStore }
        do { return try validated(JSONDecoder().decode(Record.self, from: Data(bytes))) }
        catch { throw IdentityError.invalidStore }
    }

    private func validated(_ record: Record) throws -> Record {
        guard record.version == 1, record.key.count == 32,
              TimeInterval(record.createdAt) <= now().timeIntervalSince1970 + 300,
              TimeInterval(record.createdAt) + Self.rootLifetime > now().timeIntervalSince1970,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: record.key),
              SecCertificateCreateWithData(nil, record.certificate as CFData) != nil
        else { throw IdentityError.invalidStore }
        // Reconstruct the exact expected public certificate fields and verify
        // its signature, so a mismatched/non-CA/modified record fails closed.
        let tbs = Self.rootTBS(id: record.id, createdAt: record.createdAt, publicKey: key.publicKey)
        var outer = DER.Reader(record.certificate)
        guard let certificate = outer.take(0x30), outer.isEmpty else { throw IdentityError.invalidStore }
        var fields = DER.Reader(certificate)
        guard fields.takeEncoded(0x30) == tbs,
              fields.takeEncoded(0x30) == Self.signatureAlgorithm,
              let signatureBits = fields.take(0x03), signatureBits.first == 0, fields.isEmpty,
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureBits.dropFirst()),
              key.publicKey.isValidSignature(signature, for: tbs)
        else { throw IdentityError.invalidStore }
        return record
    }

    private static func privateIPv4(_ address: String) throws -> Data {
        let pieces = address.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { throw IdentityError.invalidAddress }
        let octets = pieces.compactMap { piece -> UInt8? in
            guard let value = UInt8(piece), String(value) == piece else { return nil }
            return value
        }
        guard octets.count == 4,
              octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
              (octets[0] == 192 && octets[1] == 168) || octets[0] == 127
        else { throw IdentityError.invalidAddress }
        return Data(octets)
    }

    private static func rootTBS(id: UUID, createdAt: Int64, publicKey: P256.Signing.PublicKey) -> Data {
        let subject = name("TheAll Local " + id.uuidString.prefix(8))
        let date = Date(timeIntervalSince1970: TimeInterval(createdAt))
        let serial = Data(SHA256.hash(data: Data(id.uuidString.utf8)).prefix(16))
        return tbs(serial: serial, issuer: subject, subject: subject, publicKey: publicKey,
            notBefore: date.addingTimeInterval(-300), notAfter: date.addingTimeInterval(rootLifetime), extensions: [
                extensionValue([2, 5, 29, 19], critical: true,
                               value: DER.sequence(DER.value(0x01, Data([0xff])) + DER.integer(Data([0])))),
                extensionValue([2, 5, 29, 15], critical: true, value: DER.bitString(Data([0x06]), unusedBits: 1)),
                extensionValue([2, 5, 29, 14], value: DER.value(0x04, keyIdentifier(publicKey)))
            ])
    }

    private static func tbs(serial: Data, issuer: Data, subject: Data, publicKey: P256.Signing.PublicKey,
                            notBefore: Date, notAfter: Date, extensions: [Data]) -> Data {
        let publicKeyAlgorithm = DER.sequence(DER.oid([1, 2, 840, 10045, 2, 1]) + DER.oid([1, 2, 840, 10045, 3, 1, 7]))
        let spki = DER.sequence(publicKeyAlgorithm + DER.bitString(publicKey.x963Representation))
        return DER.sequence(DER.value(0xa0, DER.integer(Data([2]))) + DER.integer(serial) + signatureAlgorithm + issuer
            + DER.sequence(DER.time(notBefore) + DER.time(notAfter)) + subject + spki
            + DER.value(0xa3, DER.sequence(extensions.reduce(Data(), +))))
    }

    private static func name(_ value: String) -> Data {
        DER.sequence(DER.value(0x31, DER.sequence(DER.oid([2, 5, 4, 3]) + DER.value(0x0c, Data(value.utf8)))))
    }
    private static func extensionValue(_ oid: [UInt64], critical: Bool = false, value: Data) -> Data {
        DER.sequence(DER.oid(oid) + (critical ? DER.value(0x01, Data([0xff])) : Data()) + DER.value(0x04, value))
    }
    private static func keyIdentifier(_ key: P256.Signing.PublicKey) -> Data {
        // SHA-1 is the RFC 5280 identifier format, not a certificate signature.
        Data(Insecure.SHA1.hash(data: key.x963Representation))
    }
    private static func randomSerial() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // UUID randomness is a fallback only if the system random call fails.
        if bytes.allSatisfy({ $0 == 0 }) { return Data(SHA256.hash(data: Data(UUID().uuidString.utf8)).prefix(16)) }
        return Data(bytes)
    }
    private static func sign(_ tbs: Data, with key: P256.Signing.PrivateKey) throws -> Data {
        DER.sequence(tbs + signatureAlgorithm + DER.bitString(try key.signature(for: tbs).derRepresentation))
    }

    private static func profile(record: Record, name: String) throws -> Data {
        let identifier = "app.theall.local." + record.id.uuidString.lowercased()
        let certificate: [String: Any] = ["PayloadType": "com.apple.security.root", "PayloadVersion": 1,
            "PayloadIdentifier": identifier + ".certificate", "PayloadUUID": record.id.uuidString,
            "PayloadDisplayName": name, "PayloadDescription": "TheAll local Mac connection certificate.",
            "PayloadCertificateFileName": "TheAll-Local-CA.cer", "PayloadContent": record.certificate]
        let profile: [String: Any] = ["PayloadType": "Configuration", "PayloadVersion": 1,
            "PayloadIdentifier": identifier, "PayloadUUID": UUID().uuidString, "PayloadDisplayName": name,
            "PayloadDescription": "Enables an encrypted connection to this Mac. After installation, enable full trust in Settings > General > About > Certificate Trust Settings.",
            "PayloadContent": [certificate]]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

/// Only the DER shapes required for fixed P-256 CA and server certificates.
private enum DER {
    static func value(_ tag: UInt8, _ contents: Data) -> Data {
        var length = contents.count
        var encodedLength = Data()
        if length < 128 { encodedLength.append(UInt8(length)) }
        else {
            while length > 0 { encodedLength.insert(UInt8(length & 0xff), at: 0); length >>= 8 }
            encodedLength.insert(0x80 | UInt8(encodedLength.count), at: 0)
        }
        return Data([tag]) + encodedLength + contents
    }
    static func sequence(_ contents: Data) -> Data { value(0x30, contents) }
    static func integer(_ bytes: Data) -> Data {
        var bytes = Data(bytes.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes.append(0) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return value(0x02, bytes)
    }
    static func bitString(_ bytes: Data, unusedBits: UInt8 = 0) -> Data { value(0x03, Data([unusedBits]) + bytes) }
    static func oid(_ components: [UInt64]) -> Data {
        var bytes = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var number = component
            var encoded = [UInt8(number & 0x7f)]
            number >>= 7
            while number > 0 { encoded.insert(UInt8(number & 0x7f) | 0x80, at: 0); number >>= 7 }
            bytes.append(contentsOf: encoded)
        }
        return value(0x06, bytes)
    }
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let general = calendar.component(.year, from: date) >= 2050
        formatter.dateFormat = general ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return value(general ? 0x18 : 0x17, Data(formatter.string(from: date).utf8))
    }
    struct Reader {
        private var bytes: Data
        init(_ data: Data) { bytes = Data(data) }
        var isEmpty: Bool { bytes.isEmpty }
        mutating func take(_ tag: UInt8) -> Data? {
            guard let encoded = takeEncoded(tag) else { return nil }
            let count = encoded[1] & 0x80 == 0 ? 2 : 2 + Int(encoded[1] & 0x7f)
            return Data(encoded.dropFirst(count))
        }
        mutating func takeEncoded(_ tag: UInt8) -> Data? {
            guard bytes.count >= 2, bytes[0] == tag else { return nil }
            var length = Int(bytes[1])
            var header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7f
                guard (1...4).contains(count), bytes.count >= 2 + count, bytes[2] != 0 else { return nil }
                length = 0
                for byte in bytes[2..<(2 + count)] { length = length * 256 + Int(byte) }
                guard length >= 128 else { return nil }
                header += count
            }
            guard length <= bytes.count - header else { return nil }
            let result = Data(bytes.prefix(header + length))
            bytes = Data(bytes.dropFirst(header + length))
            return result
        }
    }
}
