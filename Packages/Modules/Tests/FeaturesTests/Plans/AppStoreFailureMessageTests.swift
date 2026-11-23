import Foundation
import StoreKit
import Testing

@testable import Features

struct AppStoreFailureMessageTests {
  @Test func aNetworkFailureSaysToCheckTheNetwork() {
    #expect(
      appStoreFailureMessage(StoreKitError.networkError(URLError(.notConnectedToInternet)))
        == "App Store につながりませんでした。ネットワークを確かめて、もう一度お試しください。")
  }

  @Test func aPurchaseNotAllowedPointsToScreenTime() {
    #expect(
      appStoreFailureMessage(Product.PurchaseError.purchaseNotAllowed)
        == "この端末では購入が許されていません。スクリーンタイムの設定を確かめてください。")
  }

  @Test(arguments: [
    Product.PurchaseError.productUnavailable as any Error,
    StoreKitError.notAvailableInStorefront,
  ])
  func aPlanThatCantBeBoughtSaysSo(error: any Error) {
    #expect(appStoreFailureMessage(error) == "このプランは今は買えません。")
  }

  @Test func anythingElseSaysToTryLater() {
    #expect(
      appStoreFailureMessage(StoreKitError.unknown)
        == "App Store で問題が起きました。しばらくしてから、もう一度お試しください。")
  }
}
