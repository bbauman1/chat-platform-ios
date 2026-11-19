import Foundation
#if canImport(Network)
import Network

#endif

/// The socket closed. `code` is the WebSocket close code (1006 when the
/// connection dropped without one).
public struct WebSocketClosed: Error, Sendable, Equatable {
    public var code: Int
    public init(code: Int) { self.code = code }
}

/// One open WebSocket carrying text frames. Swapped for a stub in tests.
public protocol WebSocketConnection: Sendable {
    func send(_ text: String) async throws
    /// The next text frame. Throws `WebSocketClosed` once the socket closes.
    func receive() async throws -> String
    func close(code: Int)
}

public protocol WebSocketTransport: Sendable {
    func connect(to url: URL) async throws -> any WebSocketConnection
}

#if canImport(Network)
/// WebSockets on Network.framework, which (unlike `URLSessionWebSocketTask`)
/// reports application close codes such as 4000 and 4401.
/// Pings are answered automatically.
public struct NetworkWebSocketTransport: WebSocketTransport {
    public init() {}

    public func connect(to url: URL) async throws -> any WebSocketConnection {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 1 << 20
        let parameters: NWParameters = url.scheme == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        let connection = NWConnection(to: .url(url), using: parameters)
        let socket = NetworkWebSocket(connection: connection)
        try await socket.start()
        return socket
    }
}

final class NetworkWebSocket: WebSocketConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.chatplatform.websocket")

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    if once.claim() {
                        continuation.resume(throwing: ChatError.network(String(describing: error)))
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: WebSocketClosed(code: 1006)) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ text: String) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8), contentContext: context, isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: ChatError.network(String(describing: error)))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    func receive() async throws -> String {
        while true {
            let (data, metadata) = try await receiveMessage()
            switch metadata?.opcode {
            case .text?:
                return String(decoding: data ?? Data(), as: UTF8.self)
            case .close?:
                connection.cancel()
                throw WebSocketClosed(code: Self.code(metadata?.closeCode))
            default:
                continue  // pings, pongs and binary frames
            }
        }
    }

    private func receiveMessage() async throws -> (Data?, NWProtocolWebSocket.Metadata?) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if let metadata, error == nil || metadata.opcode == .close {
                    continuation.resume(returning: (data, metadata))
                } else {
                    // The connection failed or ended without a close frame.
                    continuation.resume(throwing: WebSocketClosed(code: 1006))
                }
            }
        }
    }

    func close(code: Int) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code >= 4000 && code <= 4999
            ? .privateCode(UInt16(code)) : .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(
            content: nil, contentContext: context, isComplete: true,
            completion: .contentProcessed { [connection] _ in connection.cancel() })
    }

    private static func code(_ closeCode: NWProtocolWebSocket.CloseCode?) -> Int {
        switch closeCode {
        case .protocolCode(let code)?: return Int(code.rawValue)
        case .applicationCode(let code)?: return Int(code)
        case .privateCode(let code)?: return Int(code)
        case nil: return 1005
        @unknown default: return 1006
        }
    }
}

/// Lets exactly one caller through, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
#endif
