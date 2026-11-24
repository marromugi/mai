import Features
import Foundation
import SwiftUI

@main
struct MaiApp: App {
  @State private var fonts: FontLibrary
  @State private var account: AccountModel?

  init() {
    let fonts = FontLibrary(server: Self.server)
    fonts.load()
    _fonts = State(initialValue: fonts)
    let account = Self.server.map(Self.account(server:))
    _account = State(initialValue: account)
    // From launch, as StoreKit asks, so no transaction is missed.
    Task { await PlanTransactions.listen { await account?.check() } }
  }

  var body: some Scene {
    WindowGroup {
      RootView(fonts: fonts, account: account)
    }
  }

  /// The Worker in `Server/`. Not deployed yet, so only a debug build has one: the one `wrangler dev`
  /// serves, or the one `MAI_SERVER_URL` names.
  private static var server: URL? {
    #if DEBUG
      let address = ProcessInfo.processInfo.environment["MAI_SERVER_URL"] ?? "http://localhost:8787"
      guard let url = URL(string: address) else {
        preconditionFailure("MAI_SERVER_URL, \(address), isn't a URL.")
      }
      return url
    #else
      return nil
    #endif
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
