import Foundation
import Security
import CryptoKit

// Shared by the app and its credential helper. Secrets travel only through
// private pipes, never argv, environment variables, or diagnostic output.
struct AICredentialHelperRequest: Codable {
    enum Operation: String, Codable { case load, save, delete }
    let operation: Operation
    let provider: String
    var data: Data? = nil
    // Used for isolated integration tests; the service/account remain fixed.
    var keychainPath: String? = nil
}

struct AICredentialHelperResponse: Codable {
    let status: Int32
    var data: Data? = nil
}

struct AICredentialHelperIdentity {
    static let suffix = ".credential-helper"
    let identifier: String
    let certificateHash: String

    static func current() throws -> Self {
        var code: SecCode?
        try check(SecCodeCopySelf([], &code))
        var staticCode: SecStaticCode?
        try check(SecCodeCopyStaticCode(code!, [], &staticCode))
        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &information))
        let values = information as? [String: Any] ?? [:]
        guard let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { throw Failure.status(errSecCSUnsigned) }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        return Self(identifier: identifier, certificateHash: hash)
    }

    func requirement(identifier: String) throws -> SecRequirement {
        let escaped = identifier.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let expression = "identifier \"\(escaped)\" and certificate leaf = H\"\(certificateHash)\""
        var requirement: SecRequirement?
        try Self.check(SecRequirementCreateWithString(expression as CFString, [], &requirement))
        return requirement!
    }

    func validateHelper(at url: URL) throws {
        var code: SecStaticCode?
        try Self.check(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        try Self.check(SecStaticCodeCheckValidity(code!, SecCSFlags(rawValue: kSecCSStrictValidate),
                                                try requirement(identifier: identifier + Self.suffix)))
    }

    func validateHelper(processID: pid_t) throws {
        var process: SecCode?
        try Self.check(SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: processID] as CFDictionary, [], &process))
        try Self.check(SecCodeCheckValidity(process!, [], try requirement(identifier: identifier + Self.suffix)))
    }

    func validateParent() throws -> String {
        guard identifier.hasSuffix(Self.suffix), getppid() > 1 else { throw Failure.status(errSecAuthFailed) }
        let parentIdentifier = String(identifier.dropLast(Self.suffix.count))
        var parent: SecCode?
        try Self.check(SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: getppid()] as CFDictionary, [], &parent))
        try Self.check(SecCodeCheckValidity(parent!, [], try requirement(identifier: parentIdentifier)))
        return parentIdentifier
    }

    enum Failure: Error { case status(OSStatus) }
    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw Failure.status(status) }
    }
}
