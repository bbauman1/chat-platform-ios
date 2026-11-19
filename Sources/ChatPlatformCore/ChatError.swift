import Foundation

/// Errors from the chat client.
public enum ChatError: Error, Sendable, Equatable {
    /// The API answered with an error body (`{ error: { code } }`).
    case api(status: Int, code: String, retryAfter: TimeInterval?)
    /// The request never got an answer (offline, timeout, connection reset).
    case network(String)
    /// The response wasn't what the API contract says.
    case invalidResponse
    /// No identity token provider is set (`ChatClient.identify`).
    case notIdentified
    /// The identity token was rejected (or isn't a JWT, for
    /// `identify(provider:tokenProvider:)`), or the user signed out or was deleted.
    case signedOut
    case cancelled

    /// Worth retrying with the same idempotency key.
    public var isRetryable: Bool {
        switch self {
        case .network: return true
        case .api(let status, _, _): return status == 429 || status >= 500
        default: return false
        }
    }

    var code: String? {
        if case .api(_, let code, _) = self { return code }
        return nil
    }
}

struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        var code: String
    }
    var error: Body
}
