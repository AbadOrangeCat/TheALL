import Foundation
import Security

// This executable is installed once per signing identity. App updates keep
// using that exact executable, so modern Keychain cdhash partitions stay valid.
func respond(_ response: AICredentialHelperResponse) {
    if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data) }
}

do {
    let identity = try AICredentialHelperIdentity.current()
    let parentIdentifier = try identity.validateParent()
    let encoded = FileHandle.standardInput.readDataToEndOfFile()
    guard encoded.count <= 1_048_576 else { throw AICredentialHelperIdentity.Failure.status(errSecParam) }
    let request = try JSONDecoder().decode(AICredentialHelperRequest.self, from: encoded)
    guard ["claude", "openai"].contains(request.provider) else { throw AICredentialHelperIdentity.Failure.status(errSecParam) }
    try AICredentialHelperIdentity.check(SecKeychainSetUserInteractionAllowed(false))
    var keychain: SecKeychain?
    if let path = request.keychainPath { try AICredentialHelperIdentity.check(SecKeychainOpen(path, &keychain)) }
    var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: parentIdentifier + ".ai-connections.v3",
        kSecAttrAccount as String: request.provider]
    if let keychain { query[kSecMatchSearchList as String] = [keychain] }
    switch request.operation {
    case .load:
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        respond(AICredentialHelperResponse(status: status, data: value as? Data))
    case .save:
        guard let data = request.data else { throw AICredentialHelperIdentity.Failure.status(errSecParam) }
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query.removeValue(forKey: kSecMatchSearchList as String)
            if let keychain { query[kSecUseKeychain as String] = keychain }
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        respond(AICredentialHelperResponse(status: status))
    case .delete:
        respond(AICredentialHelperResponse(status: SecItemDelete(query as CFDictionary)))
    }
} catch AICredentialHelperIdentity.Failure.status(let status) {
    respond(AICredentialHelperResponse(status: status))
} catch {
    respond(AICredentialHelperResponse(status: errSecDecode))
}
