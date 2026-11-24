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

/// The account a plan pays for, as the screens show it: signing in after a purchase, the own key,
/// the check at launch, and signing out. Made only where there is a server to sign in to.
@Observable public final class AccountModel {
  private let account: SyncAccount
  let kept: KeptAccountID
  private(set) var phase = AccountPhase.signedOut
  /// The recovery key of the own key just made, until the person says it is written down.
  private(set) var recoveryKeyToShow: RecoveryKey?
  /// What went wrong, written for a person, until it is dismissed.
  var problem: String?
  private var settling = false

  init(account: SyncAccount, kept: KeptAccountID = .standard) {
    self.account = account
    self.kept = kept
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

  /// Whether a plan was bought on this device, so signing in can make or find its account.
  var canSignIn: Bool { kept.id != nil }

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

  /// Checks the session with Apple and sends the subscriptions again (`SyncAccount.check()`).
  public func check() async {
    do {
      switch try await account.check() {
      case .credentialRevoked, .sessionEnded, .signedOut:
        phase = .signedOut
      case .subscriptionsSent:
        break
      }
    } catch {
      accountLogger.error("The account couldn't be checked: \(error)")
    }
  }

  /// Signs in for the account kept, then settles the own key.
  func signIn() async {
    guard let id = kept.id, phase == .signedOut else { return }
    phase = .working
    do {
      let session = try await account.signIn(for: id)
      if session.account != id {
        kept.keep(session.account)
      }
      try await settle(session)
    } catch {
      report(error, "Signing in")
      do {
        phase = try account.session() == nil ? .signedOut : .signedIn
      } catch {
        accountLogger.error("The session couldn't be read: \(error)")
        phase = .signedOut
      }
    }
  }

  /// Settles the own key when signed in, as when the account's settings are shown. Not while
  /// signing in or settling already, which would each make a key.
  func settleOwnKey() async {
    guard phase == .signedIn || phase == .recoveryKeyNeeded, !settling else { return }
    settling = true
    defer { settling = false }
    do {
      guard let session = try account.session() else {
        phase = .signedOut
        return
      }
      try await settle(session)
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
      phase = .signedIn
      return nil
    } catch {
      accountLogger.error("Restoring the own key failed: \(error)")
      return error.localizedDescription
    }
  }

  func signOut() async {
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

  private func settle(_ session: Session) async throws(AccountError) {
    switch try await account.settleOwnKey(session) {
    case .ready:
      phase = .signedIn
    case .made(let recoveryKey):
      phase = .signedIn
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
