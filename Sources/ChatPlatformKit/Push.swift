#if canImport(UIKit)
import ChatPlatformCore
import UIKit
import UserNotifications

extension PushEnvironment {
    /// The APNs environment this build's tokens come from, read from the
    /// embedded provisioning profile: `sandbox` for development signing,
    /// `production` for ad hoc, TestFlight and App Store builds (App Store
    /// builds carry no profile).
    public static var current: PushEnvironment {
        from(provisioningProfile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) })
    }

    /// The profile is a signed plist; its XML is readable as Latin-1 text.
    static func from(provisioningProfile data: Data?) -> PushEnvironment {
        guard let data, let text = String(data: data, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>")
        else { return .production }
        return text[key.upperBound...].prefix(100).contains("<string>development</string>") ? .sandbox : .production
    }
}

/// Helpers for the host app's `UNUserNotificationCenterDelegate`.
///
/// ```swift
/// func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
///     async -> UNNotificationPresentationOptions {
///     if let options = ChatPush.presentationOptions(for: notification) { return options }
///     return [.banner, .sound]  // your own pushes
/// }
///
/// func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
///     if ChatPush.chatNotification(for: response) != nil { showSupportChat() }
/// }
/// ```
@MainActor
public enum ChatPush {
    /// Chat screens on screen now. Weak, so a screen torn down without
    /// disappearing doesn't keep counting.
    static let visible = NSHashTable<UIViewController>.weakObjects()
    /// Overrides the count in tests.
    static var visibleScreensOverride: Int?
    static var visibleScreens: Int { visibleScreensOverride ?? visible.allObjects.count }

    /// How to show a push while the app is open: nil if it isn't a chat push;
    /// nothing while a chat screen is visible, since the message appears in
    /// the thread; otherwise a banner, as when the app is in the background.
    public static func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        presentationOptions(userInfo: notification.request.content.userInfo)
    }

    static func presentationOptions(userInfo: [AnyHashable: Any]) -> UNNotificationPresentationOptions? {
        guard ChatNotification(userInfo: userInfo) != nil else { return nil }
        return visibleScreens > 0 ? [] : [.banner, .list, .sound, .badge]
    }

    /// The chat push the user tapped, or nil for any other notification.
    /// Show the chat screen when it isn't nil.
    public static func chatNotification(for response: UNNotificationResponse) -> ChatNotification? {
        ChatNotification(userInfo: response.notification.request.content.userInfo)
    }
}
#endif
