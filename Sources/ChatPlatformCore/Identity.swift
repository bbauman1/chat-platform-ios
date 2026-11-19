import Foundation
#if canImport(Security)
import Security
#endif

/// Sign-in services whose ID tokens the API verifies itself, for apps
/// without their own server. Each is switched on per app.
public enum IdentityProvider: String, Sendable, CaseIterable {
    /// Sign in with Apple: the `identityToken` from the authorization.
    case apple
    /// Firebase Authentication: `user.getIDToken()`.
    case firebase
    /// Supabase Auth: the session's `accessToken`.
    case supabase
}

/// What `POST /v1/sdk/sessions` gets for each identity source.
enum IdentityCredential: Sendable, Equatable {
    case signed(String)
    case provider(IdentityProvider, String)
    case anonymous(installSecret: String)
    case development(userId: String)

    struct Body: Encodable {
        struct ProviderToken: Encodable {
            var provider: String
            var token: String
        }
        struct Anonymous: Encodable {
            var installSecret: String
        }
        struct Development: Encodable {
            var userId: String
        }
        var appKey: String
        var identityToken: String?
        var providerToken: ProviderToken?
        var anonymous: Anonymous?
        var development: Development?
    }

    func body(appKey: String) -> Body {
        var body = Body(appKey: appKey)
        switch self {
        case .signed(let token): body.identityToken = token
        case .provider(let provider, let token): body.providerToken = .init(provider: provider.rawValue, token: token)
        case .anonymous(let secret): body.anonymous = .init(installSecret: secret)
        case .development(let userId): body.development = .init(userId: userId)
        }
        return body
    }
}

typealias IdentityCredentialProvider = @Sendable () async throws -> IdentityCredential

/// Where `identifyAnonymously()` keeps the install's secret.
public protocol InstallSecretStorage: Sendable {
    /// The saved secret, or nil when there is none. Throws when the store
    /// can't be read right now (the Keychain before the first unlock after a
    /// restart), so the SDK doesn't mistake a locked store for a new install.
    func load() throws -> Data?
    /// Saves the secret, or deletes it for nil. Throws when it wasn't saved.
    func save(_ secret: Data?) throws
}

/// The install secret couldn't be read or saved (``InstallSecretStorage``).
public struct InstallSecretUnavailable: Error, Sendable {
    public var status: Int32
    public init(status: Int32) { self.status = status }
}

public final class InMemoryInstallSecretStorage: InstallSecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: Data?

    public init(_ secret: Data? = nil) { self.secret = secret }

    public func load() throws -> Data? { lock.withLock { secret } }
    public func save(_ secret: Data?) throws { lock.withLock { self.secret = secret } }
}

#if canImport(Security)
/// Keeps the install secret in the Keychain, readable after first unlock and
/// never synced, so another device or a backup restore starts a new
/// anonymous user. Keychain items outlive the app, so a marker in
/// `UserDefaults` (deleted with the app) makes a reinstall start over too.
public final class KeychainInstallSecretStorage: InstallSecretStorage, @unchecked Sendable {
    private let service: String
    private let account: String
    private let defaults: UserDefaults
    private let marker: String

    public init(service: String = "dev.chatplatform.sdk", account: String = "install-secret", defaults: UserDefaults = .standard) {
        self.service = service
        self.account = account
        self.defaults = defaults
        marker = "\(service).\(account).installed"
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> Data? {
        guard defaults.bool(forKey: marker) else { return nil }
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw InstallSecretUnavailable(status: status) }
        return result as? Data
    }

    public func save(_ secret: Data?) throws {
        let deleted = SecItemDelete(query as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw InstallSecretUnavailable(status: deleted)
        }
        guard let secret else {
            defaults.removeObject(forKey: marker)
            return
        }
        var item = query
        item[kSecValueData as String] = secret
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw InstallSecretUnavailable(status: added) }
        defaults.set(true, forKey: marker)
    }
}
#endif

enum Identity {
    /// The ID the API gives an anonymous user: `anon:` and the first 32
    /// characters of base64url(SHA-256(secret)).
    static func anonymousUserId(secret: Data) -> String {
        "anon:" + String(base64URL(SHA256.hash(secret)).prefix(32))
    }

    /// A development user ID the API accepts (`[A-Za-z0-9_.@-]{1,64}`):
    /// other characters become `-`, so `"dev-" + UIDevice.current.name` works.
    static func developmentUserId(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@-")
        let cleaned = String(raw.map { allowed.contains($0) ? $0 : "-" }.prefix(64))
        return cleaned.isEmpty ? "dev" : cleaned
    }

    /// The `sub` claim of a JWT, read without verifying it (the API verifies
    /// it); only used to scope the device's cache to the user.
    static func subject(ofJWT token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = claims["sub"] as? String, !sub.isEmpty
        else { return nil }
        return sub
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The install's secret: the saved one, or a new one once it's saved.
    /// Throws a retryable `ChatError.network` while the store is unavailable.
    static func installSecret(in storage: InstallSecretStorage) throws -> Data {
        do {
            if let stored = try storage.load(), stored.count == 32 { return stored }
            let secret = randomSecret()
            try storage.save(secret)
            return secret
        } catch {
            throw ChatError.network("install secret unavailable: \(error)")
        }
    }

    static func randomSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// SHA-256 (FIPS 180-4), so the core builds without CryptoKit on Linux.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ data: Data) -> Data {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
        ]
        var message = [UInt8](data)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((bitLength >> UInt64(shift)) & 0xff)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8
                    | UInt32(message[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
            h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return Data(h.flatMap { value in [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xff) } })
    }
}
