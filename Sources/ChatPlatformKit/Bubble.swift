#if canImport(UIKit)
import UIKit

/// A message bubble's shape: a rounded rectangle, with the Messages tail on
/// the last bubble of a run. As in Messages on iOS 26, the tail hangs under
/// the bubble's bottom corner (`BubbleShape.tailDrop` points below it) and
/// never past its side, so the bubble's frame (and the text inside it)
/// stays the same with or without one. Traced from a Messages screenshot.
enum BubbleShape {
    enum Tail: Equatable {
        case none
        /// Outgoing: the bottom right corner.
        case trailing
        /// Incoming: the bottom left corner.
        case leading
    }

    /// How far the tail's tip hangs below the bubble.
    static let tailDrop: CGFloat = 6.4

    static func path(size: CGSize, radius: CGFloat, tail: Tail) -> UIBezierPath {
        let w = size.width, h = size.height
        let r = max(0, min(radius, w / 2, h / 2))
        guard tail != .none, w > 0, h > 0 else {
            return UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r)
        }
        // Drawn for a leading tail; a trailing one is its mirror image.
        let path = UIBezierPath()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addArc(withCenter: CGPoint(x: w - r, y: r), radius: r, startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: w, y: h - r))
        path.addArc(withCenter: CGPoint(x: w - r, y: h - r), radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: true)
        // The tail: from the bottom edge down to its tip, then up the left
        // side, which bends out into the bubble's straight edge.
        let base = min(21, w - r)
        let tip = CGPoint(x: 8, y: h + tailDrop)
        let neck = CGPoint(x: 10.4, y: h + 0.4)
        let top = max(r, h - 24)
        path.addLine(to: CGPoint(x: base, y: h))
        path.addCurve(to: tip, controlPoint1: CGPoint(x: base - 2, y: h), controlPoint2: CGPoint(x: 14, y: tip.y))
        path.addCurve(to: neck, controlPoint1: CGPoint(x: 8, y: h + 4.9), controlPoint2: CGPoint(x: 10.4, y: h + 2.4))
        path.addCurve(
            to: CGPoint(x: 0, y: top), controlPoint1: CGPoint(x: 9.9, y: h - 6.6),
            controlPoint2: CGPoint(x: 0, y: top + 0.82 * (neck.y - top)))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(withCenter: CGPoint(x: r, y: r), radius: r, startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        path.close()
        if tail == .trailing {
            path.apply(CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: w, y: 0)))
        }
        return path
    }
}

/// A bubble that paints its shape (tail included) with a layer, so its
/// subviews (text, images, card buttons) sit in an unclipped rectangle.
final class BubbleView: UIView {
    private let shape = CAShapeLayer()

    var fillColor: UIColor = .clear {
        didSet { updateFill() }
    }
    var cornerRadius: CGFloat = 18 {
        didSet { if cornerRadius != oldValue { setNeedsLayout() } }
    }
    var tail: BubbleShape.Tail = .none {
        didSet { if tail != oldValue { setNeedsLayout() } }
    }

    /// The painted shape, in the bubble's coordinates.
    var shapePath: UIBezierPath {
        BubbleShape.path(size: bounds.size, radius: cornerRadius, tail: tail)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.insertSublayer(shape, at: 0)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateFill() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = shapePath.cgPath
        CATransaction.commit()
    }

    private func updateFill() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.fillColor = fillColor.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
    }
}

/// A person's avatar: their image, else their initials on gray like
/// Contacts; the AI gets a sparkle on the accent, and the team as a whole a
/// people symbol.
final class AvatarView: UIView {
    private let gradient = CAGradientLayer()
    private let initials = UILabel()
    private let symbol = UIImageView()
    let imageView = UIImageView()
    /// The image this view is showing, so a late load for a reused cell is dropped.
    private(set) var imageURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.addSublayer(gradient)
        initials.textAlignment = .center
        initials.textColor = .white
        initials.adjustsFontSizeToFitWidth = true
        initials.minimumScaleFactor = 0.6
        symbol.contentMode = .center
        symbol.tintColor = .white
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        for view in [initials, symbol, imageView] { addSubview(view) }
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.setNeedsLayout() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var colors: [UIColor] = []

    /// Contacts' monogram gradient, top to bottom: gray, and violet-gray in dark mode.
    static let monogram: [UIColor] = [
        UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 79 / 255, green: 74 / 255, blue: 99 / 255, alpha: 1)
            : UIColor(red: 169 / 255, green: 173 / 255, blue: 185 / 255, alpha: 1) },
        UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: 54 / 255, green: 49 / 255, blue: 78 / 255, alpha: 1)
            : UIColor(red: 134 / 255, green: 139 / 255, blue: 151 / 255, alpha: 1) },
    ]

    func configure(_ sender: RowSender?, tint: UIColor, aiColor: UIColor = .systemPurple) {
        imageURL = sender?.avatarURL
        imageView.image = nil
        imageView.isHidden = true
        let letters = sender?.initials ?? ""
        let symbolName: String?
        if sender?.isAI == true {
            colors = [tint, aiColor]
            symbolName = "sparkles"
        } else {
            colors = Self.monogram
            symbolName = letters.isEmpty ? "person.2.fill" : nil
        }
        initials.text = symbolName == nil ? letters : nil
        initials.isHidden = symbolName != nil
        symbol.isHidden = symbolName == nil
        symbol.image = symbolName.map {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        } ?? nil
        setNeedsLayout()
    }

    func setImage(_ image: UIImage?, for url: URL) {
        guard url == imageURL, let image else { return }
        imageView.image = image
        imageView.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        gradient.colors = colors.map { $0.resolvedColor(with: traitCollection).cgColor }
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        CATransaction.commit()
        initials.font = UIFont.systemFont(ofSize: (bounds.height * 0.53).rounded(), weight: .semibold)
        initials.frame = bounds.insetBy(dx: 2, dy: 0)
        symbol.frame = bounds
        imageView.frame = bounds
    }
}
#endif
