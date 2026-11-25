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

  @Test func signingInWithNoPurchaseAsksTheServerForASessionOnly() async throws {
    let account = UUID()
    let server = ScriptedServer([
      "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
      "POST /sessions": [
        .status(200, json: #"{"account":"\#(account.uuidString.lowercased())","token":"s1.a.b"}"#)
      ],
    ])
    let apple = ScriptedApple(bought: .failure(URLError(.notConnectedToInternet)))
    let signedIn = try await self.account(server, apple: apple).signIn()
    #expect(signedIn == Session(token: "s1.a.b", account: account, appleUser: ScriptedApple.user))
    #expect(try sessions.load() == signedIn)
    #expect(server.routes() == ["POST /challenges", "POST /sessions"])
  }

  @Test func signingInWithNoPurchaseToNoAccountKeepsNoSession() async throws {
    let server = ScriptedServer([
      "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
      "POST /sessions": [.status(404)],
    ])
    await #expect {
      try await account(server).signIn()
    } throws: { error in
      guard case .noAccount = error as? AccountError else { return false }
      return true
    }
    #expect(try sessions.load() == nil)
  }

  @Test func startingOverSendsTheKeyHeldInPlaceOfTheCheckRead() async throws {
    let held = OwnKey.generate()
    let ownKeys = MemoryOwnKeys(held)
    let server = ScriptedServer(["PUT /account/own-key-check": [.status(204)]])
    let check = Data(repeating: 0xab, count: 32)
    let outcome = try await account(server, ownKeys: ownKeys).startOver(session, replacing: check)
    #expect(outcome == .made(RecoveryKey(held)))
    #expect(try ownKeys.load() == held)
    let sent = try #require(server.requests.first)
    #expect(
      sent.value(forHTTPHeaderField: "Mai-Replaces-Own-Key-Check")
        == String(repeating: "ab", count: 32))
    #expect(sent.httpBody == held.check)
    #expect(server.routes() == ["PUT /account/own-key-check"])
  }

  @Test func startingOverWithNoKeyHeldKeepsANewOneBeforeSendingIt() async throws {
    let ownKeys = MemoryOwnKeys()
    let server = ScriptedServer([:])
    await #expect(throws: AccountError.self) {
      try await account(server, ownKeys: ownKeys).startOver(session, replacing: Data(count: 32))
    }
    let made = try #require(try ownKeys.load())
    #expect(server.requests.first?.httpBody == made.check)
  }

  /// The first start over reached the server but its answer didn't reach the device: the second
  /// sends the same key, which the server says is done.
  @Test func aStartOverSentAgainSendsTheSameKey() async throws {
    let ownKeys = MemoryOwnKeys()
    let server = ScriptedServer(["PUT /account/own-key-check": [.unreachable, .status(204)]])
    let account = try account(server, ownKeys: ownKeys)
    await #expect(throws: AccountError.self) {
      try await account.startOver(session, replacing: Data(count: 32))
    }
    let outcome = try await account.startOver(session, replacing: Data(count: 32))
    let made = try #require(try ownKeys.load())
    #expect(outcome == .made(RecoveryKey(made)))
    #expect(server.requests.map(\.httpBody) == [made.check, made.check])
  }

  @Test func aCheckChangedSinceItWasReadStartsNothingOver() async throws {
    let held = OwnKey.generate()
    let ownKeys = MemoryOwnKeys(held)
    let server = ScriptedServer(["PUT /account/own-key-check": [.status(409)]])
    await #expect {
      try await account(server, ownKeys: ownKeys).startOver(session, replacing: Data(count: 32))
    } throws: { error in
      guard case .ownKeyChanged = error as? AccountError else { return false }
      return true
    }
    #expect(try ownKeys.load() == held)
  }

  @Test func aKeyHeldThatIsTheAccountsStartsNothingOver() async throws {
    let held = OwnKey.generate()
    let server = ScriptedServer([:])
    let outcome = try await account(server, ownKeys: MemoryOwnKeys(held)).startOver(
      session, replacing: held.check)
    #expect(outcome == .ready)
    #expect(server.requests.isEmpty)
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
    (
      .signInNeededToDelete,
      "サインインが切れたため、アカウントを削除できませんでした。もう一度 Apple でサインインしてから削除してください。"
    ),
    (.notForgotten(.failed(-25308)), "アカウントは削除しましたが、この端末のサインインの情報を消せませんでした。"),
    (
      .purchaseIsAnotherAccounts,
      "この端末の App Store で買ったプランは、別の Apple アカウントの同期のアカウントのものです。プランを買ったときの Apple アカウントでサインインするか、この端末の App Store を自分のアカウントにして、プランに入り直してください。"
    ),
    (
      .noAccount,
      "この Apple アカウントには、同期のアカウントがありません。ほかの端末でプランに入ったときと同じ Apple アカウントでサインインするか、プランに入ってください。"
    ),
    (.ownKeyChanged, "ほかの端末で自分の鍵が変わったため、サーバーの文書は消していません。"),
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

  /// A sync state directory holding a state file for the signed-in account and for another one.
  private func syncStates() throws -> (directory: URL, mine: URL, other: URL) {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let mine = directory.appending(path: "\(session.account.uuidString.lowercased()).json")
    let other = directory.appending(path: "\(UUID().uuidString.lowercased()).json")
    try Data("{}".utf8).write(to: mine)
    try Data("{}".utf8).write(to: other)
    return (directory, mine, other)
  }

  @Test func deletingTheAccountForgetsItsSessionAndSyncState() async throws {
    let server = ScriptedServer(["DELETE /account": [.status(204)]])
    let ownKeys = MemoryOwnKeys(OwnKey.generate())
    let account = try signedIn().account(server, ownKeys: ownKeys)
    let states = try syncStates()
    defer { try? FileManager.default.removeItem(at: states.directory) }

    try await account.deleteAccount(syncStateIn: states.directory)
    #expect(server.routes() == ["DELETE /account"])
    #expect(
      server.requests.first?.value(forHTTPHeaderField: "Authorization")
        == "Bearer \(session.token)")
    #expect(try sessions.load() == nil)
    #expect(!FileManager.default.fileExists(atPath: states.mine.path()))
    #expect(FileManager.default.fileExists(atPath: states.other.path()))
  }

  @Test func anAccountNeverSyncedIsDeletedAllTheSame() async throws {
    let account = try signedIn().account(ScriptedServer(["DELETE /account": [.status(204)]]))
    try await account.deleteAccount(
      syncStateIn: FileManager.default.temporaryDirectory.appending(
        path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory))
    #expect(try sessions.load() == nil)
  }

  /// 200 included: the Worker answers a deletion with 204 only.
  @Test(arguments: [ScriptedServer.Answer.status(502), .status(200), .unreachable])
  func anAccountTheServerDidntDeleteIsKeptOnTheDevice(_ answer: ScriptedServer.Answer)
    async throws
  {
    let key = OwnKey.generate()
    let ownKeys = MemoryOwnKeys(key)
    let account = try signedIn().account(
      ScriptedServer(["DELETE /account": [answer]]), ownKeys: ownKeys)
    let states = try syncStates()
    defer { try? FileManager.default.removeItem(at: states.directory) }

    await #expect {
      try await account.deleteAccount(syncStateIn: states.directory)
    } throws: { error in
      guard case .server = error as? AccountError else { return false }
      return true
    }
    #expect(try sessions.load() == session)
    #expect(try ownKeys.load() == key)
    #expect(FileManager.default.fileExists(atPath: states.mine.path()))
  }

  /// The server can't say whether the account is gone, so only the session is dropped.
  @Test func deletingWithASessionTheServerEndedDropsOnlyTheSession() async throws {
    let key = OwnKey.generate()
    let ownKeys = MemoryOwnKeys(key)
    let account = try signedIn().account(
      ScriptedServer(["DELETE /account": [.status(401)]]), ownKeys: ownKeys)
    let states = try syncStates()
    defer { try? FileManager.default.removeItem(at: states.directory) }

    await #expect {
      try await account.deleteAccount(syncStateIn: states.directory)
    } throws: { error in
      guard case .signInNeededToDelete = error as? AccountError else { return false }
      return true
    }
    #expect(try sessions.load() == nil)
    #expect(try ownKeys.load() == key)
    #expect(FileManager.default.fileExists(atPath: states.mine.path()))
  }

  @Test func deletingWithNoSessionKeptAsksForASignInAndSendsNothing() async throws {
    let server = ScriptedServer(["DELETE /account": [.status(204)]])
    await #expect {
      try await account(server).deleteAccount(
        syncStateIn: FileManager.default.temporaryDirectory)
    } throws: { error in
      guard case .signInNeededToDelete = error as? AccountError else { return false }
      return true
    }
    #expect(server.routes().isEmpty)
  }

  /// Deleted on the server, a session the keychain won't remove says so, apart from a deletion
  /// that didn't happen.
  @Test func anAccountDeletedWhoseSessionCantBeRemovedSaysSo() async throws {
    let sessions = UnremovableSessions(session)
    let account = SyncAccount(
      server: AccountServer(
        url: try #require(URL(string: "https://worker.test")),
        transport: ScriptedServer(["DELETE /account": [.status(204)]])),
      apple: ScriptedApple(), purchases: ScriptedApple(), sessions: sessions,
      ownKeys: MemoryOwnKeys())
    await #expect {
      try await account.deleteAccount(syncStateIn: FileManager.default.temporaryDirectory)
    } throws: { error in
      guard case .notForgotten = error as? AccountError else { return false }
      return true
    }
  }
}

/// Holds one session, and refuses to remove it.
private final class UnremovableSessions: SessionStore {
  let session: Session

  init(_ session: Session) {
    self.session = session
  }

  func load() throws(KeychainError) -> Session? { session }
  func save(_ session: Session) throws(KeychainError) {}
  func remove() throws(KeychainError) { throw .failed(-25308) }
}
