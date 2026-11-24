import Foundation
import Sync
import SyncFakes
import Synchronization

/// Answers each request to the Worker with the next answer written for its route, and keeps every
/// request. A route with no answer left fails the way an unreachable server does.
final class ScriptedServer: HTTPTransport {
  enum Answer {
    case status(Int, json: String = "{}")
    case unreachable
  }

  private let answers: Mutex<[String: [Answer]]>
  private let sent = Mutex<[URLRequest]>([])

  /// `answers` by route, `"PUT /account/own-key-check"` for one.
  init(_ answers: [String: [Answer]]) {
    self.answers = Mutex(answers)
  }

  var requests: [URLRequest] { sent.withLock { $0 } }

  func routes() -> [String] {
    requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    sent.withLock { $0.append(request) }
    let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
    let answer = answers.withLock { answers -> Answer in
      guard var queue = answers[route], !queue.isEmpty else { return .unreachable }
      let first = queue.removeFirst()
      answers[route] = queue
      return first
    }
    switch answer {
    case .unreachable:
      throw URLError(.cannotConnectToHost)
    case .status(let status, let json):
      guard
        let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"])
      else {
        preconditionFailure("A request always has a URL")
      }
      return (Data(json.utf8), response)
    }
  }

  /// `GET /account`'s answer for an account whose own key check is `check`.
  static func account(check: Data?) -> Answer {
    .status(200, json: accountAnswer(check: check))
  }
}

/// Apple and the App Store as each test sets them, counting the sign-ins asked for and keeping whose
/// credential state was asked. Signs in as the Apple user `user`.
final class ScriptedApple: AppleSignIn, Purchases {
  static let user = "000123.scripted"

  private let state: Mutex<Result<AppleCredentialState, URLError>>
  private let bought: Result<[SignedSubscription], URLError>
  private let signIns = Mutex(0)
  private let asked = Mutex<[String]>([])

  init(
    state: Result<AppleCredentialState, URLError> = .success(.authorized),
    bought: Result<[SignedSubscription], URLError> = .success([
      SignedSubscription(transaction: "t", renewalInfo: "r")
    ])
  ) {
    self.state = Mutex(state)
    self.bought = bought
  }

  var signInsAsked: Int { signIns.withLock { $0 } }
  var usersAsked: [String] { asked.withLock { $0 } }

  func signIn(nonce: String) async throws -> AppleCredential {
    signIns.withLock { $0 += 1 }
    return AppleCredential(user: Self.user, identityToken: "id", authorizationCode: "code")
  }

  func credentialState(of user: String) async throws -> AppleCredentialState {
    asked.withLock { $0.append(user) }
    return try state.withLock { try $0.get() }
  }

  func subscriptions(for account: UUID) async throws -> [SignedSubscription] {
    try bought.get()
  }
}
