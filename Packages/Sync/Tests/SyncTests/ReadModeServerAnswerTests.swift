import CryptoKit
import Foundation
import Sync
import SyncFakes
import Testing

/// How `ReadModeServer`, and the revision a writing comes with, take answers the Worker isn't
/// meant to give.
struct ReadModeServerAnswerTests {
  private let ownKey = OwnKey.generate()

  private func isUnexpected(_ error: any Error) -> Bool {
    guard case .unexpectedAnswer = error as? ServerError else { return false }
    return true
  }

  private func isRefused(_ status: Int) -> (any Error) -> Bool {
    { error in
      guard case .refused(status, _) = error as? ServerError else { return false }
      return true
    }
  }

  @Test func anApprovalAnsweredWithoutAnAgentsTokenIsUnexpected() async {
    let server = ReadModeServer(
      url: ReadModeSetUp.fakeURL, token: "t",
      transport: FixedAnswer(
        status: 201,
        body: #"{"agent":"\#(UUID().uuidString.lowercased())","token":"s1.x.y"}"#))
    let key = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    await #expect(
      performing: { try await server.approve(key, signature: Data([1])) }, throws: isUnexpected)
  }

  /// Answered with another status than each route's, the change is refused.
  @Test func aChangeAnsweredWithAnotherStatusIsRefused() async {
    let server = ReadModeServer(
      url: ReadModeSetUp.fakeURL, token: "t",
      transport: FixedAnswer(status: 200, body: #"{"error":"x"}"#))
    await #expect(performing: { try await server.revoke(UUID()) }, throws: isRefused(200))
    await #expect(performing: { try await server.turnOff() }, throws: isRefused(200))
    await #expect(performing: { try await server.exclude(UUID()) }, throws: isRefused(200))
    await #expect(performing: { try await server.include(UUID()) }, throws: isRefused(200))
  }

  /// The routes name a writing and an agent by their lowercase IDs, as the Worker reads them.
  @Test func writingsAndAgentsAreNamedInLowercase() async throws {
    let transport = FixedAnswer(status: 204, body: "")
    let server = ReadModeServer(url: ReadModeSetUp.fakeURL, token: "t", transport: transport)
    let id = UUID()
    try await server.exclude(id)
    try await server.include(id)
    _ = try await server.revoke(id)
    #expect(
      await transport.lastComponents() == Array(repeating: id.uuidString.lowercased(), count: 3))
  }

  /// The answer to `POST /copies` holds one entry for each copy sent, in the order sent.
  @Test(arguments: ["drop the last", "swap", "another agent"])
  func copiesAnsweredOutOfStepAreUnexpected(_ change: String) async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let rewriting = Rewriting(fake: fake)
    let device = ReadModeSetUp(
      ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
      transport: rewriting)
    _ = try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data("a".utf8)))
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data("b".utf8)))
    _ = try await device.synchronizer.sync()
    await rewriting.set(rewrite: { request, data, response in
      guard request.url?.lastPathComponent == "copies",
        var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        var copies = json["copies"] as? [[String: Any]], copies.count == 2
      else { return (data, response) }
      switch change {
      case "drop the last": copies.removeLast()
      case "swap": copies.swapAt(0, 1)
      default: copies[0]["agent"] = UUID().uuidString.lowercased()
      }
      json["copies"] = copies
      return ((try? JSONSerialization.data(withJSONObject: json)) ?? data, response)
    })
    await #expect(
      performing: { try await device.readMode.turnOn(until: clock.now + 600) },
      throws: isUnexpected)
  }

  /// A revision is 64 lowercase hex digits; any other is an answer of the wrong shape.
  @Test(arguments: [
    String(repeating: "a", count: 62), String(repeating: "a", count: 63),
    String(repeating: "a", count: 65), String(repeating: "A", count: 64),
  ])
  func aWritingWithAnotherRevisionIsUnexpected(_ revision: String) async throws {
    let sealed = try ownKey.seal(PlainWriting(id: UUID(), updated: .now, contents: Data()))
    let saving = FixedAnswer(
      status: 200, body: #"{"revision":"\#(String(repeating: "0", count: 64))"}"#)
    _ = try await WritingServer(url: ReadModeSetUp.fakeURL, token: "t", transport: saving)
      .save(sealed, over: nil)
    let bytes = try #require(await saving.lastBody())
    let server = WritingServer(
      url: ReadModeSetUp.fakeURL, token: "t",
      transport: FixedAnswer(status: 200, bytes: bytes, headers: ["Mai-Revision": revision]))
    await #expect(performing: { try await server.read(sealed.id) }, throws: isUnexpected)
  }

  /// A sync state whose writing key isn't 32 bytes isn't read.
  @Test func aStateWithAShortWritingKeyIsNotRead() async throws {
    let (device, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
    _ = try #require(
      try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey)))
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data()))
    _ = try await device.synchronizer.sync()
    let state = String(decoding: try Data(contentsOf: device.stateFile), as: UTF8.self)
    let short = Data(repeating: 1, count: 31).base64EncodedString()
    let range = try #require(state.firstRange(of: #/"writingKey":"[^"]*"/#))
    let edited = state.replacingCharacters(in: range, with: #""writingKey":"\#(short)""#)
    try Data(edited.utf8).write(to: device.stateFile)
    await #expect(throws: DecodingError.self) {
      _ = try await device.readMode.turnOn(until: clock.now + 600)
    }
  }
}

/// Answers every request with one status, body and headers, keeping each request's last path
/// component and body.
actor FixedAnswer: HTTPTransport {
  private let status: Int
  private let bytes: Data
  private let headers: [String: String]
  private var requests: [URLRequest] = []

  init(status: Int, body: String, headers: [String: String] = [:]) {
    self.init(status: status, bytes: Data(body.utf8), headers: headers)
  }

  init(status: Int, bytes: Data, headers: [String: String] = [:]) {
    self.status = status
    self.bytes = bytes
    self.headers = headers
  }

  func lastComponents() -> [String] {
    requests.compactMap { $0.url?.lastPathComponent }
  }

  func lastBody() -> Data? {
    requests.last?.httpBody
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: nil, headerFields: headers)
    else { throw URLError(.badURL) }
    return (bytes, response)
  }
}
