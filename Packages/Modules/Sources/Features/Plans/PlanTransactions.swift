import Foundation
import StoreKit

/// StoreKit's transactions that come outside a purchase on the plans screen: renewals, a purchase
/// approved through Ask to Buy, one made on another device. Listened to from launch, as StoreKit
/// asks, so none is missed.
public enum PlanTransactions {
  /// Finishes each verified transaction of a plan, keeps its account ID when the device keeps none,
  /// and calls `changed` so the account can send it to the server. Runs as long as the app does.
  public static func listen(changed: @escaping @MainActor () async -> Void) async {
    await listen(keptIn: .standard, changed: changed)
  }

  static func listen(keptIn kept: KeptAccountID, changed: @escaping @MainActor () async -> Void)
    async
  {
    let plans = Set(SyncPlan.allCases.map(\.productID))
    for await update in Transaction.updates {
      switch update {
      case .verified(let transaction) where plans.contains(transaction.productID):
        if kept.id == nil, let id = transaction.appAccountToken {
          kept.keep(id)
        }
        await transaction.finish()
        await changed()
      case .verified:
        break
      case .unverified(let transaction, let error):
        plansLogger.error(
          "A transaction of \(transaction.productID, privacy: .public) wasn't verified: \(error)")
      }
    }
  }
}
