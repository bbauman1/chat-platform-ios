import Foundation

/// The SDK's entry point.
///
/// ```swift
/// let chat = ChatClient(configuration: .init(appKey: "app_…", apiURL: apiURL))
/// chat.identify(userId: user.id) { try await myServer.chatIdentityToken() }
/// let conversation = try chat.conversation()
/// conversation.start()
/// ```
///
/// Aliases and attributes travel inside the identity token your server signs
/// (`aliases`, `attrs`, `cv` claims), so they can't be
/// forged from the device. Change them by signing a new token with a higher
/// `cv`; the SDK picks it up the next time it starts a session.
@MainActor
public final class ChatClient {
    public let configuration: ChatConfiguration
    let api: APIClient
    private let webSockets: WebSocketTransport
    private let cache: MessageCache
    let clock: ChatClock
    private var store: ConversationStore?
    /// The device token from `registerDeviceToken`, registered for each user identified.
    var pushRegistration: DeviceRegistration?
    /// Unsent `track` events.
    var eventStore: EventStore
    var eventFlushTask: Task<Void, Never>?
    /// The registration being sent, so a new session that starts while it's
    /// in flight doesn't send the same one again.
    var registering: (registration: DeviceRegistration, task: Task<Void, Error>)?
    /// The session (`APIClient.sessionNumber`) the last registration went to.
    var registeredSession: Int?
    let appearance: AppearanceStore
    private let installSecrets: InstallSecretStorage
    /// How the current user signed in; an anonymous user's secret is
    /// replaced when their account is deleted.
    private var isAnonymous = false

    /// Creates a client. Make one per app and keep it.
    ///
    /// - Parameters:
    ///   - configuration: the app key and API URL.
    ///   - http: how requests are sent; replaced in tests.
    ///   - webSockets: how the realtime socket connects; the system's by default.
    ///   - sessionStorage: Keychain on Apple platforms by default.
    ///   - messageCache: files under Application Support by default.
    ///   - clock: the time source; replaced in tests.
    ///   - appearanceCache: where the app's remote appearance is kept between
    ///     launches; a file under Application Support by default.
    ///   - installSecretStorage: where `identifyAnonymously()` keeps this
    ///     install's secret; the Keychain on Apple platforms by default.
    public init(
        configuration: ChatConfiguration,
        http: HTTPTransport = URLSessionHTTPTransport(),
        webSockets: WebSocketTransport? = nil,
        sessionStorage: SessionStorage? = nil,
        messageCache: MessageCache? = nil,
        clock: ChatClock = SystemClock(),
        appearanceCache: AppearanceCache? = nil,
        installSecretStorage: InstallSecretStorage? = nil
    ) {
        self.configuration = configuration
        #if canImport(Security)
        let storage = sessionStorage ?? KeychainSessionStorage()
        installSecrets = installSecretStorage ?? KeychainInstallSecretStorage()
        #else
        let storage = sessionStorage ?? InMemorySessionStorage()
        installSecrets = installSecretStorage ?? InMemoryInstallSecretStorage()
        #endif
        api = APIClient(configuration: configuration, transport: http, storage: storage, clock: clock)
        #if canImport(Network)
        self.webSockets = webSockets ?? NetworkWebSocketTransport()
        #else
        guard let webSockets else { preconditionFailure("Pass a WebSocketTransport on this platform") }
        self.webSockets = webSockets
        #endif
        cache = messageCache ?? FileMessageCache()
        eventStore = FileEventStore(appKey: configuration.appKey)
        self.clock = clock
        appearance = AppearanceStore(
            api: api, cache: appearanceCache ?? FileAppearanceCache(appKey: configuration.appKey),
            appKey: configuration.appKey, isEnabled: configuration.remoteAppearance)
        let api = api
        Task { [weak self] in
            await api.onSessionStarted { [weak self] number in
                Task { @MainActor in await self?.sessionStarted(number) }
            }
        }
    }

    /// The app's appearance settings from the dashboard as last fetched, or
    /// nil before the first fetch or when `remoteAppearance` is off. Chat
    /// screens apply it when they open.
    public var remoteAppearance: RemoteAppearance? { appearance.current }

    /// Fetches the app's appearance settings for the next chat screen. Called
    /// by `configure` and whenever a chat opens; a failure keeps the copy on hand.
    public func refreshAppearance() async {
        await appearance.refresh()
    }

    /// The user the SDK acts for, or nil before `identify`.
    public private(set) var userId: String?

    /// Sets the current user. `tokenProvider` is called whenever a new session
    /// is needed; it returns an identity token from your server. Identifying a
    /// different user stops the previous user's conversation and drops their
    /// session and cached messages.
    ///
    /// Apps without a server use `identify(provider:tokenProvider:)`,
    /// `identifyAnonymously()`, or in debug builds
    /// `identify(developmentUserId:)`; each is switched on in the app's identity
    /// settings.
    public func identify(userId: String, tokenProvider: @escaping IdentityTokenProvider) async {
        await identify(localUserId: userId, anonymous: false) { .signed(try await tokenProvider()) }
    }

    /// Signs in with an ID token from Sign in with Apple, Firebase or
    /// Supabase, which the API verifies against the provider. The user is
    /// `<provider>:<sub>`. `tokenProvider` is called for every new session,
    /// including after the session can't be refreshed, so return a current
    /// token (Firebase: `getIDToken()`; Supabase: the session's access token).
    /// Apple can't refresh a token silently: return the one from the latest
    /// Sign in with Apple, and identify again after the next one.
    ///
    /// Throws `ChatError.signedOut` when the token isn't a JWT with a subject,
    /// and anything `tokenProvider` throws. A later token for another subject
    /// signs this user out (`ChatError.signedOut`) instead of mixing accounts;
    /// call `identify` again after the provider's user changes.
    public func identify(provider: IdentityProvider, tokenProvider: @escaping IdentityTokenProvider) async throws {
        let token = try await tokenProvider()
        guard let subject = Identity.subject(ofJWT: token) else { throw ChatError.signedOut }
        // Every session asks for a current token: a restored session may
        // need a new one days after this call.
        await identify(localUserId: "\(provider.rawValue):\(subject)", anonymous: false) {
            let token = try await tokenProvider()
            // Another account signed in to the provider: this client's
            // conversation and cache belong to the first one, so stop until
            // the app identifies again.
            guard Identity.subject(ofJWT: token) == subject else { throw ChatError.signedOut }
            return .provider(provider, token)
        }
    }

    /// Signs in as this install, with no account: the SDK makes a random
    /// secret once and keeps it in the Keychain (this device only, never
    /// synced). `logout()` keeps it, so the install comes back to the same
    /// chat; reinstalling the app or a new device starts a new one, and
    /// `deleteAccount()` replaces it. If the device hasn't been unlocked
    /// since it restarted (a background launch), the Keychain can't be read,
    /// so this waits until it can rather than starting a new user; it returns
    /// without identifying if its task is cancelled.
    public func identifyAnonymously() async {
        let storage = installSecrets
        var secret: Data?
        while secret == nil {
            do {
                secret = try Identity.installSecret(in: storage)
            } catch {
                do {
                    try await Task.sleep(nanoseconds: Self.lockedKeychainRetry)
                } catch {
                    return
                }
            }
        }
        guard let secret else { return }
        let encoded = Identity.base64URL(secret)
        await identify(localUserId: Identity.anonymousUserId(secret: secret), anonymous: true) {
            .anonymous(installSecret: encoded)
        }
    }

    /// How often `identifyAnonymously()` tries a locked Keychain again.
    nonisolated(unsafe) static var lockedKeychainRetry: UInt64 = 1_000_000_000

    #if DEBUG
    /// Signs in as a development user with no token, for trying the chat
    /// before a server exists. Compiled only in debug builds, and refused
    /// unless development mode is on for the app. The user is
    /// `dev:<developmentUserId>`; characters other than letters, digits and
    /// `_.@-` become `-`, and it's cut to 64 characters.
    public func identify(developmentUserId: String) async {
        let userId = Identity.developmentUserId(developmentUserId)
        await identify(localUserId: "dev:\(userId)", anonymous: false) { .development(userId: userId) }
    }
    #endif

    private func identify(
        localUserId userId: String, anonymous: Bool, credential: @escaping IdentityCredentialProvider
    ) async {
        if let current = self.userId, current != userId {
            await finishEvents(for: current)
            await reset(revoke: true)
        }
        let changed = self.userId != userId
        self.userId = userId
        isAnonymous = anonymous
        await api.identify(userId: userId, credential: credential)
        // A new user's session has no device yet. Best effort: the host
        // registers again on the next launch.
        if changed, let pushRegistration { try? await register(pushRegistration) }
        scheduleEventFlush()
    }

    /// The current user's conversation (created on the server when first loaded).
    public func conversation() throws -> ConversationStore {
        guard let userId else { throw ChatError.notIdentified }
        if let store { return store }
        let realtime = RealtimeClient(api: api, transport: webSockets, clock: clock)
        let store = ConversationStore(
            api: api, realtime: realtime, cache: cache, clock: clock, userId: userId,
            appKey: api.configuration.appKey, appearance: appearance)
        self.store = store
        return store
    }

    /// Unread messages from the team, without creating a conversation (for a badge).
    public func unreadCount() async throws -> Int {
        try await api.get(UnreadCount.self, "/v1/sdk/unread").unread
    }

    /// Signs out: revokes the session on the server and deletes cached messages.
    public func logout() async {
        if let userId { await finishEvents(for: userId) }
        await reset(revoke: true)
        userId = nil
    }

    /// Deletes the end user and all of their data on the server
    /// (`DELETE /v1/sdk/me`), then everything held on the device.
    public func deleteAccount() async throws {
        // The deleted user can't come back: an anonymous install gets a new
        // identity. Drop the secret first, so a Keychain failure stops here
        // with nothing deleted, and put it back if the server delete fails.
        let anonymousSecret = isAnonymous ? try installSecrets.load() : nil
        if anonymousSecret != nil { try installSecrets.save(nil) }
        do {
            _ = try await api.send("DELETE", "/v1/sdk/me")
        } catch ChatError.signedOut {
            // A retry after a lost response: the session is already gone.
        } catch let error as ChatError where error.isSessionRejection {
            // Same as above.
        } catch {
            if let anonymousSecret { try? installSecrets.save(anonymousSecret) }
            throw error
        }
        if let userId {
            eventFlushTask?.cancel()
            eventFlushTask = nil
            eventStore.save(eventStore.load().filter { $0.userId != userId && $0.userId != nil })
        }
        await reset(revoke: false)
        await api.signOut()
        userId = nil
        isAnonymous = false
    }

    private func reset(revoke: Bool) async {
        if let store {
            await store.realtime.stop()
            await store.clear()
        } else {
            cache.save(nil)
        }
        store = nil
        if revoke { await api.signOut() } else { await api.clearSession() }
    }
}
