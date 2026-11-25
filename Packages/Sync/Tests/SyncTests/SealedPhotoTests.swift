import Foundation
import Sync
import SyncFakes
import Testing

struct SealedPhotoTests {
  private let ownKey = OwnKey.generate()
  private let token = "s1.session.token"
  private static let photo = PlainPhoto(
    id: UUID(), photo: Data("夜の机で撮った写真".utf8), thumbnail: Data("その小さな写真".utf8))

  /// Sends `photo` through the fake and gives back the bytes of each part, as the server keeps
  /// them.
  private func sent(_ photo: PlainPhoto) async throws -> (photo: Data, thumbnail: Data) {
    let fake = FakeWritingServer(accepting: token)
    let server = try WritingServer(
      url: #require(URL(string: "https://fake.test")), token: token, transport: fake)
    let sealed = try ownKey.seal(photo)
    _ = try await server.send(sealed.thumbnail)
    _ = try await server.send(sealed.photo)
    let bodies = await fake.requests.compactMap(\.httpBody)
    try #require(bodies.count == 2)
    return (bodies[1], bodies[0])
  }

  /// Each part: `6d 61 70 01`, the photo's ID, the part (1 the photo, 2 the thumbnail), the photo
  /// key sealed (60 bytes), then the part sealed (28 bytes more than it).
  @Test func eachPartIsLaidOutAsTheServerReadmeSays() async throws {
    let (photo, thumbnail) = try await sent(Self.photo)
    let id = withUnsafeBytes(of: Self.photo.id.uuid) { Data($0) }
    #expect(photo.prefix(21) == Data([0x6d, 0x61, 0x70, 0x01]) + id + Data([1]))
    #expect(thumbnail.prefix(21) == Data([0x6d, 0x61, 0x70, 0x01]) + id + Data([2]))
    #expect(photo.count == 21 + 60 + 12 + Self.photo.photo.count + 16)
    #expect(thumbnail.count == 21 + 60 + 12 + Self.photo.thumbnail.count + 16)
  }

  @Test func whatIsSentHoldsNoPlaintextAndOpensWithTheOwnKeyAlone() async throws {
    let (photo, thumbnail) = try await sent(Self.photo)
    for (sent, plain) in [(photo, Self.photo.photo), (thumbnail, Self.photo.thumbnail)] {
      #expect(sent.firstRange(of: plain) == nil)
      let envelope = try PhotoEnvelope(bytes: sent)
      #expect(try ownKey.open(envelope) == plain)
      #expect(throws: PhotoOpeningError.self) {
        try OwnKey.generate().open(envelope)
      }
    }
  }

  /// The header is sealed in, so the server can't pass one part off as the other, or as another
  /// photo's.
  @Test func aPartRelabelledDoesNotOpen() async throws {
    let (photo, _) = try await sent(Self.photo)
    var asThumbnail = photo
    asThumbnail[20] = 2
    #expect(throws: PhotoOpeningError.self) {
      try ownKey.open(PhotoEnvelope(bytes: asThumbnail))
    }
    var asAnother = photo
    asAnother[4] ^= 0xff
    #expect(throws: PhotoOpeningError.self) { try ownKey.open(PhotoEnvelope(bytes: asAnother)) }
    var altered = photo
    altered[altered.count - 20] ^= 0x01
    #expect(throws: PhotoOpeningError.self) { try ownKey.open(PhotoEnvelope(bytes: altered)) }
  }

  @Test(arguments: PhotoPart.allCases)
  func aPartLargerThanTheServerTakesIsNotSealed(_ part: PhotoPart) throws {
    let large = Data(count: part.largest - 21 - 60 - 28 + 1)
    let photo = PlainPhoto(
      id: UUID(), photo: part == .photo ? large : Data([1]),
      thumbnail: part == .thumbnail ? large : Data([1]))
    #expect(throws: SealingError.photoTooLarge(part.largest + 1, largest: part.largest)) {
      try ownKey.seal(photo)
    }
  }

  @Test func whatIsNotASealedPhotoIsRefused() throws {
    #expect(throws: PhotoEnvelopeError.self) { try PhotoEnvelope(bytes: Data(count: 108)) }
    #expect(throws: PhotoEnvelopeError.self) {
      try PhotoEnvelope(bytes: Data([0x6d, 0x61, 0x69, 0x01]) + Data(count: 105))
    }
    #expect(throws: PhotoEnvelopeError.self) {
      try PhotoEnvelope(
        bytes: Data([0x6d, 0x61, 0x70, 0x01]) + Data(count: 16) + Data([3]) + Data(count: 88))
    }
    #expect(throws: PhotoEnvelopeError.self) {
      try PhotoEnvelope(
        bytes: Data([0x6d, 0x61, 0x70, 0x01]) + Data(count: 16) + Data([2])
          + Data(count: PhotoPart.thumbnail.largest))
    }
  }
}
