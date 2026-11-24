import Foundation

/// What the server says of an account (`GET /account`), as far as the device uses it.
public struct AccountState: Sendable, Equatable {
  /// The server's `plans.tier`.
  public let plan: String
  public let standing: Standing
  public let usage: PlanUsage
  /// Nil until a device has put one.
  public let ownKeyCheck: Data?

  public init(plan: String, standing: Standing, usage: PlanUsage, ownKeyCheck: Data? = nil) {
    self.plan = plan
    self.standing = standing
    self.usage = usage
    self.ownKeyCheck = ownKeyCheck
  }

  /// Whether the account's subscription pays for it.
  public enum Standing: Sendable, Equatable {
    /// Paid for by a billing period until `until`.
    case paid(until: Date)
    /// Paid for only by the billing grace period, while the App Store retries the payment, until
    /// `until`.
    case gracePeriod(until: Date)
    /// Unpaid since `since`: read but not written, and deleted at `deletesAt`.
    case lapsed(since: Date, deletesAt: Date)
  }
}

/// How much of each of its plan's limits an account has used. The counts are today's (UTC), before
/// the request that read them.
public struct PlanUsage: Sendable, Equatable, Decodable {
  public let writingsBytes: Use
  public let writings: Use
  public let photosBytes: Use
  public let requests: Use
  public let lists: Use
  public let saves: Use
  public let photos: Use

  public struct Use: Sendable, Equatable, Decodable {
    public let used: Int64
    public let limit: Int64

    public init(used: Int64, limit: Int64) {
      self.used = used
      self.limit = limit
    }

    /// Whether what is used is at the limit, past which the server answers 429.
    public var isUsedUp: Bool { used >= limit }
  }

  public init(
    writingsBytes: Use, writings: Use, photosBytes: Use, requests: Use, lists: Use, saves: Use,
    photos: Use
  ) {
    self.writingsBytes = writingsBytes
    self.writings = writings
    self.photosBytes = photosBytes
    self.requests = requests
    self.lists = lists
    self.saves = saves
    self.photos = photos
  }
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
  /// Apple user or the account has an account already, or the purchase is another account's and
  /// not a later purchase that moves it to `account`.
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
    let paidUntil = Date(millisecondsSince1970: read.paidUntil)
    let standing: AccountState.Standing
    switch (read.lapsed, read.gracePeriod, read.deletesAt) {
    case (false, false, nil):
      standing = .paid(until: paidUntil)
    case (false, true, nil):
      standing = .gracePeriod(until: paidUntil)
    case (true, false, let deletesAt?):
      standing = .lapsed(since: paidUntil, deletesAt: Date(millisecondsSince1970: deletesAt))
    default:
      throw .unexpectedAnswer(
        "lapsed \(read.lapsed), gracePeriod \(read.gracePeriod) and deletesAt \(String(describing: read.deletesAt)) don't go together"
      )
    }
    return AccountState(
      plan: read.plan, standing: standing, usage: read.usage, ownKeyCheck: check)
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
    let lapsed: Bool
    let gracePeriod: Bool
    let deletesAt: Int64?
    let usage: PlanUsage
    let ownKeyCheck: String?
  }
}

extension Date {
  init(millisecondsSince1970 milliseconds: Int64) {
    self.init(timeIntervalSince1970: Double(milliseconds) / 1000)
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
