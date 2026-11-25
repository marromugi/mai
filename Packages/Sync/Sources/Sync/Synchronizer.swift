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
  /// The IDs of the photos `writing` points at; none when its contents can't be read.
  func photos(of writing: PlainWriting) -> [UUID]
}

/// Where the device keeps its photos in plain bytes.
public protocol PlainPhotoStore: Sendable {
  /// The photo with `id`, or nil when the device has none.
  func read(_ id: UUID) async throws -> PlainPhoto?
  /// Keeps `photo`. A photo kept already with its ID stays as it is.
  func keep(_ photo: PlainPhoto) async throws
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
  /// Photos sent to the server, by photo ID.
  public var photosSent: Set<UUID> = []
  /// Photos taken from the server into the device's photo store, by photo ID.
  public var photosReceived: Set<UUID> = []
  /// The read-mode copies of the writings sent.
  public var copies = CopiesSent()

  public init() {}
}

/// Brings the device's writings and the server's to the same saves, sealing what it sends.
/// A writing changed on both sides since the last sync is kept twice, so neither edit is lost.
///
/// The photos a writing points at are sent before the writing, so no device takes in a writing
/// whose photos the server can't give yet, and taken from the server for a writing the device has
/// without them. Each is sent once, sealed with this own key.
public actor Synchronizer {
  private let writings: any PlainWritingStore
  private let photos: any PlainPhotoStore
  private let state: SyncState
  private let photoState: PhotoSyncState
  private let server: WritingServer
  private let ownKey: OwnKey
  private let readMode: ReadMode?
  private var running: Task<SyncReport, any Error>?

  /// `stateFile` keeps, for each writing, the server's revision, the device's updated time when
  /// they last matched, and the key of that revision; it is made on the first sync. The photos on
  /// the server are kept beside it (`PhotoSyncState.file(beside:)`). Once the saves are made,
  /// `readMode`, reading the same `stateFile`, sends the copies of the writings sent.
  public init(
    writings: any PlainWritingStore, photos: any PlainPhotoStore, stateFile: URL,
    server: WritingServer, ownKey: OwnKey, readMode: ReadMode? = nil
  ) {
    self.writings = writings
    self.photos = photos
    state = SyncState(file: stateFile)
    photoState = PhotoSyncState(file: PhotoSyncState.file(beside: stateFile))
    self.server = server
    self.ownKey = ownKey
    self.readMode = readMode
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
    var onServer = try photoState.load(sealedWith: ownKey)
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
          id, mine: mine[id], theirs: theirs[id], synced: &synced, onServer: &onServer,
          reporting: &report)
      } catch let error as SealingError {
        failures[id] = error
      } catch let error as OpeningError {
        failures[id] = error
      } catch let error as PhotoOpeningError {
        failures[id] = error
      } catch let error as ServerError where error.concernsOneWriting {
        failures[id] = error
      } catch let error as any OneWritingFailure {
        failures[id] = error
      }
    }
    // One sending of copies a sync, after the saves: a sync sends each writing at most once, and
    // the server deletes the copies of a writing's earlier revision on each save it takes.
    if let readMode {
      do {
        report.copies = try await readMode.sendCopies(of: report.sent)
      } catch  where !failures.isEmpty {
        // The writings that failed are what the person is told; the copies go with a later sync.
        syncLogger.error("The read-mode copies weren't sent: \(error)")
      }
    }
    guard failures.isEmpty else {
      throw SyncFailures(report: report, failures: failures)
    }
    return report
  }

  /// Syncs one writing and its photos. A failure that concerns this writing alone leaves the
  /// others to go on.
  private func sync(
    _ id: UUID, mine writing: PlainWriting?, theirs entry: ServerEntry?,
    synced: inout [UUID: SyncState.Entry], onServer: inout Set<UUID>,
    reporting report: inout SyncReport
  ) async throws {
    let last = synced[id]
    let deviceChanged = writing.map { Layout.milliseconds(of: $0.updated) != last?.updated }
    guard let entry else {
      guard let writing else { preconditionFailure("Each ID is the device's or the server's") }
      try await send(writing, over: nil, into: &synced, onServer: &onServer, reporting: &report)
      return
    }
    guard entry.revision != last?.revision || writing == nil else {
      guard let writing else { return }
      if deviceChanged == true {
        try await send(
          writing, over: entry.revision, into: &synced, onServer: &onServer, reporting: &report)
      } else {
        try await settlePhotos(of: writing, onServer: &onServer, reporting: &report)
      }
      return
    }
    guard let (received, revision, key) = try await read(id) else {
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
      revision: revision, updated: Layout.milliseconds(of: received.updated), writingKey: key)
    try state.save(synced)
    report.received.insert(id)
    try await settlePhotos(of: received, onServer: &onServer, reporting: &report)
    if let copy {
      try await send(copy, over: nil, into: &synced, onServer: &onServer, reporting: &report)
    }
  }

  /// Sends `writing` once the photos it points at are on the server.
  private func send(
    _ writing: PlainWriting, over base: Revision?, into synced: inout [UUID: SyncState.Entry],
    onServer: inout Set<UUID>, reporting report: inout SyncReport
  ) async throws {
    try await settlePhotos(of: writing, onServer: &onServer, reporting: &report)
    let sealed = try ownKey.seal(writing)
    switch try await server.save(sealed, over: base) {
    case .saved(let revision):
      synced[writing.id] = SyncState.Entry(
        revision: revision, updated: Layout.milliseconds(of: writing.updated),
        writingKey: sealed.writingKey)
      try state.save(synced)
      report.sent.insert(writing.id)
    case .conflict:
      report.left.insert(writing.id)
    }
  }

  /// Brings each photo `writing` points at that isn't known to be on the server to both sides:
  /// sent when the device has it, taken from the server when the device hasn't. A photo neither
  /// side has yet, or whose part the server is still taking (409 but not readable), is left for
  /// the next sync.
  private func settlePhotos(
    of writing: PlainWriting, onServer: inout Set<UUID>, reporting report: inout SyncReport
  ) async throws {
    for id in writings.photos(of: writing) where !onServer.contains(id) {
      if let photo = try await photos.read(id) {
        let sealed = try ownKey.seal(photo)
        var stored = true
        // The thumbnail first, as a device taking the photo in asks for it first.
        for part in [sealed.thumbnail, sealed.photo] {
          guard try await server.send(part) == .alreadyThere else { continue }
          // A 409 is also an upload the server holds but may yet release; only one it gives back
          // is there.
          if try await server.readPhoto(id, part.part) == nil { stored = false }
        }
        guard stored else { continue }
        report.photosSent.insert(id)
      } else {
        guard let thumbnail = try await server.readPhoto(id, .thumbnail),
          let photo = try await server.readPhoto(id, .photo)
        else { continue }
        try await photos.keep(
          PlainPhoto(id: id, photo: ownKey.open(photo), thumbnail: ownKey.open(thumbnail)))
        report.photosReceived.insert(id)
      }
      onServer.insert(id)
      try photoState.save(onServer, sealedWith: ownKey)
    }
  }

  /// The server's writing with `id`, opened, its revision, and the key it was sealed with.
  private func read(_ id: UUID) async throws -> (PlainWriting, Revision, WritingKey)? {
    guard let (envelope, revision) = try await server.read(id) else { return nil }
    guard envelope.id == id else {
      throw ServerError.unexpectedAnswer(
        "the server gave writing \(envelope.id.uuidString) for \(id.uuidString)")
    }
    let (writing, key) = try ownKey.openWithKey(envelope)
    return (writing, revision, key)
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
    case .unreachable, .refused(status: 401, _), .limitReached: false
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

/// The photos known to be on the server, as sealed with one own key. Read with another key, as
/// after the account starts over (which removes the server's photos), it holds none.
struct PhotoSyncState {
  let file: URL

  /// Where the photos synced beside the writings' `stateFile` are kept.
  static func file(beside stateFile: URL) -> URL {
    stateFile.deletingPathExtension().appendingPathExtension("photos.json")
  }

  private struct Saved: Codable {
    let ownKeyCheck: Data
    let onServer: Set<UUID>
  }

  func load(sealedWith ownKey: OwnKey) throws -> Set<UUID> {
    let data: Data
    do {
      data = try Data(contentsOf: file)
    } catch CocoaError.fileReadNoSuchFile {
      return []
    }
    let saved = try JSONDecoder().decode(Saved.self, from: data)
    return saved.ownKeyCheck == ownKey.check ? saved.onServer : []
  }

  func save(_ onServer: Set<UUID>, sealedWith ownKey: OwnKey) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(Saved(ownKeyCheck: ownKey.check, onServer: onServer))
      .write(to: file, options: .atomic)
  }
}

/// For each writing, the server's revision and the device's updated time when they last matched.
struct SyncState {
  struct Entry: Codable, Equatable {
    let revision: Revision
    let updated: UInt64?
    /// The key of the writing at `revision`; nil in a state kept before keys were.
    let writingKey: WritingKey?
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
