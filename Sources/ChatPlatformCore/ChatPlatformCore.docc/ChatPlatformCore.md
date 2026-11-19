# ``ChatPlatformCore``

The chat client without UI: sessions, the conversation, realtime updates,
push registration and events.

## Overview

`ChatPlatformCore` talks to the chat-platform API and keeps the end user's one
conversation up to date. It has no UIKit, so it also builds on Linux and
macOS. Most apps use `ChatPlatformKit` for the chat screen, which is built on
this module.

```swift
import ChatPlatformCore

let chat = ChatClient(configuration: .init(
    appKey: "app_…", apiURL: URL(string: "https://<api>.onrender.com")!))
await chat.identify(userId: user.id) {
    try await myServer.chatIdentityToken()  // signed by your server
}
let conversation = try chat.conversation()
let token = conversation.observe { state in render(state) }
conversation.start()
conversation.send(text: "Hi")
```

## Topics

### Starting a session

- ``ChatClient``
- ``ChatConfiguration``
- ``ChatError``
- ``IdentityProvider``
- ``InstallSecretStorage``
- ``KeychainInstallSecretStorage``
- ``InMemoryInstallSecretStorage``
- ``InstallSecretUnavailable``

### The conversation

- ``ConversationStore``
- ``Conversation``
- ``Message``
- ``OutgoingMessage``
- ``ImageUpload``
- ``Reaction``
- ``ReplyPreview``
- ``SenderType``
- ``Attachment``

### Appearance

- ``RemoteAppearance``
- ``CachedAppearance``
- ``AppearanceCache``
- ``InMemoryAppearanceCache``

### Events and push

- ``EventValue``
- ``SuperwallPaywallEvent``
- ``PushEnvironment``
- ``ChatNotification``

### Storage and transport

- ``SessionStorage``
- ``MessageCache``
- ``FileMessageCache``
- ``HTTPTransport``
- ``WebSocketTransport``
