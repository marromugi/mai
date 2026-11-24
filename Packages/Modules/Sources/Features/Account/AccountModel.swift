import Foundation
import Observation
import StoreKit
internal import Sync
import os

/// Where the account screens log what went wrong.
let accountLogger = Logger(subsystem: "com.marromugi.mai", category: "account")

/// Where this device stands with the account a plan pays for.
enum AccountPhase: Equatable {
  case signedOut
  /// Signing in, settling the own key, or signing out.
  case working
  case signedIn
  /// Signed in, but the account's own key isn't on this device.
  case recoveryKeyNeeded
}

/// The account a plan pays for, as the screens show it: signing in, after a purchase or on a device
/// that didn't buy, the own key, starting over without it, the check at launch, and signing out. Made only where there is a server to sign in to.
@Observable public final class AccountModel {
  private let account: SyncAccount
  let kept: KeptAccountID
  /// Whether a start over was asked for whose recovery key hasn't been shown.
  private let startedOver: StartedOver
  private(set) var phase = AccountPhase.signedOut {
    didSet {
      if phase != .signedIn {
        ownKeySettled = false
      }
      if phase == .signedOut {
        state = nil
      }
    }
  }
  /// What the server last said of the account, read on settling the own key and by
  /// `readState()`; nil while signed out.
  private(set) var state: AccountState?
  /// The reads of the account started, and the one `state` is from, so an older read finishing
  /// later doesn't replace a newer one.
  @ObservationIgnored private var readsStarted = 0
  @ObservationIgnored private var stateRead = 0
  /// Whether the own key on the device was found to be the account's since the device last
  /// became signed in. A sync waits for it.
  private var ownKeySettled = false
  /// The recovery key of the own key just made, until the person says it is written down.
  private(set) var recoveryKeyToShow: RecoveryKey?
  /// What went wrong, written for a person, until it is dismissed.
  var problem: String?
  private var settling = false
  /// Whether the account is being deleted.
  private(set) var deleting = false
  /// Where each account's sync keeps what it last synced.
  @ObservationIgnored private let syncState: URL

  init(
    account: SyncAccount, kept: KeptAccountID = .standard,
    syncState: URL = .applicationSupportDirectory.appending(
      path: "Sync", directoryHint: .isDirectory)
  ) {
    self.account = account
    self.kept = kept
    startedOver = StartedOver(defaults: kept.defaults)
    self.syncState = syncState
  }

  /// Signs in to the Worker at `server` with Apple and the App Store, keeping the session and the
  /// own key in the keychain.
  public static func onDevice(server: URL) -> AccountModel {
    AccountModel(
      account: SyncAccount(
        server: AccountServer(url: server), apple: AppleIDSignIn(),
        purchases: StoreKitPurchases(productIDs: Set(SyncPlan.allCases.map(\.productID))),
        sessions: SessionKeychain.standard, ownKeys: OwnKeyKeychain.standard))
  }

  /// Signs in as the Apple user `user` of the stand-in Apple served by the Worker at `server`
  /// (`Server/test/stand-in-apple.ts`), keeping the session and the own key in the keychain. For
  /// local runs of a debug build, which can't reach Apple. `revoked` makes Apple say the user
  /// stopped signing in with Apple here.
  #if DEBUG
    public static func standIn(server: URL, user: String, revoked: Bool) -> AccountModel {
      var answers = StandInApple.Answers()
      answers.credentialState = revoked ? .revoked : .authorized
      let apple = StandInApple(url: server, user: user, answers: answers)
      return AccountModel(
        account: SyncAccount(
          server: AccountServer(url: server), apple: apple, purchases: apple,
          sessions: SessionKeychain.standard, ownKeys: OwnKeyKeychain.standard))
    }
  #endif

  /// Whether the plan bought for the account kept is paid for, so signing in makes or finds its
  /// account, as the 「同期」 section says; false while a purchase waits for approval, and with
  /// none kept. Read again by `check()` and `refresh()`.
  private(set) var canSignIn = false

  /// At launch: reads the session, then checks it with Apple and sends the subscriptions again.
  public func checkAtLaunch() async {
    do {
      phase = try account.session() == nil ? .signedOut : .signedIn
    } catch {
      accountLogger.error("The session couldn't be read: \(error)")
      return
    }
    await check()
  }

  /// Checks the session with Apple and sends the subscriptions again (`SyncAccount.check()`), as at
  /// launch and when StoreKit tells of a transaction. Left to the next time while signing in or
  /// out or deleting the account, which change the session themselves.
  public func check() async {
    guard phase != .working, !deleting else { return }
    do {
      let checked = try await account.check()
      switch checked {
      case .credentialRevoked, .sessionEnded, .signedOut:
        // Not when a sign-in started while the check ran.
        if phase != .working {
          phase = .signedOut
        }
      case .subscriptionsSent:
        break
      }
    } catch {
      accountLogger.error("The account couldn't be checked: \(error)")
    }
    await readWhetherBought()
  }

  /// Reads again whether the plan is paid for, then settles the own key, which reads the account,
  /// as when the account's settings are shown.
  func refresh() async {
    await readWhetherBought()
    await settleOwnKey()
  }

  /// Reads what the server says of the account now, while signed in, as after 「今すぐ同期」. The
  /// state read before stays when it can't be read, as when today's requests are used up.
  func readState() async {
    guard phase == .signedIn || phase == .recoveryKeyNeeded else { return }
    do {
      guard let session = try account.session() else { return }
      let read = try await self.read(session)
      _ = try stillIn(session, keeping: read)
    } catch {
      accountLogger.error("The account couldn't be read: \(error)")
    }
  }

  private func readWhetherBought() async {
    guard let id = kept.id else {
      canSignIn = false
      return
    }
    do {
      canSignIn = try await account.isBought(id)
    } catch {
      accountLogger.error("The purchases couldn't be read: \(error)")
    }
  }

  /// Signs in for the account kept, while a plan bought for it is on this App Store account;
  /// otherwise, as on a device that didn't buy the plan, to the account the Apple user has. Then
  /// settles the own key. A purchase refused as another account's forgets the account kept, so the
  /// plan is bought again for a new one.
  func signIn() async {
    guard phase == .signedOut else { return }
    phase = .working
    do {
      let session: Session
      if let id = kept.id {
        do {
          session = try await account.signIn(for: id)
        } catch .noPurchase {
          session = try await account.signIn()
        }
      } else {
        session = try await account.signIn()
      }
      if session.account != kept.id {
        kept.keep(session.account)
      }
      if try await !settle(session) {
        phaseFromSession()
      }
    } catch {
      if case .purchaseIsAnotherAccounts = error {
        kept.forget()
        canSignIn = false
      }
      report(error, "Signing in")
      phaseFromSession()
    }
  }

  /// Signed in or out as the session kept says, when signing in didn't end settled.
  private func phaseFromSession() {
    do {
      phase = try account.session() == nil ? .signedOut : .signedIn
    } catch {
      accountLogger.error("The session couldn't be read: \(error)")
      phase = .signedOut
    }
  }

  /// Settles the own key when signed in, as when the account's settings are shown. Not while
  /// signing in or settling already, which would each make a key, nor while deleting the account.
  func settleOwnKey() async {
    guard phase == .signedIn || phase == .recoveryKeyNeeded, !settling, !deleting else { return }
    settling = true
    defer { settling = false }
    do {
      guard let session = try account.session() else {
        phase = .signedOut
        return
      }
      _ = try await settle(session)
    } catch {
      report(error, "Settling the own key")
    }
  }

  /// Called once the person says the recovery key shown is written down.
  func recoveryKeyWrittenDown() {
    recoveryKeyToShow = nil
  }

  /// Brings the own key back from the recovery key `text`. Answers what went wrong, written for a
  /// person, or nil once the key is back.
  func restore(from text: String) async -> String? {
    do {
      guard let session = try account.session() else {
        phase = .signedOut
        return "サインインしていません。もう一度サインインしてください。"
      }
      try await account.restore(from: text, session)
      // The person holds the recovery key a start over would show.
      startedOver.forget()
      phase = .signedIn
      return nil
    } catch {
      accountLogger.error("Restoring the own key failed: \(error)")
      return error.localizedDescription
    }
  }

  /// Starts the account over without its own key, once the person confirmed it, as when no
  /// device holds the key and its recovery key is lost too: the server's writings go, and the own
  /// key held, or one made, becomes the account's, whose recovery key is shown. Only while the own
  /// key isn't here, and not while settling or deleting the account; it counts as settling. The
  /// device is marked before it asks, so that, whatever ends the start over, the recovery key is
  /// shown once the key is found to be the account's. Settled again when it fails, as when the
  /// server's answer was lost or another device changed the account's own key meanwhile.
  func startOver() async {
    guard phase == .recoveryKeyNeeded, !settling, !deleting, let check = state?.ownKeyCheck
    else { return }
    settling = true
    var failed = false
    do {
      if let session = try account.session() {
        startedOver.mark()
        let outcome = try await account.startOver(session, replacing: check)
        if try account.session() == session {
          apply(outcome)
        } else {
          phaseFromSession()
        }
      } else {
        phase = .signedOut
      }
    } catch {
      report(error, "Starting over")
      failed = true
    }
    settling = false
    if failed {
      await settleOwnKey()
    }
  }

  func signOut() async {
    guard !deleting else { return }
    let before = phase
    phase = .working
    do {
      try await account.signOut()
      phase = .signedOut
    } catch {
      phase = before
      report(error, "Signing out")
    }
  }

  /// Deletes the account on the server, then forgets it on the device: the session, the sync's
  /// state, and the account ID kept, so the device has no account. While it runs, the account is
  /// neither checked, settled, synced, nor signed out of.
  func deleteAccount() async {
    guard phase == .signedIn || phase == .recoveryKeyNeeded, !deleting else { return }
    deleting = true
    defer { deleting = false }
    do {
      try await account.deleteAccount(syncStateIn: syncState)
    } catch {
      if case .notForgotten = error {
        // Deleted on the server.
        kept.forget()
        canSignIn = false
      }
      report(error, "Deleting the account")
      do {
        if try account.session() == nil {
          phase = .signedOut
        }
      } catch {
        accountLogger.error("The session couldn't be read: \(error)")
        phase = .signedOut
      }
      return
    }
    kept.forget()
    canSignIn = false
    recoveryKeyToShow = nil
    startedOver.forget()
    phase = .signedOut
  }

  /// What a sync of the writings runs with: the session and the account's own key. Settles the own
  /// key first when it hasn't been since the device became signed in, as when the account's
  /// settings are shown. Nil while signed out, while the own key isn't the account's, while
  /// another settling runs, or while the account is being deleted.
  func syncKeys() async throws(AccountError) -> SyncKeys? {
    guard phase == .signedIn, !deleting else { return nil }
    if !ownKeySettled {
      guard !settling else { return nil }
      settling = true
      defer { settling = false }
      guard let session = try account.session() else {
        phase = .signedOut
        return nil
      }
      guard try await settle(session) else { return nil }
    }
    guard phase == .signedIn else { return nil }
    return try account.syncKeys()
  }

  /// Syncs `writings` with the account's, sealed with `keys.ownKey`.
  func synchronizer(for writings: any PlainWritingStore, keys: SyncKeys) -> Synchronizer {
    account.synchronizer(writings: writings, stateDirectory: syncState, keys: keys)
  }

  /// The account as read with `session`, and which read it was.
  private func read(_ session: Session) async throws(AccountError) -> (
    state: AccountState, number: Int
  ) {
    readsStarted += 1
    let number = readsStarted
    return (try await account.state(session), number)
  }

  /// Whether the device is still signed in to `session` after `read`, a read of the account with
  /// it; then `read` is kept, unless a read started after it was kept already.
  private func stillIn(_ session: Session, keeping read: (state: AccountState, number: Int))
    throws(AccountError) -> Bool
  {
    guard try account.session() == session else { return false }
    if read.number > stateRead {
      state = read.state
      stateRead = read.number
    }
    return true
  }

  /// Settles the own key of `session`. False, settling nothing, when the device left the session
  /// while the account was read or the key settled, as when the account was deleted meanwhile.
  private func settle(_ session: Session) async throws(AccountError) -> Bool {
    let read = try await self.read(session)
    guard try stillIn(session, keeping: read) else { return false }
    var outcome = try await account.settleOwnKey(session, against: read.state)
    guard try account.session() == session else { return false }
    if outcome == .ready, startedOver.isMarked, let key = try account.ownKey() {
      // What went wrong as the start over ended no longer stands.
      problem = nil
      outcome = .made(RecoveryKey(key))
    }
    apply(outcome)
    return true
  }

  /// Where the device stands once the own key is settled as `outcome` says.
  private func apply(_ outcome: OwnKeyOutcome) {
    switch outcome {
    case .ready:
      phase = .signedIn
      ownKeySettled = true
    case .made(let recoveryKey):
      startedOver.forget()
      phase = .signedIn
      ownKeySettled = true
      recoveryKeyToShow = recoveryKey
    case .recoveryKeyNeeded:
      phase = .recoveryKeyNeeded
    }
  }

  private func report(_ error: any Error, _ step: String) {
    if case AccountError.cancelled = error { return }
    accountLogger.error("\(step, privacy: .public) failed: \(error)")
    problem = error.localizedDescription
  }
}

/// Whether a start over was asked for whose recovery key hasn't been shown yet, kept across
/// launches: a start over that reached the server may end without saying so.
struct StartedOver {
  static let key = "syncStartedOver"

  let defaults: UserDefaults

  var isMarked: Bool { defaults.bool(forKey: Self.key) }

  func mark() {
    defaults.set(true, forKey: Self.key)
  }

  func forget() {
    defaults.removeObject(forKey: Self.key)
  }
}
