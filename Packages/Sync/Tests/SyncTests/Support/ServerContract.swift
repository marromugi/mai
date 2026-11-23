import Foundation
import Sync
import SyncFakes
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

  /// `server` lets in `ownKey`'s token; `stranger` holds another.
  func check(server: WritingServer, stranger: WritingServer, ownKey: OwnKey) async throws {
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
