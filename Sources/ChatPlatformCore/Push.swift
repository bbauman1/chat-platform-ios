import Foundation

/// Which APNs environment issued a device token: `sandbox` for development
/// builds, `production` for TestFlight and the App Store. `ChatPlatformKit`'s
/// `PushEnvironment.current` reads it from the app's provisioning profile.
public enum PushEnvironment: String, Sendable, Codable {
    case sandbox, production
}

/// A push sent by the chat service: a new message from the team.
public struct ChatNotification: Sendable, Equatable {
    public let messageId: String

    /// Nil for any notification the chat service didn't send, so the host can
    /// pass every notification here and handle the rest itself.
    public init?(userInfo: [AnyHashable: Any]) {
        guard let payload = userInfo["chatPlatform"] as? [AnyHashable: Any],
              let messageId = payload["messageId"] as? String, !messageId.isEmpty
        else { return nil }
        self.messageId = messageId
    }
}

struct DeviceRegistration: Equatable, Sendable {
    var token: String
    var environment: PushEnvironment
    var badges: Bool
}

struct RegisteredDevice: Decodable, Sendable {
    var id: String
}

extension ChatClient {
    /// Registers this device for chat pushes. Call it from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` on
    /// every launch, as Apple recommends. The token is remembered: identifying
    /// another user registers it for them, and signing out unregisters it on
    /// the server.
    ///
    /// - Parameters:
    ///   - deviceToken: the token APNs gave the app.
    ///   - environment: `.sandbox` for development builds, `.production` otherwise.
    ///   - badges: whether pushes set the app icon badge.
    public func registerDeviceToken(
        _ deviceToken: Data, environment: PushEnvironment, badges: Bool = false
    ) async throws {
        let registration = DeviceRegistration(
            token: deviceToken.map { String(format: "%02x", $0) }.joined(), environment: environment,
            badges: badges)
        pushRegistration = registration
        guard userId != nil else { return }
        try await register(registration)
    }

    /// A new session for the same user has no device (devices belong to a
    /// session, and the old one may have been revoked): register again.
    func sessionStarted(_ number: Int) async {
        // The registration that started this session registers in it.
        if let registering { try? await registering.task.value }
        guard userId != nil, let pushRegistration, registeredSession != number else { return }
        try? await register(pushRegistration)
    }

    func register(_ registration: DeviceRegistration) async throws {
        if let registering, registering.registration == registration {
            return try await registering.task.value
        }
        let api = api
        let task = Task<Int, Error> {
            struct Body: Encodable, Sendable {
                var apnsToken: String
                var environment: PushEnvironment
                var badges: Bool
            }
            // One key per registration, reused by the 401 retry, so a retry
            // after a lost response replays instead of registering again.
            _ = try await api.post(
                RegisteredDevice.self, "/v1/sdk/devices",
                json: Body(
                    apnsToken: registration.token, environment: registration.environment,
                    badges: registration.badges),
                headers: ["Idempotency-Key": UUID().uuidString.lowercased()])
            return await api.sessionNumber
        }
        let untyped = Task<Void, Error> { _ = try await task.value }
        registering = (registration, untyped)
        defer { if registering?.task == untyped { registering = nil } }
        registeredSession = try await task.value
    }
}
