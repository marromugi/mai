import Foundation
import Observation

/// The writings on the device as the screens show them: read from `store` once, then changed by
/// edits and by what a sync takes in, each saved as it is made. Both run on the main actor, so a
/// sync never saves over an edit it hasn't seen.
@Observable final class WritingLibrary {
  @ObservationIgnored let store: any WritingStore
  /// Nil until the store has been read.
  private(set) var writings: Result<[Writing], any Error>?

  init(store: any WritingStore) {
    self.store = store
  }

  /// Reads the store, with `samples` saved first when it holds none.
  func load(seedingWhenEmpty samples: [Writing]) {
    writings = Result { try store.all(seedingWhenEmpty: samples) }
  }

  /// Makes `change` to the writing with `id` and saves it; answers false when the change left it
  /// as it was. The edit is shown even when the save throws.
  @discardableResult
  func edit(_ id: Writing.ID, at now: Date, _ change: (inout Writing) -> Void) throws -> Bool {
    guard case .success(var all) = writings else { return false }
    defer { writings = .success(all) }
    return try store.edit(id, in: &all, at: now, change)
  }

  /// Every writing read from the store, for a sync. Throws while the store hasn't been read, or
  /// couldn't be.
  func forSync() throws -> [Writing] {
    switch writings {
    case .success(let all): return all
    case .failure(let error): throw error
    case nil: throw NotReadYet()
    }
  }

  /// Saves `writing` from a sync in place of the one with its ID, unless that one changed since
  /// the sync read it: `seen` is its updated time then, nil when there was none.
  func takeIn(_ writing: Writing, seen: Date?) throws {
    var all = try forSync()
    let index = all.firstIndex { $0.id == writing.id }
    guard index.map({ all[$0].updated }) == seen else {
      throw EditedDuringSync(id: writing.id)
    }
    try store.save(writing)
    if let index {
      all[index] = writing
    } else {
      all.append(writing)
    }
    writings = .success(all)
  }

  struct NotReadYet: LocalizedError {
    var errorDescription: String? {
      "文書をまだ読み込んでいません。"
    }
  }
}
