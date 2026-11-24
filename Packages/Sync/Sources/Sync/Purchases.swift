import Foundation

/// A subscription as StoreKit 2 signs it: the transaction and the renewal info, each a
/// `jwsRepresentation`.
public struct SignedSubscription: Sendable {
  public let transaction: String
  public let renewalInfo: String

  public init(transaction: String, renewalInfo: String) {
    self.transaction = transaction
    self.renewalInfo = renewalInfo
  }
}

/// The plans this App Store account pays for. StoreKit 2 on a device; a stand-in where the App
/// Store's signature can't be had.
public protocol Purchases: Sendable {
  /// The current subscriptions to a plan bought for `account`.
  func subscriptions(for account: UUID) async throws -> [SignedSubscription]
}
