import Foundation
import Sync
import Testing

/// `SyncAccount` on the Worker with the stand-in Apple (`Server/test/stand-in-apple.ts`), run under
/// `wrangler dev` with sqld by `scripts/server-contract-test.sh`, which gives the Worker's URL.
/// Left out of the ordinary run by `--skip Contract`.
struct AccountContractTests {
  private let url: URL?

  init() {
    url = ProcessInfo.processInfo.environment["MAI_SERVER_URL"].flatMap(URL.init(string:))
  }

  /// One device of the Apple user `user`, holding `ownKey` in its keychain.
  private struct Device {
    let user: String
    let account: SyncAccount
    let apple: StandInApple
    let server: AccountServer
    let sessions = MemorySessions()
    let ownKeys: MemoryOwnKeys

    init(url: URL, user: String, ownKey: OwnKey? = nil) {
      self.user = user
      apple = StandInApple(url: url, user: user)
      server = AccountServer(url: url)
      ownKeys = MemoryOwnKeys(ownKey)
      account = SyncAccount(
        server: server, apple: apple, purchases: apple, sessions: sessions, ownKeys: ownKeys)
    }
  }

  private func device(user: String, ownKey: OwnKey? = nil) throws -> Device {
    Device(
      url: try #require(url, "MAI_SERVER_URL names the local Worker"), user: user, ownKey: ownKey)
  }

  /// A new Apple user's device that bought a plan for a new account and signed in.
  private func signedIn() async throws -> (device: Device, session: Session, key: RecoveryKey) {
    let device = try device(user: "stand-in.\(UUID().uuidString)")
    let account = UUID()
    let session = try await device.account.signIn(for: account)
    let outcome = try await device.account.settleOwnKey(session)
    let recoveryKey = RecoveryKey(try #require(try device.ownKeys.load()))
    #expect(outcome == .made(recoveryKey))
    return (device, session, recoveryKey)
  }

  private func isRefused(_ status: Int) -> (any Error) -> Bool {
    { error in
      guard case .refused(status, _) = error as? ServerError else { return false }
      return true
    }
  }

  @Test func aNewAccountMakesTheOwnKeySendsItsCheckAndShowsTheRecoveryKey() async throws {
    let device = try device(user: "stand-in.\(UUID().uuidString)")
    let account = UUID()
    let session = try await device.account.signIn(for: account)
    #expect(session.account == account)
    #expect(try device.sessions.load() == session)

    let outcome = try await device.account.settleOwnKey(session)
    let kept = try #require(try device.ownKeys.load())
    #expect(outcome == .made(RecoveryKey(kept)))
    #expect(try await device.server.account(token: session.token).ownKeyCheck == kept.check)
  }

  @Test func aNewAccountIsPaidForOnItsPlanWithNothingUsedButTheRequestsBefore() async throws {
    let (device, session, _) = try await signedIn()
    let state = try await device.account.state(session)
    #expect(state.plan == "basic")
    guard case .paid(let until) = state.standing else {
      Issue.record("A new account is paid for, but it reads as \(state.standing)")
      return
    }
    #expect(until > .now)
    #expect(state.usage.writingsBytes == PlanUsage.Use(used: 0, limit: 100_000_000))
    #expect(state.usage.writings == PlanUsage.Use(used: 0, limit: 10_000))
    #expect(state.usage.saves == PlanUsage.Use(used: 0, limit: 500))
    #expect(state.usage.lists == PlanUsage.Use(used: 0, limit: 200))
    // signIn's and settleOwnKey's requests, counted before this one.
    #expect(state.usage.requests.used > 0)
    #expect(state.usage.requests.limit == 3_000)
  }

  @Test func anExistingAccountWhoseCheckMatchesSignsInAndUsesTheKey() async throws {
    let (first, session, recoveryKey) = try await signedIn()
    let second = try device(user: first.user, ownKey: recoveryKey.ownKey)

    let signedIn = try await second.account.signIn(for: session.account)
    #expect(signedIn.account == session.account)
    #expect(signedIn.token != session.token)
    #expect(try await second.account.settleOwnKey(signedIn) == .ready)
    #expect(try second.ownKeys.load() == recoveryKey.ownKey)
  }

  @Test func anotherKeyAsksForTheRecoveryKeyAndTakesOnlyTheAccounts() async throws {
    let (first, session, recoveryKey) = try await signedIn()
    let other = OwnKey.generate()
    let second = try device(user: first.user, ownKey: other)
    let signedIn = try await second.account.signIn(for: session.account)
    #expect(try await second.account.settleOwnKey(signedIn) == .recoveryKeyNeeded)

    await #expect {
      try await second.account.restore(from: RecoveryKey(other).text, signedIn)
    } throws: { error in
      guard case .notTheAccountsKey = error as? AccountError else { return false }
      return true
    }
    #expect(try second.ownKeys.load() == other)

    try await second.account.restore(from: recoveryKey.text.lowercased(), signedIn)
    #expect(try second.ownKeys.load() == recoveryKey.ownKey)
    #expect(try await second.account.settleOwnKey(signedIn) == .ready)
  }

  @Test func aDeviceWithNoKeyAsksForTheRecoveryKeyOfAnAccountThatHasOne() async throws {
    let (first, session, recoveryKey) = try await signedIn()
    let second = try device(user: first.user)
    let signedIn = try await second.account.signIn(for: session.account)
    #expect(try await second.account.settleOwnKey(signedIn) == .recoveryKeyNeeded)
    #expect(try second.ownKeys.load() == nil)

    try await second.account.restore(from: recoveryKey.text, signedIn)
    #expect(try second.ownKeys.load() == recoveryKey.ownKey)
  }

  @Test func aRevokedCredentialEndsTheSession() async throws {
    let (device, session, _) = try await signedIn()
    device.apple.change { $0.credentialState = .revoked }

    #expect(try await device.account.check() == .credentialRevoked)
    #expect(try device.sessions.load() == nil)
    await #expect(
      performing: { try await device.server.account(token: session.token) },
      throws: isRefused(401))
  }

  @Test func theSubscriptionsAreSentAgainAtLaunch() async throws {
    let (device, session, _) = try await signedIn()
    #expect(try await device.server.account(token: session.token).plan == "basic")
    let renewed = Int64(Date.now.addingTimeInterval(60 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
    device.apple.change {
      $0.plan = "plus"
      $0.expiresDate = renewed
    }

    #expect(try await device.account.check() == .subscriptionsSent(1))
    let state = try await device.server.account(token: session.token)
    #expect(state.plan == "plus")
    #expect(state.standing == .paid(until: Date(timeIntervalSince1970: Double(renewed) / 1000)))
    #expect(try device.sessions.load() == session)
  }

  @Test func aSessionTheServerEndedIsDroppedAtLaunch() async throws {
    let (device, session, _) = try await signedIn()
    try await device.server.endSession(token: session.token)

    #expect(try await device.account.check() == .sessionEnded)
    #expect(try device.sessions.load() == nil)
  }

  @Test func signingOutEndsTheSessionOnTheServerAndTheDevice() async throws {
    let (device, session, recoveryKey) = try await signedIn()

    try await device.account.signOut()
    #expect(try device.sessions.load() == nil)
    #expect(try device.ownKeys.load() == recoveryKey.ownKey)
    await #expect(
      performing: { try await device.server.account(token: session.token) },
      throws: isRefused(401))
    #expect(try await device.account.check() == .signedOut)
  }

  @Test func deletingTheAccountEndsEverySessionOfItAndForgetsItOnTheDevice() async throws {
    let (first, session, recoveryKey) = try await signedIn()
    let second = try device(user: first.user, ownKey: recoveryKey.ownKey)
    let secondSession = try await second.account.signIn(for: session.account)
    let states = FileManager.default.temporaryDirectory.appending(
      path: "mai-contract-\(UUID().uuidString)", directoryHint: .isDirectory)

    try await first.account.deleteAccount(syncStateIn: states)
    #expect(try first.sessions.load() == nil)
    for token in [session.token, secondSession.token] {
      await #expect(
        performing: { try await first.server.account(token: token) }, throws: isRefused(401))
    }
    #expect(try await second.account.check() == .sessionEnded)
  }

  @Test func aPurchaseOfAnotherAccountIsRefusedWhenTheAppleUserHasNone() async throws {
    let (_, session, _) = try await signedIn()
    // Another Apple user on a device whose App Store account bought the first one's plan.
    let second = try device(user: "stand-in.\(UUID().uuidString)")
    await #expect {
      try await second.account.signIn(for: session.account)
    } throws: { error in
      guard case .purchaseIsAnotherAccounts = error as? AccountError else { return false }
      return true
    }
    #expect(try second.sessions.load() == nil)
  }
}
