import Foundation
import Sync
import Testing

/// `SyncAccount`'s branches the Worker can't easily be made to take: answers it gives only when
/// another device acts in between, a server that can't be reached, and what Apple says. The usual
/// paths run on the Worker in `AccountContractTests`.
struct SyncAccountTests {
  private let session = Session(token: "s1.x.y", account: UUID(), appleUser: "user")
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
    let apple = ScriptedApple(bought: [])
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
}
