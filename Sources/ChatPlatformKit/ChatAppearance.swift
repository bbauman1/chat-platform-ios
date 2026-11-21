#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// A color for light and dark mode. Either side may be nil, which leaves that
/// side to the next layer.
public struct ChatColor {
    public var light: UIColor?
    public var dark: UIColor?

    public init(light: UIColor? = nil, dark: UIColor? = nil) {
        self.light = light
        self.dark = dark
    }

    /// One color for both modes; a dynamic color such as `.systemPink` keeps adapting.
    public init(_ color: UIColor) {
        self.init(light: color, dark: color)
    }

    /// This pair with its unset sides taken from `lower`.
    func over(_ lower: ChatColor?) -> ChatColor {
        ChatColor(light: light ?? lower?.light, dark: dark ?? lower?.dark)
    }

    /// The pair as one dynamic color, with `fallback` for an unset side.
    func resolved(_ fallback: UIColor) -> UIColor {
        if light == nil, dark == nil { return fallback }
        let light = light, dark = dark
        return UIColor { traits in
            let side = traits.userInterfaceStyle == .dark ? dark : light
            return (side ?? fallback).resolvedColor(with: traits)
        }
    }
}

/// How the chat looks and behaves. Every field is optional: nil leaves it to
/// the next layer. The layers, highest first:
///
/// 1. `ChatPresentationOptions.appearance`, for one chat screen.
/// 2. `ChatOptions.appearance`, passed to `ChatClient.configure` at launch.
/// 3. The app's appearance settings from the dashboard, API, CLI or MCP
///    (colors, receipts, typing, photos, title and empty state).
/// 4. The SDK's defaults: system colors, iMessage blue, Dynamic Type fonts.
///
/// Fonts, the corner radius and the title font exist only in code.
public struct ChatAppearance {
    /// Send button, links and, unless `outgoingBubble` is set, the user's bubbles.
    public var accent: ChatColor?
    public var background: ChatColor?
    public var outgoingBubble: ChatColor?
    public var outgoingText: ChatColor?
    public var incomingBubble: ChatColor?
    public var incomingText: ChatColor?
    /// Timestamps, receipts and other secondary text.
    public var secondaryText: ChatColor?
    /// The composer's field and attach button before iOS 26.
    public var inputBackground: ChatColor?
    /// Message text, at its size for the default Dynamic Type setting; the SDK
    /// scales it.
    public var bodyFont: UIFont?
    /// Timestamps, receipts and banners, scaled like `bodyFont`.
    public var captionFont: UIFont?
    /// The navigation bar's title.
    public var titleFont: UIFont?
    public var bubbleCornerRadius: CGFloat?
    /// "Seen" under the user's last message once the team read it. Without
    /// it, the message shows "Sent".
    public var showReadReceipts: Bool?
    /// The dots while someone on the team is typing.
    public var showTypingIndicator: Bool?
    /// The composer's photo button.
    public var allowPhotos: Bool?
    /// A group chat look: each teammate's and the AI's name above their
    /// messages, their avatar beside them, and the people in the title.
    /// Defaults to on.
    public var showSenders: Bool?
    /// The navigation title. Defaults to "Support" in the user's language.
    public var title: String?
    /// The text of a chat with no messages yet.
    public var emptyStateMessage: String?

    public init(
        accent: ChatColor? = nil, background: ChatColor? = nil, outgoingBubble: ChatColor? = nil,
        outgoingText: ChatColor? = nil, incomingBubble: ChatColor? = nil, incomingText: ChatColor? = nil,
        secondaryText: ChatColor? = nil, inputBackground: ChatColor? = nil, bodyFont: UIFont? = nil,
        captionFont: UIFont? = nil, titleFont: UIFont? = nil, bubbleCornerRadius: CGFloat? = nil,
        showReadReceipts: Bool? = nil, showTypingIndicator: Bool? = nil, allowPhotos: Bool? = nil,
        title: String? = nil, emptyStateMessage: String? = nil, showSenders: Bool? = nil
    ) {
        self.accent = accent
        self.background = background
        self.outgoingBubble = outgoingBubble
        self.outgoingText = outgoingText
        self.incomingBubble = incomingBubble
        self.incomingText = incomingText
        self.secondaryText = secondaryText
        self.inputBackground = inputBackground
        self.bodyFont = bodyFont
        self.captionFont = captionFont
        self.titleFont = titleFont
        self.bubbleCornerRadius = bubbleCornerRadius
        self.showReadReceipts = showReadReceipts
        self.showTypingIndicator = showTypingIndicator
        self.allowPhotos = allowPhotos
        self.showSenders = showSenders
        self.title = title
        self.emptyStateMessage = emptyStateMessage
    }

    /// The dashboard's settings as a layer. Malformed colors and texts in
    /// none of `languages` are left unset.
    init(remote: RemoteAppearance, languages: [String]) {
        func pair(_ pair: RemoteAppearance.ColorPair?) -> ChatColor? {
            guard let pair else { return nil }
            func color(_ hex: String?) -> UIColor? {
                guard let hex, let rgb = RemoteAppearance.rgb(hex) else { return nil }
                return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            }
            let result = ChatColor(light: color(pair.light), dark: color(pair.dark))
            return result.light == nil && result.dark == nil ? nil : result
        }
        let colors = remote.colors, preferences = remote.preferences
        self.init(
            accent: pair(colors.accent), background: pair(colors.background),
            outgoingBubble: pair(colors.outgoingBubble), outgoingText: pair(colors.outgoingText),
            incomingBubble: pair(colors.incomingBubble), incomingText: pair(colors.incomingText),
            showReadReceipts: preferences.showReadReceipts, showTypingIndicator: preferences.showTypingIndicator,
            allowPhotos: preferences.allowPhotos,
            title: RemoteAppearance.text(preferences.title, languages: languages),
            emptyStateMessage: RemoteAppearance.text(preferences.emptyStateMessage, languages: languages),
            showSenders: preferences.showSenders)
    }

    /// This layer over `lower`: each field this layer sets wins, and each
    /// color side it leaves unset comes from `lower`.
    public func over(_ lower: ChatAppearance) -> ChatAppearance {
        func color(_ upper: ChatColor?, _ lower: ChatColor?) -> ChatColor? {
            guard let upper else { return lower }
            return upper.over(lower)
        }
        return ChatAppearance(
            accent: color(accent, lower.accent), background: color(background, lower.background),
            outgoingBubble: color(outgoingBubble, lower.outgoingBubble),
            outgoingText: color(outgoingText, lower.outgoingText),
            incomingBubble: color(incomingBubble, lower.incomingBubble),
            incomingText: color(incomingText, lower.incomingText),
            secondaryText: color(secondaryText, lower.secondaryText),
            inputBackground: color(inputBackground, lower.inputBackground),
            bodyFont: bodyFont ?? lower.bodyFont, captionFont: captionFont ?? lower.captionFont,
            titleFont: titleFont ?? lower.titleFont, bubbleCornerRadius: bubbleCornerRadius ?? lower.bubbleCornerRadius,
            showReadReceipts: showReadReceipts ?? lower.showReadReceipts,
            showTypingIndicator: showTypingIndicator ?? lower.showTypingIndicator,
            allowPhotos: allowPhotos ?? lower.allowPhotos, title: title ?? lower.title,
            emptyStateMessage: emptyStateMessage ?? lower.emptyStateMessage,
            showSenders: showSenders ?? lower.showSenders)
    }

    /// The layers for a chat about `conversation`: `presentation`, the
    /// options given to `ChatClient.configure`, and the dashboard's settings
    /// as last fetched (unless turned off).
    @MainActor
    static func layered(
        conversation: ConversationStore, presentation: ChatPresentationOptions, strings: ChatStrings
    ) -> ChatAppearance {
        let code = ChatOptions.configured[conversation.appKey] ?? ChatOptions()
        return layered(
            presentation: presentation.appearance, code: code.appearance,
            remote: code.remoteAppearance ? conversation.remoteAppearance : nil, languages: strings.languages)
    }

    /// The four layers merged, highest first.
    static func layered(
        presentation: ChatAppearance, code: ChatAppearance, remote: RemoteAppearance?, languages: [String]
    ) -> ChatAppearance {
        let remoteLayer = remote.map { ChatAppearance(remote: $0, languages: languages) } ?? ChatAppearance()
        return presentation.over(code.over(remoteLayer))
    }
}

extension ChatTheme {
    /// The theme for merged layers, with the SDK's defaults for anything unset.
    /// An unset outgoing bubble side follows the accent.
    init(_ appearance: ChatAppearance) {
        let defaults = ChatTheme()
        let accent = appearance.accent?.resolved(defaults.tint) ?? defaults.tint
        let outgoing = appearance.outgoingBubble.map { $0.over(appearance.accent) } ?? appearance.accent
        self.init(
            tint: accent,
            background: appearance.background?.resolved(defaults.background) ?? defaults.background,
            outgoingBubble: outgoing?.resolved(defaults.tint) ?? defaults.tint,
            outgoingText: appearance.outgoingText?.resolved(defaults.outgoingText) ?? defaults.outgoingText,
            incomingBubble: appearance.incomingBubble?.resolved(defaults.incomingBubble) ?? defaults.incomingBubble,
            incomingText: appearance.incomingText?.resolved(defaults.incomingText) ?? defaults.incomingText,
            secondaryText: appearance.secondaryText?.resolved(defaults.secondaryText) ?? defaults.secondaryText,
            inputBackground: appearance.inputBackground?.resolved(defaults.inputBackground)
                ?? defaults.inputBackground,
            bodyFont: appearance.bodyFont ?? defaults.bodyFont,
            captionFont: appearance.captionFont ?? defaults.captionFont,
            bubbleCornerRadius: appearance.bubbleCornerRadius ?? defaults.bubbleCornerRadius)
    }
}

/// Settings for every chat screen, passed once to `ChatClient.configure`.
public struct ChatOptions {
    /// The code layer: beats the dashboard's settings, loses to a presentation's.
    public var appearance: ChatAppearance
    /// Whether to fetch and apply the app's appearance settings from the
    /// dashboard. Turn it off to style the chat only in code.
    public var remoteAppearance: Bool

    public init(appearance: ChatAppearance = ChatAppearance(), remoteAppearance: Bool = true) {
        self.appearance = appearance
        self.remoteAppearance = remoteAppearance
    }

    /// Options by app key, from `ChatClient.configure`.
    @MainActor static var configured: [String: ChatOptions] = [:]
}

/// Settings for one chat screen: the highest layer.
public struct ChatPresentationOptions {
    /// Overrides for this screen only.
    public var appearance: ChatAppearance
    /// Hides the navigation bar while the chat is on screen; nil leaves it as
    /// the host has it.
    public var navigationBarHidden: Bool?
    /// A close button on the leading side that dismisses the chat, for a chat
    /// presented modally.
    public var showsCloseButton: Bool
    /// Text to start the composer with when the user has no unsent draft,
    /// such as "About order #1234: ".
    public var draft: String?

    public init(
        appearance: ChatAppearance = ChatAppearance(), title: String? = nil, navigationBarHidden: Bool? = nil,
        showsCloseButton: Bool = false, draft: String? = nil
    ) {
        var appearance = appearance
        if let title { appearance.title = title }
        self.appearance = appearance
        self.navigationBarHidden = navigationBarHidden
        self.showsCloseButton = showsCloseButton
        self.draft = draft
    }
}

extension ChatClient {
    /// Creates the app's client with settings for every chat screen, and
    /// fetches the app's appearance settings for the first chat.
    ///
    /// ```swift
    /// let chat = ChatClient.configure(
    ///     appKey: "app_…", apiURL: apiURL,
    ///     options: ChatOptions(appearance: ChatAppearance(bodyFont: UIFont(name: "Avenir Next", size: 17))))
    /// ```
    ///
    /// - Parameters:
    ///   - appKey: the app's public key from the dashboard.
    ///   - apiURL: the API's base URL.
    ///   - options: the code layer of the chat's appearance.
    public static func configure(appKey: String, apiURL: URL, options: ChatOptions = ChatOptions()) -> ChatClient {
        let client = ChatClient(
            configuration: ChatConfiguration(appKey: appKey, apiURL: apiURL, remoteAppearance: options.remoteAppearance))
        ChatOptions.configured[appKey] = options
        Task { await client.refreshAppearance() }
        return client
    }
}
#endif
