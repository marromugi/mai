import SwiftUI
import Testing
import UIKit

@testable import Features

struct ColorThemeTests {
  /// The theme is remembered under this key and as these values; changing either forgets it.
  @Test func isRememberedByName() {
    #expect(ColorTheme.key == "colorTheme")
    #expect(ColorTheme.allCases.map(\.rawValue) == ["system", "light", "dark"])
  }

  /// The app's root is shown in the remembered theme; with `system`, nothing remembered, or any
  /// other value, it follows the device (unspecified).
  @MainActor
  @Test(
    arguments: [
      ("dark", UIUserInterfaceStyle.dark), ("light", .light), ("system", .unspecified),
      (nil, .unspecified), ("", .unspecified), ("Dark", .unspecified), ("sepia", .unspecified),
    ] as [(String?, UIUserInterfaceStyle)])
  func rootShowsTheRememberedTheme(_ remembered: String?, _ style: UIUserInterfaceStyle) throws {
    let suite = "ColorThemeTests.\(remembered ?? "nothing")"
    let store = try #require(UserDefaults(suiteName: suite))
    store.removePersistentDomain(forName: suite)
    if let remembered {
      store.set(remembered, forKey: ColorTheme.key)
    }
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "ColorThemeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let page = HostedPage(
      RootView(store: FileWritingStore(directory: directory)).defaultAppStorage(store))
    let root = try #require(page.child(UIHostingController<AnyView>.self))
    #expect(root.overrideUserInterfaceStyle == style)
  }
}
