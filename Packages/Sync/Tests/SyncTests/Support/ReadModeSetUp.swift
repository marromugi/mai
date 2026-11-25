import Foundation
import Sync
import SyncFakes
import Synchronization
import Testing

/// A clock the test moves.
final class TestClock: Sendable {
  private let time: Mutex<Date>

  init(_ start: Date = Date(timeIntervalSince1970: 1_790_000_000)) {
    time = Mutex(start)
  }

  var now: Date { time.withLock { $0 } }

  func advance(by seconds: TimeInterval) {
    time.withLock { $0 += seconds }
  }
}

/// One device of an account, its sync and its read mode sharing one state file, and the agent's
/// reads of the same server.
struct ReadModeSetUp {
  static let fakeURL: URL = {
    guard let url = URL(string: "https://fake.test") else {
      preconditionFailure("https://fake.test is a URL")
    }
    return url
  }()
  static let fakeToken = "s1.session.token"

  let url: URL
  let transport: any HTTPTransport
  let writings = MemoryWritingStore()
  let synchronizer: Synchronizer
  let readMode: ReadMode
  let stateFile: URL

  /// Rewrites the sync's state as it was kept before it held the writing keys.
  func forgetWritingKeys() throws {
    // A dictionary keyed by UUID is kept as an array of keys and values, one after the other.
    let state = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [Any])
    let forgotten = state.map { item in
      (item as? [String: Any])?.filter { $0.key != "writingKey" } ?? item
    }
    try JSONSerialization.data(withJSONObject: forgotten).write(to: stateFile)
  }

  init(ownKey: OwnKey, url: URL, token: String, transport: any HTTPTransport) {
    self.url = url
    self.transport = transport
    let stateFile = FileManager.default.temporaryDirectory.appending(
      path: "mai-read-mode-tests-\(UUID().uuidString)/state.json", directoryHint: .notDirectory)
    self.stateFile = stateFile
    readMode = ReadMode(
      server: ReadModeServer(url: url, token: token, transport: transport), ownKey: ownKey,
      stateFile: stateFile)
    synchronizer = Synchronizer(
      writings: writings, photos: MemoryPhotoStore(), stateFile: stateFile,
      server: WritingServer(url: url, token: token, transport: transport), ownKey: ownKey,
      readMode: readMode)
  }

  /// A device of an account on `fake`.
  static func onFake(ownKey: OwnKey, fake: FakeWritingServer) -> ReadModeSetUp {
    ReadModeSetUp(ownKey: ownKey, url: fakeURL, token: fakeToken, transport: fake)
  }

  /// A device of a new account on a fake of its own, whose clock is the one given back.
  static func onFake(ownKey: OwnKey) -> (ReadModeSetUp, TestClock) {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: fakeToken, now: { clock.now })
    return (onFake(ownKey: ownKey, fake: fake), clock)
  }

  /// What `GET /agent/writings/<ID>` gives the agent with `token`: nil for a 404.
  func agentRead(_ id: UUID, token: String) async throws -> (bytes: Data, wrapped: Data)? {
    let (bytes, response) = try await agentGet(
      "agent/writings/\(id.uuidString.lowercased())", token: token)
    guard response.statusCode != 404 else { return nil }
    #expect(response.statusCode == 200)
    let wrapped = try #require(response.value(forHTTPHeaderField: "Mai-Wrapped-Key"))
    return (bytes, try #require(Data(hex: wrapped)))
  }

  /// The agent with `token`, reading the same server.
  func agent(token: String) -> AgentServer {
    AgentServer(url: url, token: token, transport: transport)
  }

  /// The IDs `GET /agent/writings` lists for the agent with `token`.
  func agentList(token: String) async throws -> Set<UUID> {
    Set(try await agent(token: token).list().map(\.id))
  }

  /// The status `GET /agent/writings` answers the agent with `token`.
  func agentStatus(token: String) async throws -> Int {
    try await agentGet("agent/writings", token: token).1.statusCode
  }

  private func agentGet(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url.appending(path: path))
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    return try await transport.send(request)
  }
}

extension Data {
  init?(hex: String) {
    let digits = Array(hex.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes = Data()
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)
      else { return nil }
      bytes.append(byte)
    }
    self = bytes
  }
}
