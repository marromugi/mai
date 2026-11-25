import Foundation

/// A writing `GET /agent/writings` lists for the agent: one it holds an unexpired copy of.
public struct AgentListedWriting: Sendable, Equatable {
  public let id: UUID
  public let revision: Revision
  public let updated: Date
  /// When the copy expires: the end of read mode.
  public let expires: Date
}

/// The agent's read-only routes (`Server/README.md`, 「読み取りモード」), with the agent's token.
public struct AgentServer: Sendable {
  let url: URL
  /// The agent's token, `agent.<ID>.<secret>`.
  let token: String
  let transport: any HTTPTransport

  public init(url: URL, token: String, transport: any HTTPTransport = URLSession.shared) {
    self.url = url
    self.token = token
    self.transport = transport
  }

  /// The writings the agent holds an unexpired copy of; none while read mode is off.
  public func list() async throws(ServerError) -> [AgentListedWriting] {
    let (data, _) = try await transport.answer(request(for: "agent/writings"), expecting: [200])
    let listing: Listing
    do {
      listing = try JSONDecoder().decode(Listing.self, from: data)
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
    return listing.writings.map {
      AgentListedWriting(
        id: $0.id, revision: $0.revision, updated: Self.date($0.updated),
        expires: Self.date($0.expires))
    }
  }

  /// The agent's copy of the writing with `id`, or nil when it holds none that hasn't expired.
  public func copy(of id: UUID) async throws(ServerError) -> AgentCopy? {
    let (data, response) = try await transport.answer(
      request(for: "agent/writings/\(id.uuidString.lowercased())"), expecting: [200, 404])
    guard response.statusCode == 200 else { return nil }
    guard
      let wrapped = response.value(forHTTPHeaderField: "Mai-Wrapped-Key").flatMap({
        Hex.bytes(of: $0)
      })
    else {
      throw .unexpectedAnswer("a copy came without a wrapped key in its Mai-Wrapped-Key")
    }
    do {
      return try AgentCopy(id: id, bytes: data, wrapped: wrapped)
    } catch {
      throw .unexpectedAnswer(error.localizedDescription)
    }
  }

  private func request(for path: String) -> URLRequest {
    var request = URLRequest(url: url.appending(path: path))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func date(_ milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1000)
  }

  private struct Listing: Decodable {
    struct Entry: Decodable {
      let id: UUID
      let revision: Revision
      let updated: Int64
      let expires: Int64
    }
    let writings: [Entry]
  }
}
