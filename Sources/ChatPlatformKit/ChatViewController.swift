#if canImport(UIKit)
import ChatPlatformCore
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The support chat screen: a `UICollectionView` thread over a diffable data
/// source keyed by message, with exact precomputed row heights,
/// and a composer pinned to the keyboard.
///
/// ```swift
/// let chat = ChatViewController(conversation: try client.conversation())
/// navigationController?.pushViewController(chat, animated: true)
/// ```
///
/// Its look combines four layers: the `options` passed here, the
/// `ChatOptions` given to `ChatClient.configure`, the app's appearance
/// settings from the dashboard as last fetched, and the SDK's defaults. The
/// layers are read once, when the screen is made; opening it fetches the
/// dashboard's settings again for the next screen.
///
/// It starts the conversation when shown and stops it when hidden or in the
/// background, marks messages read while the newest one is on screen, keeps
/// the visible message in place while older pages load, and keeps a draft of
/// unsent text per user.
@MainActor
public final class ChatViewController: UIViewController {
    /// The theme with its fonts resolved for the current Dynamic Type size.
    public private(set) var theme: ChatTheme
    private let baseTheme: ChatTheme
    public let strings: ChatStrings
    /// The merged layers, for what the theme doesn't hold (receipts, typing,
    /// photos, title, empty state).
    let appearance: ChatAppearance
    let presentation: ChatPresentationOptions
    private let emptyState = UILabel()
    /// The group chat header: the people on the team over "2 People ›".
    let header = ChatHeaderView()
    /// Below the header when it shows, else below the navigation bar.
    private var offlineBannerTop: NSLayoutConstraint!
    var emptyStateLabel: UILabel { emptyState }
    private var hostHidNavigationBar: Bool?

    let source: ThreadSource
    private(set) var collectionView: UICollectionView!
    private(set) var inputBar: ChatInputBar!
    private var jumpAboveComposer: NSLayoutConstraint!
    private var installedAccessory: UIView?

    /// A view that sits just above the composer (the support team app's macros).
    @_spi(AgentApp) public var composerAccessory: UIView? {
        didSet { if isViewLoaded { installComposerAccessory() } }
    }

    /// Replaces the composer's text (a macro) and focuses it.
    @_spi(AgentApp) public func setComposerText(_ text: String) {
        loadViewIfNeeded()
        inputBar.text = text
        source.setTyping(!text.isEmpty)
        drafts?.save(text)
        inputBar.textView.becomeFirstResponder()
    }
    private let layout = ThreadLayout()
    private var dataSource: UICollectionViewDiffableDataSource<Int, ThreadItemID>!
    private(set) var model = ThreadModel()
    private let layoutCache = LayoutCache()
    private var calculator: RowLayoutCalculator
    private lazy var images = ImageLoader { [weak self] in self?.source }
    private var observation: ObservationToken?
    private var drafts: DraftStore?
    private var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible { ChatPush.visible.add(self) } else { ChatPush.visible.remove(self) }
        }
    }
    private var hasAppliedState = false
    /// The user is at the newest message: new messages and size changes
    /// (keyboard, composer growth) keep it in view.
    private(set) var isPinnedToBottom = true
    /// The read position when this screen appeared; team messages after it
    /// get the "NEW" divider until the user comes back to the chat.
    private(set) var unreadBoundary: Int?
    private var unreadBoundaryDecided = false
    /// Loads older pages until the first unread message is on hand, so the
    /// divider and the opening position use it. Positioning waits for it.
    private var unreadHistoryTask: Task<Void, Never>?
    private var unreadHistoryGaveUp = false
    /// Older pages are loaded to reach the first unread message only up to this many messages.
    static let unreadHistoryLimit = 500
    /// Open at the first unread message (or the newest) once there's content and a size.
    private var needsInitialPosition = true
    private var unseenNewMessages = false
    private let jumpButton = UIButton(type: .system)
    private var jumpContainer: UIView!
    private var isApplying = false
    private var isAnimatingToBottom = false
    private struct ScrollGeometry: Equatable {
        var inset: UIEdgeInsets
        var size: CGSize
        var content: CGSize
    }
    private var lastGeometry: ScrollGeometry?
    private var loadOlderTask: Task<Void, Never>?
    private let offlineBanner = UILabel()
    private var offlineTimer: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    /// The message the composer's next send replies to.
    private(set) var replyingTo: Message?
    /// Swipe to reply: the row being dragged and whether it passed the threshold.
    private var swipe: (item: ThreadItemID, messageId: String, armed: Bool)?
    private var jumpTask: Task<Void, Never>?
    /// Dragging a row this far right replies when let go.
    static let swipeThreshold: CGFloat = 60

    /// Tapbacks, as in Messages, with their accessibility names.
    static let tapbacks: [(emoji: String, name: String)] = [
        ("❤️", "reaction.heart"), ("👍", "reaction.like"), ("👎", "reaction.dislike"),
        ("😂", "reaction.laugh"), ("‼️", "reaction.emphasize"), ("❓", "reaction.question"),
    ]

    /// Date handling, injectable for tests.
    var calendar = Calendar.current
    /// Opens the native UI behind action cards; replaced in tests.
    var storeActions: StoreActions = StoreKitActions()
    /// Refund and subscription cards whose availability was checked, by
    /// message ID: false when StoreKit found nothing to act on.
    private var actionAvailability: [String: Bool] = [:]
    var now: () -> Date = Date.init
    /// Whether this controller starts and stops the conversation with its own visibility.
    var managesConnection = true

    /// - Parameters:
    ///   - conversation: from `ChatClient.conversation()`.
    ///   - options: this screen's title, navigation bar, starting draft and
    ///     appearance overrides; the highest layer.
    ///   - strings: the screen's text, in the device's language by default.
    ///   - draftKey: prefix of the `UserDefaults` key that keeps unsent text,
    ///     or nil to keep none. The key is scoped to the app and the signed-in
    ///     user, so a different user never sees another's draft.
    public convenience init(
        conversation: ConversationStore, options: ChatPresentationOptions = ChatPresentationOptions(),
        strings: ChatStrings = ChatStrings(), draftKey: String? = "dev.chatplatform.draft"
    ) {
        let appearance = ChatAppearance.layered(conversation: conversation, presentation: options, strings: strings)
        self.init(
            source: conversation, theme: ChatTheme(appearance), strings: strings,
            draftKey: Self.scopedDraftKey(draftKey, appKey: conversation.appKey, userId: conversation.userId),
            appearance: appearance, presentation: options)
        // For the next chat screen; this one keeps what it was made with.
        Task { await conversation.refreshAppearance() }
    }

    /// A chat screen with a fixed theme that skips the appearance layers.
    @available(*, deprecated, message: "Pass ChatPresentationOptions(appearance:) or ChatOptions to ChatClient.configure")
    public convenience init(
        conversation: ConversationStore, theme: ChatTheme, strings: ChatStrings = ChatStrings(),
        draftKey: String? = "dev.chatplatform.draft"
    ) {
        self.init(
            source: conversation, theme: theme, strings: strings,
            draftKey: Self.scopedDraftKey(draftKey, appKey: conversation.appKey, userId: conversation.userId))
    }

    static func scopedDraftKey(_ prefix: String?, appKey: String, userId: String) -> String? {
        prefix.map { "\($0).\(appKey).\(userId)" }
    }

    /// A chat screen over any `ThreadSource`, for the support team app.
    @_spi(AgentApp)
    public init(
        source: ThreadSource, theme: ChatTheme, strings: ChatStrings, draftKey: String?,
        appearance: ChatAppearance = ChatAppearance(), presentation: ChatPresentationOptions = ChatPresentationOptions()
    ) {
        self.source = source
        self.theme = theme
        baseTheme = theme
        self.appearance = appearance
        self.presentation = presentation
        calculator = RowLayoutCalculator(bodyFont: theme.bodyFont, captionFont: theme.captionFont)
        self.strings = strings
        drafts = draftKey.map { DraftStore(key: $0) }
        super.init(nibName: nil, bundle: nil)
        title = appearance.title ?? strings("title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    public override func viewDidLoad() {
        super.viewDidLoad()
        resolveFonts()
        view.backgroundColor = theme.background

        layout.heightForItem = { [weak self] indexPath, width in
            self?.height(at: indexPath, width: width) ?? 44
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = theme.background
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: MessageCell.reuseID)
        collectionView.register(SeparatorCell.self, forCellWithReuseIdentifier: SeparatorCell.reuseID)
        collectionView.register(UnreadDividerCell.self, forCellWithReuseIdentifier: UnreadDividerCell.reuseID)
        collectionView.register(TypingCell.self, forCellWithReuseIdentifier: TypingCell.reuseID)
        collectionView.register(LoadingCell.self, forCellWithReuseIdentifier: LoadingCell.reuseID)
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, item in
            self?.cell(collectionView, indexPath, item) ?? UICollectionViewCell()
        }

        inputBar = ChatInputBar(theme: theme, strings: strings)
        inputBar.onSend = { [weak self] text, uploads in self?.send(text, uploads) }
        inputBar.onTextChange = { [weak self] text in
            self?.source.setTyping(!text.isEmpty)
            self?.drafts?.save(text)
        }
        inputBar.onAttach = { [weak self] in self?.pickPhotos() }
        inputBar.onCancelReply = { [weak self] in self?.setReplying(nil) }
        inputBar.setAllowsPhotos(appearance.allowPhotos ?? true)
        if let draft = drafts?.load(), !draft.isEmpty {
            inputBar.text = draft
        } else if let draft = presentation.draft {
            inputBar.text = draft
        }

        emptyState.text = appearance.emptyStateMessage ?? strings("empty")
        emptyState.font = theme.captionFont
        emptyState.adjustsFontForContentSizeCategory = false
        emptyState.textColor = theme.secondaryText
        emptyState.textAlignment = .center
        emptyState.numberOfLines = 0
        emptyState.isHidden = true

        offlineBanner.text = strings("connection.offline")
        offlineBanner.font = theme.captionFont
        offlineBanner.textColor = theme.secondaryText
        offlineBanner.backgroundColor = theme.inputBackground
        offlineBanner.textAlignment = .center
        offlineBanner.layer.cornerRadius = 10
        offlineBanner.clipsToBounds = true
        offlineBanner.alpha = 0

        // "Jump to latest": a small glass circle above the composer.
        let jumpSurface: UIView
        if #available(iOS 26.0, *) {
            let effect = UIGlassEffect()
            effect.isInteractive = true
            let glass = UIVisualEffectView(effect: effect)
            glass.cornerConfiguration = .uniformCorners(radius: .fixed(18))
            glass.contentView.addSubview(jumpButton)
            jumpSurface = glass
        } else {
            let plain = UIView()
            plain.backgroundColor = theme.inputBackground
            plain.layer.cornerRadius = 18
            plain.addSubview(jumpButton)
            jumpSurface = plain
        }
        jumpButton.setImage(
            UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        jumpButton.accessibilityLabel = strings("jump.latest")
        jumpButton.addTarget(self, action: #selector(jumpToLatest), for: .touchUpInside)
        jumpButton.translatesAutoresizingMaskIntoConstraints = false
        jumpSurface.alpha = 0
        jumpSurface.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        jumpContainer = jumpSurface
        let jumpContent = (jumpSurface as? UIVisualEffectView)?.contentView ?? jumpSurface
        NSLayoutConstraint.activate([
            jumpButton.topAnchor.constraint(equalTo: jumpContent.topAnchor),
            jumpButton.bottomAnchor.constraint(equalTo: jumpContent.bottomAnchor),
            jumpButton.leadingAnchor.constraint(equalTo: jumpContent.leadingAnchor),
            jumpButton.trailingAnchor.constraint(equalTo: jumpContent.trailingAnchor),
        ])

        for subview in [collectionView!, emptyState, inputBar!, offlineBanner, jumpSurface] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // Laid out by hand in viewDidLayoutSubviews: it hangs from the navigation bar.
        header.isHidden = true
        view.insertSubview(header, aboveSubview: collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The thread runs under the composer, which floats over it.
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            emptyState.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 40),
            emptyState.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -40),
            offlineBanner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            offlineBanner.heightAnchor.constraint(equalToConstant: 24),
            offlineBanner.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            jumpSurface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            jumpSurface.widthAnchor.constraint(equalToConstant: 36),
            jumpSurface.heightAnchor.constraint(equalToConstant: 36),
        ])
        jumpAboveComposer = jumpSurface.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -8)
        jumpAboveComposer.isActive = true
        offlineBannerTop = offlineBanner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        offlineBannerTop.isActive = true
        installComposerAccessory()
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        navigationItem.largeTitleDisplayMode = .never
        configureNavigationItem()
        if #available(iOS 26.0, *) {
            // Soft edge behind the floating composer, like Messages.
            let edge = UIScrollEdgeElementContainerInteraction()
            edge.scrollView = collectionView
            edge.edge = .bottom
            inputBar.addInteraction(edge)
        }

        let swipeToReply = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeToReply.delegate = self
        collectionView.addGestureRecognizer(swipeToReply)

        observation = source.observe { [weak self] state in self?.apply(state) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.resolveFonts()
            self.inputBar.setFonts(body: self.theme.bodyFont, caption: self.theme.captionFont)
            self.offlineBanner.font = self.theme.captionFont
            self.emptyState.font = self.theme.captionFont
            self.configureNavigationItem()
            self.updateHeader(self.model.participants)
            // Keep the message being read in place while every row resizes.
            let anchor = self.isPinnedToBottom ? nil : self.visibleAnchor()
            self.isApplying = true
            self.layoutCache.reset(width: 0, category: .unspecified)
            self.layout.invalidateHeights()
            var snapshot = self.dataSource.snapshot()
            snapshot.reconfigureItems(snapshot.itemIdentifiers)
            self.dataSource.apply(snapshot, animatingDifferences: false)
            self.collectionView.layoutIfNeeded()
            if let anchor, let index = self.dataSource.indexPath(for: anchor.item)?.item,
               let frame = self.layout.frame(at: index)
            {
                self.collectionView.contentOffset.y = frame.minY - anchor.offset
            } else if self.isPinnedToBottom {
                self.scrollToBottom(animated: false)
            }
            self.isApplying = false
        }
    }

    /// The group chat look: names, avatars and the people in the title.
    var showsSenders: Bool { appearance.showSenders ?? true }

    /// The header: the people on the team who wrote here in a glass circle
    /// over "2 People ›", like a group in Messages. It replaces the title; a
    /// chat no one has answered yet keeps the plain title.
    private func updateHeader(_ participants: [RowSender]) {
        let wasShown = !header.isHidden
        guard showsSenders, !participants.isEmpty else {
            header.isHidden = true
            if wasShown {
                navigationItem.titleView = nil
                view.setNeedsLayout()
            }
            return
        }
        let text = participants.count > 1
            ? String(format: strings("header.count"), participants.count)
            : participants[0].name ?? strings("a11y.from_team")
        let font = appearance.titleFont.map { ChatTheme.scale($0, style: .headline, traits: traitCollection) }
        header.configure(
            people: participants, text: text, font: font, tint: theme.tint,
            menuTitle: strings("a11y.people"),
            names: participants.map { person in
                let name = person.name ?? strings("a11y.from_team")
                return person.isAI ? String(format: strings("sender.ai"), name) : name
            })
        for person in participants.suffix(ChatHeaderView.maxAvatars) {
            guard let url = person.avatarURL else { continue }
            let ref = ImageRef.remote(url), size = CGSize(width: ChatHeaderView.avatarSize, height: ChatHeaderView.avatarSize)
            if let image = images.cached(ref, size: size) {
                header.setImage(image, for: url)
            } else {
                let task = images.load(ref, size: size)
                Task { [weak header] in header?.setImage(await task.value, for: url) }
            }
        }
        header.isHidden = false
        // An empty title view keeps the bar's title text from showing through.
        if !wasShown {
            navigationItem.titleView = UIView()
            view.setNeedsLayout()
        }
    }

    /// Hangs the header from the navigation bar's middle (or where one
    /// would be) and keeps the oldest message below it.
    private func layoutHeader() {
        var top: CGFloat = 0
        if !header.isHidden {
            let middle: CGFloat
            if let bar = navigationController?.navigationBar, navigationController?.isNavigationBarHidden == false,
               bar.window != nil
            {
                middle = view.convert(bar.bounds, from: bar).midY
            } else {
                middle = view.safeAreaInsets.top + 22
            }
            let m = ChatHeaderView.metrics
            let height = ceil(middle + m.pillDrop + m.pillHeight / 2)
            header.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: height)
            header.anchorY = middle
            top = max(0, height + 4 - view.safeAreaInsets.top)
        }
        // The offline banner sits below the header's pill rather than over it.
        let bannerTop = 8 + (header.isHidden ? 0 : max(0, header.frame.maxY - view.safeAreaInsets.top))
        if offlineBannerTop.constant != bannerTop { offlineBannerTop.constant = bannerTop }
        if collectionView.contentInset.top != top {
            collectionView.contentInset.top = top
            collectionView.verticalScrollIndicatorInsets.top = top
        }
    }

    /// The title font and close button from the presentation and appearance.
    private func configureNavigationItem() {
        if let titleFont = appearance.titleFont {
            let font = ChatTheme.scale(titleFont, style: .headline, traits: traitCollection)
            let bar = UINavigationBarAppearance()
            bar.configureWithDefaultBackground()
            bar.titleTextAttributes[.font] = font
            navigationItem.standardAppearance = bar
            navigationItem.scrollEdgeAppearance = bar
            navigationItem.compactAppearance = bar
        }
        if presentation.showsCloseButton, navigationItem.leftBarButtonItem == nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        }
    }

    /// Re-resolves the theme's fonts for the current Dynamic Type size.
    private func resolveFonts() {
        theme = baseTheme.scaled(for: traitCollection)
        calculator = RowLayoutCalculator(bodyFont: theme.bodyFont, captionFont: theme.captionFont)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if managesConnection { source.start() }
        if let hidden = presentation.navigationBarHidden, let navigationController {
            if hostHidNavigationBar == nil { hostHidNavigationBar = navigationController.isNavigationBarHidden }
            navigationController.setNavigationBarHidden(hidden, animated: animated)
        }
        if hasAppliedState {
            // Coming back: what was unread before has been seen.
            unreadBoundaryDecided = false
            unreadHistoryGaveUp = false
            apply(source.state)
        }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.willEnterForeground() }
            },
        ]
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        markReadIfAtBottom()
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        source.setTyping(false)
        drafts?.save(inputBar.text)
        if let hostHidNavigationBar, let navigationController {
            // Leaving the chat, or covered by another screen: give the host its bar back.
            navigationController.setNavigationBarHidden(hostHidNavigationBar, animated: animated)
            self.hostHidNavigationBar = nil
        }
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if managesConnection { source.stop() }
    }

    private func didEnterBackground() {
        source.setTyping(false)
        if managesConnection { source.stop() }
    }

    private func willEnterForeground() {
        guard managesConnection else { return }
        source.start()
        source.reconnectNow()
    }

    private func installComposerAccessory() {
        installedAccessory?.removeFromSuperview()
        installedAccessory = composerAccessory
        jumpAboveComposer.isActive = false
        guard let accessory = composerAccessory else {
            jumpAboveComposer = jumpContainer.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -8)
            jumpAboveComposer.isActive = true
            return
        }
        accessory.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(accessory, belowSubview: inputBar)
        jumpAboveComposer = jumpContainer.bottomAnchor.constraint(equalTo: accessory.topAnchor, constant: -8)
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            accessory.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            accessory.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            jumpAboveComposer,
        ])
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeader()
        inputBar.restsOnHomeIndicator = view.safeAreaInsets.bottom > 0
            && inputBar.frame.maxY >= view.bounds.maxY - view.safeAreaInsets.bottom - 0.5
        let width = collectionView.bounds.width
        layoutCache.reset(width: width, category: traitCollection.preferredContentSizeCategory)
        // Keep the newest message above the composer and keyboard. The
        // automatic adjustment already adds the bottom safe area.
        let accessoryTop = installedAccessory.flatMap { $0.isHidden ? nil : $0.frame.minY } ?? .infinity
        let covered = max(0, view.bounds.maxY - min(inputBar.frame.minY, accessoryTop) - view.safeAreaInsets.bottom)
        // A taller composer (a second line, the accessory appearing) keeps the
        // newest message in view even within the "near the bottom" margin.
        let grew = covered > collectionView.contentInset.bottom
        if collectionView.contentInset.bottom != covered {
            collectionView.contentInset.bottom = covered
            collectionView.verticalScrollIndicatorInsets.bottom = covered
            // A short thread is aligned to the bottom within the insets.
            layout.invalidateLayout()
        }
        positionInitiallyIfNeeded()
        if isPinnedToBottom, hasAppliedState, !needsInitialPosition {
            isApplying = true
            collectionView.layoutIfNeeded()
            if !isNearBottom || grew { scrollToBottom(animated: false) }
            isApplying = false
        }
    }

    // MARK: State

    func apply(_ state: ConversationStore.State) {
        guard isViewLoaded else { return }
        decideUnreadBoundary(state)
        let next = ThreadModel(
            state: state, calendar: calendar, strings: strings, now: now(), unreadAfter: unreadBoundary,
            showsReadReceipts: appearance.showReadReceipts ?? true,
            showsTypingIndicator: appearance.showTypingIndicator ?? true,
            hiddenActions: Set(actionAvailability.filter { !$0.value }.keys), showsSenders: showsSenders)
        checkActionAvailability(next)
        let previous = model
        if next.participants != previous.participants || !hasAppliedState { updateHeader(next.participants) }
        // While the user is at the newest message, follow new ones; otherwise
        // keep the message they're reading still, whatever changes above it.
        let followBottom = isPinnedToBottom || !hasAppliedState
        let anchor = followBottom || previous.items.isEmpty ? nil : visibleAnchor()
        model = next
        if hasAppliedState, next.rows.contains(where: { id, row in
            row.status == .failed && previous.rows[id].map { $0.status != .failed } ?? false
        }) {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }

        var snapshot = NSDiffableDataSourceSnapshot<Int, ThreadItemID>()
        snapshot.appendSections([0])
        snapshot.appendItems(next.items)
        let existing = Set(previous.items)
        let changed = next.items.filter { id in
            existing.contains(id) && (previous.rows[id] != next.rows[id]
                || previous.separators[separatorKey(id)] != next.separators[separatorKey(id)])
        }
        snapshot.reconfigureItems(changed + (next.items.contains(.loadingOlder) && existing.contains(.loadingOlder) ? [.loadingOlder] : []))

        // Animate only changes at the bottom while following it; anchored
        // updates must land in one step so nothing visibly jumps.
        let hadMessages = previous.items.contains(where: \.isMessage)
        let animate = hasAppliedState && followBottom && hadMessages && UIView.areAnimationsEnabled
            && view.window != nil
        isApplying = true
        dataSource.apply(snapshot, animatingDifferences: animate)
        layout.invalidateHeights()
        collectionView.layoutIfNeeded()
        if let anchor, let index = dataSource.indexPath(for: anchor.item)?.item, let frame = layout.frame(at: index) {
            collectionView.contentOffset.y = frame.minY - anchor.offset
        } else if followBottom, !needsInitialPosition {
            scrollToBottom(animated: animate && next.items.last != previous.items.last)
        }
        isApplying = false
        if !followBottom, next.items.last != previous.items.last, previous.items.contains(where: \.isMessage) {
            unseenNewMessages = true
        }
        positionInitiallyIfNeeded()
        updateJumpButton()
        hasAppliedState = true
        // Once the server answered (or a cached thread is shown) and there's nothing in it.
        emptyState.isHidden = state.conversation == nil && !state.isConnected
            || next.items.contains(where: \.isMessage) || next.items.contains(.loadingOlder)
        updateOfflineBanner(connected: state.isConnected)
        markReadIfAtBottom()
        reportVisibleSequence()
    }

    /// Tells the conversation the oldest message on screen, so a reaction
    /// or receipt there reloads it.
    private func reportVisibleSequence() {
        guard let anchor = visibleAnchor(), let sequence = model.rows[anchor.item]?.sequence else { return }
        source.setFirstVisibleSequence(sequence)
    }

    private func separatorKey(_ id: ThreadItemID) -> String {
        if case .separator(let key) = id { return key }
        return ""
    }

    /// Fixes the unread boundary once per appearance, as soon as the
    /// conversation (and so the read position) is known.
    private func decideUnreadBoundary(_ state: ConversationStore.State) {
        guard !unreadBoundaryDecided, unreadHistoryTask == nil, let conversation = state.conversation else { return }
        let read = conversation.endUserRead
        let hasUnread = state.messages.contains { !$0.senderType.isEndUser && $0.sequence > read }
        // The first unread message may be older than the loaded page.
        if hasUnread, state.hasOlderMessages, (state.messages.first?.sequence ?? 0) > read + 1,
           state.messages.count < Self.unreadHistoryLimit, !unreadHistoryGaveUp
        {
            let count = state.messages.count
            unreadHistoryTask = Task { [weak self] in
                let loaded = (try? await self?.source.loadOlder()) != nil
                guard let self else { return }
                self.unreadHistoryTask = nil
                if !loaded || self.source.state.messages.count <= count { self.unreadHistoryGaveUp = true }
                self.apply(self.source.state)
            }
            return
        }
        unreadBoundaryDecided = true
        unreadBoundary = hasUnread ? read : nil
    }

    /// The first time there are messages and a size: show the first unread
    /// message near the top (with the divider above it) if there's more than
    /// a screen after it, otherwise the newest message.
    private func positionInitiallyIfNeeded() {
        guard needsInitialPosition, unreadHistoryTask == nil, collectionView.bounds.width > 0,
              model.items.contains(where: \.isMessage)
        else {
            return
        }
        needsInitialPosition = false
        isApplying = true
        layout.invalidateHeights()
        collectionView.layoutIfNeeded()
        if let index = dataSource.indexPath(for: .unreadDivider)?.item, let frame = layout.frame(at: index) {
            let top = -collectionView.adjustedContentInset.top
            let maxOffset = collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
            let target = frame.minY - collectionView.adjustedContentInset.top - 8
            collectionView.contentOffset.y = min(max(top, maxOffset), max(top, target))
            isPinnedToBottom = isNearBottom
        } else {
            scrollToBottom(animated: false)
        }
        isApplying = false
        lastGeometry = ScrollGeometry(
            inset: collectionView.adjustedContentInset, size: collectionView.bounds.size,
            content: collectionView.contentSize)
    }

    private func updateJumpButton() {
        guard jumpContainer != nil else { return }
        if isPinnedToBottom { unseenNewMessages = false }
        let distance = collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom - collectionView.contentOffset.y
        let show = !isPinnedToBottom && distance > collectionView.bounds.height / 2
        jumpButton.tintColor = unseenNewMessages ? theme.tint : theme.secondaryText
        guard show != (jumpContainer.alpha > 0) else { return }
        UIView.animate(withDuration: 0.2) {
            self.jumpContainer.alpha = show ? 1 : 0
            self.jumpContainer.transform = show ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
        }
    }

    @objc private func jumpToLatest() {
        UISelectionFeedbackGenerator().selectionChanged()
        unseenNewMessages = false
        scrollToBottom(animated: true)
        updateJumpButton()
    }

    var isJumpButtonVisible: Bool { (jumpContainer?.alpha ?? 0) > 0 }

    func indexPath(for item: ThreadItemID) -> IndexPath? {
        dataSource.indexPath(for: item)
    }

    /// The topmost visible message row and its distance below the top of the viewport.
    func visibleAnchor() -> (item: ThreadItemID, offset: CGFloat)? {
        // Ask the layout rather than `indexPathsForVisibleItems`, which is
        // stale between an offset change and the next layout pass.
        let top = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let viewport = CGRect(x: 0, y: top, width: collectionView.bounds.width, height: collectionView.bounds.height)
        let attributes = (layout.layoutAttributesForElements(in: viewport) ?? []).sorted { $0.indexPath < $1.indexPath }
        for attribute in attributes where attribute.frame.maxY > top {
            guard let item = dataSource.itemIdentifier(for: attribute.indexPath), item.isMessage else { continue }
            return (item, attribute.frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    var isNearBottom: Bool {
        guard let collectionView else { return true }
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom
        return collectionView.contentOffset.y >= maxOffset - 40
    }

    func scrollToBottom(animated: Bool) {
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.adjustedContentInset.bottom
        let offset = max(-collectionView.adjustedContentInset.top, maxOffset)
        isPinnedToBottom = true
        isAnimatingToBottom = animated && abs(collectionView.contentOffset.y - offset) > 0.5
        collectionView.setContentOffset(CGPoint(x: 0, y: offset), animated: animated)
    }

    private func updateOfflineBanner(connected: Bool) {
        offlineTimer?.cancel()
        guard !connected, managesConnection else {
            UIView.animate(withDuration: 0.2) { self.offlineBanner.alpha = 0 }
            return
        }
        // Only show it if reconnecting takes a while.
        offlineTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: 0.2) { self.offlineBanner.alpha = 1 }
        }
    }

    private func markReadIfAtBottom() {
        guard isVisible, isNearBottom, UIApplication.shared.applicationState == .active else { return }
        source.markRead()
    }

    // MARK: Rows

    private func height(at indexPath: IndexPath, width: CGFloat) -> CGFloat {
        guard indexPath.item < model.items.count else { return 0 }
        let metrics = calculator.metrics
        switch model.items[indexPath.item] {
        case .loadingOlder: return metrics.loadingHeight
        case .separator: return metrics.separatorHeight
        case .unreadDivider: return metrics.unreadDividerHeight
        case .typing: return metrics.typingHeight
        case .message:
            return messageLayout(for: model.items[indexPath.item], width: width)?.height ?? 44
        }
    }

    private func messageLayout(for id: ThreadItemID, width: CGFloat) -> MessageLayout? {
        guard let row = model.rows[id] else { return nil }
        layoutCache.reset(width: width, category: traitCollection.preferredContentSizeCategory)
        let theme = self.theme
        return layoutCache.layout(for: row) { row in
            calculator.layout(
                row, width: width, textColor: row.isOutgoing ? theme.outgoingText : theme.incomingText,
                linkColor: row.isOutgoing ? theme.outgoingText : theme.tint, quoteColor: theme.secondaryText,
                // Every badge is the incoming gray, whoever reacted.
                reactionColor: theme.incomingText,
                senderColor: theme.secondaryText == .secondaryLabel ? ChatTheme.senderName : theme.secondaryText)
        }
    }

    private func cell(_ collectionView: UICollectionView, _ indexPath: IndexPath, _ item: ThreadItemID)
        -> UICollectionViewCell
    {
        switch item {
        case .loadingOlder:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LoadingCell.reuseID, for: indexPath) as! LoadingCell
            cell.configure(loading: source.state.isLoadingOlder || source.state.hasOlderMessages)
            return cell
        case .separator(let key):
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: SeparatorCell.reuseID, for: indexPath) as! SeparatorCell
            if let separator = model.separators[key] { cell.configure(separator, theme: theme) }
            return cell
        case .unreadDivider:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: UnreadDividerCell.reuseID, for: indexPath) as! UnreadDividerCell
            cell.configure(theme: theme, strings: strings)
            return cell
        case .typing:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: TypingCell.reuseID, for: indexPath) as! TypingCell
            cell.configure(theme: theme, strings: strings, metrics: calculator.metrics, avatarColumn: showsSenders)
            return cell
        case .message:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MessageCell.reuseID, for: indexPath) as! MessageCell
            guard let row = model.rows[item],
                  let layout = messageLayout(for: item, width: collectionView.bounds.width)
            else { return cell }
            cell.configure(row, layout: layout, theme: theme, strings: strings)
            if row.status == .failed, let clientId = row.clientId {
                cell.onStatusTap = { [weak self] in self?.offerRetry(clientId) }
            }
            cell.onLinkTap = { [weak self] url in self?.open(url) }
            if let quoted = row.replyTo?.id {
                cell.onQuoteTap = { [weak self] in self?.jump(toMessage: quoted) }
            }
            // The cell is one VoiceOver element, so its card buttons, quote
            // and long-press menu are offered as actions.
            var actions: [UIAccessibilityCustomAction] = []
            if let card = row.action, let messageId = row.messageId {
                cell.onActionTap = { [weak self] index in
                    guard card.buttons.indices.contains(index) else { return }
                    self?.perform(card.buttons[index], of: card, messageId: messageId)
                }
                for (button, title) in zip(card.buttons, card.titles) {
                    actions.append(UIAccessibilityCustomAction(name: title) { [weak self] _ in
                        self?.perform(button, of: card, messageId: messageId)
                        return true
                    })
                }
            }
            if let quoted = row.replyTo?.id {
                actions.append(UIAccessibilityCustomAction(name: strings("a11y.jump_to_quote")) { [weak self] _ in
                    self?.jump(toMessage: quoted)
                    return true
                })
            }
            if let messageId = row.messageId {
                actions.append(UIAccessibilityCustomAction(name: strings("action.reply")) { [weak self] _ in
                    self?.beginReply(to: messageId)
                    return true
                })
                actions += Self.tapbacks.map { tapback in
                    UIAccessibilityCustomAction(name: "\(tapback.emoji) \(strings(tapback.name))") { [weak self] _ in
                        self?.react(tapback.emoji, on: messageId)
                        return true
                    }
                }
            }
            cell.accessibilityCustomActions = actions.isEmpty ? nil : actions
            if row.showsAvatar, let url = row.sender?.avatarURL {
                let ref = ImageRef.remote(url), size = layout.avatar.size
                if let image = images.cached(ref, size: size) {
                    cell.avatar.setImage(image, for: url)
                } else {
                    let task = images.load(ref, size: size)
                    Task { [weak cell] in
                        let image = await task.value
                        cell?.avatar.setImage(image, for: url)
                    }
                }
            }
            for (index, ref) in row.images.enumerated() where index < layout.images.count {
                let size = layout.images[index].size
                if let image = images.cached(ref, size: size) {
                    cell.setImage(image, at: index, key: ref.cacheKey)
                } else {
                    let task = images.load(ref, size: size)
                    Task { [weak cell] in
                        let image = await task.value
                        cell?.setImage(image, at: index, key: ref.cacheKey)
                    }
                }
            }
            return cell
        }
    }

    // MARK: Actions

    private func send(_ text: String, _ uploads: [ImageUpload]) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        source.send(text: text, images: uploads, replyTo: replyingTo)
        setReplying(nil)
        source.setTyping(false)
        drafts?.save("")
        scrollToBottom(animated: true)
    }

    private func open(_ url: URL) {
        guard MessageMarkdown.isSafe(url) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: Action cards

    /// Runs a card's button and reports each step.
    func perform(_ button: ActionCard.Button, of card: ActionCard, messageId: String) {
        guard let scene = view.window?.windowScene else { return }
        source.reportAction(.tapped, result: nil, on: messageId)
        let report: (MessageAction.Step, String?) -> Void = { [weak self] step, result in
            self?.source.reportAction(step, result: result, on: messageId)
        }
        switch (button, card.kind) {
        case (.rate, _):
            storeActions.requestReview(in: scene)
            report(.opened, nil)
        case (.writeReview, .rateApp(let appStoreId?)):
            guard let url = ActionCard.writeReviewURL(appStoreId: appStoreId) else { return }
            Task {
                if await storeActions.open(url) {
                    report(.opened, nil)
                    report(.outcome, "store_opened")
                } else {
                    report(.outcome, "failed")
                }
            }
        case (.refund, .refund(let productId, let transactionId)):
            Task {
                let outcome = await storeActions.refund(
                    productId: productId, transactionId: transactionId, in: scene, opened: { report(.opened, nil) })
                switch outcome {
                case .noPurchase:
                    report(.outcome, "failed")
                    showNotice(strings("card.no_purchase"))
                default:
                    report(.outcome, outcome.rawValue)
                }
            }
        case (.manageSubscription, .manageSubscription(let groupId)):
            Task {
                let outcome = await storeActions.manageSubscriptions(
                    groupId: groupId, in: scene, opened: { report(.opened, nil) })
                switch outcome {
                case .noSubscription:
                    report(.outcome, "failed")
                    showNotice(strings("card.no_subscription"))
                default:
                    report(.outcome, outcome.rawValue)
                }
            }
        default:
            break
        }
    }

    /// Asks StoreKit once per refund or subscription card whether there's
    /// anything to act on. A card with nothing behind it loses its button
    /// and reports `failed`, rather than offering a dead end.
    private func checkActionAvailability(_ model: ThreadModel) {
        for row in model.rows.values {
            guard let card = row.action, let messageId = row.messageId, actionAvailability[messageId] == nil else { continue }
            if case .rateApp = card.kind { continue }
            actionAvailability[messageId] = true
            let store = storeActions
            Task { [weak self] in
                let available =
                    switch card.kind {
                    case .refund(let productId, let transactionId):
                        await store.canRefund(productId: productId, transactionId: transactionId)
                    case .manageSubscription(let groupId):
                        await store.hasSubscription(groupId: groupId)
                    case .rateApp:
                        true
                    }
                guard !available, let self else { return }
                actionAvailability[messageId] = false
                source.reportAction(.outcome, result: "failed", on: messageId)
                apply(source.state)
            }
        }
    }

    private func showNotice(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings("action.ok"), style: .default))
        present(alert, animated: true)
    }

    // MARK: Reactions and replies

    /// Sets (or, for the one already there, removes) the end user's reaction.
    func react(_ emoji: String, on messageId: String) {
        let current = source.state.messages.first { $0.id == messageId }?.reactions.first(where: \.mine)?.emoji
        UISelectionFeedbackGenerator().selectionChanged()
        let next = current == emoji ? nil : emoji
        Task { [weak self] in try? await self?.source.setReaction(next, on: messageId) }
    }

    /// Starts a reply to a confirmed message: the banner shows above the composer.
    func beginReply(to messageId: String) {
        guard let message = source.state.messages.first(where: { $0.id == messageId }) else { return }
        setReplying(message)
        inputBar.textView.becomeFirstResponder()
    }

    func setReplying(_ message: Message?) {
        replyingTo = message
        guard let message else {
            inputBar.setReply(title: nil, preview: nil)
            return
        }
        let preview = message.text.isEmpty && !message.attachments.isEmpty ? strings("a11y.photo") : message.text
        inputBar.setReply(
            title: strings(message.senderType.isEndUser ? "reply.to_self" : "reply.to_team"),
            preview: preview.replacingOccurrences(of: "\n", with: " "))
        view.setNeedsLayout()
    }

    /// Scrolls to a quoted message, loading older pages if it isn't loaded,
    /// and flashes it.
    func jump(toMessage messageId: String) {
        jumpTask?.cancel()
        if scrollTo(messageId: messageId) { return }
        // Older pages land above the message being read, not at the bottom.
        isPinnedToBottom = false
        jumpTask = Task { [weak self] in
            guard let found = try? await self?.source.loadUntilMessage(id: messageId), found, !Task.isCancelled,
                  let self
            else { return }
            self.apply(self.source.state)
            self.scrollTo(messageId: messageId)
        }
    }

    @discardableResult
    private func scrollTo(messageId: String) -> Bool {
        guard let item = model.itemsByMessageId[messageId], let indexPath = dataSource.indexPath(for: item) else {
            return false
        }
        UISelectionFeedbackGenerator().selectionChanged()
        isPinnedToBottom = false
        collectionView.layoutIfNeeded()
        if let frame = layout.frame(at: indexPath.item) {
            let visible = collectionView.bounds.height - collectionView.adjustedContentInset.top
                - collectionView.adjustedContentInset.bottom
            let top = -collectionView.adjustedContentInset.top
            let maxOffset = collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
            let target = frame.midY - visible / 2 - collectionView.adjustedContentInset.top
            collectionView.setContentOffset(
                CGPoint(x: 0, y: min(max(top, maxOffset), max(top, target))), animated: UIView.areAnimationsEnabled)
        }
        let flash = { [weak self] in
            guard let self, let indexPath = self.dataSource.indexPath(for: item) else { return }
            (self.collectionView.cellForItem(at: indexPath) as? MessageCell)?.flash()
        }
        if UIView.areAnimationsEnabled {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                flash()
            }
        } else {
            flash()
        }
        updateJumpButton()
        return true
    }

    @objc private func handleSwipe(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            let point = recognizer.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  let item = dataSource.itemIdentifier(for: indexPath), let messageId = model.rows[item]?.messageId
            else {
                swipe = nil
                return
            }
            swipe = (item, messageId, false)
        case .changed:
            guard var current = swipe else { return }
            let dx = max(0, recognizer.translation(in: collectionView).x)
            // Follows the finger, then resists past the threshold, like Messages.
            let offset = dx <= Self.swipeThreshold ? dx : Self.swipeThreshold + (dx - Self.swipeThreshold) * 0.3
            let armed = dx >= Self.swipeThreshold
            if armed != current.armed {
                current.armed = armed
                swipe = current
                if armed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            }
            swipeCell(current.item)?.setSwipe(offset: offset, progress: dx / Self.swipeThreshold)
        case .ended, .cancelled, .failed:
            guard let current = swipe else { return }
            swipe = nil
            let cell = swipeCell(current.item)
            UIView.animate(
                withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0,
                options: [.allowUserInteraction, .beginFromCurrentState]
            ) {
                cell?.setSwipe(offset: 0, progress: 0)
            }
            if current.armed, recognizer.state == .ended { beginReply(to: current.messageId) }
        default:
            break
        }
    }

    private func swipeCell(_ item: ThreadItemID) -> MessageCell? {
        dataSource.indexPath(for: item).flatMap { collectionView.cellForItem(at: $0) as? MessageCell }
    }

    /// An emoji drawn as an image, for the tapback palette.
    static func emojiImage(_ emoji: String) -> UIImage {
        let font = UIFont.systemFont(ofSize: 26)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let size = (emoji as NSString).size(withAttributes: attributes)
        return UIGraphicsImageRenderer(size: size).image { _ in
            (emoji as NSString).draw(at: .zero, withAttributes: attributes)
        }.withRenderingMode(.alwaysOriginal)
    }

    /// Tapbacks and Reply for confirmed messages, Copy, plus Retry and Delete
    /// for a message that failed to send.
    func menuActions(for item: ThreadItemID) -> [UIMenuElement] {
        guard let row = model.rows[item] else { return [] }
        var actions: [UIMenuElement] = []
        if let messageId = row.messageId {
            let current = row.reactions.first(where: \.mine)?.emoji
            let tapbacks = Self.tapbacks.map { tapback in
                UIAction(
                    title: strings(tapback.name), image: Self.emojiImage(tapback.emoji),
                    state: tapback.emoji == current ? .on : .off
                ) { [weak self] _ in self?.react(tapback.emoji, on: messageId) }
            }
            actions.append(UIMenu(title: "", options: [.displayInline, .displayAsPalette], children: tapbacks))
            actions.append(UIAction(title: strings("action.reply"), image: UIImage(systemName: "arrowshape.turn.up.left")) {
                [weak self] _ in self?.beginReply(to: messageId)
            })
        }
        let cell = dataSource.indexPath(for: item).flatMap { collectionView.cellForItem(at: $0) as? MessageCell }
        let images = cell?.loadedImages ?? []
        let plainText = messageLayout(for: item, width: collectionView.bounds.width)?.attributedText?.string ?? row.text
        if !plainText.isEmpty || !images.isEmpty {
            actions.append(UIAction(title: strings("action.copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                var items: [[String: Any]] = []
                if !plainText.isEmpty { items.append([UTType.utf8PlainText.identifier: plainText]) }
                for image in images {
                    if let data = image.pngData() { items.append([UTType.png.identifier: data]) }
                }
                UIPasteboard.general.items = items
            })
        }
        if row.status == .failed, let clientId = row.clientId {
            actions.append(UIAction(title: strings("action.retry"), image: UIImage(systemName: "arrow.clockwise")) {
                [weak self] _ in self?.source.retry(clientId)
            })
            actions.append(UIAction(
                title: strings("action.delete"), image: UIImage(systemName: "trash"), attributes: .destructive
            ) { [weak self] _ in self?.source.discard(clientId) })
        }
        return actions
    }

    func bubblePreview(for indexPath: IndexPath) -> UITargetedPreview? {
        guard let cell = collectionView.cellForItem(at: indexPath) as? MessageCell, !cell.bubble.isHidden else {
            return nil
        }
        let parameters = UIPreviewParameters()
        // The lifted preview draws in its own container, where the bubble's
        // dynamic color can resolve to nothing; the platter paints it instead,
        // resolved against the cell as it looks in the thread.
        parameters.backgroundColor = cell.bubble.fillColor.resolvedColor(with: cell.traitCollection)
        // The bubble's own shape, tail included, which reaches past its bounds.
        parameters.visiblePath = cell.bubble.shapePath
        return UITargetedPreview(view: cell.bubble, parameters: parameters)
    }

    private func offerRetry(_ clientId: String) {
        let sheet = UIAlertController(title: nil, message: strings("status.failed"), preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: strings("action.retry"), style: .default) { [weak self] _ in
            self?.source.retry(clientId)
        })
        sheet.addAction(UIAlertAction(title: strings("action.delete"), style: .destructive) { [weak self] _ in
            self?.source.discard(clientId)
        })
        sheet.addAction(UIAlertAction(title: strings("action.cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func pickPhotos() {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = inputBar.remainingPhotoSlots
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func loadOlderIfNeeded() {
        guard loadOlderTask == nil, !needsInitialPosition, source.state.hasOlderMessages, !source.state.isLoadingOlder,
              collectionView.contentOffset.y < 600
        else { return }
        loadOlderTask = Task { [weak self] in
            try? await self?.source.loadOlder()
            self?.loadOlderTask = nil
        }
    }
}

extension ChatViewController: UICollectionViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Scrolling decides whether to follow new messages, but offset changes
        // caused by layout (insets, size, content height) or our own scrolling don't.
        let geometry = ScrollGeometry(
            inset: scrollView.adjustedContentInset, size: scrollView.bounds.size, content: scrollView.contentSize)
        defer { lastGeometry = geometry }
        if !isApplying, geometry == lastGeometry, !isAnimatingToBottom || scrollView.isTracking {
            isAnimatingToBottom = false
            isPinnedToBottom = isNearBottom
        }
        updateJumpButton()
        loadOlderIfNeeded()
    }

    public func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let item = dataSource.itemIdentifier(for: indexPaths[0]), item.isMessage else {
            return nil
        }
        let actions = menuActions(for: item)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in UIMenu(children: actions) }
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        highlightPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        bubblePreview(for: indexPath)
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfiguration configuration: UIContextMenuConfiguration,
        dismissalPreviewForItemAt indexPath: IndexPath
    ) -> UITargetedPreview? {
        bubblePreview(for: indexPath)
    }

    public func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath
    ) {
        guard indexPath.item < model.items.count, let row = model.rows[model.items[indexPath.item]],
              row.action != nil, let messageId = row.messageId
        else { return }
        source.reportAction(.shown, result: nil, on: messageId)
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        isAnimatingToBottom = false
        isPinnedToBottom = isNearBottom
        markReadIfAtBottom()
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        markReadIfAtBottom()
        reportVisibleSequence()
    }

    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            markReadIfAtBottom()
            reportVisibleSequence()
        }
    }
}

extension ChatViewController: UIGestureRecognizerDelegate {
    /// Swipe to reply starts only on a rightward, mostly horizontal drag over
    /// a confirmed message, so vertical scrolling is untouched.
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, pan !== collectionView.panGestureRecognizer
        else { return true }
        let velocity = pan.velocity(in: collectionView)
        guard velocity.x > 0, abs(velocity.x) > abs(velocity.y) * 1.5 else { return false }
        let point = pan.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let item = dataSource.itemIdentifier(for: indexPath)
        else { return false }
        return model.rows[item]?.messageId != nil
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        false
    }
}

extension ChatViewController: UICollectionViewDataSourcePrefetching {
    public func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            guard let item = dataSource.itemIdentifier(for: indexPath), let row = model.rows[item],
                  !row.images.isEmpty, let layout = messageLayout(for: item, width: collectionView.bounds.width)
            else { continue }
            for (index, ref) in row.images.enumerated() where index < layout.images.count {
                images.load(ref, size: layout.images[index].size)
            }
        }
    }
}

extension ChatViewController: PHPickerViewControllerDelegate {
    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { return }
                let sendable = UncheckedImage(image: image)
                Task { @MainActor [weak self] in
                    guard let upload = await PhotoEncoder.upload(from: sendable.image) else { return }
                    let preview = await ImageLoader.decode(upload.data, pixels: CGSize(width: 168, height: 168))
                    self?.inputBar.addPhoto(upload, preview: preview ?? sendable.image)
                }
            }
        }
    }
}

/// UIImage is immutable; this carries one across the picker's callback queue.
private struct UncheckedImage: @unchecked Sendable {
    let image: UIImage
}

extension ThreadItemID {
    var isMessage: Bool {
        if case .message = self { return true }
        return false
    }
}

extension MessageRow {
    /// The `clientId` of the end user's own messages (rows keyed `c:<clientId>`).
    var clientId: String? {
        key.hasPrefix("c:") ? String(key.dropFirst(2)) : nil
    }
}
#endif
