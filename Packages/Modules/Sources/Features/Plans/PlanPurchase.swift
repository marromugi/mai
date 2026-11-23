import Foundation
import StoreKit

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
    case .unverified(let error):
      "App Store の購入を確かめられませんでした。\(error.localizedDescription)"
    case .failed(let error):
      "購入できませんでした。\(error.localizedDescription)"
    }
  }
}

/// Buys `product` through `purchase` for the account kept in `kept`, or for a new one when none
/// is. The ID is kept only when the purchase goes through or waits for approval.
func buyPlan(
  _ product: Product,
  keptIn kept: KeptAccountID,
  purchase: (Product, Set<Product.PurchaseOption>) async throws -> Product.PurchaseResult
) async throws(PlanPurchaseError) -> PlanPurchaseOutcome {
  let id = kept.id ?? UUID()
  let result: Product.PurchaseResult
  do {
    result = try await purchase(product, [.appAccountToken(id)])
  } catch StoreKitError.userCancelled {
    return .cancelled
  } catch {
    throw .failed(error)
  }
  switch result {
  case .success(.verified(let transaction)):
    kept.keep(id)
    await transaction.finish()
    return .bought(id)
  case .success(.unverified(_, let error)):
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
