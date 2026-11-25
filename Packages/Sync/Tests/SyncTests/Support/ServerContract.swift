import Foundation
import Sync
import Synchronization
import Testing

/// What `Synchronizer` relies on from the server, run on `FakeWritingServer` in
/// `WritingServerTests` and on the Worker in `WritingServerContractTests`.
enum ServerContract: CaseIterable, Sendable {
  case aNewWritingIsSavedAndReadBackWithOneRevision
  case aSaveOverAnotherRevisionIsRefusedWithTheCurrentOne
  case aSaveOverTheCurrentRevisionMakesANewOne
  case aSaveClaimingARevisionOfAWritingNeverSavedIsRefused
  case aWritingNeverSavedIsNotThere
  case anotherTokenIsRefused
  case aPhotoIsSentAndReadBackWhole
  case aPhotoPartSentAgainIsLeftAsItWas
  case aPhotoNeverSentIsNotThere
  case anotherTokenCanNeitherSendNorReadAPhoto

  /// `server` lets in its session's token; `stranger` holds another. `ownKey` seals and opens.
  func check(server: WritingServer, stranger: WritingServer, ownKey: OwnKey) async throws {
    let photo = PlainPhoto(
      id: UUID(), photo: Data(repeating: 0xd8, count: 40_000), thumbnail: Data("小さな写真".utf8))
    let first = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.123),
      contents: Data("一稿".utf8))
    let second = PlainWriting(
      id: first.id, updated: Date(timeIntervalSince1970: 1_790_000_100.5),
      contents: Data("二稿".utf8))

    switch self {
    case .aNewWritingIsSavedAndReadBackWithOneRevision:
      guard case .saved(let revision) = try await server.save(ownKey.seal(first), over: nil) else {
        Issue.record("a new writing is saved")
        return
      }
      let read = try #require(try await server.read(first.id))
      #expect(read.revision == revision)
      #expect(try ownKey.open(read.envelope) == first)
      let listed = try await server.list().filter { $0.id == first.id }
      #expect(listed.map(\.revision) == [revision])
      #expect(listed.map(\.updated) == [1_790_000_000_123])
      #expect(listed.map(\.size) == [4 + 16 + 8 + 60 + 12 + 6 + 16])

    case .aSaveOverAnotherRevisionIsRefusedWithTheCurrentOne:
      let saved = try await server.save(ownKey.seal(first), over: nil)
      guard case .saved(let current) = saved else {
        Issue.record("a new writing is saved")
        return
      }
      #expect(try await server.save(ownKey.seal(second), over: nil) == .conflict(current: current))
      let read = try #require(try await server.read(first.id))
      #expect(try ownKey.open(read.envelope) == first)

    case .aSaveOverTheCurrentRevisionMakesANewOne:
      guard case .saved(let current) = try await server.save(ownKey.seal(first), over: nil),
        case .saved(let next) = try await server.save(ownKey.seal(second), over: current)
      else {
        Issue.record("both saves are made")
        return
      }
      #expect(next != current)
      let read = try #require(try await server.read(first.id))
      #expect(read.revision == next)
      #expect(try ownKey.open(read.envelope) == second)
      #expect(try await server.save(ownKey.seal(first), over: current) == .conflict(current: next))

    case .aSaveClaimingARevisionOfAWritingNeverSavedIsRefused:
      let other = PlainWriting(id: UUID(), updated: first.updated, contents: first.contents)
      guard case .saved(let revision) = try await server.save(ownKey.seal(other), over: nil) else {
        Issue.record("a new writing is saved")
        return
      }
      #expect(try await server.save(ownKey.seal(first), over: revision) == .conflict(current: nil))
      #expect(try await server.read(first.id) == nil)

    case .aWritingNeverSavedIsNotThere:
      #expect(try await server.read(UUID()) == nil)
      #expect(try await server.list().contains { $0.id == first.id } == false)

    case .anotherTokenIsRefused:
      await #expect {
        try await stranger.save(ownKey.seal(first), over: nil)
      } throws: { error in
        guard case ServerError.refused(status: 401, let reason) = error else { return false }
        return !reason.isEmpty
      }
      #expect(try await server.read(first.id) == nil)
      await #expect {
        try await stranger.list()
      } throws: { error in
        guard case ServerError.refused(status: 401, _) = error else { return false }
        return true
      }

    case .aPhotoIsSentAndReadBackWhole:
      let sealed = try ownKey.seal(photo)
      #expect(try await server.send(sealed.thumbnail) == .sent)
      #expect(try await server.readPhoto(photo.id, .photo) == nil)
      #expect(try await server.send(sealed.photo) == .sent)
      let thumbnail = try #require(try await server.readPhoto(photo.id, .thumbnail))
      let whole = try #require(try await server.readPhoto(photo.id, .photo))
      #expect(try ownKey.open(thumbnail) == photo.thumbnail)
      #expect(try ownKey.open(whole) == photo.photo)

    case .aPhotoPartSentAgainIsLeftAsItWas:
      let first = try ownKey.seal(photo)
      _ = try await server.send(first.photo)
      let again = try ownKey.seal(
        PlainPhoto(id: photo.id, photo: Data("別の写真".utf8), thumbnail: photo.thumbnail))
      #expect(try await server.send(again.photo) == .alreadyThere)
      let read = try #require(try await server.readPhoto(photo.id, .photo))
      #expect(try ownKey.open(read) == photo.photo)

    case .aPhotoNeverSentIsNotThere:
      #expect(try await server.readPhoto(photo.id, .photo) == nil)
      #expect(try await server.readPhoto(photo.id, .thumbnail) == nil)

    case .anotherTokenCanNeitherSendNorReadAPhoto:
      let sealed = try ownKey.seal(photo)
      await #expect {
        try await stranger.send(sealed.thumbnail)
      } throws: { error in
        guard case ServerError.refused(status: 401, _) = error else { return false }
        return true
      }
      _ = try await server.send(sealed.thumbnail)
      await #expect {
        try await stranger.readPhoto(photo.id, .thumbnail)
      } throws: { error in
        guard case ServerError.refused(status: 401, _) = error else { return false }
        return true
      }
    }
  }
}

/// Two devices, each with its own store and sync state, sharing one own key and one server.
struct TwoDevices {
  let first: Device
  let second: Device

  init(server: @escaping @Sendable () -> WritingServer, ownKey: OwnKey) throws {
    first = try Device(server: server(), ownKey: ownKey)
    second = try Device(server: server(), ownKey: ownKey)
  }

  struct Device {
    let writings = MemoryWritingStore()
    let photos = MemoryPhotoStore()
    let synchronizer: Synchronizer

    init(server: WritingServer, ownKey: OwnKey) throws {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      synchronizer = Synchronizer(
        writings: writings, photos: photos, stateFile: directory.appending(path: "state.json"),
        server: server, ownKey: ownKey)
    }
  }

  /// A photo taken on the first device reaches the second with the writing that points at it.
  func checkAPhotoTravelsWithItsWriting() async throws {
    let photo = PlainPhoto(
      id: UUID(), photo: Data("写真".utf8), thumbnail: Data("サムネイル".utf8))
    try first.photos.keep(photo)
    let written = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.25),
      contents: .pointing(at: [photo.id]))
    try first.writings.save(written)
    let sent = try await first.synchronizer.sync()
    #expect(sent.photosSent == [photo.id])
    #expect(sent.sent == [written.id])

    let received = try await second.synchronizer.sync()
    #expect(received.received == [written.id])
    #expect(received.photosReceived == [photo.id])
    #expect(try second.photos.read(photo.id) == photo)
  }

  /// A writing written on the first device reaches the second, and the second's edit comes back.
  func checkAWritingAndItsEditTravelBothWays() async throws {
    let written = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.25),
      contents: Data("朝に書いた".utf8))
    try first.writings.save(written)
    #expect(try await first.synchronizer.sync().sent == [written.id])

    #expect(try await second.synchronizer.sync().received == [written.id])
    #expect(try second.writings.all() == [written])

    let edited = PlainWriting(
      id: written.id, updated: Date(timeIntervalSince1970: 1_790_000_600),
      contents: Data("夜に書き足した".utf8))
    try second.writings.save(edited)
    #expect(try await second.synchronizer.sync().sent == [written.id])

    #expect(try await first.synchronizer.sync().received == [written.id])
    #expect(try first.writings.all() == [edited])
  }
}

/// Writings kept in memory, standing in for the app's store.
final class MemoryWritingStore: PlainWritingStore {
  private let writings = Mutex<[UUID: PlainWriting]>([:])

  func all() throws -> [PlainWriting] {
    writings.withLock { $0.values.sorted { $0.id.uuidString < $1.id.uuidString } }
  }

  func save(_ writing: PlainWriting) throws {
    writings.withLock { $0[writing.id] = writing }
  }

  /// The photos of contents made by `Data.pointing(at:)`; none for any other contents.
  func photos(of writing: PlainWriting) -> [UUID] {
    (try? JSONDecoder().decode(Pointing.self, from: writing.contents))?.photos ?? []
  }
}

/// Contents that point at photos, as `MemoryWritingStore` reads them.
private struct Pointing: Codable {
  let photos: [UUID]
}

extension Data {
  static func pointing(at photos: [UUID]) -> Data {
    do {
      return try JSONEncoder().encode(Pointing(photos: photos))
    } catch {
      preconditionFailure("A list of UUIDs always encodes: \(error)")
    }
  }
}

/// Photos kept in memory, standing in for the app's photo store.
final class MemoryPhotoStore: PlainPhotoStore {
  private let photos = Mutex<[UUID: PlainPhoto]>([:])

  func read(_ id: UUID) throws -> PlainPhoto? {
    photos.withLock { $0[id] }
  }

  func keep(_ photo: PlainPhoto) throws {
    photos.withLock { photos in
      if photos[photo.id] == nil { photos[photo.id] = photo }
    }
  }
}
