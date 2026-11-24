import Foundation
import StoreKit
internal import Sync

/// The plans this App Store account subscribes to, from StoreKit 2.
nonisolated struct StoreKitPurchases: Purchases {
  let productIDs: Set<String>

  func subscriptions(for account: UUID) async throws -> [SignedSubscription] {
    var found: [SignedSubscription] = []
    for await result in Transaction.currentEntitlements {
      guard case .verified(let transaction) = result, productIDs.contains(transaction.productID),
        transaction.appAccountToken == account,
        let status = await transaction.subscriptionStatus
      else { continue }
      found.append(
        SignedSubscription(
          transaction: result.jwsRepresentation,
          renewalInfo: status.renewalInfo.jwsRepresentation))
    }
    return found
  }
}
