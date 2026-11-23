import Foundation
import Sync
import Testing

struct SealingTests {
  private let ownKey = OwnKey.generate()

  private static let title = "誰にも見せない題"
  private static let body = "まだ誰にも話していない、夜の机で書いた本文。"
  private static let writing = PlainWriting(
    id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.5),
    contents: Data(#"{"title":"\#(title)","body":"\#(body)"}"#.utf8))

  /// Saves `writing` twice through the synchronizer, unchanged but for its updated time, and
  /// gives back every request the server was sent.
  private func interceptTwoSaves() async throws -> (all: [URLRequest], saves: [Data]) {
    let fake = FakeWritingServer(accepting: ownKey.accessToken)
    let server = try WritingServer(
      url: #require(URL(string: "https://fake.test")), accessToken: ownKey.accessToken,
      transport: fake)
    let device = try TwoDevices(server: { server }, ownKey: ownKey).first
    try device.writings.save(Self.writing)
    _ = try await device.synchronizer.sync()
    var again = Self.writing
    again.updated += 60
    try device.writings.save(again)
    _ = try await device.synchronizer.sync()

    let requests = await fake.requests
    let saves = requests.filter { $0.httpMethod == "PUT" }.compactMap(\.httpBody)
    try #require(saves.count == 2)
    return (requests, saves)
  }

  @Test func whatIsSentHoldsNoPlaintext() async throws {
    let (requests, saves) = try await interceptTwoSaves()
    let plaintexts = [Data(Self.title.utf8), Data(Self.body.utf8), Self.writing.contents]
    let encodings = plaintexts + plaintexts.map { Data($0.base64EncodedString().utf8) }

    for request in requests {
      let sent =
        Data((request.url?.absoluteString ?? "").utf8)
        + Data((request.allHTTPHeaderFields ?? [:]).description.utf8) + (request.httpBody ?? Data())
      for plaintext in encodings {
        #expect(sent.firstRange(of: plaintext) == nil)
      }
    }
    // The bytes searched are the writing itself, so the search above had something to miss.
    #expect(try ownKey.open(Envelope(bytes: saves[0])).contents == Self.writing.contents)
  }

  @Test func whatIsSentDoesNotOpenWithAnotherKey() async throws {
    let (_, saves) = try await interceptTwoSaves()
    let stranger = OwnKey.generate()
    for sent in saves {
      let envelope = try Envelope(bytes: sent)
      #expect(throws: OpeningError.self) { try stranger.open(envelope) }
    }
  }

  @Test func savingTheSameContentsTwiceSendsOtherCiphertext() async throws {
    let (_, saves) = try await interceptTwoSaves()
    let (first, second) = (saves[0], saves[1])
    #expect(first.count == second.count)
    // The writing key sealed with the own key, its nonce first; then the contents, nonce first.
    let sealedKey = 28..<88
    let contents = 88..<first.count
    #expect(first[sealedKey].prefix(12) != second[sealedKey].prefix(12))
    #expect(first[sealedKey].dropFirst(12) != second[sealedKey].dropFirst(12))
    #expect(first[contents].prefix(12) != second[contents].prefix(12))
    #expect(first[contents].dropFirst(12) != second[contents].dropFirst(12))
  }

  @Test func sealingTheSameWritingTwiceMakesOtherBytes() async throws {
    let once = try ownKey.seal(Self.writing)
    let twice = try ownKey.seal(Self.writing)
    let a = try await Envelope(bytes: bytes(of: once))
    let b = try await Envelope(bytes: bytes(of: twice))
    #expect(a != b)
    #expect(try ownKey.open(a) == ownKey.open(b))
  }

  @Test(arguments: [0, 1, 1_000, 1_899_884])
  func aSealedWritingOpensToWhatWasSealed(contentsLength: Int) async throws {
    let writing = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.001),
      contents: Data((0..<contentsLength).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
    let envelope = try await Envelope(bytes: bytes(of: ownKey.seal(writing)))
    #expect(envelope.id == writing.id)
    #expect(try ownKey.open(envelope) == writing)
  }

  @Test(arguments: [
    (1_790_000_000.0004, 1_790_000_000.000), (1_790_000_000.0006, 1_790_000_000.001),
  ])
  func theUpdatedTimeIsKeptToTheNearestMillisecond(updated: Double, opened: Double) async throws {
    let writing = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: updated), contents: Data())
    let envelope = try await Envelope(bytes: bytes(of: ownKey.seal(writing)))
    #expect(try ownKey.open(envelope).updated == Date(timeIntervalSince1970: opened))
  }

  @Test(arguments: [
    ("ID", 4), ("updated time", 27), ("sealed key's nonce", 28), ("sealed key", 50),
    ("contents' nonce", 88), ("contents", 105), ("contents' tag", -1),
  ])
  func aSealedWritingAlteredAnywhereDoesNotOpen(_ part: String, at offset: Int) async throws {
    var sent = try await bytes(
      of: ownKey.seal(
        PlainWriting(id: UUID(), updated: .now, contents: Data(repeating: 7, count: 20))))
    let index = offset >= 0 ? offset : sent.count + offset
    sent[index] ^= 0x01
    let envelope = try Envelope(bytes: sent)
    #expect(throws: OpeningError.self, "altering the \(part)") { try ownKey.open(envelope) }
  }

  @Test(arguments: [-1.0, 0.0, 0.0004, 9_007_199_254_741.0])
  func aTimeTheServerCantHoldIsNotSealed(secondsSince1970: Double) {
    let updated = Date(timeIntervalSince1970: secondsSince1970)
    #expect(throws: SealingError.updatedOutOfRange(updated)) {
      try ownKey.seal(PlainWriting(id: UUID(), updated: updated, contents: Data()))
    }
  }

  @Test func theLatestTimeTheServerHoldsIsSealed() throws {
    let updated = Date(timeIntervalSince1970: 9_007_199_254_740.991)
    #expect(throws: Never.self) {
      try ownKey.seal(PlainWriting(id: UUID(), updated: updated, contents: Data()))
    }
  }

  @Test func contentsPastTheServersLimitAreNotSealed() {
    #expect(throws: SealingError.tooLarge(1_900_001)) {
      try ownKey.seal(
        PlainWriting(id: UUID(), updated: .now, contents: Data(count: 1_899_885)))
    }
  }

  @Test(arguments: [
    (Data(count: 115), EnvelopeError.wrongSize(115)),
    (Data(count: 1_900_001), .wrongSize(1_900_001)),
    (Data([0x6d, 0x61, 0x69, 0x02]) + Data(count: 112), .notASealedWriting),
  ])
  func bytesNotOfTheOneShapeAreNotAnEnvelope(_ bytes: Data, _ error: EnvelopeError) {
    #expect(throws: error) { try Envelope(bytes: bytes) }
  }

  @Test func theSmallestAndLargestEnvelopesAreRead() throws {
    for count in [116, 1_900_000] {
      let bytes = Data([0x6d, 0x61, 0x69, 0x01]) + Data(count: count - 4)
      #expect(throws: Never.self) { try Envelope(bytes: bytes) }
    }
  }

  /// What `sealed` sends, read the way the server reads it.
  private func bytes(of sealed: Sealed) async throws -> Data {
    let fake = FakeWritingServer(accepting: "t")
    let server = try WritingServer(
      url: #require(URL(string: "https://fake.test")), accessToken: "t", transport: fake)
    _ = try await server.save(sealed, over: 0)
    return try #require(await fake.requests.last?.httpBody)
  }
}
