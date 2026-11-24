import Foundation
import Sync
import SyncFakes
import Testing

/// `SyncAccount`'s branches the Worker can't easily be made to take: answers it gives only when
/// another device acts in between, a server that can't be reached, and what Apple says. The usual
/// paths run on the Worker in `AccountContractTests`.
struct SyncAccountTests {
  private let session = Session(token: "s1.x.y", account: UUID(), appleUser: "000456.signed-in")
  private let sessions = MemorySessions()

  private func account(
    _ server: ScriptedServer, apple: ScriptedApple = ScriptedApple(),
    ownKeys: MemoryOwnKeys = MemoryOwnKeys()
  ) throws -> SyncAccount {
    SyncAccount(
      server: AccountServer(
        url: try #require(URL(string: "https://worker.test")), transport: server),
      apple: apple, purchases: apple, sessions: sessions, ownKeys: ownKeys)
  }

  private func signedIn() throws -> Self {
    try sessions.save(session)
    return self
  }

  @Test func aCredentialAppleNoLongerKnowsEndsTheSession() async throws {
    let server = ScriptedServer(["DELETE /session": [.status(204)]])
    let account = try signedIn().account(server, apple: ScriptedApple(state: .success(.notFound)))
    #expect(try await account.check() == .credentialRevoked)
    #expect(try sessions.load() == nil)
    #expect(server.routes() == ["DELETE /session"])
  }

  @Test func aRevokedCredentialIsDroppedEvenWhenTheServerCantBeReached() async throws {
    let server = ScriptedServer([:])
    let account = try signedIn().account(server, apple: ScriptedApple(state: .success(.revoked)))
    #expect(try await account.check() == .credentialRevoked)
    #expect(try sessions.load() == nil)
  }

  @Test func aCredentialStateNotReadIsTakenAsSignedIn() async throws {
    let server = ScriptedServer(["PUT /account/subscription": [.status(200)]])
    let apple = ScriptedApple(state: .failure(URLError(.notConnectedToInternet)))
    let account = try signedIn().account(server, apple: apple)
    #expect(try await account.check() == .subscriptionsSent(1))
    #expect(try sessions.load() == session)
  }

  @Test func signingOutKeepsTheSessionWhenTheServerCantBeReached() async throws {
    let account = try signedIn().account(ScriptedServer([:]))
    await #expect(throws: AccountError.self) { try await account.signOut() }
    #expect(try sessions.load() == session)
  }

  @Test func signingOutOfASessionTheServerEndedDropsIt() async throws {
    let account = try signedIn().account(ScriptedServer(["DELETE /session": [.status(401)]]))
    try await account.signOut()
    #expect(try sessions.load() == nil)
  }

  @Test func theDevicesKeyBecomesTheAccountsWhenItHasNoneAndItsRecoveryKeyIsShown() async throws {
    let key = OwnKey.generate()
    let server = ScriptedServer([
      "GET /account": [ScriptedServer.account(check: nil)],
      "PUT /account/own-key-check": [.status(204)],
    ])
    let account = try account(server, ownKeys: MemoryOwnKeys(key))
    #expect(try await account.settleOwnKey(session) == .made(RecoveryKey(key)))
    #expect(server.requests.last?.httpBody == key.check)
  }

  @Test func theDevicesKeyIsNotTheAccountsWhenAnotherDevicePutItsCheckFirst() async throws {
    let key = OwnKey.generate()
    let server = ScriptedServer([
      "GET /account": [ScriptedServer.account(check: nil)],
      "PUT /account/own-key-check": [.status(409)],
    ])
    let account = try account(server, ownKeys: MemoryOwnKeys(key))
    #expect(try await account.settleOwnKey(session) == .recoveryKeyNeeded)
  }

  @Test func aKeyMadeAsAnotherDevicePutsItsCheckFirstAsksForTheRecoveryKey() async throws {
    let ownKeys = MemoryOwnKeys()
    let server = ScriptedServer([
      "GET /account": [ScriptedServer.account(check: nil)],
      "PUT /account/own-key-check": [.status(409)],
    ])
    let account = try account(server, ownKeys: ownKeys)
    #expect(try await account.settleOwnKey(session) == .recoveryKeyNeeded)
    #expect(try ownKeys.load() != nil)
  }

  /// The check of a key made didn't reach the server; the next settling puts it, and shows the
  /// key's recovery key then.
  @Test func aKeyMadeWhoseCheckWasNotPutIsShownTheNextTime() async throws {
    let ownKeys = MemoryOwnKeys()
    let server = ScriptedServer([
      "GET /account": [ScriptedServer.account(check: nil), ScriptedServer.account(check: nil)],
      "PUT /account/own-key-check": [.unreachable, .status(204)],
    ])
    let account = try account(server, ownKeys: ownKeys)
    await #expect(throws: AccountError.self) { try await account.settleOwnKey(session) }
    let made = try #require(try ownKeys.load())
    #expect(try await account.settleOwnKey(session) == .made(RecoveryKey(made)))
  }

  @Test func aRecoveryKeyForAnAccountWithNoCheckPutsItsCheck() async throws {
    let key = OwnKey.generate()
    let ownKeys = MemoryOwnKeys()
    let server = ScriptedServer([
      "GET /account": [ScriptedServer.account(check: nil)],
      "PUT /account/own-key-check": [.status(204)],
    ])
    try await account(server, ownKeys: ownKeys).restore(from: RecoveryKey(key).text, session)
    #expect(try ownKeys.load() == key)
    #expect(server.requests.last?.httpBody == key.check)
  }

  @Test func aRecoveryKeyIsRefusedWhenAnotherDevicePutItsCheckFirst() async throws {
    let ownKeys = MemoryOwnKeys()
    let server = ScriptedServer([
      "GET /account": [ScriptedServer.account(check: nil)],
      "PUT /account/own-key-check": [.status(409)],
    ])
    await #expect {
      try await account(server, ownKeys: ownKeys)
        .restore(from: RecoveryKey(OwnKey.generate()).text, session)
    } throws: { error in
      guard case .notTheAccountsKey = error as? AccountError else { return false }
      return true
    }
    #expect(try ownKeys.load() == nil)
  }

  @Test func signingInWithNoPlanBoughtAsksNothingOfAppleOrTheServer() async throws {
    let server = ScriptedServer([:])
    let apple = ScriptedApple(bought: .success([]))
    let account = try account(server, apple: apple)
    #expect(try await !account.isBought(UUID()))
    await #expect {
      try await account.signIn(for: UUID())
    } throws: { error in
      guard case .noPurchase = error as? AccountError else { return false }
      return true
    }
    #expect(apple.signInsAsked == 0)
    #expect(server.requests.isEmpty)
  }

  /// The session keeps the Apple user who signed in, and the check at launch asks Apple of them.
  @Test func theCheckAsksAppleOfTheUserWhoSignedIn() async throws {
    let apple = ScriptedApple()
    let server = ScriptedServer([
      "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
      "POST /account": [.status(201, json: #"{"token":"s1.a.b"}"#)],
      "PUT /account/subscription": [.status(200)],
    ])
    let account = try account(server, apple: apple)
    let signedIn = try await account.signIn(for: UUID())
    #expect(signedIn.appleUser == ScriptedApple.user)
    _ = try await account.check()
    #expect(apple.usersAsked == [ScriptedApple.user])
  }

  @Test func aSubscriptionTheServerFailsOnIsSaidAndTheSessionKept() async throws {
    let account = try signedIn().account(
      ScriptedServer(["PUT /account/subscription": [.status(500)]]))
    await #expect {
      try await account.check()
    } throws: { error in
      guard case .server(.refused(status: 500, _)) = error as? AccountError else { return false }
      return true
    }
    #expect(try sessions.load() == session)
  }

  @Test func purchasesNotReadAreSaidAsTheAppStores() async throws {
    let apple = ScriptedApple(bought: .failure(URLError(.notConnectedToInternet)))
    await #expect {
      try await account(ScriptedServer([:]), apple: apple).isBought(UUID())
    } throws: { error in
      guard case .appStore = error as? AccountError else { return false }
      return true
    }
  }

  @Test func anOwnKeyCheckOfOddLengthIsNotTakenAsHex() async throws {
    let server = ScriptedServer([
      "GET /account": [
        .status(
          200,
          json: accountAnswer(check: nil).replacing(
            #""ownKeyCheck":null"#, with: #""ownKeyCheck":"abc""#))
      ]
    ])
    await #expect {
      try await account(server).settleOwnKey(session)
    } throws: { error in
      guard case .server(.unexpectedAnswer) = error as? AccountError else { return false }
      return true
    }
  }

  @Test(arguments: [
    (
      AccountError.server(.unreachable(URLError(.notConnectedToInternet))),
      "サーバーにつながりませんでした。ネットワークを確かめて、もう一度お試しください。"
    ),
    (.server(.refused(status: 500, reason: "x")), "サーバーで問題が起きました。しばらくしてから、もう一度お試しください。"),
    (.appStore(URLError(.notConnectedToInternet)), "App Store から購入を読めませんでした。しばらくしてから、もう一度お試しください。"),
    (.noPurchase, "この App Store のアカウントには、同期のプランの購入が見つかりませんでした。"),
    (.notTheAccountsKey, "このリカバリーキーは、このアカウントの鍵ではありません。"),
  ])
  func tellsAPersonWhatWentWrong(_ error: AccountError, _ message: String) {
    #expect(error.localizedDescription == message)
  }

  /// The sync sends the session's token and keeps its state in a file named by the account, so
  /// each account syncs from its own record.
  @Test func aSyncRunsWithTheSessionAndKeepsTheAccountsOwnState() async throws {
    let ownKey = OwnKey.generate()
    let fake = FakeWritingServer(accepting: session.token)
    let account = SyncAccount(
      server: AccountServer(url: try #require(URL(string: "https://worker.test")), transport: fake),
      apple: ScriptedApple(), purchases: ScriptedApple(), sessions: sessions,
      ownKeys: MemoryOwnKeys(ownKey))
    try sessions.save(session)
    let keys = try #require(try account.syncKeys())
    #expect(keys.session == session)
    #expect(keys.ownKey == ownKey)
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let writings = MemoryWritingStore()
    try writings.save(
      PlainWriting(id: UUID(), updated: .init(timeIntervalSince1970: 1_000), contents: Data()))

    let synchronizer = account.synchronizer(
      writings: writings, stateDirectory: directory, keys: keys)
    #expect(try await synchronizer.sync().sent.count == 1)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: directory.path())
        == ["\(session.account.uuidString.lowercased()).json"])
  }
}
