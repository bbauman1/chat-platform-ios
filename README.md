# ChatPlatformKit

In-app support chat for iOS 17+ that looks and feels like Messages.

## Installation

In Xcode, choose File > Add Package Dependencies and enter
`https://github.com/bbauman1/chat-platform-ios`, or add it to `Package.swift`:

```swift
.package(url: "https://github.com/bbauman1/chat-platform-ios", from: "0.3.0"),
```

Then add `ChatPlatformKit` (the chat screen) or only `ChatPlatformCore`
(the client, no UI) to your target.

Documentation: https://bbauman1.github.io/chat-platform-ios/ · Changes: [CHANGELOG.md](CHANGELOG.md)

## Usage

```swift
import ChatPlatformCore
import ChatPlatformKit

let chat = ChatClient.configure(
    appKey: "app_…",                                       // dashboard: app settings
    apiURL: URL(string: "https://<api>.onrender.com")!,
    options: ChatOptions())                                // optional: see "Customizing the chat"
await chat.identify(userId: user.id) {
    try await myServer.chatIdentityToken()                 // HS256 JWT signed with your app's secret
}
let conversation = try chat.conversation()
let token = conversation.observe { state in render(state) }
conversation.start()                                       // socket + load + resend unsent
conversation.send(text: "Hi")
```

- **Identity.** Your server signs the identity token; aliases and attributes
  are claims in it (`aliases`, `attrs`, `cv`), so a device can't forge them.
  `identify` with another `userId` drops the previous user's session and
  cache; `logout()` also revokes the session; `deleteAccount()` deletes the
  user on the server.
- **Without a server** (switch each on in the app's identity
  settings first):

  ```swift
  // Sign in with Apple, Firebase Auth or Supabase Auth: the API verifies the
  // provider's ID token. Called again whenever a new session is needed.
  try await chat.identify(provider: .firebase) {
      try await Auth.auth().currentUser!.getIDToken()
  }
  // No accounts: one private chat per install. The secret stays in the
  // Keychain (this device only) across logout(); deleteAccount() replaces it.
  await chat.identifyAnonymously()
  #if DEBUG
  // Try the chat before a server exists; refused unless development mode is on.
  await chat.identify(developmentUserId: "dev-" + UIDevice.current.name)
  #endif
  ```

  `identify(developmentUserId:)` exists only in debug builds;
  `ios/scripts/check-release-identity.sh` (run by `ci-test.sh`) fails if a
  release build contains it. New anonymous and development users are rate
  limited per IP, so session creation can fail with a retryable 429.
- **Sessions** live in the Keychain (after first unlock, this device only)
  and refresh a minute before expiry or after a 401; concurrent requests
  share one refresh.
- **Sending** is idempotent: each message keeps its `clientId` and each image
  its `Idempotency-Key` across retries and relaunches. Retryable failures
  back off and then wait for the next reconnect; others mark the message
  failed until `retry` or `discard`.
- **Realtime.** Sockets only signal: after every `ready` the
  store reloads over HTTP, catching up from the newest message it holds.
  Reconnects use jittered backoff from 0.5 s to 30 s; close 4000 refreshes
  and reconnects at once, 4401 signs in again, 4403 stops. Typing is sent
  at most every 1.5 s, and the team's typing expires after 3.5 s.
- **Local store.** The newest 200 messages and every unsent message (with its
  image bytes) are cached under Application Support, so the thread shows
  before the first load.

## Events and attributes

```swift
chat.track("paywall_viewed", properties: ["placement": "onboarding", "price": 9.99])
try await chat.setAttributes(["plan": "pro", "beta": nil])   // nil removes a key
```

- Events trigger campaigns and appear in the dashboard's customer sidebar.
  They queue on the device, per app key (surviving relaunches, at most 1,000) and go out
  in batches of up to 100 about a second later; each keeps its UUID across
  retries, so the API stores it once. Events tracked before `identify` go
  to the first user identified. Signing out sends what's queued first.
- An event with an invalid name or properties is dropped when tracked
  (names `^[A-Za-z][A-Za-z0-9_.:-]*$`, ≤ 64 characters; ≤ 50 properties of
  strings, numbers or booleans, ≤ 4 KB).
- **Superwall.** Paywall opens, closes and declines only exist in the app,
  so forward them from your `SuperwallDelegate`; the conversation sidebar
  shows them. The SDK doesn't depend on Superwall. With SuperwallKit 3, the
  placement is `presentedByEventWithName`.

  ```swift
  func handleSuperwallEvent(withInfo eventInfo: SuperwallEventInfo) {
      switch eventInfo.event {
      case .paywallOpen(let info): chat.trackSuperwall(.open, paywall: info.identifier, placement: info.presentedByPlacementWithName)
      case .paywallClose(let info): chat.trackSuperwall(.close, paywall: info.identifier, placement: info.presentedByPlacementWithName)
      case .paywallDecline(let info): chat.trackSuperwall(.decline, paywall: info.identifier, placement: info.presentedByPlacementWithName)
      default: break
      }
  }
  ```

  They're sent as `superwall.paywall_open`, `superwall.paywall_close` and
  `superwall.paywall_decline` with `paywall` and `placement` properties.
- `setAttributes` merges into the user's SDK attributes, which the device
  controls: use them for targeting and display, never for anything that
  must not be forged (identity-token `attrs` are the trusted ones).

## Push notifications

```swift
// AppDelegate
func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Task { try? await chat.registerDeviceToken(token, environment: .current) }  // every launch
}

// UNUserNotificationCenterDelegate
func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
    async -> UNNotificationPresentationOptions {
    ChatPush.presentationOptions(for: notification) ?? [.banner, .sound]   // `??`: your own pushes
}
func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    if ChatPush.chatNotification(for: response) != nil { showSupportChat() }
}
```

- Pushes are sent with the app's APNs key from the dashboard, for each team
  message; the payload carries `chatPlatform: { messageId }`, which is how
  `ChatNotification(userInfo:)` tells them from the app's own pushes.
- The token is remembered: identifying another user registers it for them,
  and signing out deletes it on the server. `badges: true` lets pushes set
  the icon badge.
- `PushEnvironment.current` reads `aps-environment` from the embedded
  provisioning profile (`sandbox` for development signing, otherwise
  `production`).
- While a chat screen is visible, chat pushes show no banner: the message
  appears in the thread.

## The chat screen

```swift
import ChatPlatformKit

let screen = ChatViewController(conversation: try chat.conversation())
navigationController?.pushViewController(screen, animated: true)
// SwiftUI: ChatView(conversation: try chat.conversation())
// Tab or button badge: ChatUnreadBadge
```

- A `UICollectionView` thread with exact precomputed row heights:
  older pages load without moving the message being read, new messages are
  followed only while the newest one is on screen, and a 5,000-message
  thread scrolls in about 0.1 ms of layout per frame.
- Looks like Messages: iMessage blue by default, light and dark mode, a
  floating composer and nav bar in Liquid Glass on iOS 26+ (a material bar
  before), Markdown in messages (bold, italic, strikethrough, code, links)
  and tappable web links, a long-press menu with Copy (plus Retry and Delete
  for a message that failed), haptics on send and on failure, drafts, up to
  4 photos per message, receipts, typing, Dynamic Type and VoiceOver.
- Reactions and replies like Messages: long-press a message for the
  tapback palette (❤️ 👍 👎 😂 ‼️ ❓; tap yours again to remove it), Reply
  and Copy. Badges sit on the bubble's top corner facing the other side.
  Swipe a message right to reply: the quoted message shows above the
  composer and then as a faded bubble above yours; tapping a quote scrolls
  to the original, loading older history when needed. A reaction that
  arrives while the thread is open (a revision-only change) reloads from
  the oldest message on screen.
- One continuous thread per user: "**Today** 8:49 AM" separators start each
  day and each pick-up after an hour or more, a blue "NEW" line marks where
  unread messages begin (until the user comes back to the chat), the screen
  opens at the first unread message, and a "jump to latest" button appears
  when scrolled up, tinted when new messages arrived.
- Action cards from the team, with full-width buttons inside the
  bubble under the prompt:
  - **Rate the app**: Apple's rating prompt, plus "Write a Review" opening
    the App Store page when the app has an App Store ID (`PATCH /v1/apps/{id}`
    with `appStoreId`). Whether the user rated isn't knowable; the card
    reports that the prompt was asked for.
  - **Refund**: Apple's refund sheet for the transaction or product the
    card names, else the newest purchase; it reports submitted, cancelled
    or failed.
  - **Manage subscription**: Apple's subscription sheet; the SDK compares
    renewal before and after and reports a cancelled renewal, a changed
    plan or no change.

  When StoreKit finds no purchase or subscription to act on, the refund or
  subscription card drops its button and reports `failed`. Each card reports
  shown, tapped, opened and the outcome to the dashboard's metrics. Card types this SDK version doesn't know show as plain messages.
- English, Spanish and German.

## Customizing the chat

Four layers, highest first; each field (and each light or dark side of a
color) comes from the highest layer that sets it:

```swift
// 2. Code, once at launch: beats the dashboard.
let chat = ChatClient.configure(appKey: "app_…", apiURL: apiURL, options: ChatOptions(
    appearance: ChatAppearance(
        accent: ChatColor(light: .systemIndigo, dark: .systemPurple),
        bodyFont: UIFont(name: "Avenir Next", size: 17),   // at the default size; Dynamic Type scales it
        titleFont: UIFont(name: "AvenirNext-DemiBold", size: 17),
        bubbleCornerRadius: 12)))

// 1. Presentation, for one screen: beats everything.
let screen = ChatViewController(conversation: try chat.conversation(), options: ChatPresentationOptions(
    appearance: ChatAppearance(allowPhotos: false),
    title: "Order #1234", showsCloseButton: true, draft: "About order #1234: "))
```

3. **The dashboard**, the API, the CLI or the MCP server:
   colors as light/dark pairs, read receipts,
   typing indicator, photos, and the title and empty-state text per
   language. The SDK fetches them at `configure` and whenever a chat opens,
   keeps them on disk, and applies them to the next chat screen, so a screen
   on display never changes. `ChatOptions(remoteAppearance: false)` ignores them.
4. **Defaults**: system colors for light and dark, iMessage blue, Dynamic
   Type, Liquid Glass on iOS 26+.

Fonts, the corner radius and the title font exist only in code. In SwiftUI,
`ChatView(conversation:options:)` takes the same options and sets the
navigation title, close button and bar visibility through SwiftUI.

## Issues and contributions

This repository is published from a private repository on every release, so
pull requests here can't be merged as they are. Please open an issue instead,
with a pull request if you like: fixes are applied upstream and ship in the
next release.

## License

MIT. See [LICENSE](LICENSE).
