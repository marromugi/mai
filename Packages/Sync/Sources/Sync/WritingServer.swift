import Foundation

/// Sends one request and gives back the answer. `URLSession` is the real one.
public protocol HTTPTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPTransport {
  public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await data(for: request)
    guard let response = response as? HTTPURLResponse else {
      preconditionFailure("An HTTP request is always answered with an HTTPURLResponse")
    }
    return (data, response)
  }
}

extension HTTPTransport {
  /// Sends `request`, and gives back the answer when its status is one of `statuses`.
  func answer(_ request: URLRequest, expecting statuses: Set<Int>) async throws(ServerError)
    -> (Data, HTTPURLResponse)
  {
    let answer: (Data, HTTPURLResponse)
    do {
      answer = try await send(request)
    } catch {
      throw .unreachable(error)
    }
    let (data, response) = answer
    guard statuses.contains(response.statusCode) else {
      let reason = (try? JSONDecoder().decode(Problem.self, from: data))?.error
      throw .refused(status: response.statusCode, reason: reason ?? "")
    }
    return answer
  }
}

/// The body of the Worker's answer to a request it refused.
private struct Problem: Decodable {
  let error: String
}

/// Tells one save of a writing from another: the SHA-256 of what was saved, as the server gives it.
public struct Revision: Sendable, Hashable, Codable {
  public let hex: String

  public init(from decoder: any Decoder) throws {
    hex = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }

  init(hex: String) {
    self.hex = hex
  }
}

/// What the server knows of a writing.
public struct ServerEntry: Sendable, Equatable, Decodable {
  public let id: UUID
  public let revision: Revision
  /// Milliseconds since 1970, as the device that sealed it wrote it.
  public let updated: Int64
  public let size: Int
}

public enum SaveOutcome: Sendable, Equatable {
  case saved(Revision)
  /// The server has another revision than the one the save was made over: nil for none.
  case conflict(current: Revision?)
}

/// The client of the Worker in `Server/`. `save` is the read mode model's `Save` for the writing
/// itself (`Specs/ReadMode`); the model has no refused save. `list` and `read` take the writings,
/// which the model leaves out; its `Sync` takes the settings #26 adds.
public struct WritingServer: Sendable {
  let url: URL
  /// The session's token (`Session.token`).
  let token: String
  let transport: any HTTPTransport

  public init(url: URL, token: String, transport: any HTTPTransport = URLSession.shared) {
    self.url = url
    self.token = token
    self.transport = transport
  }

  public func list() async throws(ServerError) -> [ServerEntry] {
    let (data, _) = try await transport.answer(request(for: "writings"), expecting: [200])
    do {
      return try JSONDecoder().decode(Listing.self, from: data).writings
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
  }

  /// The writing with `id` and its revision, or nil when the server has none.
  public func read(_ id: UUID) async throws(ServerError) -> (
    envelope: Envelope, revision: Revision
  )? {
    let (data, response) = try await transport.answer(
      request(for: path(of: id)), expecting: [200, 404])
    guard response.statusCode == 200 else { return nil }
    guard let revision = response.value(forHTTPHeaderField: "Mai-Revision") else {
      throw .unexpectedAnswer("a writing came without its Mai-Revision")
    }
    do {
      return (try Envelope(bytes: data), Revision(hex: revision))
    } catch {
      throw .unexpectedAnswer(error.localizedDescription)
    }
  }

  /// Saves `sealed` when the server's revision is still `base`, the one last read (nil for new).
  public func save(_ sealed: Sealed, over base: Revision?) async throws(ServerError) -> SaveOutcome
  {
    var request = request(for: path(of: sealed.id))
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(base?.hex ?? "none", forHTTPHeaderField: "Mai-Base-Revision")
    request.httpBody = sealed.bytes
    let (data, response) = try await transport.answer(request, expecting: [200, 409])
    let revision: Revision?
    do {
      revision = try JSONDecoder().decode(Revised.self, from: data).revision
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
    switch (response.statusCode, revision) {
    case (200, let revision?):
      return .saved(revision)
    case (200, nil):
      throw .unexpectedAnswer("a save came back without its revision")
    default:
      return .conflict(current: revision)
    }
  }

  private func path(of id: UUID) -> String {
    "writings/\(id.uuidString.lowercased())"
  }

  private func request(for path: String) -> URLRequest {
    var request = URLRequest(url: url.appending(path: path))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return request
  }

  private struct Listing: Decodable {
    let writings: [ServerEntry]
  }

  private struct Revised: Decodable {
    let revision: Revision?
  }

}

public enum ServerError: LocalizedError {
  /// The request didn't reach the server, or its answer didn't come back.
  case unreachable(any Error)
  /// The server answered with a status the request doesn't expect, and the reason it gave.
  case refused(status: Int, reason: String)
  /// The server's answer was not of the shape it promises.
  case unexpectedAnswer(String)

  public var errorDescription: String? {
    switch self {
    case .unreachable:
      "サーバーにつながりませんでした。ネットワークを確かめて、もう一度同期してください。"
    case .refused(status: 401, _):
      "サインインが切れています。設定の「同期」から、もう一度サインインしてください。"
    case .refused(status: 402, _):
      "プランの期限が切れているため、変更をサーバーに送れません。文書はこの端末に残っています。"
    case .refused(status: 429, _):
      "プランの上限に達したため、同期を止めました。1 日の回数の上限なら、日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。容量の上限なら、文書を減らすか、上のプランに変えてください。文書はこの端末に残っています。"
    case .refused(let status, _):
      "サーバーが同期を断りました（\(status)）。"
    case .unexpectedAnswer:
      "サーバーの答えが読めませんでした。"
    }
  }
}
