import Foundation
import SwiftUI
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

  /// A writing a sync takes in while a save of the device's edit is still being written is saved
  /// after it, so the store and the list hold what the sync took in.
  @Test func aWritingTakenInDuringASaveIsSavedAfterIt() async throws {
    let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
    let store = CountingStore([writing], delays: [0.3])
    let library = WritingLibrary(store: store, rest: .seconds(60))
    library.load(seedingWhenEmpty: [])
    library.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.body = "端末の追記" }
    let saving = Task { await library.saveNow() }
    // Once the save has started writing.
    try await waitUntil { store.started > 0 }

    let fromServer = Writing(
      id: writing.id, title: "夜", body: "別の端末の本文", updated: Date(timeIntervalSince1970: 3))
    try await library.takeIn(fromServer, seen: Date(timeIntervalSince1970: 2))
    await saving.value
    await library.saveNow()

    #expect(try store.all() == [fromServer])
    #expect(try library.rows?.get() == [WritingRow(fromServer)])
  }

  /// A save asked for while another is being written lands after it, so the store holds the
  /// last edit.
  @Test func savesLandInTheOrderTheyWereAskedFor() async throws {
    let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
    let store = CountingStore([writing], delays: [0.3])
    let library = WritingLibrary(store: store, rest: .seconds(60))
    library.load(seedingWhenEmpty: [])

    library.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.body = "一度目" }
    let first = Task { await library.saveNow() }
    try await waitUntil { store.started > 0 }
    library.edit(writing.id, at: Date(timeIntervalSince1970: 3)) { $0.body = "二度目" }
    await library.saveNow()
    await first.value

    #expect(try store.all().map(\.body) == ["二度目"])
  }

  /// The open writing's page going away saves what was typed on it, without waiting for the rest.
  @Test func closingThePageSavesItsEdits() async throws {
    let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
    let store = CountingStore([writing])
    let library = WritingLibrary(store: store, rest: .seconds(60))
    library.load(seedingWhenEmpty: [])
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "WritingLibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let photos = WritingPhotos(store: PhotoStore(directory: directory))
    let page = HostedPage(
      OpenWriting(
        id: writing.id, library: library, photos: photos, setting: .constant(.standard),
        open: { _ in }, edit: { library.edit($0, at: .now, $1) }, photoTaken: { _ in }))

    library.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.body = "閉じる前" }
    page.show(EmptyView())
    try await waitUntil { store.saves > 0 }
    #expect(try store.all().map(\.body) == ["閉じる前"])
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

/// Waits until `done` holds, failing after a minute: the snapshot suites running beside these can
/// hold the main actor for tens of seconds.
@MainActor
private func waitUntil(_ done: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(60)
  while !done() {
    guard ContinuousClock.now < deadline else {
      Issue.record("Waited a minute.")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

/// Writings kept in memory, counting the saves and whether each ran on the main thread; with
/// `refusing`, every save fails.
nonisolated private final class CountingStore: WritingStore {
  struct Refused: Error {}

  private let state:
    Mutex<(kept: [Writing.ID: Writing], onMain: [Bool], refusing: Bool, started: Int)>
  /// How long each save takes before it writes, in seconds, in order; the saves after them take
  /// none.
  private let delays: Mutex<[TimeInterval]>

  init(_ writings: [Writing], refusing: Bool = false, delays: [TimeInterval] = []) {
    state = Mutex(
      (Dictionary(uniqueKeysWithValues: writings.map { ($0.id, $0) }), [], refusing, 0))
    self.delays = Mutex(delays)
  }

  var saves: Int { state.withLock { $0.onMain.count } }
  var started: Int { state.withLock { $0.started } }
  var savedOnMain: [Bool] { state.withLock { $0.onMain } }

  var refusing: Bool {
    get { state.withLock { $0.refusing } }
    set { state.withLock { $0.refusing = newValue } }
  }

  func all() throws -> [Writing] {
    state.withLock { Array($0.kept.values) }
  }

  func save(_ writing: Writing) throws {
    state.withLock { $0.started += 1 }
    Thread.sleep(forTimeInterval: delays.withLock { $0.isEmpty ? 0 : $0.removeFirst() })
    try state.withLock {
      guard !$0.refusing else { throw Refused() }
      $0.onMain.append(Thread.isMainThread)
      $0.kept[writing.id] = writing
    }
  }
}
