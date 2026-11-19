import Foundation

/// What the realtime socket tells the store. Sockets only signal; the store
/// reloads over HTTP.
public enum RealtimeEvent: Sendable, Equatable {
    /// The socket is authenticated and listening. Reload now: anything that
    /// happened while disconnected was not delivered.
    case connected(revision: Int?)
    case conversationChanged(revision: Int, sequence: Int)
    /// The team is typing (`isTyping`), until `expiresAt` unless renewed.
    case teamTyping(isTyping: Bool, expiresAt: Date?)
    /// The server asks for a reload.
    case resync
    case disconnected
    /// The session can't be restored (identity rejected, or signed out).
    case signedOut
}

/// Keeps one realtime socket open while started: ticket, connect, auth frame,
/// `ready`; reconnects with jittered backoff (0.5 s → 30 s), refreshes the
/// session on 4000, signs in again on 4401 and stops on 4403.
actor RealtimeClient {
    private let api: APIClient
    private let transport: WebSocketTransport
    private let clock: ChatClock
    private let random: @Sendable () -> Double

    private var loop: Task<Void, Never>?
    /// Identifies the current loop, so a stopped loop that is still unwinding
    /// can't touch the state of a newer one.
    private var loopID = 0
    private var connection: (any WebSocketConnection)?
    private var isReady = false
    private var wakeUp: CheckedContinuation<Void, Never>?
    private var skipNextWait = false
    private var lastTypingSentAt: Date?
    private var typingActive = false
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    nonisolated let events: AsyncStream<RealtimeEvent>

    /// Senders send `typing: true` at most this often while typing.
    static let typingInterval: TimeInterval = 1.5

    init(
        api: APIClient, transport: WebSocketTransport, clock: ChatClock,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0.5...1) }
    ) {
        self.api = api
        self.transport = transport
        self.clock = clock
        self.random = random
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    var isConnected: Bool { isReady }

    func start() {
        guard loop == nil else { return }
        loopID += 1
        let id = loopID
        loop = Task { await self.run(id) }
    }

    func stop() {
        loopID += 1
        loop?.cancel()
        loop = nil
        connection?.close(code: 1000)
        connection = nil
        if isReady {
            isReady = false
            continuation.yield(.disconnected)
        }
        wake()
    }

    /// Skips the current backoff wait (the app came to the foreground, or
    /// the network came back).
    func reconnectNow() {
        if wakeUp != nil { wake() } else if !isReady { skipNextWait = true }
    }

    /// Typing in the end user's conversation, throttled to one `true` per
    /// 1.5 s; `false` always goes out if `true` went out.
    func setTyping(_ typing: Bool) async {
        guard isReady, let connection else { return }
        let now = clock.now()
        if typing {
            if let last = lastTypingSentAt, now.timeIntervalSince(last) < Self.typingInterval {
                return
            }
            lastTypingSentAt = now
            typingActive = true
        } else {
            guard typingActive else { return }
            typingActive = false
            lastTypingSentAt = nil
        }
        try? await connection.send(#"{"type":"typing","typing":\#(typing)}"#)
    }

    // MARK: Loop

    private func run(_ id: Int) async {
        var backoff = Backoff()
        while !Task.isCancelled {
            var wait = true
            do {
                try await connectOnce(id, &backoff)
            } catch let closed as WebSocketClosed {
                switch closed.code {
                case 4000:
                    // Access token behind the ticket expired: refresh, reconnect now.
                    await api.expireAccessToken()
                    wait = false
                case 4401:
                    // Session revoked or gone: sign in again with a new session.
                    await api.clearSession()
                case 4403:
                    finishLoop(id)
                    return
                default:
                    break
                }
            } catch ChatError.signedOut {
                if id == loopID { continuation.yield(.signedOut) }
                finishLoop(id)
                return
            } catch ChatError.notIdentified {
                finishLoop(id)
                return
            } catch {
                // Network failure, 503 on the ticket, cancellation: back off.
            }
            guard id == loopID, !Task.isCancelled else { return }
            disconnected()
            if wait && !skipNextWait {
                await sleep(backoff.next(random: random()))
            }
            skipNextWait = false
        }
    }

    private func connectOnce(_ id: Int, _ backoff: inout Backoff) async throws {
        let ticket = try await api.post(
            RealtimeTicket.self, "/v1/realtime/tickets", json: [String: String]())
        guard let url = URL(string: ticket.url) else { throw ChatError.invalidResponse }
        let socket = try await transport.connect(to: url)
        guard !Task.isCancelled, id == loopID else {
            socket.close(code: 1000)
            throw ChatError.cancelled
        }
        connection = socket
        let auth = try JSONEncoder.chat.encode(["type": "auth", "ticket": ticket.ticket])
        try await socket.send(String(decoding: auth, as: UTF8.self))
        while true {
            let text = try await socket.receive()
            guard id == loopID else { throw ChatError.cancelled }
            guard let frame = ServerFrame(text) else { continue }
            switch frame {
            case .ready(let revision):
                isReady = true
                backoff.reset()
                continuation.yield(.connected(revision: revision))
            case .event(let event):
                if isReady { continuation.yield(event) }
            }
        }
    }

    private func disconnected() {
        connection = nil
        typingActive = false
        lastTypingSentAt = nil
        if isReady {
            isReady = false
            continuation.yield(.disconnected)
        }
    }

    private func finishLoop(_ id: Int) {
        guard id == loopID else { return }
        disconnected()
        loop = nil
    }

    private func sleep(_ seconds: TimeInterval) async {
        let clock = self.clock
        let timer = Task {
            try? await clock.sleep(seconds: seconds)
            self.wake()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { wakeUp = continuation }
            }
        } onCancel: {
            Task { await self.wake() }
        }
        timer.cancel()
    }

    private func wake() {
        wakeUp?.resume()
        wakeUp = nil
    }
}

/// A frame from the server, decoded leniently: unknown types are ignored
/// (new event types are additive).
enum ServerFrame: Equatable {
    case ready(revision: Int?)
    case event(RealtimeEvent)

    init?(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let json = object as? [String: Any], let type = json["type"] as? String
        else { return nil }
        switch type {
        case "ready":
            self = .ready(revision: (json["revision"] as? NSNumber)?.intValue)
        case "conversation.changed":
            guard let revision = (json["revision"] as? NSNumber)?.intValue,
                  let sequence = (json["sequence"] as? NSNumber)?.intValue
            else { return nil }
            self = .event(.conversationChanged(revision: revision, sequence: sequence))
        case "typing.changed":
            // End users see only the team's typing; their own echoes are ignored.
            guard json["sender"] as? String == "member", let typing = json["typing"] as? Bool
            else { return nil }
            let expiresAt = (json["expiresAt"] as? String).flatMap(ISO8601.parse)
            self = .event(.teamTyping(isTyping: typing, expiresAt: expiresAt))
        case "resync":
            self = .event(.resync)
        default:
            return nil
        }
    }
}
