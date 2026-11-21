#if canImport(UIKit)
import UIKit

/// Colors, fonts and shapes of the chat UI: the result of the appearance
/// layers (`ChatAppearance`), with defaults that follow the system's light
/// and dark appearance.
public struct ChatTheme {
    /// Accent: send button, links, the outgoing bubble. Defaults to iMessage blue.
    public var tint: UIColor
    public var background: UIColor
    public var outgoingBubble: UIColor
    public var outgoingText: UIColor
    public var incomingBubble: UIColor
    public var incomingText: UIColor
    public var secondaryText: UIColor
    public var failure: UIColor
    public var inputBackground: UIColor
    /// Message text; scaled with Dynamic Type.
    public var bodyFont: UIFont
    public var captionFont: UIFont
    public var bubbleCornerRadius: CGFloat

    public init(
        tint: UIColor = .systemBlue,
        background: UIColor = .systemBackground,
        outgoingBubble: UIColor? = nil,
        outgoingText: UIColor = .white,
        incomingBubble: UIColor = ChatTheme.messagesGray,
        incomingText: UIColor = .label,
        secondaryText: UIColor = .secondaryLabel,
        failure: UIColor = .systemRed,
        inputBackground: UIColor = .secondarySystemBackground,
        bodyFont: UIFont = .preferredFont(forTextStyle: .body),
        captionFont: UIFont = .preferredFont(forTextStyle: .caption2),
        bubbleCornerRadius: CGFloat = 20
    ) {
        self.tint = tint
        self.background = background
        self.outgoingBubble = outgoingBubble ?? tint
        self.outgoingText = outgoingText
        self.incomingBubble = incomingBubble
        self.incomingText = incomingText
        self.secondaryText = secondaryText
        self.failure = failure
        self.inputBackground = inputBackground
        self.bodyFont = bodyFont
        self.captionFont = captionFont
        self.bubbleCornerRadius = bubbleCornerRadius
    }

    public static var `default`: ChatTheme { ChatTheme() }

    /// The incoming bubble's gray in Messages: #E9E9EB, and #262629 in dark mode.
    public static let messagesGray = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 38 / 255, green: 38 / 255, blue: 41 / 255, alpha: 1)
            : UIColor(red: 233 / 255, green: 233 / 255, blue: 235 / 255, alpha: 1)
    }

    /// Names above incoming runs: a lighter gray than `secondaryLabel` in dark mode, like Messages.
    static let senderName = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 174 / 255, green: 174 / 255, blue: 178 / 255, alpha: 1)
            : UIColor(red: 128 / 255, green: 128 / 255, blue: 133 / 255, alpha: 1)
    }

    /// The theme with fonts sized for `traits`' Dynamic Type setting. A
    /// text-style font (`preferredFont`) is resolved again for that size,
    /// keeping its weight and traits; any other font is treated as its size
    /// at the default setting and scaled with `UIFontMetrics`, including one
    /// the host already scaled with `UIFontMetrics`.
    func scaled(for traits: UITraitCollection) -> ChatTheme {
        var theme = self
        theme.bodyFont = Self.scale(bodyFont, style: .body, traits: traits)
        theme.captionFont = Self.scale(captionFont, style: .caption2, traits: traits)
        return theme
    }

    private static let textStyles: Set<UIFont.TextStyle> = [
        .largeTitle, .title1, .title2, .title3, .headline, .subheadline, .body, .callout, .footnote, .caption1,
        .caption2,
    ]

    static func scale(_ font: UIFont, style: UIFont.TextStyle, traits: UITraitCollection) -> UIFont {
        // System fonts carry a usage name here too; only real text styles count.
        if let name = font.fontDescriptor.object(forKey: .textStyle) as? String,
           textStyles.contains(UIFont.TextStyle(rawValue: name))
        {
            let base = UIFontDescriptor.preferredFontDescriptor(
                withTextStyle: UIFont.TextStyle(rawValue: name), compatibleWith: traits)
            let descriptor = base.withSymbolicTraits(font.fontDescriptor.symbolicTraits) ?? base
            return UIFont(descriptor: descriptor, size: 0)
        }
        // A font the host already scaled with UIFontMetrics can't be scaled
        // again (UIKit throws), so scale a copy built from its descriptor.
        let base = UIFont(descriptor: font.fontDescriptor, size: font.pointSize)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: base, compatibleWith: traits)
    }
}
#endif
