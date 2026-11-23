import Foundation
import Sync

/// Stands in for the Worker in `Server/`, keeping what it is sent in memory and every request it
/// was sent. Held to the Worker's answers by `ServerContract`.
actor FakeWritingServer: HTTPTransport {
  private let tokenAccepted: String
  private var writings: [String: (version: Int, updated: Int64, bytes: Data)] = [:]
  private(set) var requests: [URLRequest] = []

  init(accepting token: String) {
    tokenAccepted = token
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokenAccepted)" else {
      return answer(request, 401, json: ["error": "wrong token"])
    }
    let path = request.url?.pathComponents.dropFirst() ?? []
    switch (request.httpMethod ?? "GET", path.count) {
    case ("GET", 1):
      let listed = writings.sorted { $0.key < $1.key }.map { id, writing in
        [
          "id": id, "version": writing.version, "updated": writing.updated,
          "size": writing.bytes.count,
        ]
          as [String: Any]
      }
      return answer(request, 200, json: ["writings": listed])
    case ("GET", 2):
      guard let id = path.last, let writing = writings[id] else {
        return answer(request, 404, json: ["error": "no writing"])
      }
      return answer(
        request, 200, body: writing.bytes, headers: ["Mai-Version": "\(writing.version)"])
    case ("PUT", 2):
      guard let id = path.last, let body = request.httpBody,
        let base = request.value(forHTTPHeaderField: "Mai-Base-Version").flatMap(Int.init),
        let envelope = try? Envelope(bytes: body), envelope.id.uuidString.lowercased() == id
      else {
        return answer(request, 400, json: ["error": "not a sealed writing"])
      }
      let current = writings[id]?.version ?? 0
      guard current == base else {
        return answer(request, 409, json: ["version": current])
      }
      let updated = body[20..<28].reduce(Int64(0)) { $0 << 8 | Int64($1) }
      writings[id] = (current + 1, updated, body)
      return answer(request, 200, json: ["version": current + 1])
    default:
      return answer(request, 405, json: ["error": "no such route"])
    }
  }

  private func answer(_ request: URLRequest, _ status: Int, json: [String: Any]) -> (
    Data, HTTPURLResponse
  ) {
    do {
      return answer(request, status, body: try JSONSerialization.data(withJSONObject: json))
    } catch {
      preconditionFailure("The fake's answers are always JSON: \(error)")
    }
  }

  private func answer(
    _ request: URLRequest, _ status: Int, body: Data, headers: [String: String] = [:]
  ) -> (Data, HTTPURLResponse) {
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else {
      preconditionFailure("A request sent to the fake always has a URL")
    }
    return (body, response)
  }
}
