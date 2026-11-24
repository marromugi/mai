import Foundation
import Sync
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
    let hex = check.map { "\"\($0.map { String(format: "%02x", $0) }.joined())\"" } ?? "null"
    return .status(
      200,
      json:
        #"{"plan":"basic","paidUntil":1,"lapsed":false,"deletesAt":null,"usage":{},"ownKeyCheck":"#
        + hex + "}")
  }
}

/// Apple and the App Store as each test sets them, counting the sign-ins asked for.
final class ScriptedApple: AppleSignIn, Purchases {
  private let state: Mutex<Result<AppleCredentialState, URLError>>
  private let bought: [SignedSubscription]
  private let signIns = Mutex(0)

  init(
    state: Result<AppleCredentialState, URLError> = .success(.authorized),
    bought: [SignedSubscription] = [SignedSubscription(transaction: "t", renewalInfo: "r")]
  ) {
    self.state = Mutex(state)
    self.bought = bought
  }

  var signInsAsked: Int { signIns.withLock { $0 } }

  func signIn(nonce: String) async throws -> AppleCredential {
    signIns.withLock { $0 += 1 }
    return AppleCredential(user: "user", identityToken: "id", authorizationCode: "code")
  }

  func credentialState(of user: String) async throws -> AppleCredentialState {
    try state.withLock { try $0.get() }
  }

  func subscriptions(for account: UUID) async throws -> [SignedSubscription] {
    bought
  }
}
