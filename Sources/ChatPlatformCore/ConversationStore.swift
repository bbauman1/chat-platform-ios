import Foundation

/// An image to send: JPEG (or any format the API decodes) of at most 3 MB.
public struct ImageUpload: Sendable {
    public var data: Data
    public var width: Int
    public var height: Int

    public init(data: Data, width: Int, height: Int) {
        self.data = data
        self.width = width
        self.height = height
    }
}

/// The end user's conversation as the UI sees it: confirmed messages,
/// unsent ones, receipts, typing and connection state. Main-actor bound, so
/// UIKit reads it directly; every change is pushed to observers.
///
/// Rules: HTTP is the source of truth and the
/// socket only signals; after every (re)connect the store reloads; sends are
/// idempotent by `clientId` and image uploads by `Idempotency-Key`, both kept
/// across retries and relaunches; read receipts only move forward.
@MainActor
public final class ConversationStore {
    public struct State: Sendable, Equatable {
        public var conversation: Conversation?
        /// Confirmed messages, oldest first, unique by ID.
        public var messages: [Message] = []
        /// Unsent messages, in the order they were written.
        public var pending: [OutgoingMessage] = []
        public var hasOlderMessages = false
        public var isLoadingOlder = false
        /// The realtime socket is up; updates arrive live.
        public var isConnected = false
        public var teamIsTyping = false
        /// Messages from the team the end user hasn't read.
        public var unreadCount = 0
        /// Set when the session ended (identity rejected); the store stops.
        public var isSignedOut = false

        public init(
            conversation: Conversation? = nil, messages: [Message] = [], pending: [OutgoingMessage] = [],
            hasOlderMessages: Bool = false, isLoadingOlder: Bool = false, isConnected: Bool = false,
            teamIsTyping: Bool = false, unreadCount: Int = 0, isSignedOut: Bool = false
        ) {
            self.conversation = conversation
            self.messages = messages
            self.pending = pending
            self.hasOlderMessages = hasOlderMessages
            self.isLoadingOlder = isLoadingOlder
            self.isConnected = isConnected
            self.teamIsTyping = teamIsTyping
            self.unreadCount = unreadCount
            self.isSignedOut = isSignedOut
        }
    }

    public private(set) var state = State() {
        didSet {
            guard state != oldValue else { return }
            for observer in observers.values { observer(state) }
        }
    }

    /// Page sizes and limits.
    static let pageSize = 50
    static let catchUpPageSize = 100
    /// Reconnect catch-up reads at most this many pages before loading the newest page instead.
    static let maxCatchUpPages = 10
    /// Messages kept on disk.
    static let cachedMessages = 200
    /// Retries of one send before waiting for the next reconnect.
    static let sendAttempts = 5

    let api: APIClient
    let realtime: RealtimeClient
    private let cache: MessageCache
    private let cacheWriter: CacheWriter
    private let clock: ChatClock
    /// The signed-in end user and app this conversation belongs to.
    public let userId: String
    public let appKey: String
    let appearance: AppearanceStore?
    /// Set by `clear()`: work still in flight must not touch state or the cache.
    private var isCleared = false
    private var pumpTask: Task<Void, Never>?

    private var observers: [UUID: (State) -> Void] = [:]
    private var listener: Task<Void, Never>?
    private var newerCursor: String?
    private var olderCursor: String?
    /// The first reload after launch replaces the cached thread with the newest page.
    private var needsFreshLoad = true
    private var reloading = false
    private var reloadAgain = false
    private var pumping = false
    private var lastReadSent = 0
    private var typingClear: Task<Void, Never>?
    private var started = false
    /// The oldest message on screen, so a change that isn't a new message
    /// (a reaction, a receipt) reloads what the user is looking at.
    private var firstVisibleSequence: Int?
    /// Per message: the latest reaction selection, and the write in flight.
    private var reactionGenerations: [String: Int] = [:]
    private var reactionWrites: [String: Task<Message, Error>] = [:]

    init(
        api: APIClient, realtime: RealtimeClient, cache: MessageCache, clock: ChatClock,
        userId: String, appKey: String, appearance: AppearanceStore? = nil
    ) {
        self.appearance = appearance
        self.api = api
        self.realtime = realtime
        self.cache = cache
        self.cacheWriter = CacheWriter(cache: cache)
        self.clock = clock
        self.userId = userId
        self.appKey = appKey
        if let cached = cache.load(), cached.userId == userId, cached.appKey == appKey {
            state.conversation = cached.conversation
            state.messages = cached.messages
            // Anything unsent is retried; a failed one stays failed until the user retries.
            state.pending = cached.pending
            lastReadSent = cached.conversation?.endUserRead ?? 0
        } else {
            cache.save(nil)
        }
        let events = realtime.events
        listener = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    deinit {
        listener?.cancel()
    }

    /// The app's remote appearance as last fetched (see `ChatClient.remoteAppearance`).
    public var remoteAppearance: RemoteAppearance? { appearance?.current }

    /// Fetches the remote appearance for the next chat screen.
    public func refreshAppearance() async {
        await appearance?.refresh()
    }

    // MARK: Observing

    /// Calls `handler` with the state now and after every change, until the
    /// returned token is released or cancelled.
    public func observe(_ handler: @escaping @MainActor (State) -> Void) -> ObservationToken {
        let id = UUID()
        observers[id] = handler
        handler(state)
        return ObservationToken { [weak self] in
            Task { @MainActor in _ = self?.observers.removeValue(forKey: id) }
        }
    }

    // MARK: Lifecycle

    /// Connects the socket (which triggers a reload once ready), loads over
    /// HTTP right away, and resumes unsent messages.
    public func start() {
        guard !state.isSignedOut else { return }
        started = true
        Task { await realtime.start() }
        Task { try? await self.reload() }
        pump()
    }

    /// Disconnects the socket (the app went to the background).
    public func stop() {
        started = false
        Task { await realtime.stop() }
    }

    /// Reconnects immediately instead of waiting out the backoff.
    public func reconnectNow() {
        Task { await realtime.reconnectNow() }
    }

    private func handle(_ event: RealtimeEvent) {
        switch event {
        case .connected:
            state.isConnected = true
            Task { try? await self.reload() }
            pump()
        case .conversationChanged(let revision, _):
            if revision > (state.conversation?.revision ?? -1) {
                Task { try? await self.reload() }
            }
        case .resync:
            Task { try? await self.reload() }
        case .teamTyping(let typing, let expiresAt):
            setTeamTyping(typing, until: expiresAt)
        case .disconnected:
            state.isConnected = false
            setTeamTyping(false, until: nil)
        case .signedOut:
            state.isConnected = false
            state.isSignedOut = true
            setTeamTyping(false, until: nil)
        }
    }

    // MARK: Loading

    /// Loads the conversation and messages newer than those held (or the
    /// newest page, the first time). Calls made while a reload runs are
    /// folded into one more pass after it.
    public func reload() async throws {
        if reloading {
            reloadAgain = true
            return
        }
        reloading = true
        defer { reloading = false }
        repeat {
            reloadAgain = false
            try await performReload()
        } while reloadAgain
    }

    private func performReload() async throws {
        let conversation = try await api.get(Conversation.self, "/v1/sdk/conversation")
        try checkNotCleared()
        if needsFreshLoad || newerCursor == nil {
            try await loadNewestPage()
        } else {
            let catchUp = newerCursor
            var cursor = newerCursor
            // More revisions than new messages: something else changed (a
            // reaction or receipt), so reload from the first message on
            // screen, not only newer ones.
            var refreshingVisible = false
            if let held = state.conversation, held.id == conversation.id,
               conversation.revision - held.revision > conversation.sequence - held.sequence,
               let start = refreshStart()
            {
                cursor = Self.afterCursor(start - 1)
                refreshingVisible = true
            }
            var pages = 0
            while let after = cursor {
                let page = try await api.get(
                    MessagePage.self, "/v1/sdk/conversation/messages",
                    query: [.init(name: "after", value: after), .init(name: "limit", value: "\(Self.catchUpPageSize)")])
                try checkNotCleared()
                merge(page.messages)
                newerCursor = page.newerCursor
                pages += 1
                guard page.nextCursor != nil else { break }
                if pages >= Self.maxCatchUpPages {
                    if refreshingVisible {
                        // The screen is refreshed; the history the user is
                        // reading stays, and only new messages are left to fetch.
                        refreshingVisible = false
                        pages = 0
                        cursor = catchUp
                        newerCursor = catchUp
                        continue
                    }
                    // Too far behind to page through: show the newest page instead.
                    try await loadNewestPage()
                    break
                }
                cursor = page.newerCursor
            }
        }
        apply(conversation)
        let unread = try await api.get(UnreadCount.self, "/v1/sdk/unread")
        try checkNotCleared()
        state.unreadCount = unread.unread
        persist()
    }

    /// Where a refresh of the messages on screen starts: the first visible
    /// message, or the newest page's worth when the UI hasn't said.
    private func refreshStart() -> Int? {
        guard let oldest = state.messages.first?.sequence, let newest = state.messages.last?.sequence else {
            return nil
        }
        let start = firstVisibleSequence ?? max(oldest, newest - Self.pageSize + 1)
        return min(max(start, oldest), newest)
    }

    /// An `after` cursor at `sequence`. Cursors are opaque to other clients;
    /// the SDK reloads from a sequence it chooses.
    static func afterCursor(_ sequence: Int) -> String {
        Data("after:\(max(0, sequence))".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Tells the store the oldest message on screen (by sequence), so a
    /// change that isn't a new message refreshes what the user sees.
    public func setFirstVisibleSequence(_ sequence: Int?) {
        firstVisibleSequence = sequence
    }

    /// Loads older pages until the message with `id` is held, for jumping to
    /// a quoted message. Returns whether it's held. Gives up after
    /// `maxJumpPages` pages.
    @discardableResult
    public func loadUntilMessage(id: String) async throws -> Bool {
        var pages = 0
        while !state.messages.contains(where: { $0.id == id }) {
            guard state.hasOlderMessages, pages < Self.maxJumpPages else { return false }
            if state.isLoadingOlder {
                await Task.yield()
                continue
            }
            try await loadOlder()
            pages += 1
        }
        return true
    }

    /// Jumping to a quoted message loads at most this many older pages.
    static let maxJumpPages = 20

    private func loadNewestPage() async throws {
        let page = try await api.get(
            MessagePage.self, "/v1/sdk/conversation/messages",
            query: [.init(name: "limit", value: "\(Self.pageSize)")])
        try checkNotCleared()
        merge(page.messages, replacing: true)
        olderCursor = page.nextCursor
        state.hasOlderMessages = page.nextCursor != nil
        newerCursor = page.newerCursor
        needsFreshLoad = false
    }

    /// Loads the page before the oldest message held. The UI keeps the
    /// visible message in place while these are prepended.
    public func loadOlder() async throws {
        guard state.hasOlderMessages, !state.isLoadingOlder, let cursor = olderCursor else { return }
        state.isLoadingOlder = true
        defer { state.isLoadingOlder = false }
        let page = try await api.get(
            MessagePage.self, "/v1/sdk/conversation/messages",
            query: [.init(name: "before", value: cursor), .init(name: "limit", value: "\(Self.pageSize)")])
        try checkNotCleared()
        merge(page.messages)
        olderCursor = page.nextCursor
        state.hasOlderMessages = page.nextCursor != nil
    }

    /// After `clear()`, responses still in flight are dropped.
    private func checkNotCleared() throws {
        if isCleared { throw ChatError.cancelled }
    }

    private func apply(_ conversation: Conversation) {
        // Never go back to an older revision (a slow response after a newer one).
        if let current = state.conversation, current.id == conversation.id,
           conversation.revision < current.revision
        {
            return
        }
        state.conversation = conversation
        lastReadSent = max(lastReadSent, conversation.endUserRead)
    }

    /// Inserts messages by sequence, replacing any with the same ID, and drops
    /// unsent copies the server has confirmed (same `clientId`).
    private func merge(_ incoming: [Message], replacing: Bool = false) {
        guard !incoming.isEmpty || replacing else { return }
        // Replacing with the newest page keeps anything newer than the page
        // (a send confirmed while the page was loading).
        let pageTop = incoming.map(\.sequence).max() ?? 0
        let base = replacing ? state.messages.filter { $0.sequence > pageTop } : state.messages
        var byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        for message in incoming { byID[message.id] = message }
        let merged = byID.values.sorted { $0.sequence < $1.sequence }
        let confirmed = Set(incoming.filter { $0.senderType.isEndUser }.map(\.clientId))
        let removed = state.pending.filter { confirmed.contains($0.clientId) }
        var next = state
        next.messages = merged
        next.pending.removeAll { confirmed.contains($0.clientId) }
        if incoming.contains(where: { !$0.senderType.isEndUser }) { next.teamIsTyping = false }
        state = next
        for message in removed {
            for image in message.images { cache.removeImageData(for: image.idempotencyKey) }
        }
    }

    // MARK: Sending

    /// Queues a message and sends it. Returns nil for an empty message.
    ///
    /// - Parameters:
    ///   - text: the message text, Markdown allowed.
    ///   - images: up to 4 photos.
    ///   - replyTo: the message this one replies to (a confirmed one).
    @discardableResult
    public func send(text: String, images: [ImageUpload] = [], replyTo: Message? = nil) -> OutgoingMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return nil }
        let outgoing = OutgoingMessage(
            clientId: UUID().uuidString.lowercased(), text: trimmed,
            images: images.prefix(4).map { image in
                let key = UUID().uuidString.lowercased()
                cache.saveImageData(image.data, for: key)
                return OutgoingImage(idempotencyKey: key, width: image.width, height: image.height)
            },
            createdAt: clock.now(), state: .sending, replyTo: replyTo.map(ReplyPreview.init))
        state.pending.append(outgoing)
        persist()
        Task { await realtime.setTyping(false) }
        pump()
        return outgoing
    }

    /// Resends a failed message with its original `clientId`.
    public func retry(_ clientId: String) {
        guard let index = state.pending.firstIndex(where: { $0.clientId == clientId }) else { return }
        state.pending[index].state = .sending
        persist()
        pump()
    }

    /// Drops an unsent message.
    public func discard(_ clientId: String) {
        guard let index = state.pending.firstIndex(where: { $0.clientId == clientId }) else { return }
        let removed = state.pending.remove(at: index)
        for image in removed.images { cache.removeImageData(for: image.idempotencyKey) }
        persist()
    }

    /// Sends queued messages one at a time, in order. Stops at a retryable
    /// failure (offline, server trouble) and resumes on the next reconnect.
    func pump() {
        guard !pumping, !state.isSignedOut, !isCleared else { return }
        pumping = true
        pumpTask = Task {
            defer { pumping = false }
            var skipped = Set<String>()
            while !isCleared, !Task.isCancelled, let next = state.pending.first(where: { $0.state == .sending && !skipped.contains($0.clientId) }) {
                switch await deliver(next) {
                case .sent:
                    continue
                case .failed:
                    skipped.insert(next.clientId)
                case .wait:
                    return
                }
            }
        }
    }

    private enum Delivery { case sent, failed, wait }

    private func deliver(_ message: OutgoingMessage) async -> Delivery {
        var backoff = Backoff(base: 1, cap: 16)
        for attempt in 1...Self.sendAttempts {
            do {
                try await deliverOnce(message.clientId)
                return .sent
            } catch let error as ChatError where error.isRetryable {
                guard attempt < Self.sendAttempts else { return .wait }
                if case .network = error, !state.isConnected, attempt >= 2 { return .wait }
                var delay = backoff.next()
                if case .api(_, _, let retryAfter?) = error { delay = max(delay, retryAfter) }
                try? await clock.sleep(seconds: delay)
            } catch ChatError.signedOut, ChatError.notIdentified, ChatError.cancelled {
                return .wait
            } catch {
                markFailed(message.clientId)
                return .failed
            }
        }
        return .wait
    }

    private func deliverOnce(_ clientId: String) async throws {
        guard !isCleared, var message = state.pending.first(where: { $0.clientId == clientId }) else { return }
        for index in message.images.indices where message.images[index].attachment == nil {
            let key = message.images[index].idempotencyKey
            guard let data = cache.imageData(for: key) else { throw ChatError.invalidResponse }
            let response = try await api.send(
                "POST", "/v1/sdk/conversation/attachments", body: data,
                contentType: "application/octet-stream", headers: ["Idempotency-Key": key])
            guard let attachment = try? JSONDecoder.chat.decode(Attachment.self, from: response.body)
            else { throw ChatError.invalidResponse }
            guard !isCleared else { throw ChatError.cancelled }
            message.images[index].attachment = attachment
            if let i = state.pending.firstIndex(where: { $0.clientId == clientId }) {
                state.pending[i].images[index].attachment = attachment
                persist()
            }
        }
        struct Body: Encodable, Sendable {
            var clientId: String
            var text: String
            var attachmentIds: [String]
            var replyToId: String?
        }
        let sent = try await api.post(
            Message.self, "/v1/sdk/conversation/messages",
            json: Body(
                clientId: message.clientId, text: message.text,
                attachmentIds: message.images.compactMap { $0.attachment?.id }, replyToId: message.replyTo?.id))
        guard !isCleared else { throw ChatError.cancelled }
        merge([sent])
        // A send moves the conversation forward; the socket's change event
        // (or the next reload) brings the revision and receipts.
        persist()
    }

    private func markFailed(_ clientId: String) {
        guard let index = state.pending.firstIndex(where: { $0.clientId == clientId }) else { return }
        state.pending[index].state = .failed
        persist()
    }

    // MARK: Reactions

    /// Sets the end user's reaction on a message (one per message; a new one
    /// replaces it), or removes it with nil. Shown at once; the server's
    /// answer then replaces it, and a failure puts back what was there.
    public func setReaction(_ emoji: String?, on messageId: String) async throws {
        guard let index = state.messages.firstIndex(where: { $0.id == messageId }) else { return }
        let generation = (reactionGenerations[messageId] ?? 0) + 1
        reactionGenerations[messageId] = generation
        let previous = state.messages[index].reactions
        let shown = Self.reactions(previous, setting: emoji)
        state.messages[index].reactions = shown
        // One write per message at a time, so the server sees selections in
        // the order the user made them.
        let earlier = reactionWrites[messageId]
        let write = Task { [api] () throws -> Message in
            _ = await earlier?.result
            let path = "/v1/sdk/conversation/messages/\(messageId)/reaction"
            let response: HTTPResponse
            if let emoji {
                struct Body: Encodable, Sendable { var emoji: String }
                response = try await api.send("PUT", path, body: try JSONEncoder.chat.encode(Body(emoji: emoji)))
            } else {
                response = try await api.send("DELETE", path)
            }
            return try JSONDecoder.chat.decode(Message.self, from: response.body)
        }
        reactionWrites[messageId] = write
        defer {
            if reactionWrites[messageId] == write { reactionWrites[messageId] = nil }
        }
        do {
            let message = try await write.value
            try checkNotCleared()
            // A newer selection is on screen and merges its own response.
            guard reactionGenerations[messageId] == generation else { return }
            merge([message])
            persist()
        } catch {
            // Put back what was there, unless something newer replaced it meanwhile.
            if reactionGenerations[messageId] == generation,
               let i = state.messages.firstIndex(where: { $0.id == messageId }), state.messages[i].reactions == shown
            {
                state.messages[i].reactions = previous
            }
            throw error
        }
    }

    /// `reactions` with the end user's reaction replaced by `emoji` (or removed).
    nonisolated static func reactions(_ reactions: [Reaction], setting emoji: String?) -> [Reaction] {
        var result = reactions
        if let index = result.firstIndex(where: \.mine) {
            result[index].mine = false
            result[index].count -= 1
            if result[index].count <= 0 { result.remove(at: index) }
        }
        guard let emoji else { return result }
        if let index = result.firstIndex(where: { $0.emoji == emoji }) {
            result[index].count += 1
            result[index].mine = true
        } else {
            result.append(Reaction(emoji: emoji, count: 1, mine: true))
        }
        return result
    }

    // MARK: Images

    /// A signed URL for a sent image.
    public func imageURL(for attachment: Attachment) async throws -> URL {
        try await api.attachmentURL(attachment.id)
    }

    /// The bytes of an image that hasn't been sent yet.
    public func localImageData(_ image: OutgoingImage) -> Data? {
        cache.imageData(for: image.idempotencyKey)
    }

    // MARK: Receipts and typing

    /// Marks everything loaded as read. Forward-only: never sends a lower
    /// sequence than one already sent or acknowledged.
    public func markRead() {
        guard let target = state.messages.last?.sequence, target > lastReadSent,
              state.conversation != nil
        else { return }
        lastReadSent = target
        state.unreadCount = 0
        Task {
            struct Body: Encodable, Sendable { var sequence: Int }
            if let conversation = try? await api.post(
                Conversation.self, "/v1/sdk/conversation/read", json: Body(sequence: target))
            {
                apply(conversation)
                persist()
            } else if lastReadSent == target {
                // Let a later call try again.
                lastReadSent = state.conversation?.endUserRead ?? 0
            }
        }
    }

    /// Call on every edit of the input (`true`) and on send, clear or leaving
    /// the screen (`false`). Sends `true` at most every 1.5 s.
    public func setTyping(_ typing: Bool) {
        Task { await realtime.setTyping(typing) }
    }

    private func setTeamTyping(_ typing: Bool, until expiresAt: Date?) {
        typingClear?.cancel()
        state.teamIsTyping = typing
        guard typing else { return }
        // A missed stop expires 3.5 s after the last start.
        let clock = self.clock
        var seconds = 3.5
        if let expiresAt { seconds = max(0, expiresAt.timeIntervalSince(clock.now())) }
        typingClear = Task { [weak self] in
            try? await clock.sleep(seconds: seconds)
            guard !Task.isCancelled else { return }
            self?.state.teamIsTyping = false
        }
    }

    // MARK: Persistence

    private func persist() {
        guard !isCleared else { return }
        let snapshot = CachedThread(
            appKey: appKey, userId: userId, conversation: state.conversation,
            messages: Array(state.messages.suffix(Self.cachedMessages)), pending: state.pending)
        Task { await cacheWriter.save(snapshot) }
    }

    /// Deletes everything held for this user, in memory and on disk.
    func clear() async {
        isCleared = true
        pumpTask?.cancel()
        listener?.cancel()
        typingClear?.cancel()
        for message in state.pending {
            for image in message.images { cache.removeImageData(for: image.idempotencyKey) }
        }
        state = State()
        await cacheWriter.clear()
    }
}

/// Writes cache snapshots in order, off the main actor.
actor CacheWriter {
    private let cache: MessageCache
    /// Set by `clear()`; snapshots queued before it but arriving after are dropped.
    private var cleared = false
    init(cache: MessageCache) { self.cache = cache }
    func save(_ thread: CachedThread?) {
        guard !cleared else { return }
        cache.save(thread)
    }
    func clear() {
        cleared = true
        cache.save(nil)
    }
}

/// Stops an observation when cancelled or released.
public final class ObservationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var onCancel: (@Sendable () -> Void)?

    public init(_ onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { onCancel = nil }
            return onCancel
        }
        action?()
    }

    deinit { cancel() }
}
