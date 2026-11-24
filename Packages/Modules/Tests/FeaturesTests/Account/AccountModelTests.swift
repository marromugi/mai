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

  private func model(
    _ answers: [String: [ScriptedWorker.Answer]], apple: ScriptedApple = ScriptedApple()
  ) throws -> AccountModel {
    let defaults = try #require(UserDefaults(suiteName: suite))
    let kept = KeptAccountID(defaults: defaults)
    kept.keep(bought)
    return AccountModel(
      account: SyncAccount(
        server: AccountServer(
          url: try #require(URL(string: "https://worker.test")),
          transport: ScriptedWorker(answers)),
        apple: apple, purchases: apple, sessions: MemorySessions(), ownKeys: MemoryOwnKeys()),
      kept: kept)
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
    #expect(model.problem == AccountError.server(.unreachable(URLError(.badURL))).errorDescription)
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

  init(_ answers: [String: [Answer]]) {
    self.answers = Mutex(answers)
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
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
