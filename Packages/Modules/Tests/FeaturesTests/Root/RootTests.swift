import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

struct RootTests {
  /// 「書きかけ」, never adjusted, set in the default remembered as base 20, line height 36,
  /// tracking 50.
  @Test func aWritingNeverAdjustedIsSetInTheRememberedDefault() throws {
    let row = try #require(
      WritingRow.samples(now: .now, calendar: .current).first { $0.title == "書きかけ" })
    assertRoot(remembering: "20 36 50", path: [row])
  }

  /// 「書きかけ」 in the standard setting, with nothing remembered.
  @Test func aWritingNeverAdjustedIsSetInTheStandardSettingWithNothingRemembered() throws {
    let row = try #require(
      WritingRow.samples(now: .now, calendar: .current).first { $0.title == "書きかけ" })
    assertRoot(remembering: nil, path: [row])
  }
}

/// The app's screen in a 402 × 874 window, reading from a store holding only `remembered` under
/// the default body setting's key.
private func assertRoot(
  remembering remembered: String?,
  path: [WritingRow],
  testName: String = #function
) {
  let suite = "RootTests.\(testName)"
  guard let store = UserDefaults(suiteName: suite) else {
    preconditionFailure("The defaults suite \(suite) can't be opened.")
  }
  store.removePersistentDomain(forName: suite)
  if let remembered {
    store.set(remembered, forKey: StoredBodySetting.key)
  }
  let page = HostedPage(
    RootView(path: path).defaultAppStorage(store))
  assertSnapshot(
    of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
