import CryptoKit
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
      let problem = try? JSONDecoder().decode(Problem.self, from: data)
      if response.statusCode == 429 {
        throw .limitReached(problem?.limit.flatMap(PlanLimit.init(rawValue:)))
      }
      throw .refused(status: response.statusCode, reason: problem?.error ?? "")
    }
    return answer
  }
}

/// The body of the Worker's answer to a request it refused; `limit` comes with a 429.
private struct Problem: Decodable {
  let error: String
  let limit: String?
}

/// A limit of the account's plan, as the Worker names it in a 429.
public enum PlanLimit: String, Sendable, Equatable {
  /// Today's requests.
  case requests
  /// Today's listings of the writings.
  case lists
  /// Today's saves of a writing.
  case saves
  /// Today's photos.
  case photos
  /// The writings' bytes, or their number.
  case storage
  /// The photos' bytes.
  case photoStorage = "photo-storage"
}

/// Tells one save of a writing from another: the SHA-256 of what was saved, as the server gives it.
public struct Revision: Sendable, Hashable, Codable {
  /// The 32 bytes of the SHA-256.
  let bytes: Data

  public var hex: String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    guard let revision = Revision(hex: try container.decode(String.self)) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "a revision is a SHA-256 in lowercase hex")
    }
    self = revision
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }

  /// The revision written as 64 lowercase hex digits; nil for any other text.
  init?(hex: String) {
    guard let bytes = Hex.bytes(of: hex), bytes.count == 32 else { return nil }
    self.bytes = bytes
  }

  /// The revision of the sealed writing `bytes`.
  init(of bytes: Data) {
    self.bytes = Data(SHA256.hash(data: bytes))
  }

}

/// Bytes written as lowercase hex, two digits each, as the Worker writes them.
enum Hex {
  /// The bytes `text` writes; nil for any other text.
  static func bytes(of text: String) -> Data? {
    let digits = Array(text.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes = Data(capacity: digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let high = value(of: digits[index]), let low = value(of: digits[index + 1]) else {
        return nil
      }
      bytes.append(high << 4 | low)
    }
    return bytes
  }

  private static func value(of digit: UInt8) -> UInt8? {
    switch digit {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): digit - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): digit - UInt8(ascii: "a") + 10
    default: nil
    }
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

public enum PhotoSent: Sendable, Equatable {
  case sent
  /// The server has this part already, or is taking it now (409).
  case alreadyThere
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
    guard
      let revision = response.value(forHTTPHeaderField: "Mai-Revision").flatMap({
        Revision(hex: $0)
      })
    else {
      throw .unexpectedAnswer("a writing came without a revision in its Mai-Revision")
    }
    do {
      return (try Envelope(bytes: data), revision)
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

  /// Sends one part of a sealed photo. A part the server has already, or is taking now (409), is
  /// left as it is.
  public func send(_ sealed: SealedPhoto) async throws(ServerError) -> PhotoSent {
    var request = request(for: path(of: sealed.id, sealed.part))
    request.httpMethod = "PUT"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.httpBody = sealed.bytes
    let (_, response) = try await transport.answer(request, expecting: [201, 409])
    return response.statusCode == 201 ? .sent : .alreadyThere
  }

  /// One part of the photo with `id`, or nil when the server has none.
  public func readPhoto(_ id: UUID, _ part: PhotoPart) async throws(ServerError) -> PhotoEnvelope? {
    let (data, response) = try await transport.answer(
      request(for: path(of: id, part)), expecting: [200, 404])
    guard response.statusCode == 200 else { return nil }
    let envelope: PhotoEnvelope
    do {
      envelope = try PhotoEnvelope(bytes: data)
    } catch {
      throw .unexpectedAnswer(error.localizedDescription)
    }
    guard envelope.id == id, envelope.part == part else {
      throw .unexpectedAnswer(
        "the server gave the \(envelope.part) of photo \(envelope.id.uuidString) for the \(part) of \(id.uuidString)"
      )
    }
    return envelope
  }

  private func path(of id: UUID) -> String {
    "writings/\(id.uuidString.lowercased())"
  }

  private func path(of photo: UUID, _ part: PhotoPart) -> String {
    let path = "photos/\(photo.uuidString.lowercased())"
    switch part {
    case .photo: return path
    case .thumbnail: return path + "/thumbnail"
    }
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
  /// The server answered with a status the request doesn't expect, and the reason it gave. Never
  /// 429, which is `limitReached`.
  case refused(status: Int, reason: String)
  /// A limit of the plan is reached (429); nil when the answer didn't say which.
  case limitReached(PlanLimit?)
  /// The server's answer was not of the shape it promises.
  case unexpectedAnswer(String)

  public var errorDescription: String? {
    switch self {
    case .unreachable:
      "サーバーにつながりませんでした。ネットワークを確かめて、もう一度同期してください。"
    case .refused(status: 401, _):
      "サインインが切れました。もう一度 Apple でサインインしてください。文書はこの端末に残っています。"
    case .refused(status: 402, _):
      "プランの期限が切れているため、この端末の変更をサーバーに送れません。ほかの端末の変更は受け取ります。プランに入り直すと、また送れます。文書はこの端末に残っています。"
    case .limitReached(.requests?):
      Self.dailyLimit("リクエストの回数")
    case .limitReached(.lists?):
      Self.dailyLimit("一覧の回数")
    case .limitReached(.saves?):
      Self.dailyLimit("保存の回数")
    case .limitReached(.photos?):
      Self.dailyLimit("写真の枚数")
    case .limitReached(.storage?):
      "文書の容量か本数がプランの上限に達したため、同期を止めました。文書を減らすか、上のプランに変えてください。文書はこの端末に残っています。"
    case .limitReached(.photoStorage?):
      "写真の容量がプランの上限に達したため、同期を止めました。上のプランに変えると、また送れます。文書と写真はこの端末に残っています。"
    case .limitReached(nil):
      "プランの上限に達したため、同期を止めました。1 日の回数の上限なら、日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。容量の上限なら、文書を減らすか、上のプランに変えてください。文書はこの端末に残っています。"
    case .refused(let status, _):
      "サーバーが同期を断りました（\(status)）。"
    case .unexpectedAnswer:
      "サーバーの答えが読めませんでした。"
    }
  }

  private static func dailyLimit(_ what: String) -> String {
    "今日の\(what)がプランの上限に達したため、同期を止めました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。文書はこの端末に残っています。"
  }
}
