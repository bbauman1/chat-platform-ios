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
    /// An action card's buttons at the bottom of the bubble, each under a hairline.
    var actionButtons: [CGRect] = []
    var actionTitles: [NSAttributedString] = []
    /// The sender's name line above the bubble.
    var sender: CGRect = .zero
    var senderAttributedText: NSAttributedString?
    /// The sender's avatar beside the last bubble of a run.
    var avatar: CGRect = .zero
    /// The tapback badge's tail: a bigger and a smaller dot trailing off its
    /// bottom corner, like Messages.
    var reactionDots: [CGRect] = []
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
    /// An action card's button row, and the card's narrowest width.
    var actionButtonHeight: CGFloat = 44
    var actionMinWidth: CGFloat = 220
    /// Space between the sender's name line and what's under it.
    var senderSpacing: CGFloat = 2
    /// Group chat avatars beside incoming bubbles, and the gap to the bubble.
    var avatarSize: CGFloat = 28
    var avatarGap: CGFloat = 8
    /// A tapback badge is at least this tall, and never narrower than tall.
    var reactionMinSide: CGFloat = 30
    /// The badge's tail dots.
    var reactionDotSizes: (big: CGFloat, small: CGFloat) = (9, 4.5)
    /// "AI" after the AI's name.
    var aiBadgeColor: UIColor = .systemPurple
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
        layout(
            row, width: width, textColor: textColor, linkColor: linkColor, quoteColor: quoteColor,
            reactionColor: reactionColor, senderColor: quoteColor)
    }

    func layout(
        _ row: MessageRow, width: CGFloat, textColor: UIColor, linkColor: UIColor,
        quoteColor: UIColor, reactionColor: UIColor, senderColor: UIColor
    ) -> MessageLayout {
        let m = metrics
        // Incoming bubbles move right of the avatars in the group chat look.
        let leading: CGFloat = !row.isOutgoing && row.avatarColumn ? m.avatarSize + m.avatarGap : 0
        let maxBubble = floor((width - 2 * m.sideInset - leading) * m.maxBubbleWidthFraction)
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

        // An action card: full-width buttons under the prompt.
        var actionButtons: [CGRect] = []
        var actionTitles: [NSAttributedString] = []
        if let card = row.action {
            contentWidth = max(contentWidth, min(maxText, m.actionMinWidth - m.bubblePadding.left - m.bubblePadding.right))
            for title in card.titles {
                let text = NSAttributedString(string: title, attributes: [
                    .font: actionFont, .foregroundColor: linkColor,
                ])
                let width = ceil(text.boundingRect(
                    with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: m.actionButtonHeight),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).width)
                contentWidth = max(contentWidth, min(maxText, width))
                let height = max(m.actionButtonHeight, ceil(actionFont.lineHeight) + 20)
                actionButtons.append(CGRect(x: 0, y: y, width: 0, height: height))
                actionTitles.append(text)
                y += height
            }
        }

        // Above the bubble: the AI's name, the quoted message, then room for the tapback badge.
        var top: CGFloat = 0
        var sender = CGRect.zero
        var senderText: NSAttributedString?
        if let label = row.senderLabel {
            let text = NSMutableAttributedString(
                string: label, attributes: [.font: captionFont, .foregroundColor: senderColor])
            if let badge = row.senderBadge {
                let font = UIFont.systemFont(ofSize: (captionFont.pointSize * 0.9).rounded(), weight: .semibold)
                text.append(NSAttributedString(string: "  " + badge, attributes: [
                    .font: font, .foregroundColor: m.aiBadgeColor, .kern: 0.3,
                ]))
            }
            let bounds = text.boundingRect(
                with: CGSize(width: maxBubble, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let x = m.sideInset + leading + m.bubblePadding.left / 2
            sender = CGRect(x: x, y: 0, width: min(ceil(bounds.width), maxBubble), height: ceil(captionFont.lineHeight))
            senderText = text
            top = sender.maxY + m.senderSpacing
        }
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
            let quoteX = row.isOutgoing ? width - m.sideInset - quoteWidth : m.sideInset + leading
            quote = CGRect(
                x: quoteX, y: top, width: quoteWidth, height: size.height + m.quotePadding.top + m.quotePadding.bottom)
            quoteText = CGRect(
                x: quoteX + m.quotePadding.left, y: top + m.quotePadding.top, width: size.width, height: size.height)
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
            top += max(0, Self.badgeSize(reactionSize, metrics: m).height - m.reactionOverlap)
        }

        let bubbleWidth = contentWidth + m.bubblePadding.left + m.bubblePadding.right
        let bubbleX = row.isOutgoing ? width - m.sideInset - bubbleWidth : m.sideInset + leading
        let bubble = CGRect(x: bubbleX, y: top, width: bubbleWidth, height: y)
        // Frames inside the bubble become frames in the cell.
        func shift(_ r: CGRect) -> CGRect { r.offsetBy(dx: bubbleX, dy: top) }
        textFrame = shift(textFrame)
        imageFrames = imageFrames.map(shift)
        actionButtons = actionButtons.map { shift(CGRect(x: 0, y: $0.minY, width: bubbleWidth, height: $0.height)) }
        if row.isOutgoing, contentWidth > textFrame.width, textFrame.width > 0 {
            // Right-align short text under wider images in outgoing bubbles.
            textFrame.origin.x = bubble.maxX - m.bubblePadding.right - textFrame.width
        }

        // The badge sits on the bubble's top corner facing the other side,
        // like Messages' tapbacks: top left of your messages, top right of the team's.
        var reactions = CGRect.zero, reactionsText = CGRect.zero
        var reactionDots: [CGRect] = []
        if reactionText != nil {
            let badge = Self.badgeSize(reactionSize, metrics: m, circle: row.reactions.count == 1 && row.reactions[0].count == 1)
            var x = row.isOutgoing ? bubble.minX - badge.width + m.reactionOutset : bubble.maxX - m.reactionOutset
            x = min(max(4, x), width - 4 - badge.width)
            reactions = CGRect(x: x, y: bubble.minY - badge.height + m.reactionOverlap, width: badge.width, height: badge.height)
            reactionsText = CGRect(
                x: reactions.midX - reactionSize.width / 2, y: reactions.midY - reactionSize.height / 2,
                width: reactionSize.width, height: reactionSize.height)
            // The tail trails off the corner away from the bubble's middle.
            let (big, small) = m.reactionDotSizes
            let outward: CGFloat = row.isOutgoing ? -1 : 1
            let corner = CGPoint(
                x: row.isOutgoing ? reactions.minX + badge.height * 0.22 : reactions.maxX - badge.height * 0.22,
                y: reactions.maxY - badge.height * 0.22)
            let bigCenter = CGPoint(x: corner.x + outward * big * 0.35, y: corner.y + big * 0.45)
            let smallCenter = CGPoint(x: bigCenter.x + outward * big * 0.85, y: bigCenter.y + big * 0.8)
            reactionDots = [
                CGRect(x: bigCenter.x - big / 2, y: bigCenter.y - big / 2, width: big, height: big),
                CGRect(x: smallCenter.x - small / 2, y: smallCenter.y - small / 2, width: small, height: small),
            ]
        }
        var avatar = CGRect.zero
        if row.showsAvatar, !row.isOutgoing {
            avatar = CGRect(x: m.sideInset, y: bubble.maxY - m.avatarSize, width: m.avatarSize, height: m.avatarSize)
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
            reactions: reactions, reactionsText: reactionsText, reactionsAttributedText: reactionText,
            actionButtons: actionButtons, actionTitles: actionTitles, sender: sender,
            senderAttributedText: senderText, avatar: avatar, reactionDots: reactionDots)
    }

    /// A tapback badge around its text: a circle for one emoji, a pill for more.
    static func badgeSize(_ text: CGSize, metrics m: LayoutMetrics, circle: Bool = true) -> CGSize {
        let height = max(m.reactionMinSide, text.height + m.reactionPadding.top + m.reactionPadding.bottom)
        if circle {
            let side = max(height, text.width + 8)
            return CGSize(width: side, height: side)
        }
        return CGSize(width: max(height, text.width + m.reactionPadding.left + m.reactionPadding.right), height: height)
    }

    /// Card buttons use the body font, semibold.
    var actionFont: UIFont {
        let descriptor = bodyFont.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
        ])
        return UIFont(descriptor: descriptor, size: bodyFont.pointSize)
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
        hasher.combine(row.action)
        hasher.combine(row.senderLabel)
        hasher.combine(row.senderBadge)
        hasher.combine(row.showsAvatar)
        hasher.combine(row.avatarColumn)
        let key = Key(row: row.key, content: hasher.finalize())
        if let cached = layouts[key] { return cached }
        let layout = compute(row)
        layouts[key] = layout
        return layout
    }
}
#endif
