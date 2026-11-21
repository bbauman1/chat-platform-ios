#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// A message bubble with text and up to four images. Frames come from a
/// precomputed `MessageLayout`; nothing is measured here.
final class MessageCell: UICollectionViewCell {
    static let reuseID = "message"

    /// The bubble, which the long-press menu lifts as its preview.
    let bubble = UIView()
    private let textLabel = UILabel()
    private var imageViews: [UIImageView] = []
    /// An action card's buttons, each under a hairline.
    private var actionButtons: [UIButton] = []
    private var actionDividers: [UIView] = []
    private let statusLabel = UILabel()
    /// The quoted message, faded, above the bubble.
    let quoteBubble = UIView()
    private let quoteLabel = UILabel()
    /// Tapbacks on the bubble's top corner.
    let reactionBadge = UIView()
    let reactionLabel = UILabel()
    /// Revealed behind the row while it's swiped to reply.
    /// The AI's name above its first message in a run.
    private let senderLabel = UILabel()
    private let replyArrow = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var layout: MessageLayout?
    /// The images this cell is showing, so a late load for a reused cell is dropped.
    private(set) var imageKeys: [String] = []
    var onStatusTap: (() -> Void)?
    var onLinkTap: ((URL) -> Void)?
    var onQuoteTap: (() -> Void)?
    /// A tap on an action card's button, by index.
    var onActionTap: ((Int) -> Void)?
    /// A layer color doesn't follow light and dark by itself.
    private var badgeBorder: UIColor = .systemBackground

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.reactionBadge.layer.borderColor = self.badgeBorder.resolvedColor(with: self.traitCollection).cgColor
        }
        replyArrow.contentMode = .center
        replyArrow.alpha = 0
        insertSubview(replyArrow, belowSubview: contentView)
        quoteBubble.layer.cornerCurve = .continuous
        quoteBubble.isUserInteractionEnabled = true
        quoteBubble.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(quoteTapped)))
        contentView.addSubview(quoteBubble)
        quoteLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(quoteLabel)
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true
        contentView.addSubview(bubble)
        textLabel.numberOfLines = 0
        textLabel.isUserInteractionEnabled = true
        textLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(textTapped(_:))))
        // Text and images live inside the bubble, so the long-press menu's
        // lifted preview (the bubble) shows them.
        bubble.addSubview(textLabel)
        for _ in 0..<4 {
            let view = UIImageView()
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 6
            view.layer.cornerCurve = .continuous
            view.isAccessibilityElement = false
            imageViews.append(view)
            bubble.addSubview(view)
        }
        for index in 0..<2 {
            let divider = UIView()
            actionDividers.append(divider)
            bubble.addSubview(divider)
            let button = UIButton(type: .system)
            button.tag = index
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.addTarget(self, action: #selector(actionTapped(_:)), for: .touchUpInside)
            actionButtons.append(button)
            bubble.addSubview(button)
        }
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(statusTapped)))
        contentView.addSubview(statusLabel)
        reactionBadge.layer.cornerCurve = .continuous
        reactionBadge.layer.borderWidth = 2
        contentView.addSubview(reactionBadge)
        contentView.addSubview(reactionLabel)
        senderLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(senderLabel)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: MessageRow, layout: MessageLayout, theme: ChatTheme, strings: ChatStrings) {
        self.layout = layout
        bubble.backgroundColor = row.isOutgoing ? theme.outgoingBubble : theme.incomingBubble
        bubble.layer.cornerRadius = theme.bubbleCornerRadius
        // Text color is baked into the attributed string at measure time.
        textLabel.attributedText = layout.attributedText
        textLabel.isHidden = layout.attributedText == nil
        for (index, button) in actionButtons.enumerated() {
            let shown = index < layout.actionTitles.count
            button.isHidden = !shown
            actionDividers[index].isHidden = !shown
            actionDividers[index].backgroundColor = theme.secondaryText.withAlphaComponent(0.3)
            if shown {
                UIView.performWithoutAnimation {
                    button.setAttributedTitle(layout.actionTitles[index], for: .normal)
                    button.layoutIfNeeded()
                }
            }
        }
        imageKeys = row.images.map(\.cacheKey)
        for (index, view) in imageViews.enumerated() {
            view.isHidden = index >= row.images.count
            view.image = nil
            view.backgroundColor = theme.secondaryText.withAlphaComponent(0.15)
        }
        switch row.status {
        case .none: statusLabel.text = nil
        case .sending: statusLabel.text = strings("status.sending")
        case .sent: statusLabel.text = strings("status.sent")
        case .seen: statusLabel.text = strings("status.seen")
        case .failed: statusLabel.text = strings("status.failed")
        }
        statusLabel.font = theme.captionFont
        statusLabel.textColor = row.status == .failed ? theme.failure : theme.secondaryText
        statusLabel.textAlignment = row.isOutgoing ? .right : .left
        statusLabel.isHidden = row.status == .none
        contentView.alpha = row.status == .sending ? 0.7 : 1

        quoteBubble.isHidden = layout.quoteAttributedText == nil
        quoteLabel.isHidden = quoteBubble.isHidden
        quoteLabel.attributedText = layout.quoteAttributedText
        quoteLabel.numberOfLines = LayoutMetrics().quoteMaxLines
        if let replyTo = row.replyTo {
            let quoted = replyTo.senderType.isEndUser ? theme.outgoingBubble : theme.incomingBubble
            quoteBubble.backgroundColor = quoted.withAlphaComponent(0.3)
        }
        quoteBubble.layer.cornerRadius = min(theme.bubbleCornerRadius, layout.quote.height / 2)
        quoteBubble.accessibilityLabel = strings("a11y.jump_to_quote")

        let mine = row.reactions.contains(where: \.mine)
        reactionBadge.isHidden = layout.reactionsAttributedText == nil
        reactionLabel.isHidden = reactionBadge.isHidden
        reactionLabel.attributedText = layout.reactionsAttributedText
        reactionBadge.backgroundColor = mine ? theme.tint : theme.incomingBubble
        badgeBorder = theme.background
        reactionBadge.layer.borderColor = theme.background.resolvedColor(with: traitCollection).cgColor
        reactionBadge.layer.cornerRadius = layout.reactions.height / 2
        replyArrow.tintColor = theme.secondaryText

        senderLabel.attributedText = layout.senderAttributedText
        senderLabel.isHidden = layout.senderAttributedText == nil

        var label = [
            row.isOutgoing ? strings("a11y.from_you")
                : row.aiName.map { String(format: strings("sender.ai"), $0.isEmpty ? strings("a11y.from_team") : $0) }
                ?? strings("a11y.from_team"),
        ]
        if let replyTo = row.replyTo {
            label.append(String(format: strings("a11y.reply_to"), replyTo.textPreview.isEmpty ? strings("a11y.photo") : replyTo.textPreview))
        }
        if !row.images.isEmpty { label.append(Array(repeating: strings("a11y.photo"), count: row.images.count).joined(separator: ", ")) }
        if !row.text.isEmpty { label.append(row.text) }
        if !row.reactions.isEmpty {
            let list = row.reactions.map { $0.count > 1 ? "\($0.emoji) \($0.count)" : $0.emoji }.joined(separator: ", ")
            label.append(String(format: strings("a11y.reactions"), list))
        }
        if let status = statusLabel.text { label.append(status) }
        accessibilityLabel = label.joined(separator: ". ")
        accessibilityTraits = row.status == .failed ? .button : .staticText
        setNeedsLayout()
    }

    func setImage(_ image: UIImage?, at index: Int, key: String) {
        guard imageKeys.indices.contains(index), imageKeys[index] == key else { return }
        imageViews[index].image = image
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        bubble.frame = layout.bubble
        // The layout's frames are in the cell; text and images are in the bubble.
        let origin = layout.bubble.origin
        textLabel.frame = layout.text.offsetBy(dx: -origin.x, dy: -origin.y)
        for (index, view) in imageViews.enumerated() where index < layout.images.count {
            view.frame = layout.images[index].offsetBy(dx: -origin.x, dy: -origin.y)
        }
        let hairline = 1 / max(1, traitCollection.displayScale)
        for (index, frame) in layout.actionButtons.enumerated() where index < actionButtons.count {
            let local = frame.offsetBy(dx: -origin.x, dy: -origin.y)
            actionButtons[index].frame = local
            actionDividers[index].frame = CGRect(x: 0, y: local.minY, width: local.width, height: hairline)
        }
        statusLabel.frame = layout.status
        quoteBubble.frame = layout.quote
        quoteLabel.frame = layout.quoteText
        reactionBadge.frame = layout.reactions
        reactionLabel.frame = layout.reactionsText
        senderLabel.frame = layout.sender
        let arrowSide: CGFloat = 28
        replyArrow.frame = CGRect(
            x: 8, y: layout.bubble.midY - arrowSide / 2, width: arrowSide, height: arrowSide)
    }

    /// Moves the row right while it's swiped to reply; `progress` 1 means
    /// letting go replies.
    func setSwipe(offset: CGFloat, progress: CGFloat) {
        contentView.transform = offset == 0 ? .identity : CGAffineTransform(translationX: offset, y: 0)
        replyArrow.alpha = min(1, progress)
        let scale = 0.6 + 0.4 * min(1, progress)
        replyArrow.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageKeys = []
        onStatusTap = nil
        onLinkTap = nil
        onQuoteTap = nil
        onActionTap = nil
        setSwipe(offset: 0, progress: 0)
    }

    @objc private func statusTapped() { onStatusTap?() }
    @objc private func quoteTapped() { onQuoteTap?() }
    @objc private func actionTapped(_ sender: UIButton) { onActionTap?(sender.tag) }

    /// Briefly highlights the bubble, after jumping to it from a quote.
    func flash() {
        let original = bubble.alpha
        UIView.animate(withDuration: 0.15, animations: { self.bubble.alpha = 0.4 }) { _ in
            UIView.animate(withDuration: 0.35) { self.bubble.alpha = original }
        }
    }

    @objc private func textTapped(_ recognizer: UITapGestureRecognizer) {
        guard let text = layout?.attributedText,
              let url = MessageMarkdown.link(at: recognizer.location(in: textLabel), in: text, size: textLabel.bounds.size)
        else { return }
        onLinkTap?(url)
    }

    /// The images currently shown, for Copy.
    var loadedImages: [UIImage] {
        imageViews.prefix(imageKeys.count).compactMap(\.image)
    }

    override func accessibilityActivate() -> Bool {
        guard let onStatusTap else { return false }
        onStatusTap()
        return true
    }

    // Frames come from the layout; skip self-sizing.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes
    {
        layoutAttributes
    }
}

/// "**Today** 8:49 AM", centered, between stretches of conversation.
final class SeparatorCell: UICollectionViewCell {
    static let reuseID = "separator"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        contentView.addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ separator: ThreadModel.Separator, theme: ChatTheme) {
        let bold = UIFont.systemFont(ofSize: theme.captionFont.pointSize + 1, weight: .semibold)
        let regular = UIFont.systemFont(ofSize: theme.captionFont.pointSize + 1)
        let text = NSMutableAttributedString(
            string: separator.day, attributes: [.font: bold, .foregroundColor: theme.secondaryText])
        text.append(NSAttributedString(
            string: " " + separator.time, attributes: [.font: regular, .foregroundColor: theme.secondaryText]))
        label.attributedText = text
        accessibilityLabel = "\(separator.day) \(separator.time)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes
    {
        layoutAttributes
    }
}

/// A blue line with "NEW" in the middle, above the first unread message.
final class UnreadDividerCell: UICollectionViewCell {
    static let reuseID = "unread"
    private let label = UILabel()
    private let left = UIView()
    private let right = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [left, right, label] { contentView.addSubview(view) }
        label.textAlignment = .center
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(theme: ChatTheme, strings: ChatStrings) {
        label.text = strings("unread.new")
        label.font = UIFont.systemFont(ofSize: theme.captionFont.pointSize, weight: .bold)
        label.textColor = theme.tint
        left.backgroundColor = theme.tint
        right.backgroundColor = theme.tint
        accessibilityLabel = strings("unread.a11y")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let size = label.sizeThatFits(bounds.size)
        let labelWidth = ceil(size.width) + 16
        label.frame = CGRect(x: (bounds.width - labelWidth) / 2, y: 0, width: labelWidth, height: bounds.height)
        let line: CGFloat = 1
        let y = (bounds.height - line) / 2
        left.frame = CGRect(x: 16, y: y, width: max(0, label.frame.minX - 16), height: line)
        right.frame = CGRect(x: label.frame.maxX, y: y, width: max(0, bounds.width - 16 - label.frame.maxX), height: line)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes
    {
        layoutAttributes
    }
}

/// Three pulsing dots in an incoming bubble while the team is typing.
final class TypingCell: UICollectionViewCell {
    static let reuseID = "typing"
    /// The bubble, which the long-press menu lifts as its preview.
    let bubble = UIView()
    private var dots: [UIView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerCurve = .continuous
        contentView.addSubview(bubble)
        for _ in 0..<3 {
            let dot = UIView()
            dot.layer.cornerRadius = 4
            dots.append(dot)
            bubble.addSubview(dot)
        }
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(theme: ChatTheme, strings: ChatStrings, metrics: LayoutMetrics) {
        bubble.backgroundColor = theme.incomingBubble
        bubble.layer.cornerRadius = theme.bubbleCornerRadius
        bubble.frame = CGRect(x: metrics.sideInset, y: 4, width: 60, height: 36)
        for (index, dot) in dots.enumerated() {
            dot.backgroundColor = theme.secondaryText
            dot.frame = CGRect(x: 14 + CGFloat(index) * 12, y: 14, width: 8, height: 8)
        }
        accessibilityLabel = strings("typing")
        startAnimating()
    }

    func startAnimating() {
        // Skip the animation when Reduce Motion is on, and in snapshot tests.
        guard !UIAccessibility.isReduceMotionEnabled, UIView.areAnimationsEnabled else { return }
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAllAnimations()
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.beginTime = CACurrentMediaTime() + Double(index) * 0.2
            dot.layer.add(pulse, forKey: "pulse")
        }
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes
    {
        layoutAttributes
    }
}

/// A spinner at the top while older messages load.
final class LoadingCell: UICollectionViewCell {
    static let reuseID = "loading"
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(loading: Bool) {
        if loading && UIView.areAnimationsEnabled { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.center = CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutAttributes
    {
        layoutAttributes
    }
}
#endif
