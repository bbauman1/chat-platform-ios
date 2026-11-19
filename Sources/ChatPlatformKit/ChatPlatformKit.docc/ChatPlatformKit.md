# ``ChatPlatformKit``

An in-app support chat screen that looks and feels like Messages.

## Overview

`ChatPlatformKit` shows the end user's conversation from `ChatPlatformCore`.
It uses a `UICollectionView` with precomputed row heights, light and dark
mode, Markdown, photos, reactions, replies, receipts and typing indicators.

```swift
import ChatPlatformKit

let screen = ChatViewController(conversation: try chat.conversation())
navigationController?.pushViewController(screen, animated: true)
```

In SwiftUI, use ``ChatView``.

## Topics

### Showing the chat

- ``ChatViewController``
- ``ChatView``
- ``ChatUnreadBadge``

### Appearance and language

- ``ChatAppearance``
- ``ChatColor``
- ``ChatOptions``
- ``ChatPresentationOptions``
- ``ChatTheme``
- ``ChatStrings``

### Push notifications

- ``ChatPush``
