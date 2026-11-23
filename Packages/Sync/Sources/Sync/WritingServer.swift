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

/// What the server knows of a writing.
public struct ServerEntry: Sendable, Equatable, Decodable {
  public let id: UUID
  /// Counts the saves the server accepted, from 1.
  public let version: Int
  /// Milliseconds since 1970, as the device that sealed it wrote it.
  public let updated: Int64
  public let size: Int
}

public enum SaveOutcome: Sendable, Equatable {
  case saved(version: Int)
  /// The server has a version other than the one the save was made over.
  case conflict(current: Int)
}

/// The client of the Worker in `Server/`. Its operations are the read mode model's
/// (`Specs/ReadMode`): `save` is a device's `Save`, and `list` with `read` is what `Sync` reads.
public struct WritingServer: Sendable {
  let url: URL
  let accessToken: String
  let transport: any HTTPTransport

  public init(url: URL, accessToken: String, transport: any HTTPTransport = URLSession.shared) {
    self.url = url
    self.accessToken = accessToken
    self.transport = transport
  }

  public func list() async throws(ServerError) -> [ServerEntry] {
    let (data, _) = try await send(request(for: "writings"), expecting: [200])
    do {
      return try JSONDecoder().decode(Listing.self, from: data).writings
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
  }

  /// The writing with `id` and its version, or nil when the server has none.
  public func read(_ id: UUID) async throws(ServerError) -> (envelope: Envelope, version: Int)? {
    let (data, response) = try await send(request(for: path(of: id)), expecting: [200, 404])
    guard response.statusCode == 200 else { return nil }
    guard let version = response.value(forHTTPHeaderField: "Mai-Version").flatMap(Int.init) else {
      throw .unexpectedAnswer("a writing came without its Mai-Version")
    }
    do {
      return (try Envelope(bytes: data), version)
    } catch {
      throw .unexpectedAnswer(error.localizedDescription)
    }
  }

  /// Saves `sealed` when the server's version is still `base`, the one last read (0 for new).
  public func save(_ sealed: Sealed, over base: Int) async throws(ServerError) -> SaveOutcome {
    var request = request(for: path(of: sealed.id))
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue(String(base), forHTTPHeaderField: "Mai-Base-Version")
    request.httpBody = sealed.bytes
    let (data, response) = try await send(request, expecting: [200, 409])
    let version: Int
    do {
      version = try JSONDecoder().decode(Versioned.self, from: data).version
    } catch {
      throw .unexpectedAnswer(String(describing: error))
    }
    return response.statusCode == 200 ? .saved(version: version) : .conflict(current: version)
  }

  private func path(of id: UUID) -> String {
    "writings/\(id.uuidString.lowercased())"
  }

  private func request(for path: String) -> URLRequest {
    var request = URLRequest(url: url.appending(path: path))
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func send(_ request: URLRequest, expecting statuses: Set<Int>) async throws(ServerError)
    -> (Data, HTTPURLResponse)
  {
    let answer: (Data, HTTPURLResponse)
    do {
      answer = try await transport.send(request)
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

  private struct Listing: Decodable {
    let writings: [ServerEntry]
  }

  private struct Versioned: Decodable {
    let version: Int
  }

  private struct Problem: Decodable {
    let error: String
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
    case .refused(let status, _) where status == 401:
      "サーバーがこの端末の鍵を受け付けませんでした。"
    case .refused(let status, _):
      "サーバーが同期を断りました（\(status)）。"
    case .unexpectedAnswer:
      "サーバーの答えが読めませんでした。"
    }
  }
}
