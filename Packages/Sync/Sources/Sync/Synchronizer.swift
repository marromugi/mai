import CryptoKit
import Foundation

/// Where the device keeps its writings in plain bytes. Saving a writing replaces the one with its
/// ID.
public protocol PlainWritingStore: Sendable {
  func all() async throws -> [PlainWriting]
  /// Throws a `OneWritingFailure` when it is this writing alone that can't be saved, such as
  /// contents the store can't read; any other error stops the sync.
  func save(_ writing: PlainWriting) async throws
  /// Saves `copy`, the device's edit as a new writing, then `received` in place of that edit. A
  /// store that can refuse `received` refuses before saving either, so a refusal leaves no copy.
  func keepBoth(_ received: PlainWriting, copy: PlainWriting) async throws
}

extension PlainWritingStore {
  /// Saves `copy`, then `received`, for a store that refuses no writing for having changed.
  public func keepBoth(_ received: PlainWriting, copy: PlainWriting) async throws {
    try await save(copy)
    try await save(received)
  }
}

/// A store's failure to save one writing, which leaves the sync to go on with the others.
public protocol OneWritingFailure: Error {}

/// What one `Synchronizer.sync()` did, by writing ID.
public struct SyncReport: Sendable, Equatable {
  /// Saved on the server.
  public var sent: Set<UUID> = []
  /// Taken from the server into the device's store.
  public var received: Set<UUID> = []
  /// Changed on both sides since the last sync: the server's save kept the ID, and the
  /// device's was kept as a new writing, by the ID given here.
  public var keptBoth: [UUID: UUID] = [:]
  /// Changed on the server while this sync ran; the next sync takes them.
  public var left: Set<UUID> = []

  public init() {}
}

/// Brings the device's writings and the server's to the same saves, sealing what it sends.
/// A writing changed on both sides since the last sync is kept twice, so neither edit is lost.
public actor Synchronizer {
  private let writings: any PlainWritingStore
  private let state: SyncState
  private let server: WritingServer
  private let ownKey: OwnKey
  private var running: Task<SyncReport, any Error>?

  /// `stateFile` keeps, for each writing, the server's revision and the device's updated time when
  /// they last matched; it is made on the first sync.
  public init(
    writings: any PlainWritingStore, stateFile: URL, server: WritingServer, ownKey: OwnKey
  ) {
    self.writings = writings
    state = SyncState(file: stateFile)
    self.server = server
    self.ownKey = ownKey
  }

  /// Runs after any sync already running has ended.
  public func sync() async throws -> SyncReport {
    let previous = running
    let task = Task {
      _ = await previous?.result
      return try await syncOnce()
    }
    running = task
    return try await task.value
  }

  private func syncOnce() async throws -> SyncReport {
    var synced = try state.load()
    let mine = Dictionary(try await writings.all().map { ($0.id, $0) }) { first, _ in
      preconditionFailure("The device's store keeps one writing per ID, but gave \(first.id) twice")
    }
    var theirs: [UUID: ServerEntry] = [:]
    for entry in try await server.list() {
      guard theirs.updateValue(entry, forKey: entry.id) == nil else {
        throw ServerError.unexpectedAnswer("the server listed \(entry.id.uuidString) twice")
      }
    }
    var report = SyncReport()
    var failures: [UUID: any Error] = [:]

    for id in Set(mine.keys).union(theirs.keys) {
      do {
        try await sync(
          id, mine: mine[id], theirs: theirs[id], synced: &synced, reporting: &report)
      } catch let error as SealingError {
        failures[id] = error
      } catch let error as OpeningError {
        failures[id] = error
      } catch let error as ServerError where error.concernsOneWriting {
        failures[id] = error
      } catch let error as any OneWritingFailure {
        failures[id] = error
      }
    }
    guard failures.isEmpty else {
      throw SyncFailures(report: report, failures: failures)
    }
    return report
  }

  /// Syncs one writing. A failure that concerns this writing alone leaves the others to go on.
  private func sync(
    _ id: UUID, mine writing: PlainWriting?, theirs entry: ServerEntry?,
    synced: inout [UUID: SyncState.Entry], reporting report: inout SyncReport
  ) async throws {
    let last = synced[id]
    let deviceChanged = writing.map { Layout.milliseconds(of: $0.updated) != last?.updated }
    guard let entry else {
      guard let writing else { preconditionFailure("Each ID is the device's or the server's") }
      try await send(writing, over: nil, into: &synced, reporting: &report)
      return
    }
    guard entry.revision != last?.revision || writing == nil else {
      if let writing, deviceChanged == true {
        try await send(writing, over: entry.revision, into: &synced, reporting: &report)
      }
      return
    }
    guard let (received, revision) = try await read(id) else {
      report.left.insert(id)
      return
    }
    var copy: PlainWriting?
    if let writing, deviceChanged == true, !received.matches(writing) {
      copy = PlainWriting(id: writing.copyID, updated: writing.updated, contents: writing.contents)
    }
    if let copy {
      try await writings.keepBoth(received, copy: copy)
      report.keptBoth[id] = copy.id
    } else {
      try await writings.save(received)
    }
    // The server's copy and the sync state are kept before the device's copy is sent, so a
    // failed send leaves only a new writing for the next sync to send, not a second copy.
    synced[id] = SyncState.Entry(
      revision: revision, updated: Layout.milliseconds(of: received.updated))
    try state.save(synced)
    report.received.insert(id)
    if let copy {
      try await send(copy, over: nil, into: &synced, reporting: &report)
    }
  }

  private func send(
    _ writing: PlainWriting, over base: Revision?, into synced: inout [UUID: SyncState.Entry],
    reporting report: inout SyncReport
  ) async throws {
    switch try await server.save(ownKey.seal(writing), over: base) {
    case .saved(let revision):
      synced[writing.id] = SyncState.Entry(
        revision: revision, updated: Layout.milliseconds(of: writing.updated))
      try state.save(synced)
      report.sent.insert(writing.id)
    case .conflict:
      report.left.insert(writing.id)
    }
  }

  /// The server's writing with `id`, opened, and its revision.
  private func read(_ id: UUID) async throws -> (PlainWriting, Revision)? {
    guard let (envelope, revision) = try await server.read(id) else { return nil }
    guard envelope.id == id else {
      throw ServerError.unexpectedAnswer(
        "the server gave writing \(envelope.id.uuidString) for \(id.uuidString)")
    }
    return (try ownKey.open(envelope), revision)
  }
}

/// A sync that went through every writing, but some failed alone: sealed too large, sealed with
/// another own key, refused by the server, or not saved by the store (`OneWritingFailure`).
/// `report` is what the rest did.
public struct SyncFailures: LocalizedError {
  public let report: SyncReport
  public let failures: [UUID: any Error]

  public var errorDescription: String? {
    "\(failures.count) 件の文書を同期できませんでした。"
  }
}

extension ServerError {
  /// Whether the failure is about one writing, so the others can still sync. An ended session and
  /// a plan's limit (429) are the account's, and stop the sync. A lapsed plan (402) refuses only
  /// writes, so the sync goes on taking in the server's writings.
  fileprivate var concernsOneWriting: Bool {
    switch self {
    case .unreachable, .refused(status: 401, _), .refused(status: 429, _): false
    case .refused, .unexpectedAnswer: true
    }
  }
}

extension PlainWriting {
  /// The ID of this edit's copy, kept beside the server's save of the same writing. The same edit
  /// always gets the same ID, so a sync that stops after keeping the copy and runs again keeps it
  /// once. A UUID of version 8 (RFC 9562) made from the SHA-256 of the ID, the updated time to the
  /// millisecond, and the contents.
  fileprivate var copyID: UUID {
    var hash = SHA256()
    withUnsafeBytes(of: id.uuid) { hash.update(bufferPointer: $0) }
    withUnsafeBytes(of: (Layout.milliseconds(of: updated) ?? 0).bigEndian) {
      hash.update(bufferPointer: $0)
    }
    hash.update(data: contents)
    var bytes = Array(hash.finalize().prefix(16))
    bytes[6] = bytes[6] & 0x0f | 0x80
    bytes[8] = bytes[8] & 0x3f | 0x80
    return UUID(uuid: Layout.uuid(Data(bytes)))
  }

  /// The same contents and updated time, to the millisecond the server keeps.
  fileprivate func matches(_ other: PlainWriting) -> Bool {
    contents == other.contents
      && Layout.milliseconds(of: updated) == Layout.milliseconds(of: other.updated)
  }
}

/// For each writing, the server's revision and the device's updated time when they last matched.
struct SyncState {
  struct Entry: Codable, Equatable {
    let revision: Revision
    let updated: UInt64?
  }

  let file: URL

  func load() throws -> [UUID: Entry] {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return [:]
    }
    return try JSONDecoder().decode([UUID: Entry].self, from: data)
  }

  func save(_ entries: [UUID: Entry]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(entries).write(to: file, options: .atomic)
  }
}
