import Features
import Foundation
import SwiftUI

@main
struct MaiApp: App {
  @State private var fonts = FontLibrary(server: Self.server)

  var body: some Scene {
    WindowGroup {
      RootView(fonts: fonts)
    }
  }

  /// The Worker in `Server/`. Not deployed yet, so only a debug build has one: the one `wrangler dev`
  /// serves, or the one `MAI_SERVER_URL` names.
  private static var server: URL? {
    #if DEBUG
      URL(string: ProcessInfo.processInfo.environment["MAI_SERVER_URL"] ?? "http://localhost:8787")
    #else
      nil
    #endif
  }
}
