import Foundation
import Sync
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

  /// Holds the first request to the route `holding` until `release()`.
  init(_ answers: [String: [Answer]], holding: String? = nil) {
    self.answers = Mutex(answers)
    self.holding = holding
  }

  /// How many requests to the held route came.
  var heldCount: Int { held.withLock { $0.count } }
  var isHolding: Bool { held.withLock { $0.gate != nil } }

  func release() {
    held.withLock { $0.gate?.resume() }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
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
    let hex = check.map { "\"\($0.map { String(format: "%02x", $0) }.joined())\"" } ?? "null"
    return .status(
      200, json: #"{"plan":"basic","paidUntil":1,"lapsed":false,"ownKeyCheck":"# + hex + "}")
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
