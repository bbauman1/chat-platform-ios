import Foundation

/// The end user's conversation (`GET /v1/sdk/conversation`).
public struct Conversation: Codable, Sendable, Equatable {
    public var id: String
    /// Highest message sequence in the conversation.
    public var sequence: Int
    /// Bumped by every change; realtime events older than this are dropped.
    public var revision: Int
    /// Highest sequence the end user has read.
    public var endUserRead: Int
    /// Highest sequence the team has read (drives "Seen" receipts).
    public var agentRead: Int

    public init(id: String, sequence: Int, revision: Int, endUserRead: Int, agentRead: Int) {
        self.id = id
        self.sequence = sequence
        self.revision = revision
        self.endUserRead = endUserRead
        self.agentRead = agentRead
    }
}

/// Who sent a message. Unknown future values decode as `.unknown` (`/v1` is additive).
public enum SenderType: Sendable, Equatable, Hashable, Codable {
    case endUser, member, campaign, system
    /// The app's AI agent ("Your Agent"); `Message.senderName` is its name.
    case aiAgent
    case unknown(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "end_user": self = .endUser
        case "member": self = .member
        case "campaign": self = .campaign
        case "system": self = .system
        case "ai_agent": self = .aiAgent
        default: self = .unknown(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var rawValue: String {
        switch self {
        case .endUser: "end_user"
        case .member: "member"
        case .campaign: "campaign"
        case .system: "system"
        case .aiAgent: "ai_agent"
        case .unknown(let raw): raw
        }
    }

    /// True for messages the end user wrote; everything else is from the team.
    public var isEndUser: Bool { self == .endUser }
}

public struct Attachment: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var width: Int
    public var height: Int

    public init(id: String, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}

/// One emoji's reactions on a message, as the end user sees them
public struct Reaction: Codable, Sendable, Equatable, Hashable {
    public var emoji: String
    public var count: Int
    /// The end user's own reaction is this one.
    public var mine: Bool

    public init(emoji: String, count: Int, mine: Bool) {
        self.emoji = emoji
        self.count = count
        self.mine = mine
    }
}

/// The message a reply quotes.
public struct ReplyPreview: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var senderType: SenderType
    /// The first 120 characters of the quoted text.
    public var textPreview: String
    public var hasAttachments: Bool

    public init(id: String, senderType: SenderType, textPreview: String, hasAttachments: Bool) {
        self.id = id
        self.senderType = senderType
        self.textPreview = textPreview
        self.hasAttachments = hasAttachments
    }

    /// The preview the server would give for `message`.
    public init(_ message: Message) {
        self.init(
            id: message.id, senderType: message.senderType, textPreview: String(message.text.prefix(120)),
            hasAttachments: !message.attachments.isEmpty)
    }
}

/// A message the server has stored.
public struct Message: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var sequence: Int
    /// The client-generated idempotency key the message was sent with.
    public var clientId: String
    public var senderType: SenderType
    public var text: String
    public var attachments: [Attachment]
    public var createdAt: Date
    /// Grouped by emoji, in order of first use.
    public var reactions: [Reaction]
    /// The message this one replies to.
    public var replyTo: ReplyPreview?
    /// Set for an action message (`kind: "action"`): a card with a
    /// button that opens native UI. `text` is its prompt, in the user's language.
    public var action: MessageAction?
    /// The AI agent's name on its messages (`senderType` `.aiAgent`); nil otherwise.
    public var senderName: String?

    public init(
        id: String, sequence: Int, clientId: String, senderType: SenderType, text: String,
        attachments: [Attachment] = [], createdAt: Date, reactions: [Reaction] = [], replyTo: ReplyPreview? = nil,
        action: MessageAction? = nil, senderName: String? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.clientId = clientId
        self.senderType = senderType
        self.text = text
        self.attachments = attachments
        self.createdAt = createdAt
        self.reactions = reactions
        self.replyTo = replyTo
        self.action = action
        self.senderName = senderName
    }

    private enum CodingKeys: String, CodingKey {
        case id, sequence, clientId, senderType, text, attachments, createdAt, reactions, replyTo, kind, action
        case senderName
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(clientId, forKey: .clientId)
        try c.encode(senderType, forKey: .senderType)
        try c.encode(text, forKey: .text)
        try c.encode(attachments, forKey: .attachments)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(reactions, forKey: .reactions)
        try c.encodeIfPresent(replyTo, forKey: .replyTo)
        try c.encode(action == nil ? "text" : "action", forKey: .kind)
        try c.encodeIfPresent(action, forKey: .action)
        try c.encodeIfPresent(senderName, forKey: .senderName)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sequence = try c.decode(Int.self, forKey: .sequence)
        clientId = try c.decode(String.self, forKey: .clientId)
        senderType = try c.decode(SenderType.self, forKey: .senderType)
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        // Older caches (and servers before P1.14) have neither field.
        reactions = try c.decodeIfPresent([Reaction].self, forKey: .reactions) ?? []
        replyTo = try c.decodeIfPresent(ReplyPreview.self, forKey: .replyTo)
        // Older servers and caches have no kind; a kind this SDK doesn't
        // know shows as text. A malformed action never fails the message.
        let kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        action = kind == "action" ? try? c.decodeIfPresent(MessageAction.self, forKey: .action) : nil
        // Servers before P11.5 and older caches have no sender name.
        senderName = try c.decodeIfPresent(String.self, forKey: .senderName)
    }
}

/// What an action message asks the app to do.
public struct MessageAction: Codable, Sendable, Equatable, Hashable {
    /// `rate_app`, `refund`, `manage_subscription`, or a type a newer SDK
    /// renders (shown as an ordinary message here).
    public var type: String
    /// String and number parameters, as strings. `rate_app` gets `appStoreId`;
    /// `refund` may have `productId` or `transactionId`; `manage_subscription`
    /// may have `subscriptionGroupId`. Other values are dropped.
    public var params: [String: String]

    public init(type: String, params: [String: String] = [:]) {
        self.type = type
        self.params = params
    }

    /// A step the SDK reports (`POST .../action-events`); `outcome` carries a result.
    public enum Step: String, Sendable, Codable {
        case shown, tapped, opened, outcome
    }

    private enum CodingKeys: String, CodingKey { case type, params }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        var params: [String: String] = [:]
        if let p = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: .params) {
            for key in p.allKeys {
                if let value = try? p.decode(String.self, forKey: key) {
                    params[key.stringValue] = value
                } else if let value = try? p.decode(Int.self, forKey: key) {
                    params[key.stringValue] = String(value)
                } else if let value = try? p.decode(Double.self, forKey: key) {
                    params[key.stringValue] = String(value)
                }
            }
        }
        self.params = params
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(params, forKey: .params)
    }
}

/// A page of history (`GET /v1/sdk/conversation/messages`), oldest first.
public struct MessagePage: Codable, Sendable, Equatable {
    public var messages: [Message]
    /// Continues in the same direction; nil at the end.
    public var nextCursor: String?
    /// An `after` cursor at the newest message seen, for catching up.
    public var newerCursor: String
}

/// `POST /v1/sdk/sessions` and `/refresh`.
public struct SessionTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    /// Access token lifetime in seconds.
    public var expiresIn: Int
}

/// A stored session: tokens plus when the access token expires.
public struct StoredSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var accessExpiresAt: Date
    /// The app key the session was issued for, so a reconfigured app never reuses it.
    public var appKey: String
    /// The customer's user ID passed to `identify`, so switching users starts a new session.
    public var userId: String

    public init(
        accessToken: String, refreshToken: String, accessExpiresAt: Date, appKey: String,
        userId: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accessExpiresAt = accessExpiresAt
        self.appKey = appKey
        self.userId = userId
    }
}

/// `POST /v1/realtime/tickets`.
struct RealtimeTicket: Codable, Sendable {
    var ticket: String
    var url: String
    var expiresIn: Int
}

struct UnreadCount: Codable, Sendable {
    var unread: Int
}
