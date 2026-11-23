import SnapshotTesting
import SwiftUI
import Sync
import Testing

@testable import Features

struct SyncSettingsTests {
  /// Offers to type the recovery key or make a key, and says to wait when another device syncs.
  @Test func withNoOwnKeyThePageOffersToRestoreOrMakeOne() throws {
    assertPage(SyncSettingsPage(ownKey: nil, serverURL: nil))
  }

  @Test func withAnOwnKeyThePageSyncsAndShowsWhatTheServerKeeps() throws {
    assertPage(SyncSettingsPage(ownKey: try fixedKey(), serverURL: "https://mai.example"))
  }

  @Test func withAnOwnKeyAtTheLargestSize() throws {
    assertPage(
      SyncSettingsPage(ownKey: try fixedKey(), serverURL: "https://mai.example"),
      size: .accessibility5)
  }

  @Test func aURLThatIsNotAServersIsNamedUnderIt() throws {
    assertPage(SyncSettingsPage(ownKey: try fixedKey(), serverURL: "mai.example"))
  }

  @Test func theRecoveryKeyIsSetTwoGroupsToALine() throws {
    let recoveryKey = RecoveryKey(try fixedKey())
    assertPage(NavigationStack { RecoveryKeyView(recoveryKey: recoveryKey) })
  }

  @Test func theRecoveryKeyInDarkMode() throws {
    let recoveryKey = RecoveryKey(try fixedKey())
    assertPage(NavigationStack { RecoveryKeyView(recoveryKey: recoveryKey) }, colorScheme: .dark)
  }

  @Test func theRecoveryKeyIsTypedOnAPageOfItsOwn() {
    assertPage(
      NavigationStack {
        RecoveryKeyEntryView(sync: .forTests(store: FileWritingStore(directory: nowhere)))
      })
  }
}

private let nowhere = URL(filePath: "/nonexistent")

private func fixedKey() throws -> OwnKey {
  try OwnKey(rawRepresentation: Data(0..<32))
}

/// The sync page in a navigation stack, with `ownKey` kept and `serverURL` set.
private struct SyncSettingsPage: View {
  let sync: WritingSync
  let defaults: UserDefaults

  init(ownKey: OwnKey?, serverURL: String?) {
    sync = .forTests(store: FileWritingStore(directory: nowhere), keys: MemoryOwnKeys(ownKey))
    let suite = "SyncSettingsTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
      preconditionFailure("The defaults suite \(suite) can't be opened.")
    }
    defaults.set(serverURL, forKey: WritingSync.serverURLKey)
    self.defaults = defaults
  }

  var body: some View {
    NavigationStack {
      SyncSettingsView(sync: sync, syncNow: {})
    }
    .defaultAppStorage(defaults)
  }
}

/// `page` in a 402 × 874 window.
private func assertPage(
  _ page: some View,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let hosted = HostedPage(
    page
      .dynamicTypeSize(size)
      .environment(\.colorScheme, colorScheme))
  assertSnapshot(
    of: hosted.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
