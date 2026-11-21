#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// The composer: attach button, growing text view (up to 5 lines, then it
/// scrolls), picked-photo strip and send button. Pinned to the keyboard by
/// `ChatViewController` through `keyboardLayoutGuide`.
@MainActor
final class ChatInputBar: UIView, UITextViewDelegate {
    var onSend: ((String, [ImageUpload]) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onAttach: (() -> Void)?
    var onCancelReply: (() -> Void)?

    let textView = UITextView()
    private let placeholder = UILabel()
    let sendButton = UIButton(type: .system)
    let attachButton = UIButton(type: .system)
    private let photoStrip = UIStackView()
    private var field = UIView()
    private var textHeight: NSLayoutConstraint!
    /// "Replying to Support" with the quoted text, above the field while replying.
    let replyBanner = UIView()
    private let replyTitle = UILabel()
    private let replyPreview = UILabel()
    private var fieldTop: NSLayoutConstraint!
    private var fieldBelowBanner: NSLayoutConstraint!
    private var attachSurface: UIView!
    private var fieldAfterAttach: NSLayoutConstraint!
    private var fieldAtEdge: NSLayoutConstraint!
    private var fieldBottom: NSLayoutConstraint!
    /// Measured from Messages (402 pt wide iPhone): a 39.5 pt glass circle
    /// and field, 28 pt from the screen's sides.
    static let height: CGFloat = 39.5
    static let sideInset: CGFloat = 28
    /// With the keyboard down, the field sits 6.5 pt into the home
    /// indicator's area, like Messages; above the keyboard it keeps 8 pt clear.
    var restsOnHomeIndicator = false {
        didSet {
            guard restsOnHomeIndicator != oldValue else { return }
            fieldBottom.constant = restsOnHomeIndicator ? 6.5 : -8
        }
    }
    private(set) var photos: [(upload: ImageUpload, preview: UIImage)] = []
    private var theme: ChatTheme
    private let strings: ChatStrings
    static let maxPhotos = 4

    init(theme: ChatTheme, strings: ChatStrings) {
        self.theme = theme
        self.strings = strings
        super.init(frame: .zero)
        backgroundColor = .clear

        // iMessage layout: a round attach button, then a field holding the
        // text and the send button. Both are Liquid Glass on iOS 26 and
        // later, over the thread, which scrolls underneath; earlier versions
        // get a material bar instead.
        let usesGlass: Bool
        if #available(iOS 26.0, *) { usesGlass = true } else { usesGlass = false }
        if !usesGlass {
            let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
            material.translatesAutoresizingMaskIntoConstraints = false
            addSubview(material)
            NSLayoutConstraint.activate([
                material.topAnchor.constraint(equalTo: topAnchor),
                material.leadingAnchor.constraint(equalTo: leadingAnchor),
                material.trailingAnchor.constraint(equalTo: trailingAnchor),
                // Reaches under the home indicator.
                material.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 100),
            ])
        }
        let attachBackground = Self.surface(cornerRadius: Self.height / 2, glass: usesGlass, fill: theme.inputBackground)
        let field = Self.surface(cornerRadius: Self.height / 2, glass: usesGlass, fill: theme.inputBackground)
        self.field = field
        attachSurface = attachBackground

        attachButton.setImage(
            UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)),
            for: .normal)
        attachButton.tintColor = .label
        attachButton.accessibilityLabel = strings("input.attach")
        attachButton.addAction(UIAction { [weak self] _ in self?.onAttach?() }, for: .touchUpInside)

        sendButton.setImage(
            UIImage(systemName: "arrow.up.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)),
            for: .normal)
        sendButton.tintColor = theme.tint
        sendButton.accessibilityLabel = strings("input.send")
        sendButton.addAction(UIAction { [weak self] _ in self?.send() }, for: .touchUpInside)

        textView.font = theme.bodyFont
        textView.textColor = theme.incomingText
        textView.tintColor = theme.tint
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.textContainerInset = Self.textInsets(theme.bodyFont)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityLabel = strings("input.placeholder")

        placeholder.text = strings("input.placeholder")
        placeholder.font = theme.bodyFont
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false

        photoStrip.axis = .horizontal
        photoStrip.spacing = 6
        photoStrip.isHidden = true

        let fieldStack = UIStackView(arrangedSubviews: [photoStrip, textView])
        fieldStack.axis = .vertical
        fieldStack.spacing = 4
        fieldStack.isLayoutMarginsRelativeArrangement = true
        fieldStack.directionalLayoutMargins = .init(top: 0, leading: 4, bottom: 0, trailing: 0)
        let fieldContent = (field as? UIVisualEffectView)?.contentView ?? field
        for view in [fieldStack, placeholder, sendButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            fieldContent.addSubview(view)
        }
        let attachContent = (attachBackground as? UIVisualEffectView)?.contentView ?? attachBackground
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        attachContent.addSubview(attachButton)
        for view in [attachBackground, field] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textHeight = textView.heightAnchor.constraint(equalToConstant: Self.height)
        fieldAfterAttach = field.leadingAnchor.constraint(equalTo: attachBackground.trailingAnchor, constant: 12)
        fieldAtEdge = field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset)
        fieldBottom = field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        buildReplyBanner(theme: theme, strings: strings)
        fieldTop = field.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        fieldBelowBanner = field.topAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: 6)
        NSLayoutConstraint.activate([
            fieldTop,
            replyBanner.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            replyBanner.leadingAnchor.constraint(equalTo: field.leadingAnchor),
            replyBanner.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            attachBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.sideInset),
            attachBackground.bottomAnchor.constraint(equalTo: field.bottomAnchor),
            attachBackground.widthAnchor.constraint(equalToConstant: Self.height),
            attachBackground.heightAnchor.constraint(equalToConstant: Self.height),
            attachButton.topAnchor.constraint(equalTo: attachContent.topAnchor),
            attachButton.bottomAnchor.constraint(equalTo: attachContent.bottomAnchor),
            attachButton.leadingAnchor.constraint(equalTo: attachContent.leadingAnchor),
            attachButton.trailingAnchor.constraint(equalTo: attachContent.trailingAnchor),

            fieldAfterAttach,
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.sideInset),
            fieldBottom,

            fieldStack.topAnchor.constraint(equalTo: fieldContent.topAnchor, constant: 0),
            fieldStack.leadingAnchor.constraint(equalTo: fieldContent.leadingAnchor),
            fieldStack.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor),
            fieldStack.bottomAnchor.constraint(equalTo: fieldContent.bottomAnchor),
            textHeight,

            sendButton.trailingAnchor.constraint(equalTo: fieldContent.trailingAnchor, constant: -3.75),
            sendButton.bottomAnchor.constraint(equalTo: fieldContent.bottomAnchor, constant: -3.75),
            sendButton.widthAnchor.constraint(equalToConstant: 32),
            sendButton.heightAnchor.constraint(equalToConstant: 32),

            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 13),
            placeholder.centerYAnchor.constraint(equalTo: textView.centerYAnchor),
        ])
        updateState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A rounded surface: interactive Liquid Glass, or a plain fill before iOS 26.
    private static func surface(cornerRadius: CGFloat, glass: Bool, fill: UIColor) -> UIView {
        if glass, #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            let view = UIVisualEffectView(effect: effect)
            view.cornerConfiguration = .uniformCorners(radius: .fixed(cornerRadius))
            return view
        }
        let view = UIView()
        view.backgroundColor = fill
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        return view
    }

    /// Centers one line of `font` in the 39.5 pt field.
    private static func textInsets(_ font: UIFont) -> UIEdgeInsets {
        let vertical = max(4, (height - font.lineHeight) / 2)
        return UIEdgeInsets(top: vertical, left: 8, bottom: vertical, right: 4)
    }

    private func buildReplyBanner(theme: ChatTheme, strings: ChatStrings) {
        replyBanner.backgroundColor = theme.inputBackground
        replyBanner.layer.cornerRadius = 12
        replyBanner.layer.cornerCurve = .continuous
        replyBanner.isHidden = true
        let accent = UIView()
        accent.backgroundColor = theme.tint
        accent.layer.cornerRadius = 1.5
        setBannerFonts()
        replyTitle.textColor = theme.tint
        replyPreview.textColor = theme.secondaryText
        replyPreview.lineBreakMode = .byTruncatingTail
        let close = UIButton(type: .system)
        close.setImage(
            UIImage(systemName: "xmark.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)),
            for: .normal)
        close.tintColor = theme.secondaryText
        close.accessibilityLabel = strings("reply.cancel")
        close.addAction(UIAction { [weak self] _ in self?.onCancelReply?() }, for: .touchUpInside)
        for view in [accent, replyTitle, replyPreview, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            replyBanner.addSubview(view)
        }
        replyBanner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(replyBanner)
        NSLayoutConstraint.activate([
            accent.leadingAnchor.constraint(equalTo: replyBanner.leadingAnchor, constant: 10),
            accent.topAnchor.constraint(equalTo: replyBanner.topAnchor, constant: 8),
            accent.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: -8),
            accent.widthAnchor.constraint(equalToConstant: 3),
            replyTitle.leadingAnchor.constraint(equalTo: accent.trailingAnchor, constant: 8),
            replyTitle.topAnchor.constraint(equalTo: replyBanner.topAnchor, constant: 7),
            replyTitle.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            replyPreview.leadingAnchor.constraint(equalTo: replyTitle.leadingAnchor),
            replyPreview.topAnchor.constraint(equalTo: replyTitle.bottomAnchor, constant: 1),
            replyPreview.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            replyPreview.bottomAnchor.constraint(equalTo: replyBanner.bottomAnchor, constant: -7),
            close.trailingAnchor.constraint(equalTo: replyBanner.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: replyBanner.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 32),
            close.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    /// Shows who and what the next message replies to, or hides it with nil.
    func setReply(title: String?, preview: String?) {
        let replying = title != nil
        replyTitle.text = title
        replyPreview.text = preview
        replyBanner.isHidden = !replying
        replyBanner.accessibilityElements = nil
        fieldTop.isActive = !replying
        fieldBelowBanner.isActive = replying
    }

    var isReplying: Bool { !replyBanner.isHidden }
    var replyPreviewFont: UIFont { replyPreview.font }

    var text: String {
        get { textView.text }
        set {
            textView.text = newValue
            textDidChange(notify: false)
        }
    }

    /// Shows or hides the photo button (the `allowPhotos` preference).
    func setAllowsPhotos(_ allowed: Bool) {
        attachSurface.isHidden = !allowed
        fieldAtEdge.isActive = false
        fieldAfterAttach.isActive = allowed
        fieldAtEdge.isActive = !allowed
    }

    func addPhoto(_ upload: ImageUpload, preview: UIImage) {
        guard photos.count < Self.maxPhotos else { return }
        photos.append((upload, preview))
        rebuildStrip()
    }

    var remainingPhotoSlots: Int { Self.maxPhotos - photos.count }

    private func rebuildStrip() {
        photoStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, photo) in photos.enumerated() {
            let button = UIButton(type: .custom)
            button.setImage(photo.preview, for: .normal)
            button.imageView?.contentMode = .scaleAspectFill
            button.clipsToBounds = true
            button.layer.cornerRadius = 8
            button.accessibilityLabel = strings("input.remove_photo")
            button.addAction(UIAction { [weak self] _ in self?.removePhoto(at: index) }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 56).isActive = true
            button.heightAnchor.constraint(equalToConstant: 56).isActive = true
            photoStrip.addArrangedSubview(button)
        }
        photoStrip.addArrangedSubview(UIView())
        photoStrip.isHidden = photos.isEmpty
        updateState()
    }

    private func removePhoto(at index: Int) {
        guard photos.indices.contains(index) else { return }
        photos.remove(at: index)
        rebuildStrip()
    }

    /// Follows a Dynamic Type change.
    /// Follows a Dynamic Type change: the composer in the body font, the
    /// reply banner in the caption font.
    func setFonts(body: UIFont, caption: UIFont) {
        theme.bodyFont = body
        theme.captionFont = caption
        textView.font = body
        textView.textContainerInset = Self.textInsets(body)
        placeholder.font = body
        setBannerFonts()
        textDidChange(notify: false)
    }

    private func setBannerFonts() {
        replyTitle.font = UIFont.systemFont(ofSize: theme.captionFont.pointSize + 1, weight: .semibold)
        replyPreview.font = UIFont.systemFont(ofSize: theme.captionFont.pointSize + 1)
    }

    func textViewDidChange(_ textView: UITextView) {
        textDidChange(notify: true)
    }

    private func textDidChange(notify: Bool) {
        let lineHeight = theme.bodyFont.lineHeight
        let maxHeight = ceil(lineHeight * 5 + textView.textContainerInset.top + textView.textContainerInset.bottom)
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width > 0 ? textView.bounds.width : 280, height: .greatestFiniteMagnitude)).height
        textHeight.constant = min(max(Self.height, ceil(fitting)), maxHeight)
        textView.isScrollEnabled = fitting > maxHeight
        updateState()
        if notify { onTextChange?(textView.text) }
    }

    private func updateState() {
        placeholder.isHidden = !textView.text.isEmpty
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText || !photos.isEmpty
        // Like Messages, the send arrow appears once there's something to send.
        sendButton.isHidden = !sendButton.isEnabled
        attachButton.isEnabled = photos.count < Self.maxPhotos
    }

    private func send() {
        let text = textView.text ?? ""
        let uploads = photos.map(\.upload)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !uploads.isEmpty else { return }
        onSend?(text, uploads)
        photos = []
        rebuildStrip()
        self.text = ""
        onTextChange?("")
    }
}
#endif
