import Foundation
internal import Sync

/// The writings in `store` as the sync sees them, each sealed as its `Writing.Contents`. The
/// samples stay on the device: every device seeds its own, at its own first launch.
nonisolated struct SyncedWritings: PlainWritingStore {
  let store: any WritingStore

  func all() throws -> [PlainWriting] {
    try store.all().filter { !$0.id.isSample }.map { writing in
      PlainWriting(
        id: writing.id, updated: writing.updated, contents: try Writing.Contents(writing).encoded())
    }
  }

  func save(_ writing: PlainWriting) throws {
    let contents: Writing.Contents
    do {
      contents = try JSONDecoder().decode(Writing.Contents.self, from: writing.contents)
    } catch {
      throw UnreadableContents(id: writing.id, reason: error)
    }
    try store.save(
      Writing(id: writing.id, title: contents.title, body: contents.body, updated: writing.updated))
  }
}

extension Writing {
  /// What a writing seals for the server: everything but its ID and updated time, which the
  /// sealed writing carries in its header. Every device reads it, so a field is only ever added,
  /// and a device ignores the ones it doesn't know.
  nonisolated struct Contents: Codable, Equatable {
    let title: String
    let body: String

    init(_ writing: Writing) {
      title = writing.title
      body = writing.body
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
    "同期で届いた文書 \(id.uuidString) の中身が読めませんでした。"
  }
}
