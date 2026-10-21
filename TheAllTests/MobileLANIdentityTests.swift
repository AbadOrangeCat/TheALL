import XCTest
import Security
import CryptoKit
@testable import TheAll

final class MobileLANIdentityTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllLANIdentityTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func trusted(_ material: MobileLANIdentity.Material, host: String,
                         authority: SecCertificate? = nil, date: Date? = nil) throws -> Bool {
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates([material.certificate, material.authorityCertificate] as CFArray,
            SecPolicyCreateSSL(true, host as CFString), &trust), errSecSuccess)
        let value = try XCTUnwrap(trust)
        XCTAssertEqual(SecTrustSetAnchorCertificates(value, [authority ?? material.authorityCertificate] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(value, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetNetworkFetchAllowed(value, false), errSecSuccess)
        if let date { XCTAssertEqual(SecTrustSetVerifyDate(value, date as CFDate), errSecSuccess) }
        return SecTrustEvaluateWithError(value, nil)
    }

    func testCertificateTrustChecksIPAuthorityAndExpiry() throws {
        let folder = try directory()
        let material = try MobileLANIdentity(file: folder.appendingPathComponent("identity.json")).prepare(address: "192.168.1.12")
        XCTAssertTrue(try trusted(material, host: "192.168.1.12"))
        XCTAssertFalse(try trusted(material, host: "192.168.1.13"))
        XCTAssertFalse(try trusted(material, host: "localhost"))
        XCTAssertFalse(try trusted(material, host: "192.168.1.12", date: Date().addingTimeInterval(91 * 86400)))
        let other = try MobileLANIdentity(file: folder.appendingPathComponent("other.json")).prepare(address: "192.168.1.12")
        XCTAssertFalse(try trusted(material, host: "192.168.1.12", authority: other.authorityCertificate))
    }

    func testIdentityContainsLeafAndRejectsMismatchedPrivateKey() throws {
        let material = try MobileLANIdentity(file: directory().appendingPathComponent("identity.json")).prepare(address: "127.0.0.1")
        let identity = try XCTUnwrap(sec_identity_copy_ref(material.identity)).takeRetainedValue()
        var certificate: SecCertificate?
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        XCTAssertEqual(SecIdentityCopyPrivateKey(identity, &key), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(certificate)) as Data,
                       SecCertificateCopyData(material.certificate) as Data)
        let wrongKey = try XCTUnwrap(SecKeyCreateWithData(P256.Signing.PrivateKey().x963Representation as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
             kSecAttrKeySizeInBits: 256] as CFDictionary, nil))
        XCTAssertNil(SecIdentityCreate(nil, material.certificate, wrongKey))
        XCTAssertNotNil(SecIdentityCreate(nil, material.certificate, try XCTUnwrap(key)))
    }

    func testAuthorityPersistsWhileLeafAndAddressCanChange() throws {
        let file = try directory().appendingPathComponent("MobileAccess/LANIdentity.json")
        let first = try MobileLANIdentity(file: file).prepare(address: "10.0.1.2")
        let stored = try Data(contentsOf: file)
        let second = try MobileLANIdentity(file: file).prepare(address: "172.16.1.3")
        XCTAssertEqual(first.authorityDER, second.authorityDER)
        XCTAssertEqual(first.authorityName, second.authorityName)
        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(stored, try Data(contentsOf: file))
        XCTAssertNotEqual(SecCertificateCopyData(first.certificate) as Data, SecCertificateCopyData(second.certificate) as Data)
        XCTAssertTrue(try trusted(second, host: "172.16.1.3"))
        XCTAssertFalse(try trusted(second, host: "10.0.1.2"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCorruptOrMismatchedAuthorityIsPreserved() throws {
        let file = try directory().appendingPathComponent("identity.json")
        let corrupted = Data("{broken}".utf8)
        try corrupted.write(to: file)
        XCTAssertThrowsError(try MobileLANIdentity(file: file).prepare(address: "10.0.0.1"))
        XCTAssertEqual(try Data(contentsOf: file), corrupted)
        try FileManager.default.removeItem(at: file)
        _ = try MobileLANIdentity(file: file).prepare(address: "10.0.0.1")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["key"] = P256.Signing.PrivateKey().rawRepresentation.base64EncodedString()
        let mismatched = try JSONSerialization.data(withJSONObject: record)
        try mismatched.write(to: file)
        XCTAssertThrowsError(try MobileLANIdentity(file: file).prepare(address: "10.0.0.1"))
        XCTAssertEqual(try Data(contentsOf: file), mismatched)
    }

    func testSymlinksIncludingDanglingLinksAreRejected() throws {
        let folder = try directory()
        let missing = folder.appendingPathComponent("missing.json")
        let link = folder.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)
        XCTAssertThrowsError(try MobileLANIdentity(file: link).prepare(address: "10.0.0.1"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let realFolder = folder.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        let directoryLink = folder.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: realFolder)
        XCTAssertThrowsError(try MobileLANIdentity(file: directoryLink.appendingPathComponent("identity.json")).prepare(address: "10.0.0.1"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: realFolder.path), [])
    }

    func testProfileContainsOnlyPublicCertificateAndNoPrivateKey() throws {
        let file = try directory().appendingPathComponent("identity.json")
        let material = try MobileLANIdentity(file: file).prepare(address: "192.168.0.2")
        let profile = try XCTUnwrap(PropertyListSerialization.propertyList(from: material.mobileConfiguration, format: nil) as? [String: Any])
        XCTAssertEqual(profile["PayloadType"] as? String, "Configuration")
        let payloads = try XCTUnwrap(profile["PayloadContent"] as? [[String: Any]])
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0]["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payloads[0]["PayloadContent"] as? Data, material.authorityDER)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let privateKey = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(record["key"] as? String)))
        XCTAssertNil(material.authorityDER.range(of: privateKey))
        XCTAssertNil(material.mobileConfiguration.range(of: privateKey))
        XCTAssertFalse(String(decoding: material.mobileConfiguration, as: UTF8.self).contains(privateKey.base64EncodedString()))
    }

    func testPublicIPv4HostnamesAndNonCanonicalAddressesAreRejectedBeforeWriting() throws {
        let file = try directory().appendingPathComponent("identity.json")
        let identity = MobileLANIdentity(file: file)
        for invalid in ["8.8.8.8", "0.0.0.0", "169.254.1.2", "172.32.0.1", "localhost", "::1", "127.1", "010.0.0.1", "192.168.1.999", "192.168.1.1\n"] {
            XCTAssertThrowsError(try identity.prepare(address: invalid), invalid)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testExpiredAuthorityFailsClosedWithoutReplacement() throws {
        let file = try directory().appendingPathComponent("identity.json")
        let initialDate = Date()
        _ = try MobileLANIdentity(file: file, now: { initialDate }).prepare(address: "10.0.0.1")
        let data = try Data(contentsOf: file)
        XCTAssertThrowsError(try MobileLANIdentity(file: file, now: { initialDate.addingTimeInterval(11 * 365 * 86400) }).prepare(address: "10.0.0.1"))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testConcurrentInitializationPublishesOnlyOneCompleteAuthority() throws {
        let file = try directory().appendingPathComponent("MobileAccess/LANIdentity.json")
        let lock = NSLock()
        var fingerprints: [String] = []
        var failures = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            do {
                let material = try MobileLANIdentity(file: file).prepare(address: "10.0.0.1")
                lock.lock(); fingerprints.append(material.fingerprint); lock.unlock()
            } catch { lock.lock(); failures += 1; lock.unlock() }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(fingerprints.count, 8)
        XCTAssertEqual(Set(fingerprints).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["LANIdentity.json"])
    }

    func testHardLinkedRecordIsRejectedWithoutChangingTarget() throws {
        let folder = try directory()
        let original = folder.appendingPathComponent("original.json")
        _ = try MobileLANIdentity(file: original).prepare(address: "10.0.0.1")
        let bytes = try Data(contentsOf: original)
        let hardLink = folder.appendingPathComponent("linked.json")
        try FileManager.default.linkItem(at: original, to: hardLink)
        XCTAssertThrowsError(try MobileLANIdentity(file: hardLink).prepare(address: "10.0.0.1"))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
}
