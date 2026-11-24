import Features
import Foundation
import SwiftUI

@main
struct MaiApp: App {
  @State private var fonts: FontLibrary

  init() {
    let fonts = FontLibrary(server: Self.server)
    fonts.load()
    _fonts = State(initialValue: fonts)
  }

  var body: some Scene {
    WindowGroup {
      RootView(fonts: fonts)
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
}
