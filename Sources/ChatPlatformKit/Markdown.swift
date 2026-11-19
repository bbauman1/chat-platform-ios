#if canImport(UIKit)
import UIKit

/// Renders a message's inline Markdown (bold, italic, strikethrough, code,
/// links) and bare web links into an attributed string for a bubble. Block
/// syntax (headings, lists) is left as typed, like iMessage. Thread-safe.
enum MessageMarkdown {
    struct Style {
        var font: UIFont
        var color: UIColor
        var linkColor: UIColor
    }

    private static let markdownCharacters = CharacterSet(charactersIn: "*_`~[")

    static func render(_ text: String, style: Style) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.color]
        let output: NSMutableAttributedString
        if text.rangeOfCharacter(from: markdownCharacters) != nil,
           let parsed = try? AttributedString(
               markdown: text,
               options: .init(
                   allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                   failurePolicy: .returnPartiallyParsedIfPossible))
        {
            output = NSMutableAttributedString()
            for run in parsed.runs {
                var attributes = base
                let intent = run.inlinePresentationIntent ?? []
                attributes[.font] = font(style.font, intent)
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if intent.contains(.code) {
                    attributes[.backgroundColor] = style.color.withAlphaComponent(0.12)
                }
                if let link = run.link, isSafe(link) {
                    attributes[Self.linkKey] = link
                }
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        } else {
            output = NSMutableAttributedString(string: text, attributes: base)
        }
        detectLinks(in: output)
        output.enumerateAttribute(Self.linkKey, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard value != nil else { return }
            output.addAttributes(
                [.foregroundColor: style.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return output
    }

    private static func font(_ base: UIFont, _ intent: InlinePresentationIntent) -> UIFont {
        if intent.contains(.code) {
            return UIFont.monospacedSystemFont(ofSize: base.pointSize * 0.94, weight: .regular)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if intent.contains(.emphasized) { traits.insert(.traitItalic) }
        guard traits != base.fontDescriptor.symbolicTraits,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    /// Where a link's URL is kept. Not `.link`: a label draws `.link` text in
    /// the system's link color, whatever the theme's accent.
    static let linkKey = NSAttributedString.Key("ChatPlatformLink")

    /// Only web and mail links open; others (custom schemes, javascript:) render as text.
    static func isSafe(_ url: URL) -> Bool {
        ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Makes bare URLs tappable. Skipped for text that can't contain one, so
    /// long threads don't pay for detection on every message.
    private static func detectLinks(in text: NSMutableAttributedString) {
        let string = text.string
        guard string.contains("://") || string.localizedCaseInsensitiveContains("www."), let detector else { return }
        let whole = NSRange(location: 0, length: text.length)
        for match in detector.matches(in: string, range: whole) {
            guard let url = match.url, isSafe(url),
                  text.attribute(Self.linkKey, at: match.range.location, effectiveRange: nil) == nil
            else { continue }
            text.addAttribute(Self.linkKey, value: url, range: match.range)
        }
    }

    /// The link at a point in a label-sized box showing `text`, if any.
    static func link(at point: CGPoint, in text: NSAttributedString, size: CGSize) -> URL? {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyph = manager.glyphIndex(for: point, in: container)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .insetBy(dx: -4, dy: -4).contains(point)
        else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < text.length else { return nil }
        switch text.attribute(Self.linkKey, at: index, effectiveRange: nil) {
        case let url as URL: return url
        case let string as String: return URL(string: string)
        default: return nil
        }
    }
}
#endif
