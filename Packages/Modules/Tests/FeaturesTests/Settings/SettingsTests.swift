import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

struct SettingsTests {
  /// With nothing remembered, the standard setting, and 「標準に戻す」 dimmed.
  @Test func settingsShowTheStandardSetting() {
    assertSettings(remembering: nil)
  }

  @Test func settingsShowTheRememberedSetting() {
    assertSettings(remembering: "20 36 50")
  }

  @Test func settingsInDarkMode() {
    assertSettings(remembering: nil, colorScheme: .dark)
  }

  @Test func settingsAtTheLargestSize() {
    assertSettings(remembering: nil, size: .accessibility5)
  }
}

/// The settings sheet's content in a 402 × 874 window, reading from a store holding only
/// `remembered` under the default setting's key.
private func assertSettings(
  remembering remembered: String?,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let suite = "SettingsTests.\(testName)"
  guard let store = UserDefaults(suiteName: suite) else {
    preconditionFailure("The defaults suite \(suite) can't be opened.")
  }
  store.removePersistentDomain(forName: suite)
  if let remembered {
    store.set(remembered, forKey: StoredBodySetting.key)
  }
  let page = HostedPage(
    SettingsView()
      .defaultAppStorage(store)
      .dynamicTypeSize(size)
      .environment(\.colorScheme, colorScheme))
  assertSnapshot(
    of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
