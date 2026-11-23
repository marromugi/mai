import XCTest

/// Two installs of the app syncing through a local Worker, run step by step by
/// `scripts/sync-app-test.sh`, which gives `MAI_SYNC_CHECK_DIR` (where the steps leave what the
/// next one reads) and `MAI_SERVER_URL`. Skipped without them.
nonisolated final class SyncAppTests: XCTestCase {
  /// The writing the script saves on the first install, before it syncs.
  static let writingTitle = "同期で届く文書"

  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["MAI_SYNC_CHECK_DIR"] != nil,
      "Run by scripts/sync-app-test.sh")
    continueAfterFailure = false
  }

  /// The first install, with no server yet: makes the own key, and leaves its recovery key and
  /// the value the server keeps for the script.
  @MainActor func testMakesTheOwnKeyAndShowsItsRecoveryKey() throws {
    let app = SyncedApp(serverURL: "")
    app.openSyncPage()
    app.ui.buttons["新しい鍵を作る"].tap()
    app.ui.buttons["作る"].firstMatch.tap()
    let recoveryKey = app.ui.staticTexts["recoveryKey"]
    XCTAssert(recoveryKey.waitForExistence(timeout: 5))
    try write(recoveryKey.label, to: "recovery-key.txt")
    app.ui.navigationBars.buttons.firstMatch.tap()
    let digest = app.ui.staticTexts["accessTokenSHA256"]
    XCTAssert(digest.waitForExistence(timeout: 5))
    try write(digest.label, to: "access-token-sha256.txt")
  }

  /// The first install, with the server set: the writing the script saved is sent when the app
  /// comes to the front.
  @MainActor func testSendsTheWritingSavedOnThisInstall() throws {
    let app = SyncedApp(serverURL: try serverURL)
    XCTAssert(app.row(titled: Self.writingTitle).waitForExistence(timeout: 10))
    app.openSyncPage()
    app.waitForASync()
  }

  /// A second install with no own key: the recovery key typed back restores it, and the writing
  /// the first install sent arrives, with the samples kept once each.
  @MainActor func testRestoresTheOwnKeyAndReceivesTheWriting() throws {
    let app = SyncedApp(serverURL: try serverURL)
    XCTAssertFalse(app.row(titled: Self.writingTitle).exists)
    app.openSyncPage()
    app.ui.buttons["リカバリーキーを入力"].tap()
    let written = try String(
      contentsOf: try directory.appending(path: "recovery-key.txt"), encoding: .utf8)
    let field =
      app.ui.textViews.firstMatch.exists
      ? app.ui.textViews.firstMatch : app.ui.textFields.firstMatch
    field.tap()
    // As a person might type it: lower case, with spaces between the groups.
    field.typeText(written.replacing("\n", with: " ").replacing("-", with: " ").lowercased())
    app.ui.buttons["自分の鍵を戻す"].tap()

    app.ui.buttons["リカバリーキーを表示"].tap()
    XCTAssertEqual(app.ui.staticTexts["recoveryKey"].label, written)
    app.ui.navigationBars.buttons.firstMatch.tap()
    app.ui.buttons["今すぐ同期"].tap()
    app.waitForASync()

    app.ui.terminate()
    let relaunched = SyncedApp(serverURL: try serverURL)
    XCTAssert(relaunched.row(titled: Self.writingTitle).waitForExistence(timeout: 10))
    XCTAssertEqual(relaunched.rows(titled: "パンを焼く日").count, 1)
  }

  private var directory: URL {
    get throws {
      URL(
        filePath: try XCTUnwrap(ProcessInfo.processInfo.environment["MAI_SYNC_CHECK_DIR"]),
        directoryHint: .isDirectory)
    }
  }

  private var serverURL: String {
    get throws {
      try XCTUnwrap(ProcessInfo.processInfo.environment["MAI_SERVER_URL"])
    }
  }

  private func write(_ text: String, to name: String) throws {
    try Data(text.utf8).write(to: try directory.appending(path: name))
  }
}

/// The app launched with `serverURL` as its sync server.
@MainActor
private struct SyncedApp {
  let ui = XCUIApplication()

  init(serverURL: String) {
    ui.launchArguments = ["-syncServerURL", serverURL]
    ui.launch()
  }

  func openSyncPage() {
    let settings = ui.buttons["設定"]
    XCTAssert(settings.waitForExistence(timeout: 10))
    settings.tap()
    // The row reads 「同期」 and whether it is on.
    ui.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "同期")).firstMatch.tap()
  }

  /// Waits until the sync page shows a sync that ended, and checks it didn't fail.
  func waitForASync() {
    XCTAssert(ui.staticTexts["まだ"].waitForNonExistence(timeout: 20))
    XCTAssert(ui.staticTexts["同期しています…"].waitForNonExistence(timeout: 20))
    XCTAssertFalse(ui.staticTexts["できませんでした"].exists, ui.debugDescription)
  }

  func rows(titled title: String) -> XCUIElementQuery {
    ui.buttons.matching(NSPredicate(format: "label CONTAINS %@", title))
  }

  func row(titled title: String) -> XCUIElement {
    rows(titled: title).firstMatch
  }
}
