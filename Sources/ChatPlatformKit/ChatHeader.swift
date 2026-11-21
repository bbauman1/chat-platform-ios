#if canImport(UIKit)
import UIKit

/// The chat's title in the group chat look: the people on the team stacked
/// over "Support · 2 People ›", which lists them in a menu, like a group in
/// Messages.
final class ChatHeaderView: UIView {
    static let avatarSize: CGFloat = 24
    static let maxAvatars = 3
    /// How much each avatar overlaps the one before it.
    private static let overlap: CGFloat = 8

    private var avatars: [AvatarView] = []
    private let button = UIButton(type: .system)
    private var avatarsWidth: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        button.showsMenuAsPrimaryAction = true
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        people: [RowSender], text: String, font: UIFont?, tint: UIColor, menuTitle: String, names: [String]
    ) {
        let shown = Array(people.suffix(Self.maxAvatars))
        while avatars.count < shown.count {
            let avatar = AvatarView()
            avatar.layer.borderWidth = 1.5
            avatars.append(avatar)
            addSubview(avatar)
        }
        for (index, avatar) in avatars.enumerated() {
            avatar.isHidden = index >= shown.count
            if index < shown.count { avatar.configure(shown[index], tint: tint) }
        }
        let titleFont = font ?? UIFont.systemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .semibold)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)
        config.attributedTitle = AttributedString(text, attributes: AttributeContainer([
            .font: titleFont, .foregroundColor: UIColor.label,
        ]))
        config.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: titleFont.pointSize * 0.75, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 3
        config.baseForegroundColor = .secondaryLabel
        button.configuration = config
        button.menu = UIMenu(title: menuTitle, children: names.map { name in
            UIAction(title: name, attributes: .disabled) { _ in }
        })
        button.accessibilityLabel = text
        button.accessibilityHint = menuTitle
        avatarsWidth = CGFloat(shown.count) * Self.avatarSize - CGFloat(max(0, shown.count - 1)) * Self.overlap
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setImage(_ image: UIImage?, for url: URL) {
        for avatar in avatars { avatar.setImage(image, for: url) }
    }

    override var intrinsicContentSize: CGSize {
        let label = button.sizeThatFits(CGSize(width: 260, height: 20))
        return CGSize(width: min(260, max(avatarsWidth, label.width)), height: Self.avatarSize + 18)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var x = (bounds.width - avatarsWidth) / 2
        let border = (superview?.backgroundColor ?? .systemBackground).resolvedColor(with: traitCollection).cgColor
        for avatar in avatars where !avatar.isHidden {
            avatar.frame = CGRect(x: x, y: 0, width: Self.avatarSize, height: Self.avatarSize)
            avatar.layer.borderColor = border
            x += Self.avatarSize - Self.overlap
        }
        button.frame = CGRect(x: 0, y: Self.avatarSize, width: bounds.width, height: bounds.height - Self.avatarSize)
    }
}
#endif
