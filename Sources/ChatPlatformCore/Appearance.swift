import Foundation

/// The app's appearance settings from the dashboard, API, CLI or MCP: the
/// remote layer of the SDK's customization. Settings in code win over it; it
/// wins over the SDK's defaults.
///
/// Every field is optional, and keys this SDK doesn't know are ignored, so
/// settings added later never break an older app.
public struct RemoteAppearance: Codable, Sendable, Equatable {
    /// A color for light and dark mode, as `#RRGGBB`. A missing side falls
    /// through to the next layer.
    public struct ColorPair: Codable, Sendable, Equatable {
        public var light: String?
        public var dark: String?

        public init(light: String? = nil, dark: String? = nil) {
            self.light = light
            self.dark = dark
        }
    }

    public struct Colors: Codable, Sendable, Equatable {
        public var accent: ColorPair?
        public var background: ColorPair?
        public var outgoingBubble: ColorPair?
        public var outgoingText: ColorPair?
        public var incomingBubble: ColorPair?
        public var incomingText: ColorPair?

        public init(
            accent: ColorPair? = nil, background: ColorPair? = nil, outgoingBubble: ColorPair? = nil,
            outgoingText: ColorPair? = nil, incomingBubble: ColorPair? = nil, incomingText: ColorPair? = nil
        ) {
            self.accent = accent
            self.background = background
            self.outgoingBubble = outgoingBubble
            self.outgoingText = outgoingText
            self.incomingBubble = incomingBubble
            self.incomingText = incomingText
        }
    }

    public struct Preferences: Codable, Sendable, Equatable {
        public var showReadReceipts: Bool?
        public var showTypingIndicator: Bool?
        public var allowPhotos: Bool?
        /// Each teammate's and the AI's name and avatar on their messages.
        public var showSenders: Bool?
        /// The chat's title by language code (`en`, `pt-BR`).
        public var title: [String: String]?
        /// The text of an empty chat by language code.
        public var emptyStateMessage: [String: String]?

        public init(
            showReadReceipts: Bool? = nil, showTypingIndicator: Bool? = nil, allowPhotos: Bool? = nil,
            title: [String: String]? = nil, emptyStateMessage: [String: String]? = nil, showSenders: Bool? = nil
        ) {
            self.showReadReceipts = showReadReceipts
            self.showTypingIndicator = showTypingIndicator
            self.allowPhotos = allowPhotos
            self.showSenders = showSenders
            self.title = title
            self.emptyStateMessage = emptyStateMessage
        }
    }

    /// Goes up by one on every save; 0 for an app that never saved.
    public var version: Int
    public var colors: Colors
    public var preferences: Preferences

    public init(version: Int = 0, colors: Colors = Colors(), preferences: Preferences = Preferences()) {
        self.version = version
        self.colors = colors
        self.preferences = preferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        colors = try container.decodeIfPresent(Colors.self, forKey: .colors) ?? Colors()
        preferences = try container.decodeIfPresent(Preferences.self, forKey: .preferences) ?? Preferences()
    }

    /// The text for the first of `languages` that `texts` has, matching a
    /// whole tag (`pt-BR`) before a language alone (`pt`). Nil when none
    /// match, so the next layer (or the SDK's own translation) applies
    /// rather than text in a language the user may not read.
    public static func text(_ texts: [String: String]?, languages: [String]) -> String? {
        guard let texts, !texts.isEmpty else { return nil }
        func base(_ tag: String) -> String {
            String(tag.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(tag)).lowercased()
        }
        func normalized(_ tag: String) -> String { tag.replacingOccurrences(of: "_", with: "-").lowercased() }
        for language in languages {
            if let match = texts.first(where: { normalized($0.key) == normalized(language) }) { return match.value }
            let wanted = base(language)
            if let match = texts.keys.sorted().first(where: { base($0) == wanted }) { return texts[match] }
        }
        return nil
    }

    /// Red, green and blue from 0 to 1 for a `#RRGGBB` color, or nil if malformed.
    public static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255
        )
    }
}

/// The last appearance document fetched, kept on disk between launches.
public struct CachedAppearance: Codable, Sendable, Equatable {
    public var appKey: String
    public var appearance: RemoteAppearance
    public var etag: String?

    public init(appKey: String, appearance: RemoteAppearance, etag: String?) {
        self.appKey = appKey
        self.appearance = appearance
        self.etag = etag
    }
}

public protocol AppearanceCache: Sendable {
    func load() -> CachedAppearance?
    func save(_ cached: CachedAppearance)
}

/// One JSON file per app key under Application Support.
final class FileAppearanceCache: AppearanceCache, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(appKey: String, directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatPlatform", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = String(appKey.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }.map(Character.init))
        url = base.appendingPathComponent("appearance-\(safe).json")
    }

    func load() -> CachedAppearance? {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder.chat.decode(CachedAppearance.self, from: data)
        }
    }

    func save(_ cached: CachedAppearance) {
        lock.withLock {
            if let data = try? JSONEncoder.chat.encode(cached) { try? data.write(to: url, options: .atomic) }
        }
    }
}

public final class InMemoryAppearanceCache: AppearanceCache, @unchecked Sendable {
    private let lock = NSLock()
    private var cached: CachedAppearance?

    public init(_ cached: CachedAppearance? = nil) { self.cached = cached }

    public func load() -> CachedAppearance? { lock.withLock { cached } }
    public func save(_ cached: CachedAppearance) { lock.withLock { self.cached = cached } }
}

/// Holds the app's remote appearance: the cached copy at once, and a fresh
/// one after `refresh()`. Shared by the client and its conversation, so a
/// chat screen reads the copy on hand when it opens and asks for a new one
/// for the next screen; a screen already showing never changes.
@MainActor
final class AppearanceStore {
    private let api: APIClient
    private let cache: AppearanceCache
    private let appKey: String
    let isEnabled: Bool
    private var cached: CachedAppearance?
    private var refreshing: Task<Void, Never>?

    init(api: APIClient, cache: AppearanceCache, appKey: String, isEnabled: Bool) {
        self.api = api
        self.cache = cache
        self.appKey = appKey
        self.isEnabled = isEnabled
        if isEnabled, let stored = cache.load(), stored.appKey == appKey { cached = stored }
    }

    /// Nil when remote appearance is off or nothing has been fetched yet.
    var current: RemoteAppearance? { isEnabled ? cached?.appearance : nil }

    /// Fetches the document unless a fetch is already running; failures
    /// keep the cached copy.
    func refresh() async {
        guard isEnabled else { return }
        if let refreshing { return await refreshing.value }
        let task = Task { [api, appKey] in
            do {
                guard let (appearance, etag) = try await api.appearance(etag: self.cached?.etag) else { return }
                let fresh = CachedAppearance(appKey: appKey, appearance: appearance, etag: etag)
                self.cached = fresh
                self.cache.save(fresh)
            } catch {
                // Offline or an outage: the cached copy (or the defaults) stays.
            }
        }
        refreshing = task
        await task.value
        refreshing = nil
    }
}
