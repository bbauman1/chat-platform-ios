#if canImport(UIKit)
import ChatPlatformCore
import Foundation

/// What the chat UI needs from a conversation. `ConversationStore` is the
/// real one; tests substitute a fake with fixed state.
@MainActor
protocol ThreadSource: AnyObject {
    var state: ConversationStore.State { get }
    func observe(_ handler: @escaping @MainActor (ConversationStore.State) -> Void) -> ObservationToken
    func start()
    func stop()
    func reconnectNow()
    @discardableResult func send(text: String, images: [ImageUpload], replyTo: Message?) -> OutgoingMessage?
    func retry(_ clientId: String)
    func discard(_ clientId: String)
    func loadOlder() async throws
    func markRead()
    func setTyping(_ typing: Bool)
    func imageURL(for attachment: Attachment) async throws -> URL
    func localImageData(_ key: String) -> Data?
    func setReaction(_ emoji: String?, on messageId: String) async throws
    func setFirstVisibleSequence(_ sequence: Int?)
    @discardableResult func loadUntilMessage(id: String) async throws -> Bool
}

extension ConversationStore: ThreadSource {
    func localImageData(_ key: String) -> Data? {
        localImageData(OutgoingImage(idempotencyKey: key, width: 0, height: 0))
    }
}
#endif
