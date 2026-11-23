import Foundation
import StoreKit
import os

/// Where the plans screen and its purchases log what went wrong.
let plansLogger = Logger(subsystem: "com.marromugi.mai", category: "plans")

/// The account ID the app makes for whoever buys a plan, kept once a purchase goes through or
/// waits for approval. The purchase carries it as `appAccountToken`, and the server makes the
/// account under it.
struct KeptAccountID {
  static let key = "syncAccountID"

  let defaults: UserDefaults

  static let standard = KeptAccountID(defaults: .standard)

  /// Nil until a purchase has kept one.
  var id: UUID? {
    defaults.string(forKey: Self.key).flatMap(UUID.init(uuidString:))
  }

  func keep(_ id: UUID) {
    defaults.set(id.uuidString, forKey: Self.key)
  }
}

/// How a purchase that didn't fail ended.
enum PlanPurchaseOutcome: Equatable {
  /// Paid for, by the account with this ID.
  case bought(UUID)
  /// Waiting for someone to approve it, such as a parent through Ask to Buy.
  case waiting
  case cancelled
}

enum PlanPurchaseError: LocalizedError {
  /// App Store's signature on the transaction didn't check out, so it isn't taken as paid.
  case unverified(VerificationResult<Transaction>.VerificationError)
  case failed(any Error)

  var errorDescription: String? {
    switch self {
    case .unverified:
      "App Store の購入を確かめられませんでした。しばらくしてから、もう一度お試しください。"
    case .failed(let error):
      appStoreFailureMessage(error)
    }
  }
}

/// What a person is told when the App Store couldn't do what was asked, by the kind of failure.
nonisolated func appStoreFailureMessage(_ error: any Error) -> String {
  switch error {
  case StoreKitError.networkError:
    "App Store につながりませんでした。ネットワークを確かめて、もう一度お試しください。"
  case Product.PurchaseError.purchaseNotAllowed:
    "この端末では購入が許されていません。スクリーンタイムの設定を確かめてください。"
  case Product.PurchaseError.productUnavailable, StoreKitError.notAvailableInStorefront:
    "このプランは今は買えません。"
  default:
    "App Store で問題が起きました。しばらくしてから、もう一度お試しください。"
  }
}

/// Buys `product` through `purchase` for the account kept in `kept`, or, when none is kept, the
/// account a plan already subscribed to was bought for, or a new one. The ID is kept only when the
/// purchase goes through or waits for approval.
func buyPlan(
  _ product: Product,
  keptIn kept: KeptAccountID,
  purchase: (Product, Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult
) async throws(PlanPurchaseError) -> PlanPurchaseOutcome {
  let id: UUID
  if let keptID = kept.id {
    id = keptID
  } else if let subscribed = await subscribedAccountID() {
    id = subscribed
  } else {
    id = UUID()
  }
  let result: Product.PurchaseResult
  do {
    result = try await purchase(product, [.appAccountToken(id)])
  } catch StoreKitError.userCancelled {
    return .cancelled
  } catch {
    plansLogger.error("The purchase of \(product.id, privacy: .public) failed: \(error)")
    throw .failed(error)
  }
  switch result {
  case .success(.verified(let transaction)):
    kept.keep(id)
    await transaction.finish()
    return .bought(id)
  case .success(.unverified(_, let error)):
    plansLogger.error("The purchase of \(product.id, privacy: .public) wasn't verified: \(error)")
    throw .unverified(error)
  case .pending:
    kept.keep(id)
    return .waiting
  case .userCancelled:
    return .cancelled
  @unknown default:
    throw .failed(StoreKitError.unknown)
  }
}

/// The account a plan this App Store account subscribes to now was bought for.
private func subscribedAccountID() async -> UUID? {
  let plans = Set(SyncPlan.allCases.map(\.productID))
  for await result in Transaction.currentEntitlements {
    if case .verified(let transaction) = result, plans.contains(transaction.productID),
      let id = transaction.appAccountToken
    {
      return id
    }
  }
  return nil
}
