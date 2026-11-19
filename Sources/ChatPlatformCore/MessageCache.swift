import Foundation

/// A message the end user wrote that the server hasn't confirmed yet. Its
/// `clientId` and each image's `idempotencyKey` stay the same across retries
/// and relaunches, so a resend can never create a duplicate.
public struct OutgoingMessage: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable {
        case sending
        /// Gave up after a non-retryable error or too many attempts; `retry` resends.
        case failed
    }

    public var clientId: String
    public var text: String
    public var images: [OutgoingImage]
    public var createdAt: Date
    public var state: State
    /// The message this one replies to.
    public var replyTo: ReplyPreview?
    public var id: String { clientId }

    public init(
        clientId: String, text: String, images: [OutgoingImage], createdAt: Date, state: State,
        replyTo: ReplyPreview? = nil
    ) {
        self.clientId = clientId
        self.text = text
        self.images = images
        self.createdAt = createdAt
        self.state = state
        self.replyTo = replyTo
    }
}

public struct OutgoingImage: Codable, Sendable, Equatable, Hashable {
    /// `Idempotency-Key` for the upload; the server derives the attachment ID from it.
    public var idempotencyKey: String
    /// Width and height of the local image, for layout before the upload finishes.
    public var width: Int
    public var height: Int
    /// Set once uploaded.
    public var attachment: Attachment?

    public init(idempotencyKey: String, width: Int, height: Int, attachment: Attachment? = nil) {
        self.idempotencyKey = idempotencyKey
        self.width = width
        self.height = height
        self.attachment = attachment
    }
}

/// What the SDK keeps on disk between launches, so the thread shows instantly
/// and unsent messages survive a relaunch.
public struct CachedThread: Codable, Sendable, Equatable {
    /// The app the thread belongs to; a cache from another app (or another
    /// environment's key) is never shown.
    public var appKey: String?
    public var userId: String
    public var conversation: Conversation?
    /// The newest messages, oldest first.
    public var messages: [Message]
    public var pending: [OutgoingMessage]

    public init(
        appKey: String?, userId: String, conversation: Conversation?, messages: [Message], pending: [OutgoingMessage]
    ) {
        self.appKey = appKey
        self.userId = userId
        self.conversation = conversation
        self.messages = messages
        self.pending = pending
    }
}

/// Local storage for the thread and for unsent image bytes.
public protocol MessageCache: Sendable {
    func load() -> CachedThread?
    func save(_ thread: CachedThread?)
    func imageData(for key: String) -> Data?
    func saveImageData(_ data: Data, for key: String)
    func removeImageData(for key: String)
}

/// Keeps everything in memory.
public final class InMemoryMessageCache: MessageCache, @unchecked Sendable {
    private let lock = NSLock()
    private var thread: CachedThread?
    private var images: [String: Data] = [:]

    public init() {}

    public func load() -> CachedThread? { lock.withLock { thread } }
    public func save(_ thread: CachedThread?) { lock.withLock { self.thread = thread } }
    public func imageData(for key: String) -> Data? { lock.withLock { images[key] } }
    public func saveImageData(_ data: Data, for key: String) { lock.withLock { images[key] = data } }
    public func removeImageData(for key: String) { lock.withLock { images[key] = nil } }
}

/// Files under Application Support (excluded from backups): `thread.json`
/// plus one file per unsent image.
public final class FileMessageCache: MessageCache, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatPlatform", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(
            at: base.appendingPathComponent("images"), withIntermediateDirectories: true)
        #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS) || os(visionOS)
        var url = base
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }

    private var threadURL: URL { directory.appendingPathComponent("thread.json") }

    private func imageURL(_ key: String) -> URL {
        // Keys are UUIDs we generate; strip anything else so a key can't escape the folder.
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("images").appendingPathComponent(safe)
    }

    public func load() -> CachedThread? {
        lock.withLock {
            guard let data = try? Data(contentsOf: threadURL) else { return nil }
            return try? JSONDecoder.chat.decode(CachedThread.self, from: data)
        }
    }

    public func save(_ thread: CachedThread?) {
        lock.withLock {
            guard let thread else {
                try? FileManager.default.removeItem(at: threadURL)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("images"))
                try? FileManager.default.createDirectory(
                    at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
                return
            }
            guard let data = try? JSONEncoder.chat.encode(thread) else { return }
            try? data.write(to: threadURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func imageData(for key: String) -> Data? {
        lock.withLock { try? Data(contentsOf: imageURL(key)) }
    }

    public func saveImageData(_ data: Data, for key: String) {
        lock.withLock {
            try? data.write(to: imageURL(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    public func removeImageData(for key: String) {
        lock.withLock { try? FileManager.default.removeItem(at: imageURL(key)) }
    }
}
