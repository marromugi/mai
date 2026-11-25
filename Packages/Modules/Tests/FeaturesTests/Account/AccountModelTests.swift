import Foundation
import Sync
import SyncFakes
import Synchronization
import Testing

@testable import Features

/// How `AccountModel` moves between phases, over a scripted Worker and Apple.
@Suite(.serialized)
struct AccountModelTests {
  private let suite = "AccountModelTests.\(UUID().uuidString)"
  private let bought = UUID()

  /// With `session` kept on the device, `key` in its keychain, and, when `keeps`, the account ID
  /// a plan was bought for.
  private func model(
    _ answers: [String: [ScriptedWorker.Answer]], worker: ScriptedWorker? = nil,
    apple: ScriptedApple = ScriptedApple(), session: Session? = nil, key: OwnKey? = nil,
    keeps: Bool = true
  ) throws -> AccountModel {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let kept = KeptAccountID(defaults: defaults)
    if keeps {
      kept.keep(bought)
    }
    let sessions = MemorySessions()
    if let session {
      try sessions.save(session)
    }
    let ownKeys = MemoryOwnKeys()
    if let key {
      try ownKeys.save(key)
    }
    return AccountModel(
      account: SyncAccount(
        server: AccountServer(
          url: try #require(URL(string: "https://worker.test")),
          transport: worker ?? ScriptedWorker(answers)),
        apple: apple, purchases: apple, sessions: sessions, ownKeys: ownKeys),
      kept: kept)
  }

  private var session: Session {
    Session(token: "s1.a.b", account: bought, appleUser: "user")
  }

  @Test func aSessionKeptIsSignedInAtLaunch() async throws {
    let model = try model(["PUT /account/subscription": [.status(200)]], session: session)
    await model.checkAtLaunch()
    #expect(model.phase == .signedIn)
    #expect(model.canSignIn)
  }

  /// Read mode is the signed-in account's only, even with a session and a key kept.
  @Test func readModeIsOnlyWhileSignedIn() async throws {
    let model = try model(
      ["PUT /account/subscription": [.status(200)]], session: session, key: OwnKey.generate())
    #expect(model.phase == .signedOut)
    #expect(model.readMode() == nil)
    await model.checkAtLaunch()
    #expect(model.phase == .signedIn)
    #expect(model.readMode() != nil)
  }

  @Test func noSessionIsSignedOutAtLaunch() async throws {
    let model = try model([:])
    await model.checkAtLaunch()
    #expect(model.phase == .signedOut)
  }

  @Test func aSessionTheServerEndedSignsOutAtLaunch() async throws {
    let model = try model(["PUT /account/subscription": [.status(401)]], session: session)
    await model.checkAtLaunch()
    #expect(model.phase == .signedOut)
  }

  @Test func noAccountIDKeptOffersNoSignIn() async throws {
    let model = try model([:], keeps: false)
    await model.refresh()
    #expect(!model.canSignIn)
  }

  @Test func theAccountsKeyOnTheDeviceIsSignedIn() async throws {
    let key = OwnKey.generate()
    let model = try model(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: key.check)],
      ], session: session, key: key)
    await model.checkAtLaunch()
    await model.refresh()
    #expect(model.phase == .signedIn)
    #expect(model.problem == nil)
  }

  /// Settings shown read the account as they settle the own key, and a read after a sync reads it
  /// again; one that fails keeps what was read, and signing out forgets it.
  @Test func settingsShownReadTheAccountUntilSignedOut() async throws {
    let key = OwnKey.generate()
    let model = try model(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [
          .status(200, json: accountAnswer(check: key.check, paidUntil: 6_000)),
          .status(200, json: accountAnswer(check: key.check, paidUntil: 6_000, gracePeriod: true)),
          .status(429, json: #"{"error":"x","limit":"requests"}"#),
        ],
        "DELETE /session": [.status(204)],
      ], session: session, key: key)
    await model.checkAtLaunch()
    #expect(model.state == nil)
    await model.refresh()
    let until = Date(timeIntervalSince1970: 6)
    #expect(model.state?.standing == .paid(until: until))

    await model.readState()
    #expect(model.state?.standing == .gracePeriod(until: until))
    await model.readState()
    #expect(model.state?.standing == .gracePeriod(until: until))

    await model.signOut()
    #expect(model.state == nil)
  }

  /// The account read for a session the device signed out of while it was read is dropped, and
  /// settles nothing.
  @Test func anAccountReadAcrossASignOutIsDropped() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: key.check)],
        "DELETE /session": [.status(204)],
      ], holding: "GET /account")
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    let reading = Task { await model.refresh() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.signOut()
    worker.release()
    await reading.value
    #expect(model.phase == .signedOut)
    #expect(model.state == nil)
  }

  /// A model over `worker` whose session store and own key store the test holds, keeping the
  /// sync's state in `syncState`.
  private func model(
    over worker: ScriptedWorker, sessions: any SessionStore,
    ownKeys: MemoryOwnKeys = MemoryOwnKeys(),
    syncState: URL = .applicationSupportDirectory.appending(
      path: "Sync", directoryHint: .isDirectory)
  ) throws -> AccountModel {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let kept = KeptAccountID(defaults: defaults)
    kept.keep(bought)
    let apple = ScriptedApple()
    return AccountModel(
      account: SyncAccount(
        server: AccountServer(
          url: try #require(URL(string: "https://worker.test")), transport: worker),
        apple: apple, purchases: apple, sessions: sessions, ownKeys: ownKeys),
      kept: kept, syncState: syncState)
  }

  /// The session dropped while signing in reads the account (a check that met a 401): signing in
  /// ends signed out, not still working.
  @Test func aSignInWhoseSessionGoesWhileTheAccountIsReadEndsSignedOut() async throws {
    let worker = ScriptedWorker(Self.newAccount, holding: "GET /account")
    let sessions = MemorySessions()
    let model = try model(over: worker, sessions: sessions)
    let signingIn = Task { await model.signIn() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    try sessions.remove()
    worker.release()
    await signingIn.value
    #expect(model.phase == .signedOut)
    #expect(model.state == nil)
  }

  /// A sync whose session is replaced while the account is read gets no keys: the key on the
  /// device wasn't settled against the new session's account.
  @Test func aSyncWhoseSessionChangesWhileTheAccountIsReadGetsNoKeys() async throws {
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: OwnKey.generate().check)],
      ], holding: "GET /account")
    let sessions = MemorySessions()
    try sessions.save(session)
    let ownKeys = MemoryOwnKeys()
    try ownKeys.save(OwnKey.generate())
    let model = try model(over: worker, sessions: sessions, ownKeys: ownKeys)
    await model.checkAtLaunch()
    let keys = Task { try await model.syncKeys() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    try sessions.save(Session(token: "s1.c.d", account: UUID(), appleUser: "user"))
    worker.release()
    #expect(try await keys.value == nil)
    #expect(model.state == nil)
  }

  /// Two reads of the account at once: the one started later is kept, whichever ends last.
  @Test func theLaterReadOfTheAccountIsKept() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [
          .status(200, json: accountAnswer(check: key.check, paidUntil: 1_000)),
          .status(200, json: accountAnswer(check: key.check, paidUntil: 2_000)),
        ],
      ], holding: "GET /account")
    let sessions = MemorySessions()
    try sessions.save(session)
    let ownKeys = MemoryOwnKeys()
    try ownKeys.save(key)
    let model = try model(over: worker, sessions: sessions, ownKeys: ownKeys)
    await model.checkAtLaunch()
    let first = Task { await model.readState() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.readState()
    worker.release()
    await first.value
    // The held read, started first, is answered last, with the second answer.
    #expect(model.state?.standing == .paid(until: Date(timeIntervalSince1970: 1)))
  }

  /// While the recovery key is asked for, the account is still read.
  @Test func theAccountIsReadWhileTheRecoveryKeyIsNeeded() async throws {
    let model = try model(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [
          ScriptedWorker.account(check: OwnKey.generate().check),
          .status(200, json: accountAnswer(check: nil, paidUntil: 3_000, gracePeriod: true)),
        ],
      ], session: session, key: OwnKey.generate())
    await model.checkAtLaunch()
    await model.refresh()
    #expect(model.phase == .recoveryKeyNeeded)
    await model.readState()
    #expect(model.state?.standing == .gracePeriod(until: Date(timeIntervalSince1970: 3)))
  }

  /// A sign-in that fails, on a device whose keychain then can't be read, ends signed out.
  @Test func aFailedSignInWhoseSessionCantBeReadEndsSignedOut() async throws {
    var answers = Self.newAccount
    answers["GET /account"] = []
    let worker = ScriptedWorker(answers)
    let sessions = BreakingSessions()
    let model = try model(over: worker, sessions: sessions)
    sessions.breaksAfterSave = true
    await model.signIn()
    #expect(model.phase == .signedOut)
    #expect(model.problem != nil)
  }

  @Test func aSignedOutDeviceDoesntReadTheAccount() async throws {
    let worker = ScriptedWorker([:])
    let model = try model([:], worker: worker, keeps: false)
    await model.checkAtLaunch()
    await model.refresh()
    await model.readState()
    #expect(model.state == nil)
    #expect(worker.asked.isEmpty)
  }

  /// Settings shown again while the own key is being settled don't settle it a second time.
  @Test func aRefreshWhileSettlingDoesntSettleAgain() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [
          ScriptedWorker.account(check: key.check), ScriptedWorker.account(check: key.check),
        ],
      ], holding: "GET /account")
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    let first = Task { await model.refresh() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.refresh()
    worker.release()
    await first.value
    #expect(worker.heldCount == 1)
    #expect(model.phase == .signedIn)
  }

  @Test func theRecoveryKeyBringsBackTheAccountsKey() async throws {
    let key = OwnKey.generate()
    let model = try model(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [
          ScriptedWorker.account(check: key.check), ScriptedWorker.account(check: key.check),
        ],
      ], session: session)
    await model.checkAtLaunch()
    await model.refresh()
    #expect(model.phase == .recoveryKeyNeeded)
    #expect(await model.restore(from: RecoveryKey(key).text) == nil)
    #expect(model.phase == .signedIn)
  }

  @Test func aSignOutTheServerDidntGetStaysSignedIn() async throws {
    let model = try model(["PUT /account/subscription": [.status(200)]], session: session)
    await model.checkAtLaunch()
    await model.signOut()
    #expect(model.phase == .signedIn)
    #expect(model.problem != nil)
  }

  @Test func aSecondSignInWhileOneRunsIsNotStarted() async throws {
    let apple = ScriptedApple(waits: true)
    let model = try model(Self.newAccount, apple: apple)
    let signingIn = Task { await model.signIn() }
    while apple.waiting == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.signIn()
    apple.go()
    await signingIn.value
    #expect(apple.waiting == 1)
  }

  private static let newAccount: [String: [ScriptedWorker.Answer]] = [
    "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
    "POST /account": [.status(201, json: #"{"token":"s1.a.b"}"#)],
    "GET /account": [ScriptedWorker.account(check: nil)],
    "PUT /account/own-key-check": [.status(204)],
  ]

  @Test func aNewAccountShowsTheRecoveryKeyOfTheKeyMade() async throws {
    let model = try model(Self.newAccount)
    await model.signIn()
    #expect(model.phase == .signedIn)
    #expect(model.recoveryKeyToShow != nil)
    model.recoveryKeyWrittenDown()
    #expect(model.recoveryKeyToShow == nil)
  }

  /// The Apple user's account is another than the one the plan was bought for: its ID is kept, so
  /// the next purchase carries it.
  @Test func signingInToAnotherAccountKeepsItsID() async throws {
    let other = UUID()
    let model = try model([
      "POST /challenges": [
        .status(201, json: #"{"challenge":"c"}"#), .status(201, json: #"{"challenge":"d"}"#),
      ],
      "POST /account": [.status(409)],
      "POST /sessions": [
        .status(200, json: #"{"account":"\#(other.uuidString.lowercased())","token":"s1.a.b"}"#)
      ],
      "GET /account": [ScriptedWorker.account(check: Data(repeating: 1, count: 32))],
    ])
    await model.signIn()
    #expect(model.kept.id == other)
    #expect(model.phase == .recoveryKeyNeeded)
  }

  /// A device that didn't buy the plan: the Apple user's account is signed in to, and its ID kept.
  @Test func signingInWithNoAccountIDKeptAsksForASessionOnly() async throws {
    let other = UUID()
    let worker = ScriptedWorker([
      "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
      "POST /sessions": [
        .status(200, json: #"{"account":"\#(other.uuidString.lowercased())","token":"s1.a.b"}"#)
      ],
      "GET /account": [ScriptedWorker.account(check: Data(repeating: 1, count: 32))],
    ])
    let model = try model([:], worker: worker, keeps: false)
    await model.signIn()
    #expect(worker.asked == ["POST /challenges", "POST /sessions", "GET /account"])
    #expect(model.kept.id == other)
    #expect(model.phase == .recoveryKeyNeeded)
    #expect(model.problem == nil)
  }

  /// The account ID kept, with no plan bought for it on this App Store account.
  @Test func signingInWithNoPurchaseOfTheAccountKeptAsksForASessionOnly() async throws {
    let worker = ScriptedWorker([
      "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
      "POST /sessions": [
        .status(200, json: #"{"account":"\#(bought.uuidString.lowercased())","token":"s1.a.b"}"#)
      ],
      "GET /account": [ScriptedWorker.account(check: nil)],
      "PUT /account/own-key-check": [.status(204)],
    ])
    let model = try model([:], worker: worker, apple: ScriptedApple(bought: []))
    await model.signIn()
    #expect(!worker.asked.contains("POST /account"))
    #expect(model.phase == .signedIn)
    #expect(model.kept.id == bought)
  }

  @Test func anAppleUserWithNoAccountIsToldHowToGetOne() async throws {
    let model = try model(
      [
        "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
        "POST /sessions": [.status(404)],
      ], keeps: false)
    await model.signIn()
    #expect(model.phase == .signedOut)
    #expect(model.kept.id == nil)
    #expect(model.problem == AccountError.noAccount.localizedDescription)
  }

  /// The purchase is another Apple user's account's: what happened and what to do is said, and the
  /// account ID kept is forgotten, so a plan bought again is bought for a new account.
  @Test func aPurchaseOfAnotherAccountSaysWhatToDoAndForgetsItsID() async throws {
    let model = try model([
      "POST /challenges": [
        .status(201, json: #"{"challenge":"c"}"#), .status(201, json: #"{"challenge":"d"}"#),
      ],
      "POST /account": [.status(409)],
      "POST /sessions": [.status(404)],
    ])
    await model.refresh()
    #expect(model.canSignIn)
    await model.signIn()
    #expect(model.phase == .signedOut)
    #expect(model.kept.id == nil)
    #expect(!model.canSignIn)
    #expect(model.problem == AccountError.purchaseIsAnotherAccounts.localizedDescription)
  }

  /// No device holds the own key and its recovery key is lost: the account starts over with the
  /// check it was read with, and the new key's recovery key is shown.
  @Test func startingOverMakesANewKeyAndShowsItsRecoveryKey() async throws {
    let check = Data(repeating: 1, count: 32)
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [ScriptedWorker.account(check: check)],
      "PUT /account/own-key-check": [.status(204)],
    ])
    let model = try model([:], worker: worker, session: session)
    await model.checkAtLaunch()
    await model.refresh()
    #expect(model.phase == .recoveryKeyNeeded)
    await model.startOver()
    #expect(model.phase == .signedIn)
    #expect(model.problem == nil)
    let keys = try #require(try await model.syncKeys())
    #expect(model.recoveryKeyToShow == RecoveryKey(keys.ownKey))
    #expect(worker.asked.filter { $0 == "PUT /account/own-key-check" }.count == 1)
  }

  /// Another device changed the own key since it was read: nothing goes, that is said, and the key
  /// is settled again against the account as it is now.
  @Test func startingOverAfterTheKeyChangedSettlesAgain() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [
        ScriptedWorker.account(check: Data(repeating: 1, count: 32)),
        ScriptedWorker.account(check: Data(repeating: 2, count: 32)),
      ],
      "PUT /account/own-key-check": [.status(409)],
    ])
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    await model.refresh()
    await model.startOver()
    #expect(model.problem == AccountError.ownKeyChanged.localizedDescription)
    #expect(model.phase == .recoveryKeyNeeded)
    #expect(model.recoveryKeyToShow == nil)
  }

  /// The start over reached the server, but its answer didn't reach the device: the settling after
  /// it finds the key the account's, and shows its recovery key all the same.
  @Test func aStartOverWhoseAnswerWasLostShowsTheRecoveryKey() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [
        ScriptedWorker.account(check: Data(repeating: 1, count: 32)),
        ScriptedWorker.account(check: key.check),
        ScriptedWorker.account(check: key.check),
      ],
    ])
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    await model.refresh()
    await model.startOver()
    #expect(model.phase == .signedIn)
    #expect(model.recoveryKeyToShow == RecoveryKey(key))
    #expect(model.problem == nil)

    // Shown once.
    model.recoveryKeyWrittenDown()
    await model.refresh()
    #expect(model.phase == .signedIn)
    #expect(model.recoveryKeyToShow == nil)
  }

  /// Signed out before the start over ended: the recovery key is shown once signed in again.
  @Test func aStartOverOvertakenByASignOutShowsTheRecoveryKeyOnSigningInAgain() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [
          ScriptedWorker.account(check: Data(repeating: 1, count: 32)),
          ScriptedWorker.account(check: key.check),
        ],
        "PUT /account/own-key-check": [.status(204)],
        "DELETE /session": [.status(204)],
        "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
        "POST /account": [.status(201, json: #"{"token":"s1.a.b"}"#)],
      ], holding: "PUT /account/own-key-check")
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    await model.refresh()
    let startingOver = Task { await model.startOver() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.signOut()
    worker.release()
    await startingOver.value
    #expect(model.phase == .signedOut)
    #expect(model.recoveryKeyToShow == nil)

    await model.signIn()
    #expect(model.phase == .signedIn)
    #expect(model.recoveryKeyToShow == RecoveryKey(key))
  }

  /// Once started over, the page's button can't start it over again.
  @Test func aSecondStartOverAfterOneDoneSendsNothing() async throws {
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [ScriptedWorker.account(check: Data(repeating: 1, count: 32))],
      "PUT /account/own-key-check": [.status(204), .status(204)],
    ])
    let model = try model([:], worker: worker, session: session, key: OwnKey.generate())
    await model.checkAtLaunch()
    await model.refresh()
    await model.startOver()
    #expect(model.phase == .signedIn)
    await model.startOver()
    #expect(worker.asked.filter { $0 == "PUT /account/own-key-check" }.count == 1)
  }

  @Test func aStartOverWhileOneRunsIsNotStarted() async throws {
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: Data(repeating: 1, count: 32))],
        "PUT /account/own-key-check": [.status(204), .status(204)],
      ], holding: "PUT /account/own-key-check")
    let model = try model([:], worker: worker, session: session, key: OwnKey.generate())
    await model.checkAtLaunch()
    await model.refresh()
    let first = Task { await model.startOver() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.startOver()
    worker.release()
    await first.value
    #expect(worker.heldCount == 1)
    #expect(model.phase == .signedIn)
  }

  @Test func aStartOverWhileTheAccountIsDeletedSendsNothing() async throws {
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: Data(repeating: 1, count: 32))],
        "DELETE /account": [.status(204)],
      ], holding: "DELETE /account")
    let model = try model([:], worker: worker, session: session, key: OwnKey.generate())
    await model.checkAtLaunch()
    await model.refresh()
    let deleting = Task { await model.deleteAccount() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.startOver()
    worker.release()
    await deleting.value
    #expect(!worker.asked.contains("PUT /account/own-key-check"))
  }

  /// The session went before the start over: signed out, and nothing sent.
  @Test func aStartOverWithNoSessionSignsOut() async throws {
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [ScriptedWorker.account(check: Data(repeating: 1, count: 32))],
    ])
    let sessions = MemorySessions()
    try sessions.save(session)
    let model = try model(over: worker, sessions: sessions, ownKeys: MemoryOwnKeys())
    await model.checkAtLaunch()
    await model.refresh()
    #expect(model.phase == .recoveryKeyNeeded)
    try sessions.remove()
    await model.startOver()
    #expect(model.phase == .signedOut)
    #expect(!worker.asked.contains("PUT /account/own-key-check"))
  }

  /// A start over that didn't happen, then the recovery key typed: its key is the person's
  /// already, so nothing is shown.
  @Test func aRecoveryKeyTypedAfterAStartOverThatDidntHappenShowsNothing() async throws {
    let theirs = OwnKey.generate()
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [
        ScriptedWorker.account(check: Data(repeating: 1, count: 32)),
        ScriptedWorker.account(check: theirs.check),
        ScriptedWorker.account(check: theirs.check),
        ScriptedWorker.account(check: theirs.check),
      ],
      "PUT /account/own-key-check": [.status(409)],
    ])
    let model = try model([:], worker: worker, session: session, key: OwnKey.generate())
    await model.checkAtLaunch()
    await model.refresh()
    await model.startOver()
    #expect(model.phase == .recoveryKeyNeeded)
    #expect(await model.restore(from: RecoveryKey(theirs).text) == nil)
    await model.refresh()
    #expect(model.phase == .signedIn)
    #expect(model.recoveryKeyToShow == nil)
  }

  @Test func startingOverWhileTheKeyIsHereSendsNothing() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)],
      "GET /account": [ScriptedWorker.account(check: key.check)],
    ])
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    await model.refresh()
    await model.startOver()
    #expect(!worker.asked.contains("PUT /account/own-key-check"))
    #expect(model.phase == .signedIn)
  }

  @Test func aCancelledSignInSaysNothing() async throws {
    let model = try model(Self.newAccount, apple: ScriptedApple(cancels: true))
    await model.signIn()
    #expect(model.phase == .signedOut)
    #expect(model.problem == nil)
  }

  @Test func aFailedSignInSaysWhy() async throws {
    let model = try model([:])
    await model.signIn()
    #expect(model.phase == .signedOut)
    #expect(model.problem == "サーバーにつながりませんでした。ネットワークを確かめて、もう一度お試しください。")
  }

  /// StoreKit telling of a transaction while a sign-in waits on Apple doesn't end the sign-in.
  @Test func aCheckDuringASignInLeavesItGoing() async throws {
    let apple = ScriptedApple(waits: true)
    let model = try model(Self.newAccount, apple: apple)
    let signingIn = Task { await model.signIn() }
    while apple.waiting == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.check()
    #expect(model.phase == .working)
    apple.go()
    await signingIn.value
    #expect(model.phase == .signedIn)
  }

  @Test func aPurchaseWaitingForApprovalOffersNoSignIn() async throws {
    let waiting = try model([:], apple: ScriptedApple(bought: []))
    await waiting.refresh()
    #expect(!waiting.canSignIn)
    let paid = try model([:])
    await paid.refresh()
    #expect(paid.canSignIn)
  }

  /// A key made on signing in is the account's: the sync runs with it without settling again.
  @Test func aKeyMadeOnSigningInIsSyncedWith() async throws {
    let model = try model(Self.newAccount)
    await model.signIn()
    let keys = try #require(try await model.syncKeys())
    #expect(keys.session.token == "s1.a.b")
  }

  /// Signed in again after signing out, where settling the key failed: the sync settles it
  /// first, rather than taking the last account's settling for this one's.
  @Test func aSignInWhoseSettlingFailedIsSettledBeforeASync() async throws {
    var answers = Self.newAccount
    answers["DELETE /session"] = [.status(204)]
    answers["POST /challenges"]?.append(.status(201, json: #"{"challenge":"d"}"#))
    answers["POST /account"]?.append(.status(201, json: #"{"token":"s1.c.d"}"#))
    let model = try model(answers)
    await model.signIn()
    _ = try await model.syncKeys()
    await model.signOut()
    await model.signIn()
    #expect(model.phase == .signedIn)

    await #expect(throws: AccountError.self) { try await model.syncKeys() }
  }

  /// A sync asked for while the own key is being settled waits for the next, and settles nothing.
  @Test func aSyncWhileSettlingGetsNoKeys() async throws {
    let key = OwnKey.generate()
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: key.check)],
      ], holding: "GET /account")
    let model = try model([:], worker: worker, session: session, key: key)
    await model.checkAtLaunch()
    let settling = Task { await model.refresh() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await model.syncKeys() == nil)
    worker.release()
    await settling.value
    #expect(worker.heldCount == 1)
    #expect(try await model.syncKeys() != nil)
  }

  @Test func signingOutGoesBackToSignIn() async throws {
    var answers = Self.newAccount
    answers["DELETE /session"] = [.status(204)]
    let model = try model(answers)
    await model.signIn()
    await model.signOut()
    #expect(model.phase == .signedOut)
    #expect(model.problem == nil)
  }

  /// Signed in at launch over `worker`, with `key` on the device and a sync state file for the
  /// account in a directory of its own.
  private func signedInForDeletion(
    _ answers: [String: [ScriptedWorker.Answer]], holding: String? = nil,
    key: OwnKey = OwnKey.generate()
  ) async throws -> (
    model: AccountModel, worker: ScriptedWorker, sessions: MemorySessions,
    ownKeys: MemoryOwnKeys, stateFile: URL
  ) {
    var answers = answers
    answers["PUT /account/subscription"] = [.status(200)]
    let worker = ScriptedWorker(answers, holding: holding)
    let sessions = MemorySessions()
    try sessions.save(session)
    let ownKeys = MemoryOwnKeys()
    try ownKeys.save(key)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "mai-account-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stateFile = directory.appending(path: "\(bought.uuidString.lowercased()).json")
    try Data("{}".utf8).write(to: stateFile)
    let model = try model(over: worker, sessions: sessions, ownKeys: ownKeys, syncState: directory)
    await model.checkAtLaunch()
    return (model, worker, sessions, ownKeys, stateFile)
  }

  @Test func deletingTheAccountGoesBackToBeforeAPlanWasBought() async throws {
    let (model, _, sessions, ownKeys, stateFile) = try await signedInForDeletion([
      "DELETE /account": [.status(204)]
    ])
    #expect(model.phase == .signedIn)
    #expect(model.canSignIn)

    await model.deleteAccount()
    #expect(model.problem == nil)
    #expect(model.phase == .signedOut)
    #expect(!model.canSignIn)
    #expect(model.kept.id == nil)
    #expect(try sessions.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: stateFile.path()))
  }

  @Test func anAccountTheServerDidntDeleteStaysSignedIn() async throws {
    let (model, _, sessions, _, stateFile) = try await signedInForDeletion([
      "DELETE /account": [.status(502)]
    ])
    await model.deleteAccount()
    #expect(model.problem != nil)
    #expect(model.phase == .signedIn)
    #expect(model.kept.id == bought)
    #expect(try sessions.load() == session)
    #expect(FileManager.default.fileExists(atPath: stateFile.path()))
    #expect(!model.deleting)
  }

  @Test func aDeletionThatFailsWhileTheRecoveryKeyIsNeededStillAsksForIt() async throws {
    let (model, _, _, _, _) = try await signedInForDeletion([
      "GET /account": [ScriptedWorker.account(check: OwnKey.generate().check)],
      "DELETE /account": [.status(502)],
    ])
    await model.settleOwnKey()
    #expect(model.phase == .recoveryKeyNeeded)
    await model.deleteAccount()
    #expect(model.problem != nil)
    #expect(model.phase == .recoveryKeyNeeded)
  }

  /// A session that can't be read sends nothing, so the account ID is kept.
  @Test func aDeletionWhoseSessionCantBeReadKeepsTheAccountID() async throws {
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)], "DELETE /account": [.status(204)],
    ])
    let sessions = BreakingSessions()
    try sessions.save(session)
    let model = try model(over: worker, sessions: sessions)
    await model.checkAtLaunch()
    sessions.breaksAfterSave = true
    try sessions.save(session)

    await model.deleteAccount()
    #expect(model.problem != nil)
    #expect(!worker.asked.contains("DELETE /account"))
    #expect(model.kept.id == bought)
    #expect(model.phase == .signedOut)
  }

  @Test func aDeletionWhileSignedOutSendsNothing() async throws {
    let worker = ScriptedWorker(["DELETE /account": [.status(204)]])
    let sessions = MemorySessions()
    try sessions.save(session)
    let model = try model(over: worker, sessions: sessions)
    await model.deleteAccount()
    #expect(worker.asked.isEmpty)
    #expect(model.kept.id == bought)
  }

  /// A recovery key not yet written down is of the account deleted, so it isn't shown after.
  @Test func deletingTheAccountDropsTheRecoveryKeyToShow() async throws {
    var answers = Self.newAccount
    answers["DELETE /account"] = [.status(204)]
    let model = try model(answers)
    await model.signIn()
    #expect(model.recoveryKeyToShow != nil)
    await model.deleteAccount()
    #expect(model.recoveryKeyToShow == nil)
  }

  /// A settling the deletion overtook doesn't sign the device back in, nor show a recovery key.
  @Test func aSettlingThatEndsAfterTheDeletionLeavesItSignedOut() async throws {
    let worker = ScriptedWorker(
      [
        "PUT /account/subscription": [.status(200)],
        "GET /account": [ScriptedWorker.account(check: nil)],
        "PUT /account/own-key-check": [.status(204)],
        "DELETE /account": [.status(204)],
      ], holding: "PUT /account/own-key-check")
    let sessions = MemorySessions()
    try sessions.save(session)
    let model = try model(over: worker, sessions: sessions)
    await model.checkAtLaunch()
    let settling = Task { await model.settleOwnKey() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    await model.deleteAccount()
    worker.release()
    await settling.value
    #expect(model.phase == .signedOut)
    #expect(model.recoveryKeyToShow == nil)
  }

  /// Deleted on the server, the account ID goes even when the session can't be removed.
  @Test func anAccountDeletedWhoseSessionCantBeRemovedForgetsItsID() async throws {
    let worker = ScriptedWorker([
      "PUT /account/subscription": [.status(200)], "DELETE /account": [.status(204)],
    ])
    let sessions = BreakingSessions()
    try sessions.save(session)
    let model = try model(over: worker, sessions: sessions)
    await model.checkAtLaunch()
    sessions.removalFails = true

    await model.deleteAccount()
    #expect(model.problem == AccountError.notForgotten(.failed(-25308)).localizedDescription)
    #expect(model.kept.id == nil)
    #expect(!model.canSignIn)
  }

  /// The server can't say whether the account is gone, so its ID is kept for signing in again.
  @Test func aDeletionRefusedForTheSessionSignsOutAndKeepsTheAccountID() async throws {
    let (model, _, _, ownKeys, _) = try await signedInForDeletion([
      "DELETE /account": [.status(401)]
    ])
    await model.deleteAccount()
    #expect(model.problem == AccountError.signInNeededToDelete.localizedDescription)
    #expect(model.phase == .signedOut)
    #expect(model.kept.id == bought)
    #expect(try ownKeys.load() != nil)
  }

  /// While the account is being deleted, nothing else reaches the server with its session.
  @Test func whileDeletingNothingElseUsesTheSession() async throws {
    let (model, worker, _, _, _) = try await signedInForDeletion(
      ["DELETE /account": [.status(204)]], holding: "DELETE /account")
    let deleting = Task { await model.deleteAccount() }
    while !worker.isHolding {
      try await Task.sleep(for: .milliseconds(10))
    }
    let before = worker.asked
    #expect(try await model.syncKeys() == nil)
    await model.check()
    await model.settleOwnKey()
    await model.signOut()
    await model.deleteAccount()
    #expect(worker.asked == before)
    worker.release()
    await deleting.value
    #expect(worker.heldCount == 1)
    #expect(model.phase == .signedOut)
  }
}

/// Answers each request with the next answer written for its route; with none left, it fails the
/// way an unreachable server does.
nonisolated final class ScriptedWorker: HTTPTransport {
  enum Answer: Sendable {
    case status(Int, json: String = "{}")
  }

  private let answers: Mutex<[String: [Answer]]>
  private let holding: String?
  private let held = Mutex<(count: Int, gate: CheckedContinuation<Void, Never>?)>((0, nil))
  private let routes = Mutex<[String]>([])

  /// Holds the first request to the route `holding` until `release()`.
  init(_ answers: [String: [Answer]], holding: String? = nil) {
    self.answers = Mutex(answers)
    self.holding = holding
  }

  /// How many requests to the held route came.
  var heldCount: Int { held.withLock { $0.count } }
  var isHolding: Bool { held.withLock { $0.gate != nil } }
  /// The routes asked, in order.
  var asked: [String] { routes.withLock { $0 } }

  func release() {
    held.withLock { $0.gate?.resume() }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
    routes.withLock { $0.append(route) }
    if route == holding {
      let first = held.withLock { held -> Bool in
        held.count += 1
        return held.count == 1
      }
      if first {
        await withCheckedContinuation { gate in held.withLock { $0.gate = gate } }
      }
    }
    let answer = answers.withLock { answers -> Answer? in
      guard var queue = answers[route], !queue.isEmpty else { return nil }
      let first = queue.removeFirst()
      answers[route] = queue
      return first
    }
    guard case .status(let status, let json) = answer else {
      throw URLError(.cannotConnectToHost)
    }
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: nil)
    else {
      preconditionFailure("A request always has a URL")
    }
    return (Data(json.utf8), response)
  }

  static func account(check: Data?) -> Answer {
    .status(200, json: accountAnswer(check: check))
  }
}

/// Apple and the App Store: a sign-in that is cancelled, or waits until `go()`.
nonisolated final class ScriptedApple: AppleSignIn, Purchases {
  private let cancels: Bool
  private let waits: Bool
  private let bought: [SignedSubscription]
  private let state = Mutex<(waiting: Int, gate: CheckedContinuation<Void, Never>?)>((0, nil))

  init(
    cancels: Bool = false, waits: Bool = false,
    bought: [SignedSubscription] = [SignedSubscription(transaction: "t", renewalInfo: "r")]
  ) {
    self.cancels = cancels
    self.waits = waits
    self.bought = bought
  }

  var waiting: Int { state.withLock { $0.waiting } }

  func go() {
    state.withLock { $0.gate?.resume() }
  }

  func signIn(nonce: String) async throws -> AppleCredential {
    if cancels { throw CancellationError() }
    if waits {
      await withCheckedContinuation { gate in
        state.withLock {
          $0.gate = gate
          $0.waiting += 1
        }
      }
    }
    return AppleCredential(user: "user", identityToken: "id", authorizationCode: "code")
  }

  func credentialState(of user: String) async throws -> AppleCredentialState { .authorized }

  func subscriptions(for account: UUID) async throws -> [SignedSubscription] { bought }
}

/// Keeps a session in memory; once `breaksAfterSave` and a session is saved, every load fails,
/// and while `removalFails`, every removal does.
nonisolated final class BreakingSessions: SessionStore {
  private let kept = Mutex<(session: Session?, breaks: Bool, broken: Bool, removalFails: Bool)>(
    (nil, false, false, false))

  var breaksAfterSave: Bool {
    get { kept.withLock { $0.breaks } }
    set { kept.withLock { $0.breaks = newValue } }
  }

  var removalFails: Bool {
    get { kept.withLock { $0.removalFails } }
    set { kept.withLock { $0.removalFails = newValue } }
  }

  func load() throws(KeychainError) -> Session? {
    try kept.withLock { kept throws(KeychainError) in
      if kept.broken { throw .failed(-25308) }
      return kept.session
    }
  }

  func save(_ session: Session) throws(KeychainError) {
    kept.withLock {
      $0.session = session
      $0.broken = $0.breaks
    }
  }

  func remove() throws(KeychainError) {
    try kept.withLock { kept throws(KeychainError) in
      if kept.removalFails { throw .failed(-25308) }
      kept.session = nil
    }
  }
}

nonisolated final class MemorySessions: SessionStore {
  private let kept = Mutex<Session?>(nil)

  func load() throws(KeychainError) -> Session? { kept.withLock { $0 } }
  func save(_ session: Session) throws(KeychainError) { kept.withLock { $0 = session } }
  func remove() throws(KeychainError) { kept.withLock { $0 = nil } }
}

nonisolated final class MemoryOwnKeys: OwnKeyStore {
  private let kept = Mutex<OwnKey?>(nil)

  func load() throws(KeychainError) -> OwnKey? { kept.withLock { $0 } }

  func save(_ key: OwnKey) throws(KeychainError) {
    try kept.withLock { kept throws(KeychainError) in
      guard kept == nil else { throw .alreadyKept }
      kept = key
    }
  }

  func replace(with key: OwnKey) throws(KeychainError) { kept.withLock { $0 = key } }
}
