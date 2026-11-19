# Changelog

Changes to the iOS SDK (`ChatPlatformCore` and `ChatPlatformKit`). Versions
follow [semantic versioning](https://semver.org). Add notes under
`Unreleased` as you go; `ios/scripts/release/release.mjs prepare` dates them
at release.

## Unreleased

## 0.1.0 (2026-11-19)

The first public release.

- `ChatClient`: sign in with a token signed by your server (`identify`),
  sessions kept in the Keychain, sign out and account deletion.
- Sign-in without a server of your own: `identify(provider:tokenProvider:)`
  passes a Sign in with Apple, Firebase or Supabase ID token,
  `identifyAnonymously()` keeps one chat per install with a Keychain secret
  (this device only, kept across `logout()`, replaced by `deleteAccount()`),
  and `identify(developmentUserId:)` signs in a test user in debug builds
  only.
- One continuous conversation per user, kept current over a realtime socket.
  Messages send idempotently, are cached on the device, and retry after
  failures and relaunches.
- `ChatViewController` and `ChatView`: a chat screen that looks and feels like
  Messages. It shows Markdown, up to 4 photos per message, receipts, typing,
  time separators and a NEW divider, and a short message when the chat is
  empty, in light and dark mode, with Dynamic Type and VoiceOver, in English,
  Spanish and German.
- Reactions and replies: long-press tapbacks with a preview of the message,
  swipe to reply, quoted bubbles, and jumping to the quoted message.
- Customization in layers: `ChatOptions` in
  `ChatClient.configure(appKey:apiURL:options:)` for every chat,
  `ChatPresentationOptions` for one screen's appearance, title, close button
  and starting draft, and the app's appearance settings from the dashboard,
  API, CLI or MCP in between (colors, read receipts, typing indicator,
  photos, localized title and empty state). Every color is a light/dark pair
  whose sides fall through separately. `ChatViewController(conversation:theme:)`
  is deprecated in favor of `ChatPresentationOptions(appearance:)`.
- Push: `registerDeviceToken` and `ChatPush` helpers for presenting and
  opening chat notifications.
- Events and attributes: `track(_:properties:)` and `setAttributes(_:)`.
  `trackSuperwall(_:paywall:placement:)` forwards Superwall paywall opens,
  closes and declines to the conversation sidebar, without depending on
  Superwall.
