import Foundation
import Sync
import Testing

/// The writing in `Server/test/fixtures/sealed-writing.json`, which the Worker's tests open by the
/// layout in `Server/README.md` and keep, so the app and the server read one shape.
struct FixtureTests {
  private struct Fixture: Decodable {
    let ownKey: String
    let id: UUID
    let updated: Int64
    let contents: String
    let envelope: String
  }

  private let fixture: Fixture
  private let ownKey: OwnKey

  init() throws {
    let file = URL(filePath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../Server/test/fixtures/sealed-writing.json")
    fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
    ownKey = try OwnKey(rawRepresentation: Self.bytes(fixture.ownKey))
  }

  private var writing: PlainWriting {
    PlainWriting(
      id: fixture.id, updated: Date(timeIntervalSince1970: Double(fixture.updated) / 1000),
      contents: Data(fixture.contents.utf8))
  }

  @Test func opensToTheWritingSealed() throws {
    let envelope = try Envelope(bytes: Self.bytes(fixture.envelope))
    #expect(try ownKey.open(envelope) == writing)
  }

  @Test func isWhatSealingTheWritingSends() async throws {
    let fake = FakeWritingServer(accepting: "t")
    let server = try WritingServer(
      url: #require(URL(string: "https://fake.test")), accessToken: "t", transport: fake)
    _ = try await server.save(ownKey.seal(writing), over: 0)
    let sent = try #require(await fake.requests.last?.httpBody)
    let kept = try Self.bytes(fixture.envelope)
    #expect(sent.count == kept.count)
    #expect(sent.prefix(28) == kept.prefix(28))
  }

  private static func bytes(_ hex: String) throws -> Data {
    let digits = Array(hex.utf8)
    return Data(
      try stride(from: 0, to: digits.count, by: 2).map { index in
        try #require(UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16))
      })
  }
}
