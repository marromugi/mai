import SnapshotTesting
import SwiftUI
import Sync
import Testing

@testable import Features

/// The account's screens: the settings' 「同期」 section, the plans screen once Plus is bought, and
/// the recovery key shown and typed.
struct AccountScreenTests {
  /// After a purchase, before signing in: the Apple button under 「同期のプラン」.
  @Test func syncSectionOffersSignInOnceAPlanIsBought() {
    assertSyncSection(.signedOut, canSignIn: true)
  }

  /// With no plan bought, the section is as before: 「同期のプラン」 only.
  @Test func syncSectionWithNoPlanBought() {
    assertSyncSection(.signedOut, canSignIn: false)
  }

  @Test func syncSectionWhileSigningIn() {
    assertSyncSection(.working, canSignIn: true)
  }

  @Test func syncSectionSignedIn() {
    assertSyncSection(.signedIn, canSignIn: true)
  }

  /// Signed in, with the plan no longer current: 「サインアウト」 is still there.
  @Test func syncSectionSignedInWithNoPlanCurrent() {
    assertSyncSection(.signedIn, canSignIn: false)
  }

  /// Signed in, before the first sync: how it went, and 「今すぐ同期」.
  @Test func syncSectionSignedInBeforeTheFirstSync() {
    assertSyncSection(.signedIn, canSignIn: true, syncStatus: .notYet)
  }

  @Test func syncSectionWhileSyncing() {
    assertSyncSection(.signedIn, canSignIn: true, syncStatus: .syncing)
  }

  /// The plan's limit, said plainly under the row.
  @Test func syncSectionStoppedByThePlansLimit() {
    assertSyncSection(
      .signedIn, canSignIn: true,
      syncStatus: .stopped(ServerError.refused(status: 429, reason: "").localizedDescription))
  }

  @Test func syncSectionStoppedByALapsedPlanInDarkMode() {
    assertSyncSection(
      .signedIn, canSignIn: true,
      syncStatus: .stopped(ServerError.refused(status: 402, reason: "").localizedDescription),
      colorScheme: .dark)
  }

  @Test func syncSectionAsksForTheRecoveryKey() {
    assertSyncSection(.recoveryKeyNeeded, canSignIn: true)
  }

  @Test func syncSectionOffersSignInInDarkMode() {
    assertSyncSection(.signedOut, canSignIn: true, colorScheme: .dark)
  }

  @Test func syncSectionSignedInAtTheLargestSize() {
    assertSyncSection(.signedIn, canSignIn: true, size: .accessibility5)
  }

  @Test func plusBoughtOffersSignIn() {
    assertPushed(planBought(.signedOut), title: "同期のプラン")
  }

  @Test func plusBoughtOffersSignInInDarkMode() {
    assertPushed(planBought(.signedOut), title: "同期のプラン", colorScheme: .dark)
  }

  @Test func plusBoughtWhileSigningIn() {
    assertPushed(planBought(.working), title: "同期のプラン")
  }

  @Test func plusBoughtAndSignedIn() {
    assertPushed(planBought(.signedIn), title: "同期のプラン")
  }

  @Test func plusBoughtAsksForTheRecoveryKey() {
    assertPushed(planBought(.recoveryKeyNeeded), title: "同期のプラン")
  }

  @Test func theRecoveryKeyIsSetTwoGroupsToALine() throws {
    try assertPushed(RecoveryKeyView(recoveryKey: recoveryKey(), done: {}), title: nil)
  }

  @Test func theRecoveryKeyInDarkMode() throws {
    try assertPushed(
      RecoveryKeyView(recoveryKey: recoveryKey(), done: {}), title: nil, colorScheme: .dark)
  }

  @Test func theRecoveryKeyAtTheLargestSize() throws {
    try assertPushed(
      RecoveryKeyView(recoveryKey: recoveryKey(), done: {}), title: nil, size: .accessibility5)
  }

  @Test func theRecoveryKeyIsTypedOnAPageOfItsOwn() {
    assertPushed(RecoveryKeyEntryView(restore: { _ in nil }), title: nil)
  }

  private func planBought(_ phase: AccountPhase) -> PlanBought {
    PlanBought(offer: PlanOffer(plan: .plus, price: "¥700"), phase: phase)
  }

  private func recoveryKey() throws -> RecoveryKey {
    RecoveryKey(try OwnKey(rawRepresentation: Data(0..<32)))
  }
}

/// The settings' 「同期」 section and the account's after it, as `SettingsForm` sets them, with the
/// account at `phase`.
private func assertSyncSection(
  _ phase: AccountPhase,
  canSignIn: Bool,
  syncStatus: WritingSync.Status? = nil,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  assertPushed(
    Form {
      Section {
        NavigationLink("同期のプラン") {}
      } header: {
        Text("同期")
      } footer: {
        Text("文書はこの端末の中に置かれます。ほかの端末とそろえるには、プランに入ります。")
      }
      AccountRows(
        phase: phase, canSignIn: canSignIn, signIn: {}, signOut: {}, restore: { _ in nil },
        syncStatus: syncStatus)
    },
    title: "設定", colorScheme: colorScheme, size: size, testName: testName)
}

/// `content` on a navigation stack titled `title` (or by `content` itself when nil), in a
/// 402 × 874 window.
private func assertPushed(
  _ content: some View,
  title: String?,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let page = HostedPage(
    NavigationStack {
      if let title {
        content
          .navigationTitle(title)
          .navigationBarTitleDisplayMode(.inline)
      } else {
        content
      }
    }
    .dynamicTypeSize(size)
    .environment(\.colorScheme, colorScheme))
  assertSnapshot(
    of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
