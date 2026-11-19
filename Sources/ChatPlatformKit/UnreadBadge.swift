#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// A small count badge for a "Support" button. Hidden at zero.
///
/// ```swift
/// badge.count = try await client.unreadCount()
/// ```
public final class ChatUnreadBadge: UILabel {
    private let theme: ChatTheme

    public init(theme: ChatTheme = .default) {
        self.theme = theme
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        textColor = .white
        backgroundColor = theme.failure
        textAlignment = .center
        clipsToBounds = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var count: Int = 0 {
        didSet {
            text = count > 99 ? "99+" : "\(count)"
            isHidden = count <= 0
            invalidateIntrinsicContentSize()
        }
    }

    public override var intrinsicContentSize: CGSize {
        let base = super.intrinsicContentSize
        return CGSize(width: max(18, base.width + 10), height: 18)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
#endif
