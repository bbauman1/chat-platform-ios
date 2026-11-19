import Foundation

/// A Superwall paywall event worth showing to support. Superwall's webhooks
/// carry only store events, so paywall opens, closes and declines come from
/// the app.
public enum SuperwallPaywallEvent: String, Sendable, CaseIterable {
    case open = "paywall_open"
    case close = "paywall_close"
    case decline = "paywall_decline"

    /// The event name `track` sends: `superwall.paywall_open` and so on.
    public var eventName: String { "superwall.\(rawValue)" }
}

extension ChatClient {
    /// Forwards a Superwall paywall event, so the conversation sidebar can
    /// show which paywalls the user saw and declined. The SDK doesn't depend
    /// on Superwall: call this from your `SuperwallDelegate`.
    ///
    /// ```swift
    /// func handleSuperwallEvent(withInfo eventInfo: SuperwallEventInfo) {
    ///     switch eventInfo.event {
    ///     case .paywallOpen(let info):
    ///         chat.trackSuperwall(.open, paywall: info.identifier, placement: info.presentedByPlacementWithName)
    ///     case .paywallClose(let info):
    ///         chat.trackSuperwall(.close, paywall: info.identifier, placement: info.presentedByPlacementWithName)
    ///     case .paywallDecline(let info):
    ///         chat.trackSuperwall(.decline, paywall: info.identifier, placement: info.presentedByPlacementWithName)
    ///     default:
    ///         break
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - event: what happened to the paywall.
    ///   - paywall: the paywall's identifier in Superwall.
    ///   - placement: the placement that presented it, when known.
    public func trackSuperwall(_ event: SuperwallPaywallEvent, paywall: String, placement: String?) {
        var properties: [String: EventValue?] = ["paywall": .string(paywall)]
        if let placement, !placement.isEmpty { properties["placement"] = .string(placement) }
        track(event.eventName, properties: properties)
    }
}
