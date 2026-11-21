#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// Identifies a row in the thread. The diffable data source holds only these;
/// the row's content lives in `ThreadModel`, so a changed message is
/// reconfigured in place instead of deleted and inserted.
enum ThreadItemID: Hashable, Sendable {
    case loadingOlder
    /// "Today 8:49 AM": before the first message of a day, and when the chat
    /// picks back up after an hour or more. Keyed by the message it precedes.
    case separator(String)
    /// The blue "NEW" line above the first message that was unread when the
    /// screen opened.
    case unreadDivider
    /// A message. The end user's own messages are keyed by `clientId`
    /// (`c:<clientId>`), so a pending message and its confirmed copy are the
    /// same row and confirming it reconfigures the cell in place; the team's
    /// messages by server ID (`m:<id>`).
    case message(String)
    case typing
}

/// One message row, confirmed or not.
struct MessageRow: Equatable {
    enum Status: Equatable {
        case none, sending, sent, seen, failed
    }

    var key: String
    /// The server's ID; nil until the message is confirmed. Only confirmed
    /// messages take reactions and replies.
    var messageId: String? = nil
    var sequence: Int? = nil
    var isOutgoing: Bool
    var text: String
    var images: [ImageRef]
    var createdAt: Date
    var status: Status
    /// Rounds the bubble's corner on the side of the next message from the same sender.
    var groupedWithNext: Bool
    var reactions: [Reaction] = []
    /// The message this one quotes.
    var replyTo: ReplyPreview? = nil
    /// Buttons under an action message's prompt.
    var action: ActionCard? = nil
    /// The AI agent's name, on its messages; nil for people.
    var aiName: String? = nil
    /// "Penny · AI" above the first message of a run from the AI.
    var senderLabel: String? = nil
}

/// An image in a bubble: a sent attachment or the local bytes of an unsent one.
enum ImageRef: Hashable {
    case attachment(Attachment)
    case local(key: String, width: Int, height: Int)

    var cacheKey: String {
        switch self {
        case .attachment(let a): "a:\(a.id)"
        case .local(let key, _, _): "l:\(key)"
        }
    }

    var pixelSize: CGSize {
        switch self {
        case .attachment(let a): CGSize(width: a.width, height: a.height)
        case .local(_, let w, let h): CGSize(width: w, height: h)
        }
    }
}

/// The thread's rows, built from the store's state.
struct ThreadModel {
    var items: [ThreadItemID] = []
    var rows: [ThreadItemID: MessageRow] = [:]
    var separators: [String: Separator] = [:]
    /// Rows by the server's message ID, for jumping to a quoted message.
    var itemsByMessageId: [String: ThreadItemID] = [:]

    struct Separator: Equatable {
        /// "Today", "Yesterday", "Monday" or a date, shown in bold.
        var day: String
        var time: String
    }

    /// A gap this long between messages starts a new separator.
    static let separatorGap: TimeInterval = 3600

    /// An empty thread.
    init() {}

    /// Builds rows from state. `calendar` and `strings` decide separators;
    /// `unreadAfter` places the "NEW" divider above the first team message
    /// with a higher sequence. Cards on `hiddenActions` (message IDs) show
    /// as plain messages.
    init(
        state: ConversationStore.State, calendar: Calendar, strings: ChatStrings, now: Date,
        unreadAfter: Int? = nil, showsReadReceipts: Bool = true, showsTypingIndicator: Bool = true,
        hiddenActions: Set<String> = []
    ) {
        if state.hasOlderMessages { items.append(.loadingOlder) }
        let agentRead = state.conversation?.agentRead ?? 0
        // Only the newest outgoing message shows Sent / Seen.
        let lastOutgoingSequence = state.messages.last(where: { $0.senderType.isEndUser })?.sequence
        // A pending message whose confirmed copy already arrived is that row.
        let confirmedClientIds = Set(state.messages.lazy.filter(\.senderType.isEndUser).map(\.clientId))
        let pendingMessages = state.pending.filter { !confirmedClientIds.contains($0.clientId) }
        var entries: [(id: ThreadItemID, row: MessageRow)] = []
        for message in state.messages {
            var status = MessageRow.Status.none
            if message.senderType.isEndUser, message.sequence == lastOutgoingSequence, pendingMessages.isEmpty {
                status = showsReadReceipts && message.sequence <= agentRead ? .seen : .sent
            }
            let key = message.senderType.isEndUser ? "c:\(message.clientId)" : "m:\(message.id)"
            entries.append((
                .message(key),
                MessageRow(
                    key: key, messageId: message.id, sequence: message.sequence,
                    isOutgoing: message.senderType.isEndUser, text: message.text,
                    images: message.attachments.map(ImageRef.attachment), createdAt: message.createdAt,
                    status: status, groupedWithNext: false, reactions: message.reactions, replyTo: message.replyTo,
                    action: message.senderType.isEndUser || hiddenActions.contains(message.id)
                        ? nil : message.action.flatMap { ActionCard($0, strings: strings) },
                    aiName: message.senderType == .aiAgent ? (message.senderName ?? "") : nil)
            ))
        }
        // Unsent messages go where they were written, so one that failed
        // before newer replies arrived stays above them. Each is placed after
        // every confirmed message up to its time, which keeps their own order.
        var confirmed = entries[...]
        entries = []
        for pending in pendingMessages {
            while let next = confirmed.first, next.row.createdAt <= pending.createdAt {
                entries.append(next)
                confirmed = confirmed.dropFirst()
            }
            let key = "c:\(pending.clientId)"
            entries.append((
                .message(key),
                MessageRow(
                    key: key, isOutgoing: true, text: pending.text,
                    images: pending.images.map { image in
                        image.attachment.map(ImageRef.attachment)
                            ?? .local(key: image.idempotencyKey, width: image.width, height: image.height)
                    },
                    createdAt: pending.createdAt,
                    status: pending.state == .failed ? .failed : .sending, groupedWithNext: false,
                    replyTo: pending.replyTo)
            ))
        }
        entries.append(contentsOf: confirmed)
        let formatters = SeparatorFormatters(calendar: calendar, locale: strings.locale)
        // Diffable data sources trap on duplicate IDs; keep the first of any repeat.
        var seen = Set<ThreadItemID>()
        entries = entries.filter { seen.insert($0.id).inserted }
        let firstUnreadKey = unreadAfter.flatMap { boundary in
            state.messages.first { !$0.senderType.isEndUser && $0.sequence > boundary }.map { "m:\($0.id)" }
        }
        var previousDate: Date?
        var previousGrouped = false
        for (index, entry) in entries.enumerated() {
            let date = entry.row.createdAt
            if let previousDate, calendar.isDate(previousDate, inSameDayAs: date),
               date.timeIntervalSince(previousDate) < Self.separatorGap
            {
                // Same stretch of conversation: no separator.
            } else {
                items.append(.separator(entry.row.key))
                separators[entry.row.key] = Self.separator(date, calendar: calendar, now: now, strings: strings, formatters: formatters)
            }
            previousDate = date
            if entry.row.key == firstUnreadKey { items.append(.unreadDivider) }
            var row = entry.row
            // The AI's name goes above the first message of each run of its messages.
            if let name = row.aiName, !previousGrouped {
                row.senderLabel = String(format: strings("sender.ai"), name.isEmpty ? strings("a11y.from_team") : name)
            }
            if index + 1 < entries.count {
                let next = entries[index + 1].row
                // A switch between the AI and a person starts a new group.
                row.groupedWithNext = next.isOutgoing == row.isOutgoing
                    && (next.aiName == nil) == (row.aiName == nil)
                    && calendar.isDate(next.createdAt, inSameDayAs: date)
                    && next.createdAt.timeIntervalSince(date) < 120
                    && next.key != firstUnreadKey
            } else {
                row.groupedWithNext = false
            }
            previousGrouped = row.groupedWithNext
            items.append(entry.id)
            rows[entry.id] = row
            if let messageId = row.messageId { itemsByMessageId[messageId] = entry.id }
        }
        if state.teamIsTyping, showsTypingIndicator { items.append(.typing) }
    }

    static func separator(
        _ date: Date, calendar: Calendar, now: Date, strings: ChatStrings, formatters: SeparatorFormatters
    ) -> Separator {
        let time = formatters.time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return Separator(day: strings("day.today"), time: time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return Separator(day: strings("day.yesterday"), time: time)
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return Separator(day: formatters.weekday.string(from: date), time: time)
        }
        return Separator(day: formatters.date.string(from: date), time: time)
    }
}

/// Date formatters for separators, made once per model build.
struct SeparatorFormatters {
    let time: DateFormatter
    let weekday: DateFormatter
    let date: DateFormatter

    init(calendar: Calendar, locale: Locale) {
        func make(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        time = make("jmm")
        weekday = make("EEEE")
        date = make("EEEMMMd")
    }
}
#endif
