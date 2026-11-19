#if canImport(UIKit) && canImport(SwiftUI)
import ChatPlatformCore
import SwiftUI

/// The chat screen for SwiftUI apps: `ChatViewController` with the same
/// appearance layers. Inside a `NavigationStack`, SwiftUI owns the bar, so
/// this view sets the title from the layers (the presentation's, the code
/// layer's, the dashboard's, or "Support" in the user's language), adds the
/// close button, and hides the bar as the options ask.
///
/// ```swift
/// NavigationStack { ChatView(conversation: conversation) }
/// ```
public struct ChatView: View {
    let conversation: ConversationStore
    let options: ChatPresentationOptions
    let strings: ChatStrings
    let draftKey: String?
    /// Resolved once, like the controller's layers, so the bar never changes on screen.
    @State private var title: String
    @State private var titleFont: UIFont?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The parameters are `ChatViewController`'s.
    public init(
        conversation: ConversationStore, options: ChatPresentationOptions = ChatPresentationOptions(),
        strings: ChatStrings = ChatStrings(), draftKey: String? = "dev.chatplatform.draft"
    ) {
        self.conversation = conversation
        self.options = options
        self.strings = strings
        self.draftKey = draftKey
        let appearance = ChatAppearance.layered(conversation: conversation, presentation: options, strings: strings)
        _title = State(initialValue: appearance.title ?? strings("title"))
        _titleFont = State(initialValue: appearance.titleFont)
    }

    public var body: some View {
        ChatScreen(conversation: conversation, options: options, strings: strings, draftKey: draftKey)
            .ignoresSafeArea()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(NavigationBarVisibility(hidden: options.navigationBarHidden))
            .toolbar {
                if let titleFont {
                    // SwiftUI's title takes no font, so a custom one goes in its place.
                    ToolbarItem(placement: .principal) {
                        Text(title)
                            .font(Font(scaled(titleFont) as CTFont))
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if options.showsCloseButton {
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel(strings("action.close"))
                    }
                }
            }
    }
}

extension ChatView {
    /// The title font at the current Dynamic Type size, as the controller scales it.
    private func scaled(_ font: UIFont) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return ChatTheme.scale(font, style: .headline, traits: traits)
    }
}

/// nil leaves the host's bar as it is; true hides it and false shows it.
private struct NavigationBarVisibility: ViewModifier {
    let hidden: Bool?

    func body(content: Content) -> some View {
        if let hidden {
            content.toolbar(hidden ? .hidden : .visible, for: .navigationBar)
        } else {
            content
        }
    }
}

/// The controller itself; the navigation options are applied by `ChatView`.
private struct ChatScreen: UIViewControllerRepresentable {
    let conversation: ConversationStore
    let options: ChatPresentationOptions
    let strings: ChatStrings
    let draftKey: String?

    func makeUIViewController(context: Context) -> ChatViewController {
        var options = options
        options.showsCloseButton = false
        options.navigationBarHidden = nil
        return ChatViewController(conversation: conversation, options: options, strings: strings, draftKey: draftKey)
    }

    func updateUIViewController(_ controller: ChatViewController, context: Context) {}
}
#endif
