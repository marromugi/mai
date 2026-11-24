import Foundation
import Synchronization

/// Stands in for Sign in with Apple and the App Store where neither can be reached: the tests, and
/// a debug build run against `Server/test/stand-in-apple.ts` under `wrangler dev`, which signs what
/// Apple would sign. Never used against a deployed Worker, which checks Apple's own signatures.
public final class StandInApple: AppleSignIn, Purchases {
  /// What the stand-in answers; changed by the tests between steps.
  public struct Answers: Sendable {
    /// The plan each account's subscription is to, by `plans.tier`; nil for none bought.
    public var plan: String? = "basic"
    /// Milliseconds since 1970; nil for a month from when it is asked.
    public var expiresDate: Int64?
    public var credentialState = AppleCredentialState.authorized

    public init() {}
  }

  private let url: URL
  private let user: String
  private let transport: any HTTPTransport
  private let answers: Mutex<Answers>
  /// One subscription per account, renewed by each answer.
  private let subscriptionIDs = Mutex<[UUID: String]>([:])

  /// Signs in as the Apple user `user` through the stand-in Worker at `url`.
  public init(
    url: URL, user: String, answers: Answers = Answers(),
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.url = url
    self.user = user
    self.transport = transport
    self.answers = Mutex(answers)
  }

  public func change(_ change: (inout Answers) -> Void) {
    answers.withLock { change(&$0) }
  }

  public func signIn(nonce: String) async throws -> AppleCredential {
    let signedIn: SignedIn = try await post(
      "stand-in-apple/sign-in", ["user": user, "nonce": nonce])
    return AppleCredential(
      user: user, identityToken: signedIn.identityToken,
      authorizationCode: signedIn.authorizationCode)
  }

  public func credentialState(of user: String) async throws -> AppleCredentialState {
    answers.withLock { $0.credentialState }
  }

  public func subscriptions(for account: UUID) async throws -> [SignedSubscription] {
    let (plan, expiresDate) = answers.withLock { ($0.plan, $0.expiresDate) }
    guard let plan else { return [] }
    let id = subscriptionIDs.withLock { ids in
      if let id = ids[account] { return id }
      let id = UUID().uuidString
      ids[account] = id
      return id
    }
    var body: [String: any Sendable] = [
      "account": account.uuidString.lowercased(), "plan": plan, "originalTransactionId": id,
    ]
    body["expiresDate"] = expiresDate
    let bought: Bought = try await post("stand-in-apple/subscription", body)
    return [SignedSubscription(transaction: bought.transaction, renewalInfo: bought.renewalInfo)]
  }

  private func post<Answer: Decodable>(_ path: String, _ body: [String: any Sendable])
    async throws -> Answer
  {
    var request = URLRequest(url: url.appending(path: path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, _) = try await transport.answer(request, expecting: [200])
    return try JSONDecoder().decode(Answer.self, from: data)
  }

  private struct SignedIn: Decodable {
    let identityToken: String
    let authorizationCode: String
  }

  private struct Bought: Decodable {
    let transaction: String
    let renewalInfo: String
  }
}
