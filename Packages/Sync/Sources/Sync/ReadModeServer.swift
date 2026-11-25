import Foundation

/// An agent the account approved, as `GET /agents` lists it. Its key and signature are as the
/// server holds them, which a device checks before wrapping for it (`ReadModeView`).
public struct ServerAgent: Sendable, Equatable, Identifiable {
  public let id: UUID
  /// The key's bytes, nil when they aren't an agent's key.
  public let key: AgentKey?
  let signature: Data
  public let revoked: Bool
}

/// An approved agent's ID and the token it reads with (`agent.<ID>.<secret>`), given once.
public struct ApprovedAgent: Sendable, Equatable {
  public let id: UUID
  public let token: String
}

/// A writing's key at one revision, wrapped for one agent.
public struct CopyToSend: Sendable, Equatable {
  public let writing: UUID
  public let agent: UUID
  public let revision: Revision
  let wrapped: Data
}

/// Why the server took no copy (`Server/README.md`, 「読み取りモード」).
public enum CopyRefusal: Sendable, Hashable, Decodable {
  /// Read mode is off, has ended, or ends at another time than the copy's.
  case readMode
  case excluded
  /// The agent isn't the account's, or was revoked.
  case agent
  /// The server's writing is at another revision, or isn't there.
  case revision
  /// A reason this device doesn't know yet, as the server named it.
  case other(String)

  public init(from decoder: any Decoder) throws {
    let reason = try decoder.singleValueContainer().decode(String.self)
    self =
      switch reason {
      case "read-mode": .readMode
      case "excluded": .excluded
      case "agent": .agent
      case "revision": .revision
      default: .other(reason)
      }
  }
}

/// The read-mode routes of the Worker in `Server/` (#26): agents, read mode, exclusions and copies.
public struct ReadModeServer: Sendable {
  let url: URL
  let token: String
  let transport: any HTTPTransport

  public init(url: URL, token: String, transport: any HTTPTransport = URLSession.shared) {
    self.url = url
    self.token = token
    self.transport = transport
  }

  /// The account's agents, revoked ones included.
  public func agents() async throws(ServerError) -> [ServerAgent] {
    let listed: AgentListing = try await decoded(request(for: "agents"))
    var agents: [ServerAgent] = []
    for agent in listed.agents {
      guard let id = UUID(uuidString: agent.id), let signature = Hex.bytes(of: agent.signature)
      else {
        throw .unexpectedAnswer("an agent was listed as \(agent.id) with an unreadable signature")
      }
      let key = Hex.bytes(of: agent.publicKey).flatMap { try? AgentKey(rawRepresentation: $0) }
      agents.append(ServerAgent(id: id, key: key, signature: signature, revoked: agent.revoked))
    }
    return agents
  }

  /// Approves `agent` with `signature`. Nil when the server refuses it (409): the account has 10
  /// agents not revoked, or has had one with this key.
  public func approve(_ agent: AgentKey, signature: Data) async throws(ServerError)
    -> ApprovedAgent?
  {
    var request = request(for: "agents")
    request.httpMethod = "POST"
    request.setJSON([
      "publicKey": Self.hex(agent.rawRepresentation), "signature": Self.hex(signature),
    ])
    let (data, response) = try await transport.answer(request, expecting: [201, 409])
    guard response.statusCode == 201 else { return nil }
    let made: Approved
    do {
      made = try JSONDecoder().decode(Approved.self, from: data)
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
    guard let id = UUID(uuidString: made.agent), made.token.hasPrefix("agent.") else {
      throw .unexpectedAnswer("an approved agent came back as \(made.agent)")
    }
    return ApprovedAgent(id: id, token: made.token)
  }

  /// Revokes the agent with `id`, deleting its copies. False when the account has no such agent.
  public func revoke(_ id: UUID) async throws(ServerError) -> Bool {
    var request = request(for: "agents/\(id.uuidString.lowercased())")
    request.httpMethod = "DELETE"
    let (_, response) = try await transport.answer(request, expecting: [204, 404])
    return response.statusCode == 204
  }

  /// When read mode ends, nil when it is off or has ended.
  public func readMode() async throws(ServerError) -> Date? {
    let mode: Mode = try await decoded(request(for: "read-mode"))
    return mode.until.map(Self.date)
  }

  /// Turns read mode on until `until`, which the server answers with. A time the server's clock
  /// has passed is refused (400).
  public func turnOn(until: Date) async throws(ServerError) -> Date {
    var request = request(for: "read-mode")
    request.httpMethod = "PUT"
    request.setJSON(["until": Self.milliseconds(until)])
    let mode: Mode = try await decoded(request)
    guard let until = mode.until else {
      throw .unexpectedAnswer("read mode was turned on without saying until when")
    }
    return Self.date(until)
  }

  /// Turns read mode off, deleting every copy.
  public func turnOff() async throws(ServerError) {
    var request = request(for: "read-mode")
    request.httpMethod = "DELETE"
    _ = try await transport.answer(request, expecting: [204])
  }

  /// The writings no copy is made of.
  public func exclusions() async throws(ServerError) -> Set<UUID> {
    let listed: ExclusionListing = try await decoded(request(for: "exclusions"))
    var excluded: Set<UUID> = []
    for id in listed.exclusions {
      guard let id = UUID(uuidString: id) else {
        throw .unexpectedAnswer("an exclusion was listed as \(id)")
      }
      excluded.insert(id)
    }
    return excluded
  }

  /// Excludes the writing with `id` (「AI に読ませない」), deleting its copies.
  public func exclude(_ id: UUID) async throws(ServerError) {
    var request = request(for: "exclusions/\(id.uuidString.lowercased())")
    request.httpMethod = "PUT"
    _ = try await transport.answer(request, expecting: [204])
  }

  /// Takes the exclusion of the writing with `id` off. Its copies are the device's to send.
  public func include(_ id: UUID) async throws(ServerError) {
    var request = request(for: "exclusions/\(id.uuidString.lowercased())")
    request.httpMethod = "DELETE"
    _ = try await transport.answer(request, expecting: [204])
  }

  /// Sends `copies`, wrapped in the read mode that ends at `expires`, 100 to a request. Answers
  /// why each refused one was refused, in the order sent; nil for one kept.
  public func send(_ copies: [CopyToSend], expires: Date) async throws(ServerError)
    -> [CopyRefusal?]
  {
    var refusals: [CopyRefusal?] = []
    for start in stride(from: 0, to: copies.count, by: Self.copiesAtOnce) {
      let batch = copies[start..<min(start + Self.copiesAtOnce, copies.count)]
      var request = request(for: "copies")
      request.httpMethod = "POST"
      request.setJSON(
        Sent(
          expires: Self.milliseconds(expires),
          copies: batch.map {
            SentCopy(
              writing: $0.writing.uuidString.lowercased(), agent: $0.agent.uuidString.lowercased(),
              revision: $0.revision.hex, wrapped: Self.hex($0.wrapped))
          }))
      let kept: Kept = try await decoded(request)
      guard kept.copies.count == batch.count,
        zip(kept.copies, batch).allSatisfy({
          UUID(uuidString: $0.writing) == $1.writing && UUID(uuidString: $0.agent) == $1.agent
        })
      else {
        throw .unexpectedAnswer("the copies came back in another order than sent")
      }
      refusals += kept.copies.map(\.refused)
    }
    return refusals
  }

  /// The most copies one `POST /copies` takes.
  static let copiesAtOnce = 100

  private func decoded<Answer: Decodable>(_ request: URLRequest) async throws(ServerError)
    -> Answer
  {
    let (data, _) = try await transport.answer(request, expecting: [200])
    do {
      return try JSONDecoder().decode(Answer.self, from: data)
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
  }

  private func request(for path: String) -> URLRequest {
    var request = URLRequest(url: url.appending(path: path))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  static func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  private static func milliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  private static func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  private struct AgentListing: Decodable {
    struct Agent: Decodable {
      let id: String
      let publicKey: String
      let signature: String
      let revoked: Bool
    }
    let agents: [Agent]
  }

  private struct Approved: Decodable {
    let agent: String
    let token: String
  }

  private struct Mode: Decodable {
    let until: Int64?
  }

  private struct ExclusionListing: Decodable {
    let exclusions: [String]
  }

  private struct Sent: Encodable {
    let expires: Int64
    let copies: [SentCopy]
  }

  private struct SentCopy: Encodable {
    let writing: String
    let agent: String
    let revision: String
    let wrapped: String
  }

  private struct Kept: Decodable {
    struct Copy: Decodable {
      let writing: String
      let agent: String
      let refused: CopyRefusal?
    }
    let copies: [Copy]
  }
}

extension URLRequest {
  fileprivate mutating func setJSON(_ body: some Encodable) {
    setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      httpBody = try JSONEncoder().encode(body)
    } catch {
      preconditionFailure("Strings and numbers always encode as JSON: \(error)")
    }
  }
}
