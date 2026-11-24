import Foundation
import Testing

@testable import Mai

struct ServerAddressTests {
  private let staging = URL(string: "https://mai-server-staging.example.dev")!
  private let production = URL(string: "https://mai-server.example.dev")!

  /// A Release or Debug build: MAI_APP_STORE_SERVER is unset, so Info.plist holds an empty string.
  @Test func aBuildNamingOneServerTalksToItWhereverItCameFrom() {
    let address = ServerAddress(
      info: ["MaiServer": production.absoluteString, "MaiAppStoreServer": ""], environment: [:])
    #expect(address.appStoreServer == nil)
    for installed in [true, false, nil] {
      #expect(address.resolved(installedFromAppStore: installed) == production)
    }
  }

  @Test func aBetaBuildTheAppStoreInstalledTalksToProduction() {
    let address = beta()
    #expect(address.resolved(installedFromAppStore: true) == production)
  }

  @Test(arguments: [false, nil] as [Bool?])
  func aBetaBuildFromAnywhereElseTalksToStaging(installed: Bool?) {
    #expect(beta().resolved(installedFromAppStore: installed) == staging)
  }

  @Test func mAIServerURLStandsInForTheBuildsServerInADebugBuild() {
    let address = ServerAddress(
      info: ["MaiServer": staging.absoluteString],
      environment: ["MAI_SERVER_URL": "http://localhost:8787"])
    #expect(address.server == URL(string: "http://localhost:8787"))
  }

  private func beta() -> ServerAddress {
    ServerAddress(
      info: [
        "MaiServer": staging.absoluteString, "MaiAppStoreServer": production.absoluteString,
      ],
      environment: [:])
  }
}
