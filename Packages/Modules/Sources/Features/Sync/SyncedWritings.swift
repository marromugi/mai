import Foundation
internal import Sync
import Synchronization

/// The writings in `library` as the sync sees them, each sealed as its `Writing.Contents`. The
/// samples stay on the device: every device seeds its own, at its own first launch.
nonisolated final class SyncedWritings: PlainWritingStore {
  let library: WritingLibrary
  /// Each writing's updated time when the sync last read them, so it saves over none edited since.
  private let seen = Mutex<[Writing.ID: Date]>([:])

  init(library: WritingLibrary) {
    self.library = library
  }

  func all() async throws -> [PlainWriting] {
    let writings = try await library.forSync().filter { !$0.id.isSample }
    seen.withLock { seen in
      seen = Dictionary(uniqueKeysWithValues: writings.map { ($0.id, $0.updated) })
    }
    return try writings.map { writing in
      PlainWriting(
        id: writing.id, updated: writing.updated, contents: try Writing.Contents(writing).encoded())
    }
  }

  func save(_ writing: PlainWriting) async throws {
    let contents: Writing.Contents
    do {
      contents = try JSONDecoder().decode(Writing.Contents.self, from: writing.contents)
    } catch {
      throw UnreadableContents(id: writing.id, reason: error)
    }
    let seenThen = seen.withLock { $0[writing.id] }
    try await library.takeIn(
      Writing(
        id: writing.id, title: contents.title, body: contents.body, links: contents.links,
        updated: writing.updated),
      seen: seenThen)
    seen.withLock { $0[writing.id] = writing.updated }
  }
}

extension Writing {
  /// What a writing seals for the server: everything but its ID and updated time, which the
  /// sealed writing carries in its header. Every device reads it, so a field is only ever added,
  /// and a device ignores the ones it doesn't know. Links are read as `Writing` reads them.
  nonisolated struct Contents: Codable, Equatable {
    let title: String
    let body: String
    let links: [BodyLink]

    init(_ writing: Writing) {
      title = writing.title
      body = writing.body
      links = writing.links
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      title = try container.decode(String.self, forKey: .title)
      body = try container.decode(String.self, forKey: .body)
      let saved = (try? container.decodeIfPresent([ReadableLink].self, forKey: .links)) ?? nil
      links = (saved ?? []).compactMap(\.link).fitted(to: body)
    }

    func encoded() throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .sortedKeys
      return try encoder.encode(self)
    }
  }
}

/// A writing that came from the server opened, but whose contents aren't a writing's. The other
/// writings still sync.
nonisolated struct UnreadableContents: LocalizedError, OneWritingFailure {
  let id: Writing.ID
  let reason: any Error

  var errorDescription: String? {
    "同期で届いた文書の中身が読めませんでした。"
  }
}

/// A writing from the server not taken in because it was edited on the device while the sync
/// ran. The next sync sends the edit, or keeps both.
nonisolated struct EditedDuringSync: LocalizedError, OneWritingFailure {
  let id: Writing.ID

  var errorDescription: String? {
    "同期のあいだに書き換えた文書があります。次の同期でそろえます。"
  }
}
