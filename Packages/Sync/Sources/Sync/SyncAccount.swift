import CryptoKit
import Foundation
import os

/// Where the account's steps log what went wrong but goes on.
let syncLogger = Logger(subsystem: "com.marromugi.mai", category: "sync")

/// Where the device's own key stands with the account, once signed in.
public enum OwnKeyOutcome: Sendable, Equatable {
  /// The device holds the account's own key.
  case ready
  /// The account had no own key: the device's key, made now or kept from a settling cut short
  /// before its check was put, became the account's, and its recovery key is to be shown.
  case made(RecoveryKey)
  /// The account's own key isn't on this device; it comes back from the recovery key.
  case recoveryKeyNeeded
}

/// What `SyncAccount.check()` found.
public enum AccountCheck: Sendable, Equatable {
  case signedOut
  /// Apple says the user no longer signs in with Apple here: the session was ended.
  case credentialRevoked
  /// The server no longer lets the session in: it was dropped from the device.
  case sessionEnded
  /// The subscriptions bought for the account, this many, were sent again.
  case subscriptionsSent(Int)
}

/// The session and the own key a sync runs with.
public struct SyncKeys: Sendable, Equatable {
  public let session: Session
  public let ownKey: OwnKey
}

/// The account a plan pays for, from this device: signing in after a purchase, the own key, the
/// check at each launch, and signing out (#22's design, §1 and §3).
public struct SyncAccount: Sendable {
  let server: AccountServer
  let apple: any AppleSignIn
  let purchases: any Purchases
  let sessions: any SessionStore
  let ownKeys: any OwnKeyStore

  public init(
    server: AccountServer, apple: any AppleSignIn, purchases: any Purchases,
    sessions: any SessionStore, ownKeys: any OwnKeyStore
  ) {
    self.server = server
    self.apple = apple
    self.purchases = purchases
    self.sessions = sessions
    self.ownKeys = ownKeys
  }

  /// The session kept on the device, nil when signed out.
  public func session() throws(AccountError) -> Session? {
    do {
      return try sessions.load()
    } catch {
      throw .keychain(error)
    }
  }

  /// Whether a plan bought for `account` is current on this App Store account: false while a
  /// purchase waits for approval.
  public func isBought(_ account: UUID) async throws(AccountError) -> Bool {
    try await !subscriptions(for: account).isEmpty
  }

  /// Signs in with Apple for `account`, which a plan was bought for, making the account on the
  /// server, and keeps the session. When the Apple user or the account has one already, the person
  /// signs in with Apple a second time, since a challenge serves one request, and gets a session
  /// of the Apple user's account, which may not be `account`.
  public func signIn(for account: UUID) async throws(AccountError) -> Session {
    guard let purchase = try await subscriptions(for: account).first else {
      throw .noPurchase
    }
    let challenge = try await serverCall { () async throws(ServerError) in
      try await server.challenge()
    }
    let credential = try await credential(for: challenge)
    if let token = try await serverCall({ () async throws(ServerError) in
      try await server.makeAccount(
        account, challenge: challenge, credential: credential, transaction: purchase.transaction)
    }) {
      return try keep(Session(token: token, account: account, appleUser: credential.user))
    }
    let second = try await serverCall { () async throws(ServerError) in try await server.challenge()
    }
    let again = try await self.credential(for: second)
    guard
      let started = try await serverCall({ () async throws(ServerError) in
        try await server.startSession(challenge: second, credential: again)
      })
    else {
      throw .purchaseIsAnotherAccounts
    }
    return try keep(Session(token: started.token, account: started.account, appleUser: again.user))
  }

  /// Settles the own key against the account's own key check in `state`, the account as just read
  /// with `session` (`Server/README.md`, `GET /account`). A key is made only when the account has
  /// none and neither has the device; it is kept before its check is put, so a check is never put
  /// for a key nobody holds.
  public func settleOwnKey(_ session: Session, against state: AccountState)
    async throws(AccountError) -> OwnKeyOutcome
  {
    let kept = try keychain { () throws(KeychainError) in try ownKeys.load() }
    switch (kept, state.ownKeyCheck) {
    case (let key?, let check?):
      return key.check == check ? .ready : .recoveryKeyNeeded
    case (nil, .some):
      return .recoveryKeyNeeded
    case (let key?, nil):
      return try await putCheck(of: key, session) ? .made(RecoveryKey(key)) : .recoveryKeyNeeded
    case (nil, nil):
      let key = OwnKey.generate()
      try keychain { () throws(KeychainError) in try ownKeys.save(key) }
      return try await putCheck(of: key, session) ? .made(RecoveryKey(key)) : .recoveryKeyNeeded
    }
  }

  /// What the server says of the account now: its plan, whether it is paid for, and what it used.
  public func state(_ session: Session) async throws(AccountError) -> AccountState {
    try await serverCall { () async throws(ServerError) in
      try await server.account(token: session.token)
    }
  }

  /// Brings back the own key from the recovery key `text`, once it is the account's: kept in place
  /// of a key the device held that isn't.
  public func restore(from text: String, _ session: Session) async throws(AccountError) {
    let key: OwnKey
    do {
      key = try RecoveryKey(text: text).ownKey
    } catch {
      throw .recoveryKey(error)
    }
    let state = try await serverCall { () async throws(ServerError) in
      try await server.account(token: session.token)
    }
    if let check = state.ownKeyCheck {
      guard check == key.check else { throw .notTheAccountsKey }
    } else if try await !putCheck(of: key, session) {
      throw .notTheAccountsKey
    }
    let kept = try keychain { () throws(KeychainError) in try ownKeys.load() }
    if kept == nil {
      try keychain { () throws(KeychainError) in try ownKeys.save(key) }
    } else if kept != key {
      try keychain { () throws(KeychainError) in try ownKeys.replace(with: key) }
    }
  }

  /// At each launch, and when StoreKit tells of a new transaction: ends the session when Apple says
  /// the user stopped signing in with Apple here, and otherwise sends the account's subscriptions
  /// again, catching what the server missed.
  public func check() async throws(AccountError) -> AccountCheck {
    guard let session = try session() else { return .signedOut }
    let state: AppleCredentialState
    do {
      state = try await apple.credentialState(of: session.appleUser)
    } catch {
      // Unknown, such as offline, is taken as still signed in.
      syncLogger.error("Apple's credential state couldn't be read: \(error)")
      state = .authorized
    }
    if state == .revoked || state == .notFound {
      do {
        try await server.endSession(token: session.token)
      } catch .refused(status: 401, _) {
        // Ended already.
      } catch {
        // Dropped from the device all the same: Apple no longer lets this user in here. The
        // server's session lapses after 180 days unused.
        syncLogger.error("The session of a revoked Apple user couldn't be ended: \(error)")
      }
      try keychain { () throws(KeychainError) in try sessions.remove() }
      return .credentialRevoked
    }
    var sent = 0
    for subscription in try await subscriptions(for: session.account) {
      do {
        try await server.send(subscription, token: session.token)
      } catch .refused(status: 401, _) {
        try keychain { () throws(KeychainError) in try sessions.remove() }
        return .sessionEnded
      } catch {
        throw .server(error)
      }
      sent += 1
    }
    return .subscriptionsSent(sent)
  }

  /// What a sync of the account's writings runs with: the session and the own key kept on the
  /// device; nil while either is missing. Whether the key is the account's is `settleOwnKey`'s.
  public func syncKeys() throws(AccountError) -> SyncKeys? {
    guard let session = try session(),
      let ownKey = try keychain({ () throws(KeychainError) in try ownKeys.load() })
    else { return nil }
    return SyncKeys(session: session, ownKey: ownKey)
  }

  /// Syncs `writings` with the account's writings on the server, sealed with `keys.ownKey`. Its
  /// state is kept in `stateDirectory`, one file per account. Syncs run one after the other only
  /// on the same `Synchronizer`, so one is kept per `SyncKeys`.
  public func synchronizer(
    writings: any PlainWritingStore, stateDirectory: URL, keys: SyncKeys
  ) -> Synchronizer {
    Synchronizer(
      writings: writings,
      stateFile: Self.syncStateFile(of: keys.session.account, in: stateDirectory),
      server: WritingServer(
        url: server.url, token: keys.session.token, transport: server.transport),
      ownKey: keys.ownKey)
  }

  /// Ends the session on the server, then on the device. Kept when the server can't be reached,
  /// so the person can try again.
  public func signOut() async throws(AccountError) {
    guard let session = try session() else { return }
    do {
      try await server.endSession(token: session.token)
    } catch .refused(status: 401, _) {
      // Ended already.
    } catch {
      throw .server(error)
    }
    try keychain { () throws(KeychainError) in try sessions.remove() }
  }

  /// Deletes the account on the server (`DELETE /account`), then forgets it on the device: the
  /// session, the own key, and the sync's state of it in `stateDirectory`. Nothing is deleted
  /// when the server can't delete it, so the person can try again. A session the server no longer
  /// lets in is dropped from the device, and the account kept, since the server can't say whether
  /// it is gone.
  public func deleteAccount(syncStateIn stateDirectory: URL) async throws(AccountError) {
    guard let session = try session() else { return }
    do {
      try await server.deleteAccount(token: session.token)
    } catch .refused(status: 401, _) {
      try keychain { () throws(KeychainError) in try sessions.remove() }
      throw .signInNeededToDelete
    } catch {
      throw .server(error)
    }
    try keychain { () throws(KeychainError) in try sessions.remove() }
    try keychain { () throws(KeychainError) in try ownKeys.remove() }
    do {
      try FileManager.default.removeItem(
        at: Self.syncStateFile(of: session.account, in: stateDirectory))
    } catch CocoaError.fileNoSuchFile {
      // Never synced.
    } catch {
      // Left behind, it only makes a later sync of the same account ID send every writing again.
      syncLogger.error("The sync state of a deleted account couldn't be removed: \(error)")
    }
  }

  /// Where the sync of `account` keeps its state, in `stateDirectory`.
  static func syncStateFile(of account: UUID, in stateDirectory: URL) -> URL {
    stateDirectory.appending(
      path: "\(account.uuidString.lowercased()).json", directoryHint: .notDirectory)
  }

  private func credential(for challenge: String) async throws(AccountError) -> AppleCredential {
    let nonce = SHA256.hash(data: Data(challenge.utf8)).map { String(format: "%02x", $0) }
      .joined()
    do {
      return try await apple.signIn(nonce: nonce)
    } catch is CancellationError {
      throw .cancelled
    } catch {
      throw .apple(error)
    }
  }

  private func subscriptions(for account: UUID) async throws(AccountError)
    -> [SignedSubscription]
  {
    do {
      return try await purchases.subscriptions(for: account)
    } catch {
      throw .appStore(error)
    }
  }

  private func putCheck(of key: OwnKey, _ session: Session) async throws(AccountError) -> Bool {
    try await serverCall { () async throws(ServerError) in
      try await server.keepOwnKeyCheck(key.check, token: session.token)
    }
  }

  private func keep(_ session: Session) throws(AccountError) -> Session {
    try keychain { () throws(KeychainError) in try sessions.save(session) }
    return session
  }

  private func serverCall<T>(_ call: () async throws(ServerError) -> T) async throws(AccountError)
    -> T
  {
    do {
      return try await call()
    } catch {
      throw .server(error)
    }
  }

  private func keychain<T>(_ call: () throws(KeychainError) -> T) throws(AccountError) -> T {
    do {
      return try call()
    } catch {
      throw .keychain(error)
    }
  }
}

public enum AccountError: LocalizedError {
  case server(ServerError)
  case keychain(KeychainError)
  /// The person cancelled Sign in with Apple.
  case cancelled
  case apple(any Error)
  /// The App Store's purchases couldn't be read.
  case appStore(any Error)
  /// No plan bought for the account is on this App Store account.
  case noPurchase
  /// The server refused the purchase as another account's, and the Apple user has no account.
  case purchaseIsAnotherAccounts
  case recoveryKey(RecoveryKeyError)
  /// The recovery key is of another own key than the account's.
  case notTheAccountsKey
  /// The server no longer let the session in to delete the account; the session was dropped.
  case signInNeededToDelete

  public var errorDescription: String? {
    switch self {
    case .server(.unreachable):
      "サーバーにつながりませんでした。ネットワークを確かめて、もう一度お試しください。"
    case .server:
      "サーバーで問題が起きました。しばらくしてから、もう一度お試しください。"
    case .keychain(let error):
      error.localizedDescription
    case .cancelled:
      "サインインを取りやめました。"
    case .apple:
      "Apple でサインインできませんでした。もう一度お試しください。"
    case .appStore:
      "App Store から購入を読めませんでした。しばらくしてから、もう一度お試しください。"
    case .noPurchase:
      "この App Store のアカウントには、同期のプランの購入が見つかりませんでした。"
    case .purchaseIsAnotherAccounts:
      "このプランの購入は、別の Apple アカウントのものです。購入した Apple アカウントでサインインしてください。"
    case .recoveryKey(let error):
      error.localizedDescription
    case .notTheAccountsKey:
      "このリカバリーキーは、このアカウントの鍵ではありません。"
    case .signInNeededToDelete:
      "サインインが切れたため、アカウントを削除できませんでした。もう一度 Apple でサインインしてから削除してください。"
    }
  }
}
