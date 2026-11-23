import Foundation
import StoreKit
import StoreKitTest
import Testing

@testable import Features

/// Buys the plans of `StoreKit/Mai.storekit` through StoreKit's local testing. Hosted in the app,
/// since StoreKit refuses a test bundle with no app around it. The suites share one StoreKit, so
/// they run one at a time.
@Suite(.serialized)
struct PlanPurchaseTests {
  private let session: SKTestSession
  private let kept: KeptAccountID

  init() async throws {
    guard let url = Bundle(for: Anchor.self).url(forResource: "Mai", withExtension: "storekit")
    else {
      preconditionFailure("MaiTests carries StoreKit/Mai.storekit as a resource")
    }
    session = try SKTestSession(contentsOf: url)
    session.resetToDefaultState()
    session.disableDialogs = true
    session.clearTransactions()
    let suite = "PlanPurchaseTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      preconditionFailure("The defaults suite \(suite) can't be opened.")
    }
    kept = KeptAccountID(defaults: defaults)
  }

  @Test func eachPlanIsOnTheAppStore() async throws {
    let products = try await Product.products(for: SyncPlan.allCases.map(\.productID))
    let offers = PlanOffer.all(in: products)
    #expect(offers.map(\.plan) == SyncPlan.allCases)
    #expect(offers.map(\.price) == ["¥150", "¥700", "¥1,600"])
  }

  @Test func aPurchaseCarriesTheNewAccountIDAndKeepsIt() async throws {
    let outcome = try await buyPlan(product(.plus), keptIn: kept, purchase: Self.purchase)
    let id = try #require(kept.id)
    #expect(outcome == .bought(id))
    let bought = try await latestTransaction(.plus)
    #expect(bought.appAccountToken == id)
    #expect(kept.defaults.string(forKey: "syncAccountID") == id.uuidString)
  }

  @Test func aPurchaseCarriesTheKeptAccountID() async throws {
    let id = UUID()
    kept.keep(id)
    let outcome = try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    #expect(outcome == .bought(id))
    #expect(try await latestTransaction(.basic).appAccountToken == id)
    #expect(kept.id == id)
  }

  /// As after the app is installed again: nothing kept, but the App Store account subscribes.
  @Test func aPurchaseWithNothingKeptCarriesTheSubscribedAccountID() async throws {
    let bought = try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    let suite = "PlanPurchaseTests.\(UUID().uuidString)"
    let reinstalled = KeptAccountID(defaults: try #require(UserDefaults(suiteName: suite)))
    let upgraded = try await buyPlan(product(.plus), keptIn: reinstalled, purchase: Self.purchase)
    #expect(upgraded == bought)
    #expect(reinstalled.id == kept.id)
    #expect(try await latestTransaction(.plus).appAccountToken == kept.id)
  }

  /// The account this device keeps wins over the one a plan already subscribed to was bought for.
  @Test func aPurchaseCarriesTheKeptAccountIDOverTheSubscribedOne() async throws {
    _ = try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    let id = UUID()
    kept.keep(id)
    #expect(try await buyPlan(product(.plus), keptIn: kept, purchase: Self.purchase) == .bought(id))
    #expect(try await latestTransaction(.plus).appAccountToken == id)
  }

  /// A cancel thrown rather than returned.
  @Test func aPurchaseCancelledByThrowingKeepsNothing() async throws {
    let outcome = try await buyPlan(product(.basic), keptIn: kept) { _, _ in
      throw StoreKitError.userCancelled
    }
    #expect(outcome == .cancelled)
    #expect(kept.id == nil)
  }

  @Test func aCancelledPurchaseKeepsNothing() async throws {
    try await session.setSimulatedError(.generic(.userCancelled), forAPI: .purchase)
    let outcome = try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    #expect(outcome == .cancelled)
    #expect(kept.id == nil)
    #expect(try await transactions().isEmpty)
  }

  @Test func aFailedPurchaseKeepsNothing() async throws {
    try await session.setSimulatedError(.purchase(.productUnavailable), forAPI: .purchase)
    await #expect {
      try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    } throws: { error in
      guard case PlanPurchaseError.failed = error else { return false }
      return true
    }
    #expect(kept.id == nil)
    #expect(try await transactions().isEmpty)
  }

  @Test func aFailedPurchaseLeavesTheKeptIDAsItWas() async throws {
    let id = UUID()
    kept.keep(id)
    try await session.setSimulatedError(.purchase(.productUnavailable), forAPI: .purchase)
    await #expect(throws: PlanPurchaseError.self) {
      try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    }
    #expect(kept.id == id)
  }

  @Test func aPurchaseWhoseSignatureFailsKeepsNothing() async throws {
    try await session.setSimulatedError(.verification(.invalidSignature), forAPI: .verification)
    await #expect {
      try await buyPlan(product(.basic), keptIn: kept, purchase: Self.purchase)
    } throws: { error in
      guard case PlanPurchaseError.unverified = error else { return false }
      return true
    }
    #expect(kept.id == nil)
  }

  @Test func aPurchaseWaitingForApprovalKeepsTheIDItCarries() async throws {
    session.askToBuyEnabled = true
    let outcome = try await buyPlan(product(.pro), keptIn: kept, purchase: Self.purchase)
    #expect(outcome == .waiting)
    let id = try #require(kept.id)
    let waiting = try #require(session.allTransactions().first)
    // The approved transaction reaches the app as an update, some time after the approval.
    let approved = Task { () -> Transaction? in
      for await result in Transaction.updates {
        if case .verified(let transaction) = result, transaction.productID == SyncPlan.pro.productID
        {
          return transaction
        }
      }
      return nil
    }
    try session.approveAskToBuyTransaction(identifier: waiting.identifier)
    #expect(try #require(await approved.value).appAccountToken == id)
  }

  private static func purchase(
    _ product: Product, _ options: Set<Product.PurchaseOption>
  ) async throws -> Product.PurchaseResult {
    try await product.purchase(options: options)
  }

  private func product(_ plan: SyncPlan) async throws -> Product {
    try #require(try await Product.products(for: [plan.productID]).first)
  }

  private func latestTransaction(_ plan: SyncPlan) async throws -> Transaction {
    let result = try #require(await Transaction.latest(for: plan.productID))
    return try result.payloadValue
  }

  private func transactions() async throws -> [Transaction] {
    var all: [Transaction] = []
    for await result in Transaction.all {
      all.append(try result.payloadValue)
    }
    return all
  }
}

private final class Anchor {}
