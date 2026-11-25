import Agent
import CryptoKit
import Foundation
import Sync
import SyncFakes
import Synchronization
import Testing

/// A key the tests make in software: the Secure Enclave isn't on CI's Macs.
extension P256.KeyAgreement.PrivateKey: AgentPrivateKey {
  public static func generate() -> Self { Self() }

  public init(kept: Data) throws {
    try self.init(rawRepresentation: kept)
  }

  public var kept: Data { rawRepresentation }
}

/// A clock the test moves.
final class TestClock: Sendable {
  private let time = Mutex(Date(timeIntervalSince1970: 1_790_000_000))

  var now: Date { time.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    time.withLock { $0 += seconds }
  }
}

/// One device of an account on a fake server, and a directory of the agent's own.
struct Account {
  static let url: URL = {
    guard let url = URL(string: "https://mai.example.test") else {
      preconditionFailure("https://mai.example.test is a URL")
    }
    return url
  }()
  static let token = "s1.session.token"

  let clock = TestClock()
  let fake: FakeWritingServer
  let ownKey = OwnKey.generate()
  let writings = MemoryWritings()
  let readMode: ReadMode
  let synchronizer: Synchronizer
  let directory: URL

  init() {
    let clock = clock
    fake = FakeWritingServer(accepting: Self.token, now: { clock.now })
    directory = FileManager.default.temporaryDirectory.appending(
      path: "mai-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let stateFile = directory.appending(path: "device/state.json")
    readMode = ReadMode(
      server: ReadModeServer(url: Self.url, token: Self.token, transport: fake), ownKey: ownKey,
      stateFile: stateFile)
    synchronizer = Synchronizer(
      writings: writings, photos: NoPhotos(), stateFile: stateFile,
      server: WritingServer(url: Self.url, token: Self.token, transport: fake), ownKey: ownKey,
      readMode: readMode)
  }

  var file: PairingFile { PairingFile(directory: directory.appending(path: "agent")) }

  /// Approves `key` on the device, and gives back the line it hands the agent.
  func approve(_ key: P256.KeyAgreement.PrivateKey) async throws -> (id: UUID, line: String) {
    let approved = try #require(try await readMode.approve(AgentKey(key.publicKey)))
    return (approved.id, readMode.handoff(approved))
  }

  /// Saves a writing on the device, as the app seals its contents.
  @discardableResult
  func write(
    _ title: String, _ body: String, links: [(Range<Int>, String)] = [], at seconds: TimeInterval
  ) throws -> PlainWriting {
    try write(
      contents: [
        "title": title, "body": body, "photos": [String](),
        "links": links.map { ["range": [$0.0.lowerBound, $0.0.upperBound], "url": $0.1] },
      ], at: seconds)
  }

  /// Saves a writing on the device whose contents are `contents` as JSON.
  @discardableResult
  func write(contents: [String: Any], at seconds: TimeInterval) throws -> PlainWriting {
    let writing = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000 + seconds),
      contents: try JSONSerialization.data(withJSONObject: contents))
    writings.save(writing)
    return writing
  }
}

final class MemoryWritings: PlainWritingStore {
  private let writings = Mutex<[UUID: PlainWriting]>([:])

  func all() -> [PlainWriting] {
    writings.withLock { Array($0.values) }
  }

  func save(_ writing: PlainWriting) {
    writings.withLock { $0[writing.id] = writing }
  }

  func photos(of writing: PlainWriting) -> [UUID] { [] }
}

struct NoPhotos: PlainPhotoStore {
  func read(_ id: UUID) -> PlainPhoto? { nil }
  func keep(_ photo: PlainPhoto) {}
}

/// The fake server, with each answer passed through `change`, and the paths asked for counted.
final class Tampering: HTTPTransport {
  let fake: FakeWritingServer
  let change: @Sendable (URLRequest, Data, HTTPURLResponse) -> (Data, HTTPURLResponse)
  private let asked = Mutex<[String]>([])

  init(
    _ fake: FakeWritingServer,
    change: @escaping @Sendable (URLRequest, Data, HTTPURLResponse) -> (Data, HTTPURLResponse) = {
      ($1, $2)
    }
  ) {
    self.fake = fake
    self.change = change
  }

  var paths: [String] { asked.withLock { $0 } }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    asked.withLock { $0.append(request.url?.path() ?? "") }
    let (data, response) = try await fake.send(request)
    return change(request, data, response)
  }

  /// An answer to `request` with `status`, `headers` and `body`.
  static func answer(
    _ request: URLRequest, _ status: Int, headers: [String: String] = [:], body: Data = Data()
  ) -> (Data, HTTPURLResponse) {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: headers)
    else {
      preconditionFailure("A request made by AgentServer has a URL")
    }
    return (body, response)
  }

  /// Whether `request` is for the copy of `writing`.
  static func isCopy(_ request: URLRequest, of writing: UUID) -> Bool {
    request.url?.lastPathComponent == writing.uuidString.lowercased()
  }
}
