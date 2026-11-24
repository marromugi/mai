import Features
import Foundation
import SwiftUI

@main
struct MaiApp: App {
  @State private var services: Services

  init() {
    let services = Services(
      address: ServerAddress(
        info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment))
    _services = State(initialValue: services)
    // From launch, as StoreKit asks, so no transaction is missed.
    Task { await PlanTransactions.listen { await services.account?.check() } }
  }

  var body: some Scene {
    WindowGroup {
      if let fonts = services.fonts, let account = services.account {
        RootView(fonts: fonts, account: account)
      } else {
        // Only a Beta build waits here, while StoreKit says where it was installed from.
        Color(.systemBackground).ignoresSafeArea()
      }
    }
  }
}

/// The fonts and the account, made once the server is known: at once for a build that names one
/// server, after StoreKit's answer for a Beta build.
@MainActor @Observable
final class Services {
  private(set) var fonts: FontLibrary?
  private(set) var account: AccountModel?

  init(address: ServerAddress) {
    if address.appStoreServer == nil {
      make(server: address.server)
    } else {
      Task {
        let installed = await ServerAddress.installedFromAppStore()
        make(server: address.resolved(installedFromAppStore: installed))
      }
    }
  }

  private func make(server: URL) {
    let fonts = FontLibrary(server: server)
    fonts.load()
    self.fonts = fonts
    account = Self.account(server: server)
  }

  /// Signs in with Apple, or, in a debug build given `MAI_STAND_IN_APPLE_USER`, as that user of
  /// the stand-in Apple the Worker at `server` serves (`Server/test/stand-in-apple.ts`), which
  /// says the user stopped signing in with Apple when `MAI_STAND_IN_APPLE_REVOKED` is 1.
  private static func account(server: URL) -> AccountModel {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if let user = environment["MAI_STAND_IN_APPLE_USER"] {
        return AccountModel.standIn(
          server: server, user: user, revoked: environment["MAI_STAND_IN_APPLE_REVOKED"] == "1")
      }
    #endif
    return AccountModel.onDevice(server: server)
  }
}
