import Features
import SwiftUI

@main
struct MaiApp: App {
  init() {
    BundledFonts.register()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
