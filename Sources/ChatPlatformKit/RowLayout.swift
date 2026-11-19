#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// Frames for one row, computed once per (content, width, text size) and
/// cached. Cells only assign these frames: no Auto Layout and no text
/// measuring while scrolling.
struct MessageLayout: Equatable {
    var height: CGFloat
    var bubble: CGRect
    var text: CGRect
    var images: [CGRect]
    var status: CGRect
    var attributedText: NSAttributedString?
    /// The quoted message's faded bubble above this one, and its text.
    var quote: CGRect = .zero
    var quoteText: CGRect = .zero
    var quoteAttributedText: NSAttributedString?
    /// The tapback badge on the bubble's top corner, and its text.
    var reactions: CGRect = .zero
    var reactionsText: CGRect = .zero
    var reactionsAttributedText: NSAttributedString?
}

struct LayoutMetrics {
    var sideInset: CGFloat = 12
    var maxBubbleWidthFraction: CGFloat = 0.78
    var bubblePadding = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    var groupedSpacing: CGFloat = 2
    var spacing: CGFloat = 8
    var imageSpacing: CGFloat = 2
    var maxSingleImageSide: CGFloat = 240
    var statusHeight: CGFloat = 16
    var separatorHeight: CGFloat = 40
    var unreadDividerHeight: CGFloat = 32
    var typingHeight: CGFloat = 44
    var loadingHeight: CGFloat = 44
    var quotePadding = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
    var quoteSpacing: CGFloat = 3
    var quoteMaxLines = 2
    var reactionPadding = UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
    /// How far the badge reaches over the bubble's top edge.
    var reactionOverlap: CGFloat = 8
    /// How far the badge sticks out past the bubble's side.
    var reactionOutset: CGFloat = 12
}

/// Measures rows. Thread-safe: text is measured with
/// `NSAttributedString.boundingRect`, which is safe off the main thread.
struct RowLayoutCalculator {
    var metrics = LayoutMetrics()
    var bodyFont: UIFont
    var captionFont: UIFont

    func layout(
        _ row: MessageRow, width: CGFloat, textColor: UIColor, linkColor: UIColor,
        quoteColor: UIColor = .secondaryLabel, reactionColor: UIColor = .label
    ) -> MessageLayout {
        let m = metrics
        let maxBubble = floor((width - 2 * m.sideInset) * m.maxBubbleWidthFraction)
        let maxText = maxBubble - m.bubblePadding.left - m.bubblePadding.right
        var contentWidth: CGFloat = 0
        var y = m.bubblePadding.top

        // Images first, then text, inside one bubble.
        var imageFrames: [CGRect] = []
        if !row.images.isEmpty {
            let gridWidth = min(maxBubble, m.maxSingleImageSide + m.bubblePadding.left + m.bubblePadding.right)
                - m.bubblePadding.left - m.bubblePadding.right
            if row.images.count == 1 {
                let size = row.images[0].pixelSize
                let aspect = size.width > 0 && size.height > 0 ? size.height / size.width : 1
                var w = gridWidth
                var h = (w * aspect).rounded()
                if h > m.maxSingleImageSide {
                    h = m.maxSingleImageSide
                    w = max(80, (h / aspect).rounded())
                }
                imageFrames = [CGRect(x: m.bubblePadding.left, y: y, width: w, height: h)]
                contentWidth = w
                y += h
            } else {
                let side = floor((gridWidth - m.imageSpacing) / 2)
                for index in row.images.indices {
                    let col = CGFloat(index % 2), line = CGFloat(index / 2)
                    imageFrames.append(CGRect(
                        x: m.bubblePadding.left + col * (side + m.imageSpacing),
                        y: y + line * (side + m.imageSpacing), width: side, height: side))
                }
                let lines = CGFloat((row.images.count + 1) / 2)
                y += lines * side + (lines - 1) * m.imageSpacing
                contentWidth = 2 * side + m.imageSpacing
            }
        }

        var textFrame = CGRect.zero
        var attributed: NSAttributedString?
        if !row.text.isEmpty {
            if !imageFrames.isEmpty { y += 6 }
            let text = MessageMarkdown.render(
                row.text, style: .init(font: bodyFont, color: textColor, linkColor: linkColor))
            let bounds = text.boundingRect(
                with: CGSize(width: maxText, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let size = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
            textFrame = CGRect(x: m.bubblePadding.left, y: y, width: size.width, height: size.height)
            contentWidth = max(contentWidth, size.width)
            y += size.height
            attributed = text
        }
        y += m.bubblePadding.bottom

        // Above the bubble: the quoted message, then room for the tapback badge.
        var top: CGFloat = 0
        var quote = CGRect.zero, quoteText = CGRect.zero
        var quoteAttributed: NSAttributedString?
        if let replyTo = row.replyTo {
            let text = Self.quoteText(replyTo, font: quoteFont, color: quoteColor)
            let maxQuoteText = floor(maxBubble * 0.9) - m.quotePadding.left - m.quotePadding.right
            let bounds = text.boundingRect(
                with: CGSize(width: maxQuoteText, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let maxHeight = ceil(quoteFont.lineHeight * CGFloat(m.quoteMaxLines))
            let size = CGSize(width: ceil(bounds.width), height: min(ceil(bounds.height), maxHeight))
            let quoteWidth = size.width + m.quotePadding.left + m.quotePadding.right
            let quoteX = row.isOutgoing ? width - m.sideInset - quoteWidth : m.sideInset
            quote = CGRect(
                x: quoteX, y: 0, width: quoteWidth, height: size.height + m.quotePadding.top + m.quotePadding.bottom)
            quoteText = CGRect(
                x: quoteX + m.quotePadding.left, y: m.quotePadding.top, width: size.width, height: size.height)
            quoteAttributed = text
            top = quote.maxY + m.quoteSpacing
        }
        var reactionText: NSAttributedString?
        var reactionSize = CGSize.zero
        if !row.reactions.isEmpty {
            let text = Self.reactionText(row.reactions, font: reactionFont, color: reactionColor)
            let bounds = text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            reactionSize = CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
            reactionText = text
            let badgeHeight = reactionSize.height + m.reactionPadding.top + m.reactionPadding.bottom
            top += max(0, badgeHeight - m.reactionOverlap)
        }

        let bubbleWidth = contentWidth + m.bubblePadding.left + m.bubblePadding.right
        let bubbleX = row.isOutgoing ? width - m.sideInset - bubbleWidth : m.sideInset
        let bubble = CGRect(x: bubbleX, y: top, width: bubbleWidth, height: y)
        // Frames inside the bubble become frames in the cell.
        func shift(_ r: CGRect) -> CGRect { r.offsetBy(dx: bubbleX, dy: top) }
        textFrame = shift(textFrame)
        imageFrames = imageFrames.map(shift)
        if row.isOutgoing, contentWidth > textFrame.width, textFrame.width > 0 {
            // Right-align short text under wider images in outgoing bubbles.
            textFrame.origin.x = bubble.maxX - m.bubblePadding.right - textFrame.width
        }

        // The badge sits on the bubble's top corner facing the other side,
        // like Messages' tapbacks: top left of your messages, top right of the team's.
        var reactions = CGRect.zero, reactionsText = CGRect.zero
        if reactionText != nil {
            let badge = CGSize(
                width: reactionSize.width + m.reactionPadding.left + m.reactionPadding.right,
                height: reactionSize.height + m.reactionPadding.top + m.reactionPadding.bottom)
            var x = row.isOutgoing ? bubble.minX - badge.width + m.reactionOutset : bubble.maxX - m.reactionOutset
            x = min(max(4, x), width - 4 - badge.width)
            reactions = CGRect(x: x, y: bubble.minY - badge.height + m.reactionOverlap, width: badge.width, height: badge.height)
            reactionsText = CGRect(
                x: x + m.reactionPadding.left, y: reactions.minY + m.reactionPadding.top,
                width: reactionSize.width, height: reactionSize.height)
        }

        var height = bubble.maxY
        var status = CGRect.zero
        if row.status != .none {
            status = CGRect(x: m.sideInset, y: height + 2, width: width - 2 * m.sideInset, height: m.statusHeight)
            height = status.maxY
        }
        height += row.groupedWithNext ? m.groupedSpacing : m.spacing
        return MessageLayout(
            height: ceil(height), bubble: bubble, text: textFrame, images: imageFrames, status: status,
            attributedText: attributed, quote: quote, quoteText: quoteText, quoteAttributedText: quoteAttributed,
            reactions: reactions, reactionsText: reactionsText, reactionsAttributedText: reactionText)
    }

    /// Quotes use a smaller size of the body font.
    var quoteFont: UIFont { bodyFont.withSize((bodyFont.pointSize * 0.85).rounded()) }
    var reactionFont: UIFont { UIFont.systemFont(ofSize: (bodyFont.pointSize * 0.85).rounded()) }

    /// The quoted text, or a photo mark when it has only images.
    static func quoteText(_ reply: ReplyPreview, font: UIFont, color: UIColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let flat = reply.textPreview.replacingOccurrences(of: "\n", with: " ")
        let text = flat.isEmpty && reply.hasAttachments ? "📷" : flat
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// "❤️ 2 👍": each emoji, with its count when more than one.
    static func reactionText(_ reactions: [Reaction], font: UIFont, color: UIColor) -> NSAttributedString {
        let text = reactions.map { $0.count > 1 ? "\($0.emoji) \($0.count)" : $0.emoji }.joined(separator: " ")
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }
}

/// Cached layouts by row content and width. Invalidated wholesale when the
/// width or text size changes.
final class LayoutCache {
    private struct Key: Hashable {
        var row: String
        var content: Int
    }

    private var width: CGFloat = 0
    private var category: UIContentSizeCategory = .large
    private var layouts: [Key: MessageLayout] = [:]

    func reset(width: CGFloat, category: UIContentSizeCategory) {
        guard width != self.width || category != self.category else { return }
        self.width = width
        self.category = category
        layouts.removeAll(keepingCapacity: true)
    }

    func layout(for row: MessageRow, compute: (MessageRow) -> MessageLayout) -> MessageLayout {
        var hasher = Hasher()
        hasher.combine(row.text)
        hasher.combine(row.images)
        hasher.combine(row.isOutgoing)
        hasher.combine(row.status == .none)
        hasher.combine(row.groupedWithNext)
        hasher.combine(row.reactions)
        hasher.combine(row.replyTo)
        let key = Key(row: row.key, content: hasher.finalize())
        if let cached = layouts[key] { return cached }
        let layout = compute(row)
        layouts[key] = layout
        return layout
    }
}
#endif
