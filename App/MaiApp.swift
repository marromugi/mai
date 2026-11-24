import Features
import Foundation
import SwiftUI

@main
struct MaiApp: App {
  @State private var services: AppServices

  init() {
    let services = AppServices(
      address: ServerAddress(
        info: Bundle.main.infoDictionary ?? [:], environment: ProcessInfo.processInfo.environment))
    services.start()
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
