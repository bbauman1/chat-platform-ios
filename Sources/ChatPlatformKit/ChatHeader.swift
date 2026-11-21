#if canImport(UIKit)
import UIKit

/// The group chat header, like a group in Messages: the newest two people on
/// the team in a glass circle (one large, one small in front of its corner)
/// over a glass pill, "2 People ›" or the one person's name, which lists them
/// in a menu. It hangs from the navigation bar: the circle is centered just
/// below the bar's middle and the pill overlaps the circle's bottom edge.
final class ChatHeaderView: UIView {
    /// Measured from a Messages screenshot (402 pt wide iPhone), in points.
    struct Metrics {
        var circle: CGFloat = 59.5
        /// The circle's center below the navigation bar's middle (iOS 26's bar
        /// is taller than its buttons, so its middle is below theirs).
        var circleDrop: CGFloat = 3.8
        var front: CGFloat = 32
        var frontOffset = CGPoint(x: -7, y: -6.7)
        var back: CGFloat = 19
        var backOffset = CGPoint(x: 11.8, y: 12)
        /// Alone, the person fills most of the circle.
        var single: CGFloat = 44
        var pillHeight: CGFloat = 31
        /// The pill's center below the navigation bar's middle.
        var pillDrop: CGFloat = 43.4
        var pillPadding: CGFloat = 13.5
        var maxPillWidth: CGFloat = 240
    }

    static let metrics = Metrics()
    static let maxAvatars = 2
    /// Images are loaded at the largest size an avatar is drawn.
    static var avatarSize: CGFloat { max(metrics.front, metrics.single) }

    private let circle: UIView
    private var avatars: [AvatarView] = []
    private let pill: UIView
    let button = UIButton(type: .system)
    private var shownCount = 0
    /// The navigation bar's middle, in this view's coordinates.
    var anchorY: CGFloat = 22 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        circle = Self.glass()
        pill = Self.glass()
        super.init(frame: frame)
        circle.isUserInteractionEnabled = false
        addSubview(circle)
        let pillContent = (pill as? UIVisualEffectView)?.contentView ?? pill
        button.showsMenuAsPrimaryAction = true
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        pillContent.addSubview(button)
        addSubview(pill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Liquid Glass on iOS 26 and later, a thin material before.
    private static func glass() -> UIView {
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            let view = UIVisualEffectView(effect: effect)
            view.clipsToBounds = true
            return view
        }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        view.clipsToBounds = true
        return view
    }

    func configure(
        people: [RowSender], text: String, font: UIFont?, tint: UIColor, menuTitle: String, names: [String]
    ) {
        // The two most recent writers: the large avatar, then the small one
        // in front of its corner for the newest.
        let shown = Array(people.suffix(Self.maxAvatars))
        shownCount = shown.count
        let circleContent = (circle as? UIVisualEffectView)?.contentView ?? circle
        while avatars.count < shown.count {
            let avatar = AvatarView()
            avatars.append(avatar)
            circleContent.addSubview(avatar)
        }
        for (index, avatar) in avatars.enumerated() {
            avatar.isHidden = index >= shown.count
            if index < shown.count { avatar.configure(shown[index], tint: tint) }
        }
        // The small avatar is drawn in front of the large one's corner.
        if let back = avatars.dropFirst().first { circleContent.bringSubviewToFront(back) }
        let titleFont = font ?? UIFont.systemFont(ofSize: 17, weight: .semibold)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: Self.metrics.pillPadding, bottom: 0, trailing: Self.metrics.pillPadding - 2.5)
        config.attributedTitle = AttributedString(text, attributes: AttributeContainer([
            .font: titleFont, .foregroundColor: UIColor.label,
        ]))
        config.titleLineBreakMode = .byTruncatingTail
        config.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: titleFont.pointSize * 0.62, weight: .bold))
        config.imagePlacement = .trailing
        config.imagePadding = 3
        config.baseForegroundColor = .tertiaryLabel
        button.configuration = config
        button.menu = UIMenu(title: menuTitle, children: names.map { name in
            UIAction(title: name, attributes: .disabled) { _ in }
        })
        button.accessibilityLabel = text
        button.accessibilityHint = menuTitle
        setNeedsLayout()
    }

    func setImage(_ image: UIImage?, for url: URL) {
        for avatar in avatars { avatar.setImage(image, for: url) }
    }

    var pillFrame: CGRect { pill.frame }
    var circleFrame: CGRect { circle.frame }

    override func layoutSubviews() {
        super.layoutSubviews()
        let m = Self.metrics
        let center = CGPoint(x: bounds.midX, y: anchorY + m.circleDrop)
        circle.frame = CGRect(x: center.x - m.circle / 2, y: center.y - m.circle / 2, width: m.circle, height: m.circle)
        circle.layer.cornerRadius = m.circle / 2
        if #available(iOS 26.0, *), let glass = circle as? UIVisualEffectView {
            glass.cornerConfiguration = .capsule()
        }
        let mid = CGPoint(x: m.circle / 2, y: m.circle / 2)
        for (index, avatar) in avatars.enumerated() where !avatar.isHidden {
            let (side, offset): (CGFloat, CGPoint) = shownCount == 1
                ? (m.single, .zero)
                : index == 0 ? (m.front, m.frontOffset) : (m.back, m.backOffset)
            avatar.frame = CGRect(
                x: mid.x + offset.x - side / 2, y: mid.y + offset.y - side / 2, width: side, height: side)
        }
        let fitting = button.sizeThatFits(CGSize(width: m.maxPillWidth, height: m.pillHeight))
        let width = min(m.maxPillWidth, bounds.width, ceil(fitting.width))
        pill.frame = CGRect(
            x: bounds.midX - width / 2, y: anchorY + m.pillDrop - m.pillHeight / 2, width: width, height: m.pillHeight)
        pill.layer.cornerRadius = m.pillHeight / 2
        if #available(iOS 26.0, *), let glass = pill as? UIVisualEffectView {
            glass.cornerConfiguration = .capsule()
        }
        button.frame = pill.bounds
    }

    /// Only the circle and the pill take touches; the thread scrolls under the rest.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard pill.frame.contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
#endif
