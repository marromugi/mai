import Foundation
import Sync
import Synchronization
import Testing

/// What `Synchronizer` relies on from the server, run on `FakeWritingServer` in
/// `WritingServerTests` and on the Worker in `WritingServerContractTests`.
enum ServerContract: CaseIterable, Sendable {
  case aNewWritingIsSavedAsVersion1AndReadBack
  case aSaveOverAnOlderVersionIsRefusedWithTheCurrentOne
  case aSaveOverTheCurrentVersionMakesTheNext
  case aWritingNeverSavedIsNotThere
  case anotherTokenIsRefused

  /// `server` lets in `ownKey`'s token; `stranger` holds another.
  func check(server: WritingServer, stranger: WritingServer, ownKey: OwnKey) async throws {
    let first = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.123),
      contents: Data("一稿".utf8))
    let second = PlainWriting(
      id: first.id, updated: Date(timeIntervalSince1970: 1_790_000_100.5),
      contents: Data("二稿".utf8))

    switch self {
    case .aNewWritingIsSavedAsVersion1AndReadBack:
      let sealed = try ownKey.seal(first)
      #expect(try await server.save(sealed, over: 0) == .saved(version: 1))
      let read = try #require(try await server.read(first.id))
      #expect(read.version == 1)
      #expect(try ownKey.open(read.envelope) == first)
      let listed = try await server.list().filter { $0.id == first.id }
      #expect(listed.map(\.version) == [1])
      #expect(listed.map(\.updated) == [1_790_000_000_123])
      #expect(listed.map(\.size) == [4 + 16 + 8 + 60 + 12 + 6 + 16])

    case .aSaveOverAnOlderVersionIsRefusedWithTheCurrentOne:
      _ = try await server.save(ownKey.seal(first), over: 0)
      #expect(try await server.save(ownKey.seal(second), over: 0) == .conflict(current: 1))
      let read = try #require(try await server.read(first.id))
      #expect(try ownKey.open(read.envelope) == first)

    case .aSaveOverTheCurrentVersionMakesTheNext:
      _ = try await server.save(ownKey.seal(first), over: 0)
      #expect(try await server.save(ownKey.seal(second), over: 1) == .saved(version: 2))
      let read = try #require(try await server.read(first.id))
      #expect(read.version == 2)
      #expect(try ownKey.open(read.envelope) == second)

    case .aWritingNeverSavedIsNotThere:
      #expect(try await server.read(UUID()) == nil)
      #expect(try await server.list().contains { $0.id == first.id } == false)

    case .anotherTokenIsRefused:
      await #expect {
        try await stranger.save(ownKey.seal(first), over: 0)
      } throws: { error in
        guard case ServerError.refused(status: 401, _) = error else { return false }
        return true
      }
      #expect(try await server.read(first.id) == nil)
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
    let synchronizer: Synchronizer

    init(server: WritingServer, ownKey: OwnKey) throws {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
      synchronizer = Synchronizer(
        writings: writings, stateFile: directory.appending(path: "state.json"), server: server,
        ownKey: ownKey)
    }
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
}
