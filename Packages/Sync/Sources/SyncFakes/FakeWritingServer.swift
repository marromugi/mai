import CryptoKit
import Foundation
import Sync

/// Stands in for the Worker in `Server/`, keeping what it is sent in memory and every request it
/// was sent. Held to the Worker's answers by `ServerContract`.
public actor FakeWritingServer: HTTPTransport {
  private let tokenAccepted: String
  private var writings: [String: (revision: String, updated: Int64, bytes: Data)] = [:]
  /// Each photo's parts by `<ID>` and `<ID>/thumbnail`, as sent.
  private var photos: [String: Data] = [:]
  /// Read mode (#26), as the Worker's tables hold it.
  private var readModeUntil: Int64?
  private var exclusions: Set<String> = []
  private var agents: [FakeAgent] = []
  /// The copies by `<writing ID> <agent ID>`.
  private var copies: [String: HeldCopy] = [:]
  /// The server's clock.
  private let now: @Sendable () -> Date
  public private(set) var requests: [URLRequest] = []

  public init(accepting token: String, now: @escaping @Sendable () -> Date = Date.init) {
    tokenAccepted = token
    self.now = now
  }

  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let path = Array(request.url?.pathComponents.dropFirst() ?? [])
    if path.first == "agent" {
      return agentRead(request, path)
    }
    guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(tokenAccepted)" else {
      return answer(request, 401, json: ["error": "wrong token"])
    }
    if path.first == "photos" {
      return photo(request, Array(path))
    }
    if let first = path.first, ["agents", "read-mode", "exclusions", "copies"].contains(first) {
      return readMode(request, path)
    }
    switch (request.httpMethod ?? "GET", path.count) {
    case ("GET", 1):
      let listed = writings.sorted { $0.key < $1.key }.map { id, writing in
        [
          "id": id, "revision": writing.revision, "updated": writing.updated,
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
        request, 200, body: writing.bytes, headers: ["Mai-Revision": writing.revision])
    case ("PUT", 2):
      guard request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" else {
        return answer(request, 415, json: ["error": "not application/octet-stream"])
      }
      guard let id = path.last, let body = request.httpBody,
        let base = request.value(forHTTPHeaderField: "Mai-Base-Revision"),
        let envelope = try? Envelope(bytes: body), envelope.id.uuidString.lowercased() == id
      else {
        return answer(request, 400, json: ["error": "not a sealed writing"])
      }
      let current = writings[id]?.revision
      guard current == base || (current == nil && base == "none") else {
        return answer(request, 409, json: ["revision": current ?? NSNull()])
      }
      let updated = body[20..<28].reduce(Int64(0)) { $0 << 8 | Int64($1) }
      let revision = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
      writings[id] = (revision, updated, body)
      copies = copies.filter { $0.value.writing != id || $0.value.revision == revision }
      return answer(request, 200, json: ["revision": revision])
    default:
      return answer(request, 405, json: ["error": "no such route"])
    }
  }

  /// `PUT` and `GET` of `/photos/<ID>` and `/photos/<ID>/thumbnail`. A part is kept as sent, and
  /// one sent again is refused with 409.
  private func photo(_ request: URLRequest, _ path: [String]) -> (Data, HTTPURLResponse) {
    guard path.count == 2 || (path.count == 3 && path[2] == "thumbnail") else {
      return answer(request, 404, json: ["error": "no such route"])
    }
    let key = path.dropFirst().joined(separator: "/")
    switch request.httpMethod ?? "GET" {
    case "GET":
      guard let bytes = photos[key] else {
        return answer(request, 404, json: ["error": "no photo"])
      }
      return answer(request, 200, body: bytes)
    case "PUT":
      guard request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" else {
        return answer(request, 415, json: ["error": "not application/octet-stream"])
      }
      guard let body = request.httpBody, !body.isEmpty else {
        return answer(request, 400, json: ["error": "a sealed photo has bytes"])
      }
      guard photos[key] == nil else {
        return answer(request, 409, json: ["error": "the server has this part already"])
      }
      photos[key] = body
      return answer(request, 201, body: Data())
    default:
      return answer(request, 405, json: ["error": "no such route"])
    }
  }

  /// The copies held now, expired ones included until `sweep()`.
  public func heldCopies() -> [HeldCopy] {
    copies.values.sorted { ($0.writing, $0.agent) < ($1.writing, $1.agent) }
  }

  /// When read mode ends, as held: an ended one stays until `sweep()`.
  public func heldReadMode() -> Int64? {
    readModeUntil
  }

  public func heldExclusions() -> Set<String> {
    exclusions
  }

  /// The current revision of each writing, by lowercase ID.
  public func heldRevisions() -> [String: String] {
    writings.mapValues(\.revision)
  }

  /// The Worker's cron: deletes the copies and the read mode whose time has come.
  public func sweep() {
    let now = milliseconds(now())
    copies = copies.filter { $0.value.expires > now }
    if let until = readModeUntil, until <= now {
      readModeUntil = nil
    }
  }

  /// The device's read-mode routes: `/agents`, `/read-mode`, `/exclusions` and `/copies`.
  private func readMode(_ request: URLRequest, _ path: [String]) -> (Data, HTTPURLResponse) {
    let method = request.httpMethod ?? "GET"
    let now = milliseconds(now())
    switch (path.first, path.count, method) {
    case ("agents", 1, "GET"):
      let listed = agents.map {
        [
          "id": $0.id, "publicKey": hex($0.publicKey), "signature": hex($0.signature),
          "revoked": $0.revoked,
        ] as [String: Any]
      }
      return answer(request, 200, json: ["agents": listed])
    case ("agents", 1, "POST"):
      guard let body = json(request), let publicKey = bytes(body["publicKey"]),
        let signature = bytes(body["signature"])
      else {
        return answer(request, 400, json: ["error": "not an approval"])
      }
      guard agents.filter({ !$0.revoked }).count < 10,
        !agents.contains(where: { $0.publicKey == publicKey })
      else {
        return answer(request, 409, json: ["error": "too many agents, or a known key"])
      }
      let id = UUID().uuidString.lowercased()
      let token = "agent.\(id).\(UUID().uuidString)"
      agents.append(
        FakeAgent(
          id: id, publicKey: publicKey, signature: signature, token: token, revoked: false))
      return answer(request, 201, json: ["agent": id, "token": token])
    case ("agents", 2, "DELETE"):
      guard let index = agents.firstIndex(where: { $0.id == path[1].lowercased() }) else {
        return answer(request, 404, json: ["error": "no such agent"])
      }
      agents[index].revoked = true
      copies = copies.filter { $0.value.agent != agents[index].id }
      return answer(request, 204, body: Data())
    case ("read-mode", 1, "GET"):
      let until = readModeUntil.flatMap { $0 > now ? $0 : nil }
      return answer(request, 200, json: ["until": until ?? NSNull()])
    case ("read-mode", 1, "PUT"):
      guard let until = (json(request)?["until"] as? NSNumber)?.int64Value, until > now else {
        return answer(request, 400, json: ["error": "until is not after now"])
      }
      readModeUntil = until
      copies = copies.filter { $0.value.expires == until }
      return answer(request, 200, json: ["until": until])
    case ("read-mode", 1, "DELETE"):
      readModeUntil = nil
      copies = [:]
      return answer(request, 204, body: Data())
    case ("exclusions", 1, "GET"):
      return answer(request, 200, json: ["exclusions": exclusions.sorted()])
    case ("exclusions", 2, "PUT"):
      let id = path[1].lowercased()
      exclusions.insert(id)
      copies = copies.filter { $0.value.writing != id }
      return answer(request, 204, body: Data())
    case ("exclusions", 2, "DELETE"):
      exclusions.remove(path[1].lowercased())
      return answer(request, 204, body: Data())
    case ("copies", 1, "POST"):
      return keepCopies(request, now: now)
    default:
      return answer(request, 405, json: ["error": "no such route"])
    }
  }

  /// `POST /copies`: keeps each copy only when the Worker would (`Server/README.md`).
  private func keepCopies(_ request: URLRequest, now: Int64) -> (Data, HTTPURLResponse) {
    guard let body = json(request), let expires = (body["expires"] as? NSNumber)?.int64Value,
      let sent = body["copies"] as? [[String: Any]], (1...100).contains(sent.count)
    else {
      return answer(request, 400, json: ["error": "not copies"])
    }
    var answers: [[String: Any]] = []
    for copy in sent {
      guard let writing = (copy["writing"] as? String)?.lowercased(),
        let agent = (copy["agent"] as? String)?.lowercased(),
        let revision = copy["revision"] as? String, let wrapped = bytes(copy["wrapped"])
      else {
        return answer(request, 400, json: ["error": "not a copy"])
      }
      let refused: String? =
        if readModeUntil.map({ $0 > now && $0 == expires }) != true {
          "read-mode"
        } else if exclusions.contains(writing) {
          "excluded"
        } else if !agents.contains(where: { $0.id == agent && !$0.revoked }) {
          "agent"
        } else if writings[writing]?.revision != revision {
          "revision"
        } else {
          nil
        }
      if refused == nil {
        copies["\(writing) \(agent)"] = HeldCopy(
          writing: writing, agent: agent, revision: revision, wrapped: wrapped, expires: expires)
      }
      answers.append(["writing": writing, "agent": agent, "refused": refused ?? NSNull()])
    }
    return answer(request, 200, json: ["copies": answers])
  }

  /// The agent's routes, `GET /agent/writings` and `GET /agent/writings/<ID>`.
  private func agentRead(_ request: URLRequest, _ path: [String]) -> (Data, HTTPURLResponse) {
    guard
      let agent = agents.first(where: {
        !$0.revoked && request.value(forHTTPHeaderField: "Authorization") == "Bearer \($0.token)"
      })
    else {
      return answer(request, 401, json: ["error": "not an agent's token"])
    }
    let now = milliseconds(now())
    let readable = copies.values.filter {
      $0.agent == agent.id && $0.expires > now && writings[$0.writing]?.revision == $0.revision
    }
    switch path.count {
    case 2:
      let listed = readable.sorted { $0.writing < $1.writing }.compactMap {
        copy -> [String: Any]? in
        guard let writing = writings[copy.writing] else { return nil }
        return [
          "id": copy.writing, "revision": copy.revision, "updated": writing.updated,
          "size": writing.bytes.count, "expires": copy.expires,
        ]
      }
      return answer(request, 200, json: ["writings": listed])
    case 3:
      guard let copy = readable.first(where: { $0.writing == path[2].lowercased() }),
        let writing = writings[copy.writing]
      else {
        return answer(request, 404, json: ["error": "no copy"])
      }
      return answer(
        request, 200, body: writing.bytes,
        headers: [
          "Mai-Revision": copy.revision, "Mai-Wrapped-Key": hex(copy.wrapped),
          "Mai-Expires": String(copy.expires),
        ])
    default:
      return answer(request, 404, json: ["error": "no such route"])
    }
  }

  private func json(_ request: URLRequest) -> [String: Any]? {
    guard request.value(forHTTPHeaderField: "Content-Type") == "application/json",
      let body = request.httpBody
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
  }

  private func bytes(_ value: Any?) -> Data? {
    guard let text = value as? String, !text.isEmpty, text.count.isMultiple(of: 2),
      text == text.lowercased()
    else { return nil }
    var bytes = Data()
    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(index, offsetBy: 2)
      guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
      bytes.append(byte)
      index = next
    }
    return bytes.count <= 1024 ? bytes : nil
  }

  private func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
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

/// A read-mode copy as `FakeWritingServer` holds it. IDs are in lowercase.
public struct HeldCopy: Sendable, Equatable {
  public let writing: String
  public let agent: String
  public let revision: String
  public let wrapped: Data
  /// Milliseconds since 1970.
  public let expires: Int64
}

private struct FakeAgent {
  let id: String
  let publicKey: Data
  let signature: Data
  let token: String
  var revoked: Bool
}
