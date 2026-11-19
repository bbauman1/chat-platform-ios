import Foundation
#if canImport(Security)
import Security
#endif

/// Where the SDK keeps its session between launches.
public protocol SessionStorage: Sendable {
    func load() -> StoredSession?
    func save(_ session: StoredSession?)
}

/// Keeps the session in memory only (tests, or apps that sign in every launch).
public final class InMemorySessionStorage: SessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init(_ session: StoredSession? = nil) {
        self.session = session
    }

    public func load() -> StoredSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    public func save(_ session: StoredSession?) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }
}

#if canImport(Security)
/// Keeps the session in the Keychain, readable after first unlock so pushes
/// and background refreshes work, and never synced to other devices.
public final class KeychainSessionStorage: SessionStorage, @unchecked Sendable {
    private let service: String
    private let account: String

    public init(service: String = "dev.chatplatform.sdk", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> StoredSession? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder.chat.decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession?) {
        SecItemDelete(query as CFDictionary)
        guard let session, let data = try? JSONEncoder.chat.encode(session) else { return }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
#endif

extension JSONDecoder {
    /// ISO 8601 dates, with or without fractional seconds (the API sends them with).
    static var chat: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601.parse(raw) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad date \(raw)"))
        }
        return decoder
    }
}

extension JSONEncoder {
    static var chat: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

enum ISO8601 {
    static func parse(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
