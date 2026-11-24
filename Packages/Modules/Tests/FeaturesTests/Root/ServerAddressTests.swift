import Foundation
import Testing

@testable import Features

@MainActor
struct ServerAddressTests {
  private let staging = "https://mai-server-staging.example.dev"
  private let production = "https://mai-server.example.dev"

  /// A Release or Debug build: MAI_APP_STORE_SERVER is unset, so Info.plist holds an empty string.
  @Test func aBuildNamingOneServerTalksToItWhereverItCameFrom() throws {
    let address = ServerAddress(
      info: ["MaiServer": production, "MaiAppStoreServer": ""], environment: [:])
    #expect(address.appStoreServer == nil)
    for installed in [true, false, nil] {
      #expect(
        try address.resolved(installedFromAppStore: installed) == #require(URL(string: production)))
    }
  }

  @Test func aBuildNamingOneServerMakesItsServicesAtOnce() throws {
    let services = AppServices(
      address: ServerAddress(
        info: ["MaiServer": production, "MaiAppStoreServer": ""], environment: [:]))
    services.start()
    #expect(services.fonts != nil)
    #expect(services.account != nil)
  }

  @Test func aBetaBuildTheAppStoreInstalledTalksToProduction() throws {
    #expect(try beta().resolved(installedFromAppStore: true) == #require(URL(string: production)))
  }

  @Test(arguments: [false, nil] as [Bool?])
  func aBetaBuildFromAnywhereElseTalksToStaging(installed: Bool?) throws {
    #expect(try beta().resolved(installedFromAppStore: installed) == #require(URL(string: staging)))
  }

  @Test func mAIServerURLStandsInForTheBuildsServerInADebugBuild() throws {
    let address = ServerAddress(
      info: ["MaiServer": staging], environment: ["MAI_SERVER_URL": "http://localhost:8787"])
    #expect(try address.server == #require(URL(string: "http://localhost:8787")))
  }

  private func beta() -> ServerAddress {
    ServerAddress(info: ["MaiServer": staging, "MaiAppStoreServer": production], environment: [:])
  }
}

struct InstalledFromAppStoreTests {
  @Test(arguments: [true, false, nil] as [Bool?])
  func storeKitsAnswerWithinTheLimitIsTheAnswer(answer: Bool?) async {
    #expect(await ServerAddress.installedFromAppStore(within: .seconds(10)) { answer } == answer)
  }

  /// A StoreKit that never answers and ignores cancellation: the time limit still answers.
  @Test(.timeLimit(.minutes(1)))
  func noAnswerWithinTheLimitIsNilWithoutWaitingForStoreKit() async {
    let started = ContinuousClock.now
    let installed = await ServerAddress.installedFromAppStore(within: .milliseconds(100)) {
      while true { try? await Task.sleep(for: .seconds(1)) }
    }
    #expect(installed == nil)
    #expect(ContinuousClock.now - started < .seconds(5))
  }
}
