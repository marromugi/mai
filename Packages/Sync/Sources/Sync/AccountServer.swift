import Foundation

/// What the server says of an account (`GET /account`), as far as the device uses it.
public struct AccountState: Sendable, Equatable {
  /// The server's `plans.tier`.
  public let plan: String
  /// Milliseconds since 1970.
  public let paidUntil: Int64
  /// Nil until a device has put one.
  public let ownKeyCheck: Data?
}

/// The client of the Worker's account and sign-in routes (`Server/README.md`).
public struct AccountServer: Sendable {
  let url: URL
  let transport: any HTTPTransport

  public init(url: URL, transport: any HTTPTransport = URLSession.shared) {
    self.url = url
    self.transport = transport
  }

  /// A challenge, whose SHA-256 is the nonce Sign in with Apple is asked with.
  public func challenge() async throws(ServerError) -> String {
    var request = URLRequest(url: url.appending(path: "challenges"))
    request.httpMethod = "POST"
    let (data, _) = try await transport.answer(request, expecting: [201])
    return try decode(Challenge.self, from: data).challenge
  }

  /// Makes `account` for the Apple user of `credential`, asked with `challenge`, and paid for by
  /// `transaction`, and gives back its session token. Nil when the server refuses with 409: the
  /// Apple user or the account has an account already, or the purchase is another account's.
  public func makeAccount(
    _ account: UUID, challenge: String, credential: AppleCredential, transaction: String
  ) async throws(ServerError) -> String? {
    let request = try json(
      "account",
      MadeAccount(
        account: account.uuidString.lowercased(), challenge: challenge,
        identityToken: credential.identityToken,
        authorizationCode: credential.authorizationCode, transaction: transaction))
    let (data, response) = try await transport.answer(request, expecting: [201, 409])
    guard response.statusCode == 201 else { return nil }
    return try decode(Token.self, from: data).token
  }

  /// A session of the account of the Apple user of `credential`, asked with `challenge`; nil when
  /// the user has none. The authorization code goes along, for the server to keep Apple's newest
  /// refresh token.
  public func startSession(challenge: String, credential: AppleCredential)
    async throws(ServerError) -> (account: UUID, token: String)?
  {
    let request = try json(
      "sessions",
      StartedSession(
        challenge: challenge, identityToken: credential.identityToken,
        authorizationCode: credential.authorizationCode))
    let (data, response) = try await transport.answer(request, expecting: [200, 404])
    guard response.statusCode == 200 else { return nil }
    let started = try decode(SessionStarted.self, from: data)
    guard let account = UUID(uuidString: started.account) else {
      throw .unexpectedAnswer("a session came for an account ID that isn't a UUID")
    }
    return (account, started.token)
  }

  public func account(token: String) async throws(ServerError) -> AccountState {
    let (data, _) = try await transport.answer(
      authorized(URLRequest(url: url.appending(path: "account")), token), expecting: [200])
    let read = try decode(ReadAccount.self, from: data)
    var check: Data?
    if let hex = read.ownKeyCheck {
      guard let bytes = Data(hex: hex) else {
        throw .unexpectedAnswer("the own key check isn't hex")
      }
      check = bytes
    }
    return AccountState(
      plan: read.plan, paidUntil: read.paidUntil, ownKeyCheck: check)
  }

  /// Puts the account's own key check; false when the account has another one.
  public func keepOwnKeyCheck(_ check: Data, token: String) async throws(ServerError) -> Bool {
    var request = authorized(URLRequest(url: url.appending(path: "account/own-key-check")), token)
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = check
    let (_, response) = try await transport.answer(request, expecting: [204, 409])
    return response.statusCode == 204
  }

  /// Sends a subscription as StoreKit has it now (`PUT /account/subscription`).
  public func send(_ subscription: SignedSubscription, token: String) async throws(ServerError) {
    var request = authorized(
      try json(
        "account/subscription",
        SentSubscription(
          transaction: subscription.transaction, renewalInfo: subscription.renewalInfo)),
      token)
    request.httpMethod = "PUT"
    _ = try await transport.answer(request, expecting: [200])
  }

  /// Signs out: ends the session of `token`.
  public func endSession(token: String) async throws(ServerError) {
    var request = authorized(URLRequest(url: url.appending(path: "session")), token)
    request.httpMethod = "DELETE"
    _ = try await transport.answer(request, expecting: [204])
  }

  private func authorized(_ request: URLRequest, _ token: String) -> URLRequest {
    var request = request
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func json(_ path: String, _ body: some Encodable) throws(ServerError) -> URLRequest {
    var request = URLRequest(url: url.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      preconditionFailure("A body of strings always encodes as JSON: \(error)")
    }
    return request
  }

  private func decode<Answer: Decodable>(_ type: Answer.Type, from data: Data)
    throws(ServerError) -> Answer
  {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
  }

  private struct Challenge: Decodable {
    let challenge: String
  }

  private struct MadeAccount: Encodable {
    let account: String
    let challenge: String
    let identityToken: String
    let authorizationCode: String
    let transaction: String
  }

  private struct StartedSession: Encodable {
    let challenge: String
    let identityToken: String
    let authorizationCode: String
  }

  private struct SentSubscription: Encodable {
    let transaction: String
    let renewalInfo: String
  }

  private struct Token: Decodable {
    let token: String
  }

  private struct SessionStarted: Decodable {
    let account: String
    let token: String
  }

  private struct ReadAccount: Decodable {
    let plan: String
    let paidUntil: Int64
    let ownKeyCheck: String?
  }
}

extension Data {
  /// Reads lowercase or uppercase hex, two digits a byte.
  init?(hex: String) {
    guard hex.count.isMultiple(of: 2) else { return nil }
    var bytes: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    self.init(bytes)
  }
}
