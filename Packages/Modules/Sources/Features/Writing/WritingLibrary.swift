import Foundation
import Observation

/// The writings on the device as the screens show them: read from `store` once, then changed by
/// edits and by what a sync takes in. An edit is saved off the main actor once edits have rested
/// for `rest`, or at `saveNow()`; what a sync takes in is saved as it comes. Both are changed on
/// the main actor, so a sync never saves over an edit it hasn't seen.
@Observable final class WritingLibrary {
  @ObservationIgnored let store: any WritingStore
  /// Nil until the store has been read.
  private(set) var writings: Result<[Writing], any Error>?
  /// The list's rows, one per writing, each as its writing was last saved. Nil until the store has
  /// been read, and failed as `writings` did.
  private(set) var rows: Result<[WritingRow], any Error>?
  /// The last save that failed, until `dismissUnsaved()`. Its edits stay in `writings` and go in
  /// the next save.
  private(set) var unsaved: (any Error)?
  /// The writings edited since they were last saved.
  @ObservationIgnored private var edited: Set<Writing.ID> = []
  @ObservationIgnored private var due: Task<Void, Never>?
  /// The save running, which the next one waits for, so saves land in the order they were made.
  @ObservationIgnored private var saving: Task<Void, Never>?
  @ObservationIgnored private let rest: Duration

  /// How long edits rest before they are saved.
  static let rest = Duration.seconds(1)

  init(store: any WritingStore, rest: Duration = WritingLibrary.rest) {
    self.store = store
    self.rest = rest
  }

  /// Reads the store, with `samples` saved first when it holds none.
  func load(seedingWhenEmpty samples: [Writing]) {
    writings = Result { try store.all(seedingWhenEmpty: samples) }
    rows = writings?.map { $0.map(WritingRow.init) }
  }

  /// Makes `change` to the writing with `id`, to be saved once edits rest; answers false when the
  /// change left it as it was.
  @discardableResult
  func edit(_ id: Writing.ID, at now: Date, _ change: (inout Writing) -> Void) -> Bool {
    guard case .success(var all) = writings, all.edit(id, at: now, change) != nil else {
      return false
    }
    writings = .success(all)
    edited.insert(id)
    due?.cancel()
    due = Task { [rest] in
      do {
        try await Task.sleep(for: rest)
      } catch {
        return
      }
      await saveNow()
    }
    return true
  }

  /// Saves every edit not yet saved, off the main actor, and returns once it is saved or has
  /// failed.
  func saveNow() async {
    due?.cancel()
    due = nil
    let before = saving
    let ids = edited
    edited = []
    let unsavedWritings =
      if case .success(let all) = writings { all.filter { ids.contains($0.id) } } else {
        [Writing]()
      }
    let store = store
    let save = Task {
      await before?.value
      guard !unsavedWritings.isEmpty else { return }
      let saved = await Self.save(unsavedWritings, to: store)
      switch saved {
      case .success(let rows):
        replace(rows)
      case .failure(let error):
        edited.formUnion(ids)
        unsaved = error
      }
    }
    saving = save
    await save.value
  }

  /// Saves `writings` to `store` off the main actor and answers their rows.
  @concurrent
  private nonisolated static func save(_ writings: [Writing], to store: any WritingStore) async
    -> Result<[WritingRow], any Error>
  {
    Result {
      try writings.map { writing in
        try store.save(writing)
        return WritingRow(writing)
      }
    }
  }

  func dismissUnsaved() {
    unsaved = nil
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

  /// Saves `writing` from a sync in place of the one with its ID, after `copy`, the device's edit
  /// kept as a new writing, when there is one. Saves neither when the one with its ID changed
  /// since the sync read it: `seen` is its updated time then, nil when there was none.
  func takeIn(_ writing: Writing, keeping copy: Writing? = nil, seen: Date?) throws {
    var all = try forSync()
    guard all.first(where: { $0.id == writing.id })?.updated == seen else {
      throw EditedDuringSync(id: writing.id)
    }
    defer { writings = .success(all) }
    for saved in [copy, writing].compactMap(\.self) {
      try store.save(saved)
      if let index = all.firstIndex(where: { $0.id == saved.id }) {
        all[index] = saved
      } else {
        all.append(saved)
      }
      replace([WritingRow(saved)])
    }
  }

  /// Puts `new` in place of the rows with their IDs, adding those that have none.
  private func replace(_ new: [WritingRow]) {
    guard case .success(var all) = rows else { return }
    for row in new {
      if let index = all.firstIndex(where: { $0.id == row.id }) {
        all[index] = row
      } else {
        all.append(row)
      }
    }
    rows = .success(all)
  }

  struct NotReadYet: LocalizedError {
    var errorDescription: String? {
      "文書をまだ読み込んでいません。"
    }
  }
}
