import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Returns a fresh identity token (a JWT signed by the customer's server for
/// the current user). Called whenever the SDK needs a new session.
public typealias IdentityTokenProvider = @Sendable () async throws -> String

public struct ChatConfiguration: Sendable, Equatable {
    /// The app's public key from the dashboard (`app_…`).
    public var appKey: String
    /// The API's base URL, e.g. `https://chat-platform-api.onrender.com`.
    public var apiURL: URL
    /// Whether to fetch and apply the app's appearance settings from the
    /// dashboard. On by default.
    public var remoteAppearance: Bool

    public init(appKey: String, apiURL: URL, remoteAppearance: Bool = true) {
        self.appKey = appKey
        self.apiURL = apiURL
        self.remoteAppearance = remoteAppearance
    }
}

/// The HTTP side of the SDK: sessions (create, refresh, sign-out) and every
/// end-user route. One session at a time; concurrent callers share one
/// in-flight create or refresh, so the 60 s refresh window is never
/// needed for our own races, only for lost responses.
actor APIClient {
    let configuration: ChatConfiguration
    private let transport: HTTPTransport
    private let storage: SessionStorage
    private let clock: ChatClock

    private var identity: (userId: String, credential: IdentityCredentialProvider)?
    private var session: StoredSession?
    private var sessionTask: Task<(StoredSession, Bool), Error>?
    /// Called after a new server session replaces the old one for the same
    /// user (a rejected refresh signs in again), so per-session state such as
    /// the push device is set up again.
    private var sessionStarted: (@Sendable (Int) -> Void)?
    /// Counts sessions created (not refreshed), so callers can tell which
    /// session they set up.
    private(set) var sessionNumber = 0
    /// Bumped by sign-out and user switches, so a create or refresh that was in
    /// flight can't install a session for the previous user.
    private var generation = 0

    /// Refresh this long before the access token expires.
    static let refreshMargin: TimeInterval = 60

    init(
        configuration: ChatConfiguration, transport: HTTPTransport, storage: SessionStorage,
        clock: ChatClock
    ) {
        self.configuration = configuration
        self.transport = transport
        self.storage = storage
        self.clock = clock
        let stored = storage.load()
        session = stored?.appKey == configuration.appKey ? stored : nil
    }

    // MARK: Identity and sessions

    /// Sets who the SDK acts for. A different `userId` than the stored
    /// session's drops that session (without a network call; the old user's
    /// refresh token expires on its own unless `signOut` revoked it first).
    func identify(userId: String, credential: @escaping IdentityCredentialProvider) {
        if let session, session.userId != userId { clearSession() }
        identity = (userId, credential)
    }

    func onSessionStarted(_ handler: @escaping @Sendable (Int) -> Void) {
        sessionStarted = handler
    }

    var isIdentified: Bool { identity != nil }
    var currentUserId: String? { identity?.userId }

    /// Revokes the session on the server (best effort) and forgets it locally.
    func signOut() async {
        let current = session
        clearSession()
        identity = nil
        guard var current else { return }
        // An expired access token can't revoke anything: refresh it first
        // (and again on a 401), so the server session really ends.
        if current.accessExpiresAt <= clock.now(),
           let fresh = try? await refresh(current, userId: current.userId)
        {
            current = fresh
        }
        for attempt in 1...2 {
            var request = makeRequest("DELETE", "/v1/sdk/sessions/current")
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            guard let response = try? await transport.send(request) else { return }
            guard response.status == 401, attempt == 1,
                  let fresh = try? await refresh(current, userId: current.userId)
            else { return }
            current = fresh
        }
    }

    /// Forgets the session without a network call: it was revoked (socket
    /// 4401) or the account was deleted. The next request signs in again.
    func clearSession() {
        generation += 1
        sessionTask?.cancel()
        sessionTask = nil
        session = nil
        storage.save(nil)
    }

    /// Marks the access token expired, so the next request refreshes first.
    func expireAccessToken(_ token: String? = nil) {
        guard var current = session, token == nil || current.accessToken == token else { return }
        current.accessExpiresAt = .distantPast
        session = current
    }

    /// A session whose access token is valid for at least `refreshMargin`.
    func validSession() async throws -> StoredSession {
        if let sessionTask {
            // Shared with the caller that started it; still check that the
            // identity didn't change (logout, another user) while waiting.
            let generation = generation
            let shared = try await sessionTask.value
            guard generation == self.generation else { throw ChatError.cancelled }
            return shared.0
        }
        if let session, session.accessExpiresAt > clock.now().addingTimeInterval(Self.refreshMargin) {
            return session
        }
        guard let identity else { throw ChatError.notIdentified }
        let generation = generation
        let existing = session
        let task = Task { [configuration] in
            if let existing {
                do {
                    return (try await self.refresh(existing, userId: identity.userId), false)
                } catch let error as ChatError where error.isSessionRejection {
                    // Refresh token rejected (expired, replayed or revoked): sign in again.
                }
            }
            let credential = try await identity.credential()
            let body = try JSONEncoder.chat.encode(credential.body(appKey: configuration.appKey))
            var request = self.makeRequest("POST", "/v1/sdk/sessions", body: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let tokens: SessionTokens
            do {
                tokens = try await self.decode(SessionTokens.self, from: self.perform(request))
            } catch let error as ChatError where error.isSessionRejection {
                throw ChatError.signedOut
            }
            return (self.stored(tokens, userId: identity.userId), true)
        }
        sessionTask = task
        defer { if generation == self.generation { sessionTask = nil } }
        do {
            let (fresh, created) = try await task.value
            guard generation == self.generation else { throw ChatError.cancelled }
            session = fresh
            storage.save(fresh)
            if created {
                sessionNumber += 1
                sessionStarted?(sessionNumber)
            }
            return fresh
        } catch {
            if generation == self.generation, case ChatError.signedOut = error { clearSession() }
            throw error
        }
    }

    private func refresh(_ current: StoredSession, userId: String) async throws -> StoredSession {
        let body = try JSONEncoder.chat.encode(["refreshToken": current.refreshToken])
        var request = makeRequest("POST", "/v1/sdk/sessions/refresh", body: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let tokens = try decode(SessionTokens.self, from: try await perform(request))
        return stored(tokens, userId: userId)
    }

    private nonisolated func stored(_ tokens: SessionTokens, userId: String) -> StoredSession {
        StoredSession(
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            accessExpiresAt: clock.now().addingTimeInterval(TimeInterval(tokens.expiresIn)),
            appKey: configuration.appKey, userId: userId)
    }

    // MARK: Authorized requests

    /// Sends an authorized request. A 401 refreshes the session and retries
    /// once; the body and headers (including idempotency keys) are reused.
    func send(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
        contentType: String? = "application/json", headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        for attempt in 0..<2 {
            let session = try await validSession()
            var request = makeRequest(method, path, query: query, body: body)
            if body != nil, let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
            for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            do {
                return try await perform(request)
            } catch let error as ChatError where error.isSessionRejection && attempt == 0 {
                expireAccessToken(session.accessToken)
            }
        }
        throw ChatError.signedOut
    }

    func get<T: Decodable & Sendable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [])
        async throws -> T
    {
        try decode(type, from: try await send("GET", path, query: query))
    }

    func post<T: Decodable & Sendable>(
        _ type: T.Type, _ path: String, json: some Encodable & Sendable,
        headers: [String: String] = [:]
    ) async throws -> T {
        let body = try JSONEncoder.chat.encode(json)
        return try decode(type, from: try await send("POST", path, body: body, headers: headers))
    }

    /// A short-lived signed URL for an attachment (`GET /v1/sdk/attachments/{id}`
    /// answers 302; the URL is valid for about 5 minutes and needs no token).
    func attachmentURL(_ id: String) async throws -> URL {
        let response = try await send("GET", "/v1/sdk/attachments/\(id)")
        guard let location = response.header("Location"), let url = URL(string: location) else {
            throw ChatError.invalidResponse
        }
        return url
    }

    /// The app's appearance document (`GET /v1/sdk/appearance`). It holds no
    /// secrets, so it's fetched with the app key alone and works before
    /// `identify`. Returns nil for a 304 to `etag`.
    func appearance(etag: String?) async throws -> (RemoteAppearance, etag: String?)? {
        var request = makeRequest(
            "GET", "/v1/sdk/appearance", query: [URLQueryItem(name: "appKey", value: configuration.appKey)])
        // The SDK keeps its own copy and ETag; URLCache would hide the 304.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let response = try await perform(request)
        if response.status == 304 { return nil }
        return (try decode(RemoteAppearance.self, from: response), response.header("ETag"))
    }

    // MARK: Plumbing

    private nonisolated func makeRequest(
        _ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil
    ) -> URLRequest {
        var components = URLComponents(
            url: configuration.apiURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "ChatPlatformSDK/\(ChatPlatformCore.version)", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Sends without auth; maps transport failures and error bodies to `ChatError`.
    private func perform(_ request: URLRequest) async throws -> HTTPResponse {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as ChatError {
            throw error
        } catch is CancellationError {
            throw ChatError.cancelled
        } catch {
            throw ChatError.network(String(describing: error))
        }
        guard (200..<400).contains(response.status) else {
            let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body))?.error
                .code ?? "http_\(response.status)"
            let retryAfter = response.header("Retry-After").flatMap(TimeInterval.init)
            throw ChatError.api(status: response.status, code: code, retryAfter: retryAfter)
        }
        return response
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, from response: HTTPResponse)
        throws -> T
    {
        do {
            return try JSONDecoder.chat.decode(type, from: response.body)
        } catch {
            throw ChatError.invalidResponse
        }
    }
}

extension ChatError {
    /// A 401: the presented credential (access, refresh or identity token) was refused.
    var isSessionRejection: Bool {
        if case .api(let status, _, _) = self { return status == 401 }
        return false
    }
}
