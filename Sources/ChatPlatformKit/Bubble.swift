#if canImport(UIKit)
import UIKit

/// A message bubble's shape: a rounded rectangle, with the Messages tail on
/// the last bubble of a run. The tail reaches `BubbleShape.tailReach` points
/// past the bubble's side, so the bubble's frame (and the text inside it)
/// stays the same with or without one.
enum BubbleShape {
    enum Tail: Equatable {
        case none
        /// Outgoing: the bottom right corner.
        case trailing
        /// Incoming: the bottom left corner.
        case leading
    }

    /// How far the tail's tip reaches past the bubble's side.
    static let tailReach: CGFloat = 4

    static func path(size: CGSize, radius: CGFloat, tail: Tail) -> UIBezierPath {
        let w = size.width, h = size.height
        let r = max(0, min(radius, w / 2, h / 2))
        guard tail != .none, w > 0, h > 0 else {
            return UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: r)
        }
        // Drawn for a trailing tail; a leading one is its mirror image.
        let k = r * 0.448
        let tip = w + tailReach
        let start = max(r, tip - 22)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: start, y: h))
        path.addLine(to: CGPoint(x: r, y: h))
        path.addCurve(to: CGPoint(x: 0, y: h - r), controlPoint1: CGPoint(x: k, y: h), controlPoint2: CGPoint(x: 0, y: h - k))
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addCurve(to: CGPoint(x: r, y: 0), controlPoint1: CGPoint(x: 0, y: k), controlPoint2: CGPoint(x: k, y: 0))
        path.addLine(to: CGPoint(x: w - r, y: 0))
        path.addCurve(to: CGPoint(x: w, y: r), controlPoint1: CGPoint(x: w - k, y: 0), controlPoint2: CGPoint(x: w, y: k))
        path.addLine(to: CGPoint(x: w, y: max(r, h - 11)))
        path.addCurve(
            to: CGPoint(x: tip, y: h), controlPoint1: CGPoint(x: w, y: h - 1), controlPoint2: CGPoint(x: tip, y: h))
        path.addLine(to: CGPoint(x: tip + 0.05, y: h - 0.01))
        path.addCurve(
            to: CGPoint(x: tip - 11.04, y: h - 4.04), controlPoint1: CGPoint(x: tip - 4.07, y: h + 0.43),
            controlPoint2: CGPoint(x: tip - 8.16, y: h - 1.06))
        path.addCurve(
            to: CGPoint(x: start, y: h), controlPoint1: CGPoint(x: tip - 16, y: h),
            controlPoint2: CGPoint(x: max(start, tip - 19), y: h))
        path.close()
        if tail == .leading {
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
            colors = [UIColor(white: 0.66, alpha: 1), UIColor(white: 0.53, alpha: 1)]
            symbolName = letters.isEmpty ? "person.2.fill" : nil
        }
        initials.text = symbolName == nil ? letters : nil
        initials.isHidden = symbolName != nil
        symbol.isHidden = symbolName == nil
        symbol.image = symbolName.map {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
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
        gradient.startPoint = CGPoint(x: 0.2, y: 0)
        gradient.endPoint = CGPoint(x: 0.8, y: 1)
        CATransaction.commit()
        initials.font = UIFont.systemFont(ofSize: (bounds.height * 0.42).rounded(), weight: .semibold)
        initials.frame = bounds.insetBy(dx: 2, dy: 0)
        symbol.frame = bounds
        imageView.frame = bounds
    }
}
#endif
