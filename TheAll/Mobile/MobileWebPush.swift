import Foundation
import CryptoKit
import Security

/// RFC 8291 / RFC 8188 single-record aes128gcm and RFC 8292 VAPID.
/// https://www.rfc-editor.org/rfc/rfc8291#section-3.4
/// https://www.rfc-editor.org/rfc/rfc8292#section-2
enum MobileWebPush {
    enum PushError: LocalizedError {
        case invalidSubscription, invalidEndpoint, invalidPayload, storage, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidSubscription: return "The notification subscription is invalid. Enable notifications again."
            case .invalidEndpoint: return "This notification service is not supported."
            case .invalidPayload: return "The notification could not be prepared."
            case .storage: return "Saved notification settings could not be read or saved. Existing files were preserved."
            case .unavailable: return "The notification service could not accept the message. Try again later."
            }
        }
    }

    struct Subscription: Codable, Equatable {
        let endpoint: String
        let expirationTime: Double?
        let p256dh: String
        let auth: String

        init(json: [String: Any], now: Date = Date()) throws {
            guard let endpoint = json["endpoint"] as? String,
                  let keys = json["keys"] as? [String: Any],
                  let p256dh = keys["p256dh"] as? String, let auth = keys["auth"] as? String
            else { throw PushError.invalidSubscription }
            let expiry: Double?
            if json["expirationTime"] == nil || json["expirationTime"] is NSNull { expiry = nil }
            else if let number = json["expirationTime"] as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                    number.doubleValue > now.timeIntervalSince1970 * 1000 { expiry = number.doubleValue }
            else { throw PushError.invalidSubscription }
            self.endpoint = endpoint; self.expirationTime = expiry; self.p256dh = p256dh; self.auth = auth
            try validate()
        }

        func validate() throws {
            _ = try MobileWebPush.endpoint(endpoint)
            let receiver = try decode(p256dh), authentication = try decode(auth)
            guard receiver.count == 65, receiver.first == 4, authentication.count == 16,
                  (try? P256.KeyAgreement.PublicKey(x963Representation: receiver)) != nil,
                  expirationTime.map({ $0.isFinite && $0 > 0 }) ?? true
            else { throw PushError.invalidSubscription }
        }
        func isExpired(at date: Date) -> Bool { expirationTime.map { $0 <= date.timeIntervalSince1970 * 1000 } ?? false }
    }

    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ value: String) throws -> Data {
        guard !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - value.count % 4) % 4)), encode(bytes) == value
        else { throw PushError.invalidSubscription }
        return bytes
    }

    static func endpoint(_ value: String) throws -> URL {
        guard value.utf8.count <= 2048, !value.contains("\\"),
              let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443, let host = parts.host,
              host == host.lowercased(), !host.hasSuffix("."),
              host.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              host == "fcm.googleapis.com" || host == "updates.push.services.mozilla.com"
                || host.hasSuffix(".updates.push.services.mozilla.com")
                || host.hasSuffix(".push.apple.com"),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              !parts.path.isEmpty, parts.path != "/", let url = parts.url
        else { throw PushError.invalidEndpoint }
        return url
    }

    static func encryptedBody(_ payload: Data, subscription: Subscription,
                              key: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(), salt: Data? = nil) throws -> Data {
        try subscription.validate()
        guard payload.count <= 2048 else { throw PushError.invalidPayload }
        let receiverData = try decode(subscription.p256dh), auth = try decode(subscription.auth)
        let receiver = try P256.KeyAgreement.PublicKey(x963Representation: receiverData)
        let publicKey = key.publicKey.x963Representation
        let secret = try key.sharedSecretFromKeyAgreement(with: receiver)
        let combined = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth,
            sharedInfo: Data("WebPush: info\0".utf8) + receiverData + publicKey, outputByteCount: 32)
        let salt = try salt ?? randomBytes(16)
        guard salt.count == 16 else { throw PushError.invalidPayload }
        let contentKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: combined, salt: salt,
            info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: combined, salt: salt,
            info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })
        let box = try AES.GCM.seal(payload + Data([2]), using: contentKey, nonce: nonce)
        // salt(16), record-size(4, network order), key-id length(1), server public key(65).
        return salt + Data([0, 0, 16, 0, 65]) + publicKey + box.ciphertext + box.tag
    }

    static func request(payload: Data, subscription: Subscription, signingKey: P256.Signing.PrivateKey,
                        now: Date = Date()) throws -> URLRequest {
        let endpoint = try endpoint(subscription.endpoint)
        guard !subscription.isExpired(at: now) else { throw PushError.invalidSubscription }
        let audience = "https://" + endpoint.host!
        let header = encode(Data("{\"typ\":\"JWT\",\"alg\":\"ES256\"}".utf8))
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 3600,
            "sub": "https://github.com/AbadOrangeCat/TheALL"]
        let unsigned = header + "." + encode(try JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let signature = try signingKey.signature(for: Data(unsigned.utf8)).rawRepresentation
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try encryptedBody(payload, subscription: subscription)
        request.setValue("vapid t=\(unsigned).\(encode(signature)), k=\(encode(signingKey.publicKey.x963Representation))", forHTTPHeaderField: "Authorization")
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("300", forHTTPHeaderField: "TTL")
        request.setValue("normal", forHTTPHeaderField: "Urgency")
        return request
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw PushError.invalidPayload }
        return Data(bytes)
    }
}

/// Normal system TLS verification, no redirects/cookies/cache, and no response bodies in errors.
final class MobileWebPushSender: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func send(_ request: URLRequest) async throws -> Int {
        guard let url = request.url else { throw MobileWebPush.PushError.invalidEndpoint }
        _ = try MobileWebPush.endpoint(url.absoluteString)
        try Task.checkCancellation()
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MobileWebPush.PushError.unavailable }
        return response.statusCode
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
