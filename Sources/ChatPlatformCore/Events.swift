import Foundation

/// A property or attribute value: a string, a number or a boolean.
public enum EventValue: Sendable, Equatable, Codable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// An event waiting to be sent. Each keeps the id it was given, so a batch
/// retried after a lost response is stored once.
struct QueuedEvent: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var properties: [String: EventValue?]
    var occurredAt: Date
    /// Who it belongs to; nil for an event tracked before `identify`, which
    /// goes to the first user identified.
    var userId: String?
}

/// Where unsent events wait across launches.
protocol EventStore: Sendable {
    func load() -> [QueuedEvent]
    func save(_ events: [QueuedEvent])
}

final class InMemoryEventStore: EventStore, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [QueuedEvent] = []
    func load() -> [QueuedEvent] { lock.withLock { events } }
    func save(_ events: [QueuedEvent]) { lock.withLock { self.events = events } }
}

/// A JSON file under Application Support, excluded from backup. One file per
/// app key, so a client configured for another app (or a changed key) never
/// sends this app's events through its session.
final class FileEventStore: EventStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(appKey: String, directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatPlatform", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let safe = String(appKey.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }.map(Character.init))
        url = base.appendingPathComponent("events-\(safe).json")
    }

    func load() -> [QueuedEvent] {
        lock.withLock {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? JSONDecoder.chat.decode([QueuedEvent].self, from: data)) ?? []
        }
    }

    func save(_ events: [QueuedEvent]) {
        lock.withLock {
            if events.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else if let data = try? JSONEncoder.chat.encode(events) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

/// The API's limits, checked before queueing so one bad event
/// can't get a whole batch refused.
enum EventRules {
    static let maxQueued = 1000
    static let batchSize = 100
    /// Under the API's 48 KB JSON body limit, with room for the envelope.
    static let maxBatchBytes = 40 * 1024
    static let flushDelay: TimeInterval = 1

    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first,
              CharacterSet.letters.contains(first), first.isASCII
        else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-")
        return name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Properties: ≤ 50 keys of 1–64 characters, strings ≤ 1,024
    /// characters, finite numbers, ≤ 4 KB as JSON. Attributes follow the same
    /// value rules. Lengths are UTF-16 code units, as the API counts them; no
    /// NUL characters (Postgres can't store them) and no `__proto__` key.
    static func isValid(_ values: [String: EventValue?]) -> Bool {
        guard values.count <= 50 else { return false }
        for (key, value) in values {
            guard (1...64).contains(key.utf16.count), key != "__proto__", storable(key) else {
                return false
            }
            switch value {
            case .string(let s)?: if s.utf16.count > 1024 || !storable(s) { return false }
            case .number(let n)?: if !n.isFinite { return false }
            default: break
            }
        }
        let size = (try? JSONEncoder.chat.encode(values).count) ?? .max
        return size <= 4096
    }

    /// Swift strings are always valid Unicode, so only NUL needs refusing.
    private static func storable(_ s: String) -> Bool {
        !s.unicodeScalars.contains("\u{0}")
    }
}

/// An event as `POST /v1/sdk/events` takes it.
struct OutgoingEvent: Encodable, Sendable {
    var id: String
    var name: String
    var properties: [String: EventValue?]?
    var occurredAt: Date

    init(_ event: QueuedEvent) {
        id = event.id
        name = event.name
        properties = event.properties.isEmpty ? nil : event.properties
        occurredAt = event.occurredAt
    }
}

struct IngestResult: Decodable, Sendable {
    var accepted: Int
    var duplicates: Int
}

extension ChatClient {
    /// Records an event for the current user, for campaigns, the dashboard
    /// and analytics. Events queue on the device (surviving relaunches) and
    /// go out in batches about a second later; events tracked before
    /// `identify` belong to the first user identified. An invalid name or
    /// properties drops the event: names match
    /// `^[A-Za-z][A-Za-z0-9_.:-]*$` (at most 64 characters), with at most 50
    /// string, number or boolean properties in 4 KB.
    ///
    /// ```swift
    /// chat.track("paywall_viewed", properties: ["placement": "onboarding", "price": 9.99])
    /// ```
    public func track(_ name: String, properties: [String: EventValue?] = [:]) {
        guard EventRules.isValidName(name), EventRules.isValid(properties) else {
            debugPrint("ChatPlatform: dropped invalid event \(name)")
            return
        }
        var queue = eventStore.load()
        queue.append(QueuedEvent(
            id: UUID().uuidString.lowercased(), name: name, properties: properties, occurredAt: clock.now(),
            userId: userId))
        if queue.count > EventRules.maxQueued { queue.removeFirst(queue.count - EventRules.maxQueued) }
        eventStore.save(queue)
        scheduleEventFlush()
    }

    /// Merges attributes into the current user's SDK attributes; `nil`
    /// removes a key. These are set from the device, so use them for
    /// targeting and display only.
    @discardableResult
    public func setAttributes(_ attributes: [String: EventValue?]) async throws -> [String: EventValue] {
        guard userId != nil else { throw ChatError.notIdentified }
        guard EventRules.isValid(attributes) else { throw ChatError.api(status: 413, code: "too_large", retryAfter: nil) }
        struct Body: Encodable, Sendable { var attributes: [String: EventValue?] }
        struct Result: Decodable, Sendable { var sdkAttributes: [String: EventValue] }
        let body = try JSONEncoder.chat.encode(Body(attributes: attributes))
        let response = try await api.send("PATCH", "/v1/sdk/me/attributes", body: body)
        guard let result = try? JSONDecoder.chat.decode(Result.self, from: response.body) else {
            throw ChatError.invalidResponse
        }
        return result.sdkAttributes
    }

    func scheduleEventFlush() {
        guard eventFlushTask == nil, userId != nil else { return }
        eventFlushTask = Task { [weak self] in
            try? await self?.clock.sleep(seconds: EventRules.flushDelay)
            await self?.flushEvents(retrying: true)
            self?.eventFlushTask = nil
        }
    }

    /// Sends the current user's queued events. Network and server errors
    /// retry with backoff when `retrying`; a refused batch is dropped.
    func flushEvents(retrying: Bool) async {
        var backoff = Backoff()
        while let userId, !Task.isCancelled {
            var queue = eventStore.load()
            // Events from before `identify` belong to this user.
            if queue.contains(where: { $0.userId == nil }) {
                for index in queue.indices where queue[index].userId == nil { queue[index].userId = userId }
                eventStore.save(queue)
            }
            let batch = Self.nextBatch(queue.filter { $0.userId == userId })
            guard !batch.isEmpty else { return }
            do {
                try await sendEvents(batch)
                backoff.reset()
            } catch let error as ChatError where error.isRetryable {
                guard retrying else { return }
                try? await clock.sleep(seconds: backoff.next())
                continue
            } catch let error as ChatError where error.code == "invalid_request" || error.code == "too_large" {
                debugPrint("ChatPlatform: the API refused an event batch; dropping it")
            } catch {
                return  // signed out or identity changed: kept for later or dropped on switch
            }
            let sent = Set(batch.map(\.id))
            eventStore.save(eventStore.load().filter { !sent.contains($0.id) })
        }
    }

    /// Up to `batchSize` events whose request stays under `maxBatchBytes`
    /// (always at least one: a valid event is far smaller than the limit).
    nonisolated static func nextBatch(_ events: [QueuedEvent]) -> [QueuedEvent] {
        var batch: [QueuedEvent] = []
        var bytes = 16  // {"events":[...]}
        for event in events.prefix(EventRules.batchSize) {
            let size = ((try? JSONEncoder.chat.encode(OutgoingEvent(event)))?.count ?? EventRules.maxBatchBytes) + 1
            if !batch.isEmpty, bytes + size > EventRules.maxBatchBytes { break }
            batch.append(event)
            bytes += size
        }
        return batch
    }

    private func sendEvents(_ batch: [QueuedEvent]) async throws {
        struct Body: Encodable, Sendable { var events: [OutgoingEvent] }
        _ = try await api.post(IngestResult.self, "/v1/sdk/events", json: Body(events: batch.map(OutgoingEvent.init)))
    }

    /// On a user switch: one last try for the previous user's events, then
    /// drop what's left, since no later session can send them.
    func finishEvents(for previous: String) async {
        eventFlushTask?.cancel()
        eventFlushTask = nil
        await flushEvents(retrying: false)
        eventStore.save(eventStore.load().filter { $0.userId != previous })
    }
}
