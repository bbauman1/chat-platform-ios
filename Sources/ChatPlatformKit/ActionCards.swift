#if canImport(UIKit)
import ChatPlatformCore
import StoreKit
import UIKit

/// The buttons an action message shows under its prompt. Types
/// this SDK doesn't know have no card and show as an ordinary message.
struct ActionCard: Hashable {
    enum Kind: Hashable {
        case rateApp(appStoreId: String?)
        case refund(productId: String?, transactionId: UInt64?)
        case manageSubscription(groupId: String?)
    }

    enum Button: Hashable {
        /// Apple's rating prompt (`AppStore.requestReview`).
        case rate
        /// The App Store's write-a-review page, when the app has an App Store ID.
        case writeReview
        case refund
        case manageSubscription

        var titleKey: String {
            switch self {
            case .rate: "card.rate"
            case .writeReview: "card.write_review"
            case .refund: "card.refund"
            case .manageSubscription: "card.manage_subscription"
            }
        }
    }

    var kind: Kind
    var buttons: [Button]
    /// The buttons' titles in the chat's language.
    var titles: [String]

    init?(_ action: MessageAction, strings: ChatStrings) {
        let params = action.params
        switch action.type {
        case "rate_app":
            let id = params["appStoreId"].flatMap { $0.allSatisfy(\.isNumber) && !$0.isEmpty ? $0 : nil }
            kind = .rateApp(appStoreId: id)
            buttons = id == nil ? [.rate] : [.rate, .writeReview]
        case "refund":
            kind = .refund(productId: params["productId"], transactionId: params["transactionId"].flatMap(UInt64.init))
            buttons = [.refund]
        case "manage_subscription":
            kind = .manageSubscription(groupId: params["subscriptionGroupId"])
            buttons = [.manageSubscription]
        default:
            return nil
        }
        titles = buttons.map { strings($0.titleKey) }
    }

    /// `https://apps.apple.com/app/id<ID>?action=write-review`.
    static func writeReviewURL(appStoreId: String) -> URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreId)?action=write-review")
    }
}

/// What tapping a card's button does, behind a protocol so tests can stand in
/// for StoreKit and the App Store.
@MainActor
protocol StoreActions {
    func requestReview(in scene: UIWindowScene)
    func open(_ url: URL) async -> Bool
    /// Opens Apple's refund sheet for the transaction, or the newest one for
    /// the product, or the newest purchase. Calls `opened` once the sheet is
    /// requested.
    func refund(
        productId: String?, transactionId: UInt64?, in scene: UIWindowScene, opened: () -> Void
    ) async -> RefundOutcome
    /// Whether a refund card has a purchase to refund.
    func canRefund(productId: String?, transactionId: UInt64?) async -> Bool
    /// Whether there's an auto-renewable subscription to manage.
    func hasSubscription(groupId: String?) async -> Bool
    /// Opens subscription management and compares renewal before and after.
    func manageSubscriptions(groupId: String?, in scene: UIWindowScene, opened: () -> Void) async
        -> SubscriptionOutcome
}

enum RefundOutcome: String, Equatable {
    case submitted, cancelled, failed
    /// Nothing to refund: no purchase found.
    case noPurchase
}

enum SubscriptionOutcome: String, Equatable {
    case cancelledRenewal = "cancelled_renewal"
    case changedPlan = "changed_plan"
    case noChange = "no_change"
    case failed
    /// No active auto-renewable subscription to manage.
    case noSubscription
}

/// A subscription's renewal as StoreKit reports it, per subscription group.
struct RenewalState: Equatable {
    var productId: String
    var willAutoRenew: Bool
    /// The product it renews into, when the user picked another plan.
    var renewsTo: String?

    /// What changed while the management sheet was open. A group whose
    /// subscription is gone counts as cancelled.
    static func outcome(before: [String: RenewalState], after: [String: RenewalState]) -> SubscriptionOutcome {
        var changed = false
        for (group, old) in before {
            guard let new = after[group] else { return .cancelledRenewal }
            if old.willAutoRenew, !new.willAutoRenew { return .cancelledRenewal }
            if new.productId != old.productId || (new.renewsTo ?? new.productId) != (old.renewsTo ?? old.productId) {
                changed = true
            }
        }
        if after.keys.contains(where: { before[$0] == nil }) { changed = true }
        return changed ? .changedPlan : .noChange
    }
}

/// StoreKit 2 and the App Store.
struct StoreKitActions: StoreActions {
    func requestReview(in scene: UIWindowScene) {
        AppStore.requestReview(in: scene)
    }

    func open(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }

    func canRefund(productId: String?, transactionId: UInt64?) async -> Bool {
        await Self.refundableTransaction(productId: productId, transactionId: transactionId) != nil
    }

    func hasSubscription(groupId: String?) async -> Bool {
        let states = await Self.renewalStates(groupId: groupId)
        return !states.isEmpty
    }

    func refund(
        productId: String?, transactionId: UInt64?, in scene: UIWindowScene, opened: () -> Void
    ) async -> RefundOutcome {
        guard let transaction = await Self.refundableTransaction(productId: productId, transactionId: transactionId)
        else { return .noPurchase }
        opened()
        do {
            switch try await transaction.beginRefundRequest(in: scene) {
            case .success: return .submitted
            case .userCancelled: return .cancelled
            @unknown default: return .failed
            }
        } catch {
            return .failed
        }
    }

    func manageSubscriptions(groupId: String?, in scene: UIWindowScene, opened: () -> Void) async
        -> SubscriptionOutcome
    {
        let before = await Self.renewalStates(groupId: groupId)
        guard !before.isEmpty else { return .noSubscription }
        opened()
        do {
            if let groupId {
                try await AppStore.showManageSubscriptions(in: scene, subscriptionGroupID: groupId)
            } else {
                try await AppStore.showManageSubscriptions(in: scene)
            }
        } catch {
            return .failed
        }
        return RenewalState.outcome(before: before, after: await Self.renewalStates(groupId: groupId))
    }

    /// The transaction a refund card is about: the one named, else the
    /// newest unrevoked purchase of the product, else the newest of all.
    static func refundableTransaction(productId: String?, transactionId: UInt64?) async -> Transaction? {
        var newest: Transaction?
        for await result in Transaction.all {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if let transactionId {
                if transaction.id == transactionId { return transaction }
                continue
            }
            if let productId, transaction.productID != productId { continue }
            if newest.map({ transaction.purchaseDate > $0.purchaseDate }) ?? true { newest = transaction }
        }
        return newest
    }

    /// Current auto-renewable subscriptions by group, with their renewal.
    static func renewalStates(groupId: String?) async -> [String: RenewalState] {
        var states: [String: RenewalState] = [:]
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productType == .autoRenewable,
                  let group = transaction.subscriptionGroupID, groupId == nil || group == groupId
            else { continue }
            var state = RenewalState(productId: transaction.productID, willAutoRenew: false)
            if let status = await transaction.subscriptionStatus, case .verified(let renewal) = status.renewalInfo {
                state.willAutoRenew = renewal.willAutoRenew
                state.renewsTo = renewal.autoRenewPreference
            }
            states[group] = state
        }
        return states
    }
}
#endif
