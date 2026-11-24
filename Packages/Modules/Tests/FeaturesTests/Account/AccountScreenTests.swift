import SnapshotTesting
import SwiftUI
import Sync
import Testing

@testable import Features

/// The account's screens: the settings' 「同期」 section, the plans screen once Plus is bought, and
/// the recovery key shown and typed, and the page that deletes the account.
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
      syncStatus: .stopped(ServerError.limitReached(.saves).localizedDescription))
  }

  @Test func syncSectionStoppedByThePlansStorage() {
    assertSyncSection(
      .signedIn, canSignIn: true,
      syncStatus: .stopped(ServerError.limitReached(.storage).localizedDescription))
  }

  /// Paid for, with some of the plan used.
  @Test func planPaidFor() {
    assertPlan(.paid(until: date("2026-12-24")))
  }

  @Test func planPaidForAtTheLargestSize() {
    assertPlan(.paid(until: date("2026-12-24")), size: .accessibility5)
  }

  /// The App Store retrying the payment: when it lapses, and where the payment is checked.
  @Test func planInItsGracePeriod() {
    assertPlan(.gracePeriod(until: date("2026-11-30")))
  }

  /// Lapsed: what stopped, how many days are left before the server's writings go, and how to
  /// keep them.
  @Test func planLapsed() {
    assertPlan(.lapsed(since: date("2026-11-01"), deletesAt: date("2027-01-30")))
  }

  @Test func planLapsedInDarkMode() {
    assertPlan(
      .lapsed(since: date("2026-11-01"), deletesAt: date("2027-01-30")), colorScheme: .dark)
  }

  /// A day left: still counted in days, not 「まもなく」.
  @Test func planLapsedADayBeforeItsDeletion() {
    assertPlan(.lapsed(since: date("2026-08-27"), deletesAt: date("2026-11-25")))
  }

  /// Signed in, with the account read: the plan's sections follow the account's.
  @Test func syncSectionSignedInWithTheAccountRead() {
    assertSyncSection(
      .signedIn, canSignIn: true, state: sampleState(.paid(until: date("2026-12-24"))))
  }

  /// Signed out, with no plan's sections even when an account was read.
  @Test func syncSectionSignedOutShowsNoPlan() {
    assertSyncSection(
      .signedOut, canSignIn: true, state: sampleState(.paid(until: date("2026-12-24"))))
  }

  /// Past when it is deleted, before the cron trigger has deleted it.
  @Test func planLapsedPastItsDeletion() {
    assertPlan(.lapsed(since: date("2026-08-01"), deletesAt: date("2026-10-30")))
  }

  /// Today's saves used up: the row says so, in red.
  @Test func planWithTodaysSavesUsedUp() {
    assertPlan(.paid(until: date("2026-12-24")), saves: 500)
  }

  @Test(arguments: [
    ("2026-11-24T12:00:00Z", "2027-01-30T12:00:00Z", 67),
    ("2026-11-24T12:00:00Z", "2026-11-24T12:00:01Z", 1),
    ("2026-11-24T12:00:00Z", "2026-11-24T12:00:00Z", 0),
    ("2026-11-24T12:00:00Z", "2026-11-20T12:00:00Z", 0),
  ])
  func daysLeftCountAPartOfADayAsOne(now: String, deletesAt: String, days: Int) throws {
    let read = Date.ISO8601FormatStyle()
    #expect(
      PlanStateSections.daysLeft(from: try read.parse(now), to: try read.parse(deletesAt)) == days)
  }

  @Test func syncSectionStoppedByALapsedPlanInDarkMode() {
    assertSyncSection(
      .signedIn, canSignIn: true,
      syncStatus: .stopped(ServerError.refused(status: 402, reason: "").localizedDescription),
      colorScheme: .dark)
  }

  /// The server ended the session: signed out, with why under the Apple button.
  @Test func syncSectionAfterTheServerEndedTheSession() {
    assertSyncSection(
      .signedOut, canSignIn: true,
      syncStatus: .sessionEnded(ServerError.refused(status: 401, reason: "").localizedDescription))
  }

  /// While the own key isn't here, nothing syncs and no sync row shows.
  @Test func syncSectionAsksForTheRecoveryKey() {
    assertSyncSection(.recoveryKeyNeeded, canSignIn: true, syncStatus: .notYet)
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

  /// What goes from the server and what stays, the subscription that goes on, and the button.
  @Test func theAccountIsDeletedOnAPageOfItsOwn() {
    assertPushed(AccountDeletionView(deleteAccount: {}), title: nil)
  }

  @Test func theAccountDeletionPageInDarkMode() {
    assertPushed(AccountDeletionView(deleteAccount: {}), title: nil, colorScheme: .dark)
  }

  @Test func theAccountDeletionPageAtTheLargestSize() {
    assertPushed(AccountDeletionView(deleteAccount: {}), title: nil, size: .accessibility5)
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
  state: AccountState? = nil,
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
        Text(SettingsForm.syncFooter(phase))
      }
      AccountRows(
        phase: phase, canSignIn: canSignIn, state: state, signIn: {}, signOut: {},
        restore: { _ in nil }, syncStatus: syncStatus)
    },
    title: "設定", colorScheme: colorScheme, size: size, testName: testName)
}

/// Noon in Tokyo on `day`, written `2026-12-24`.
private func date(_ day: String) -> Date {
  guard let date = try? Date.ISO8601FormatStyle().parse("\(day)T03:00:00Z") else {
    preconditionFailure("\(day) is a day written as yyyy-MM-dd")
  }
  return date
}

/// A Basic account at `standing`, with some of the plan used and `saves` saved today.
private func sampleState(_ standing: AccountState.Standing, saves: Int64 = 12) -> AccountState {
  AccountState(
    plan: "basic", standing: standing,
    usage: PlanUsage(
      writingsBytes: .init(used: 1_234_567, limit: 100_000_000),
      writings: .init(used: 42, limit: 10_000),
      photosBytes: .init(used: 0, limit: 5_000_000_000),
      requests: .init(used: 87, limit: 3_000),
      lists: .init(used: 9, limit: 200),
      saves: .init(used: saves, limit: 500),
      photos: .init(used: 0, limit: 100)))
}

/// The plan's sections of a Basic account at `standing`, read at noon on 2026-11-24 in Tokyo,
/// with `saves` saved today.
private func assertPlan(
  _ standing: AccountState.Standing,
  saves: Int64 = 12,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  assertPushed(
    Form { PlanStateSections(state: sampleState(standing, saves: saves), now: date("2026-11-24")) }
      .environment(\.locale, Locale(identifier: "ja_JP"))
      .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo") ?? .gmt),
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
