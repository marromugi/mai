import Foundation
import Synchronization
import Testing

@testable import Features

@MainActor
struct WritingLibraryTests {
  /// An edit is shown at once and saved once edits rest, updated, and read back by the next launch.
  @Test func anEditIsSavedOnceEditsRestAndReadBackByTheNextLaunch() async throws {
    let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
    let store = CountingStore([writing])
    let library = WritingLibrary(store: store, rest: .milliseconds(50))
    library.load(seedingWhenEmpty: [])

    #expect(library.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.title = "夜" })
    let expected = Writing(
      id: writing.id, title: "夜", body: "本文", updated: Date(timeIntervalSince1970: 2))
    #expect(try library.forSync() == [expected])
    #expect(store.saves == 0)

    try await waitUntil { store.saves == 1 }
    #expect(try store.all() == [expected])
  }

  /// Typing is many edits; they are saved once, as the last left the writing.
  @Test func editsMadeBeforeTheRestAreSavedOnce() async throws {
    let writing = Writing(title: "朝", body: "", updated: Date(timeIntervalSince1970: 1))
    let store = CountingStore([writing])
    let library = WritingLibrary(store: store, rest: .milliseconds(200))
    library.load(seedingWhenEmpty: [])

    for character in "本文です" {
      library.edit(writing.id, at: .now) { $0.body.append(character) }
    }
    try await waitUntil { store.saves > 0 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(store.saves == 1)
    #expect(try store.all().map(\.body) == ["本文です"])
  }

  /// The list's row stays as the writing was saved until the edit is.
  @Test func aRowChangesOnceItsWritingIsSaved() async throws {
    let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
    let library = WritingLibrary(store: CountingStore([writing]), rest: .seconds(60))
    library.load(seedingWhenEmpty: [])

    library.edit(writing.id, at: Date(timeIntervalSince1970: 2)) {
      $0.title = "夜"
      $0.body = "本文と追記"
    }
    #expect(try library.rows?.get() == [WritingRow(writing)])

    await library.saveNow()
    #expect(
      try library.rows?.get() == [
        WritingRow(
          id: writing.id, title: "夜", characterCount: 5, updated: Date(timeIntervalSince1970: 2))
      ])
  }

  @Test func anEditThatChangesNothingIsNotSaved() async throws {
    let writing = Writing(title: "朝", body: "本文")
    let store = CountingStore([writing])
    let library = WritingLibrary(store: store, rest: .milliseconds(10))
    library.load(seedingWhenEmpty: [])

    #expect(!library.edit(writing.id, at: .now) { $0.body = "本文" })
    await library.saveNow()
    #expect(store.saves == 0)
  }

  /// A save that fails is shown, the writings still hold the edit, and the next save takes it.
  @Test func anEditWhoseSaveFailsIsKeptAndSavedNextTime() async throws {
    let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
    let store = CountingStore([writing], refusing: true)
    let library = WritingLibrary(store: store, rest: .seconds(60))
    library.load(seedingWhenEmpty: [])

    library.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.body = "本文と追記" }
    await library.saveNow()
    #expect(library.unsaved is CountingStore.Refused)
    #expect(try library.forSync().map(\.body) == ["本文と追記"])
    #expect(try store.all().map(\.body) == ["本文"])

    library.dismissUnsaved()
    store.refusing = false
    await library.saveNow()
    #expect(library.unsaved == nil)
    #expect(try store.all().map(\.body) == ["本文と追記"])
  }

  /// The store is written off the main actor.
  @Test func savingIsOffTheMainThread() async throws {
    let writing = Writing(title: "朝", body: "本文")
    let store = CountingStore([writing])
    let library = WritingLibrary(store: store, rest: .seconds(60))
    library.load(seedingWhenEmpty: [])

    library.edit(writing.id, at: .now) { $0.body = "本文と追記" }
    await library.saveNow()
    #expect(store.savedOnMain == [false])
  }
}

/// Waits until `done` holds, failing after 10 seconds.
@MainActor
private func waitUntil(_ done: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while !done() {
    guard ContinuousClock.now < deadline else {
      Issue.record("Waited 10 seconds.")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// Writings kept in memory, counting the saves and whether each ran on the main thread; with
/// `refusing`, every save fails.
nonisolated private final class CountingStore: WritingStore {
  struct Refused: Error {}

  private let state: Mutex<(kept: [Writing.ID: Writing], onMain: [Bool], refusing: Bool)>

  init(_ writings: [Writing], refusing: Bool = false) {
    state = Mutex(
      (Dictionary(uniqueKeysWithValues: writings.map { ($0.id, $0) }), [], refusing))
  }

  var saves: Int { state.withLock { $0.onMain.count } }
  var savedOnMain: [Bool] { state.withLock { $0.onMain } }

  var refusing: Bool {
    get { state.withLock { $0.refusing } }
    set { state.withLock { $0.refusing = newValue } }
  }

  func all() throws -> [Writing] {
    state.withLock { Array($0.kept.values) }
  }

  func save(_ writing: Writing) throws {
    try state.withLock {
      guard !$0.refusing else { throw Refused() }
      $0.onMain.append(Thread.isMainThread)
      $0.kept[writing.id] = writing
    }
  }
}
