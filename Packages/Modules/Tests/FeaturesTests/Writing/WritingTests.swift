import Foundation
import Testing

@testable import Features

/// A store in a directory of its own that doesn't exist yet, removed when the test ends.
private func withEmptyStore(_ test: (FileWritingStore) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "WritingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  try test(FileWritingStore(directory: directory))
}

struct WritingTests {
  @Test func aStoreNeverSavedToHasNoWritings() throws {
    try withEmptyStore { store throws in
      #expect(try store.all().isEmpty)
    }
  }

  @Test(arguments: [
    Writing(title: "", body: "", updated: Date(timeIntervalSinceReferenceDate: 0)),
    Writing(
      title: "パンを焼く日 🍞", body: Writing.sampleBody,
      updated: Date(timeIntervalSinceReferenceDate: 815_000_000.123_456)),
    Writing(
      title: "\"引用\" と \\ と\n改行", body: "\r\n\t\u{3000}",
      updated: Date(timeIntervalSinceReferenceDate: -1.5)),
    Writing(
      title: "リンク", body: "🍞の焼き方と粉の店",
      links: [
        BodyLink(range: 0..<6, url: bread), BodyLink(range: 7..<10, url: flour),
      ],
      updated: Date(timeIntervalSinceReferenceDate: 0)),
  ])
  func aSavedWritingIsReadBackByTheNextLaunch(_ writing: Writing) throws {
    try withEmptyStore { store throws in
      try store.save(writing)
      let relaunched = FileWritingStore(directory: store.directory)
      #expect(try relaunched.all() == [writing])
    }
  }

  /// A file saved before links were kept reads as a writing with none.
  @Test func aWritingSavedWithoutLinksHasNone() throws {
    try withEmptyStore { store throws in
      let id = try #require(UUID(uuidString: "6F0C9A1E-0D8B-4C49-9E35-2B7E0A1D5C11"))
      try FileManager.default.createDirectory(
        at: store.directory, withIntermediateDirectories: true)
      try Data(
        #"{"id":"\#(id.uuidString)","title":"朝","body":"本文","updated":0}"#.utf8
      ).write(to: store.file(for: id))
      #expect(
        try store.all() == [
          Writing(
            id: id, title: "朝", body: "本文", links: [],
            updated: Date(timeIntervalSinceReferenceDate: 0))
        ])
    }
  }

  /// A file whose links don't fit its body is still read, with each link widened to the whole
  /// characters it touches, and one that is empty, past the end, or covered by the link before it
  /// dropped.
  @Test(arguments: [
    ([BodyLink(range: 3..<5, url: bread)], []),
    ([BodyLink(range: 1..<1, url: bread)], []),
    (
      [BodyLink(range: 2..<4, url: bread), BodyLink(range: 3..<4, url: flour)],
      [BodyLink(range: 2..<4, url: bread)]
    ),
    (
      [BodyLink(range: 3..<4, url: bread), BodyLink(range: 2..<3, url: flour)],
      [BodyLink(range: 3..<4, url: bread)]
    ),
    // Through the middle of 🍞.
    ([BodyLink(range: 1..<3, url: bread)], [BodyLink(range: 0..<3, url: bread)]),
  ])
  func linksThatDontFitAreFittedOnReading(_ saved: [BodyLink], _ read: [BodyLink]) throws {
    try withEmptyStore { store throws in
      let writing = Writing(title: "朝", body: "🍞本文", links: saved)
      try store.save(writing)
      #expect(try store.all().map(\.links) == [read])
    }
  }

  @Test func savingAgainReplacesTheWritingWithItsID() throws {
    try withEmptyStore { store throws in
      var writing = Writing(title: "朝", body: "一行目", updated: Date(timeIntervalSince1970: 1))
      let other = Writing(title: "夜", body: "", updated: Date(timeIntervalSince1970: 2))
      try store.save(writing)
      try store.save(other)
      writing.body = "一行目\n二行目"
      writing.updated = Date(timeIntervalSince1970: 3)
      try store.save(writing)
      let saved = try store.all()
      #expect(saved.count == 2)
      #expect(saved.first { $0.id == writing.id } == writing)
      #expect(saved.first { $0.id == other.id } == other)
    }
  }

  @Test func anEmptyStoreIsSeededWithTheSamples() throws {
    try withEmptyStore { store throws in
      let samples = Writing.samples(now: .now, calendar: .current)
      #expect(try store.all(seedingWhenEmpty: samples) == samples)
      #expect(Set(try store.all().map(\.id)) == Set(samples.map(\.id)))
    }
  }

  @Test func aStoreWithWritingsIsNotSeeded() throws {
    try withEmptyStore { store throws in
      let writing = Writing(title: "朝", body: "", updated: Date(timeIntervalSince1970: 1))
      try store.save(writing)
      let samples = Writing.samples(now: .now, calendar: .current)
      #expect(try store.all(seedingWhenEmpty: samples) == [writing])
      #expect(try store.all() == [writing])
    }
  }

  @Test func aFileThatIsNotAWritingNamesItself() throws {
    try withEmptyStore { store throws in
      try store.save(Writing(title: "朝", body: ""))
      let broken = store.directory.appending(path: "broken.json")
      try Data("{".utf8).write(to: broken)
      #expect {
        try store.all()
      } throws: { error in
        (error as? UnreadableWriting)?.file.lastPathComponent == "broken.json"
          && error.localizedDescription.contains("broken.json")
      }
    }
  }

  @Test func aWritingInAFileNotNamedByItsIDNamesTheFile() throws {
    try withEmptyStore { store throws in
      let writing = Writing(title: "朝", body: "古い")
      try store.save(writing)
      try FileManager.default.copyItem(
        at: store.file(for: writing.id), to: store.directory.appending(path: "copy.json"))
      #expect {
        try store.all()
      } throws: { error in
        (error as? UnreadableWriting)?.file.lastPathComponent == "copy.json"
          && error.localizedDescription.contains(writing.id.uuidString)
      }
    }
  }

  @Test func sampleIDsDifferPastThirtyTwoBits() {
    #expect(UUID(sample: 4_294_967_297) != UUID(sample: 1))
  }

  @Test func filesOtherThanJSONAreLeftAlone() throws {
    try withEmptyStore { store throws in
      let writing = Writing(title: "朝", body: "", updated: Date(timeIntervalSince1970: 1))
      try store.save(writing)
      try Data("x".utf8).write(to: store.directory.appending(path: ".DS_Store"))
      #expect(try store.all() == [writing])
    }
  }

  @Test func aRowCountsCharactersNotCodeUnits() {
    #expect(WritingRow(Writing(title: "", body: "🍞🇯🇵が\n")).characterCount == 4)
  }

  @Test func eachSampleBodyIsAsLongAsItsRowSays() {
    let now = Date(timeIntervalSinceReferenceDate: 815_000_000)
    let calendar = Calendar(identifier: .gregorian)
    #expect(
      Writing.samples(now: now, calendar: calendar).map(WritingRow.init)
        == WritingRow.samples(now: now, calendar: calendar))
  }

  /// The samples' bodies name one of them, so the app has a title link to show.
  @Test func aSampleNamesAnotherSampleWriting() throws {
    let samples = Writing.samples(now: .now, calendar: .current)
    let bread = try #require(samples.first)
    let named = bread.body.titleMentions(of: Array(samples.dropFirst())).map(\.writing.title)
    #expect(named.contains("夜の机に向かう"))
  }

  @Test func anEditChangesTheWritingAndItsUpdatedTime() throws {
    let other = Writing(title: "夜", body: "", updated: Date(timeIntervalSince1970: 1))
    let writing = Writing(title: "朝", body: "一行目", updated: Date(timeIntervalSince1970: 1))
    var writings = [other, writing]
    let edited = try #require(
      writings.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.body += "\n二行目" })
    #expect(edited.body == "一行目\n二行目")
    #expect(edited.updated == Date(timeIntervalSince1970: 2))
    #expect(writings == [other, edited])
  }

  @Test func anEditThatChangesNothingKeepsTheUpdatedTime() {
    let writing = Writing(title: "朝", body: "一行目", updated: Date(timeIntervalSince1970: 1))
    var writings = [writing]
    #expect(writings.edit(writing.id, at: Date(timeIntervalSince1970: 2)) { $0.title = "朝" } == nil)
    #expect(writings == [writing])
  }

  @Test func anEditThatOnlyLinksTextChangesTheWriting() throws {
    let writing = Writing(title: "朝", body: "粉の店", updated: Date(timeIntervalSince1970: 1))
    var writings = [writing]
    let edited = try #require(
      writings.edit(writing.id, at: Date(timeIntervalSince1970: 2)) {
        $0.links = [BodyLink(range: 0..<3, url: flour)]
      })
    #expect(edited.links == [BodyLink(range: 0..<3, url: flour)])
    #expect(edited.updated == Date(timeIntervalSince1970: 2))
  }

  @Test func anEditToAWritingNotThereChangesNothing() {
    let writing = Writing(title: "朝", body: "一行目", updated: Date(timeIntervalSince1970: 1))
    var writings = [writing]
    #expect(writings.edit(UUID(), at: .now) { $0.title = "夜" } == nil)
    #expect(writings == [writing])
  }

  /// A title-only edit is saved, updated, and read back by the next launch.
  @Test func anEditIsSavedAndReadBackByTheNextLaunch() throws {
    try withEmptyStore { store throws in
      let writing = Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))
      try store.save(writing)
      var writings = [writing]
      try store.edit(writing.id, in: &writings, at: Date(timeIntervalSince1970: 2)) {
        $0.title = "夜"
      }
      let expected = Writing(
        id: writing.id, title: "夜", body: "本文", updated: Date(timeIntervalSince1970: 2))
      #expect(writings == [expected])
      #expect(try FileWritingStore(directory: store.directory).all() == [expected])
    }
  }

  @Test func anEditThatChangesNothingIsNotSaved() throws {
    let store = RefusingStore()
    var writings = [Writing(title: "朝", body: "本文")]
    try store.edit(writings[0].id, in: &writings, at: .now) { $0.body = "本文" }
  }

  /// A save that fails throws, and the writings still hold the edit.
  @Test func anEditWhoseSaveFailsIsKeptInTheWritings() {
    var writings = [Writing(title: "朝", body: "本文", updated: Date(timeIntervalSince1970: 1))]
    #expect(throws: RefusingStore.Refused.self) {
      try RefusingStore().edit(writings[0].id, in: &writings, at: Date(timeIntervalSince1970: 2)) {
        $0.body = "本文と追記"
      }
    }
    #expect(writings[0].body == "本文と追記")
    #expect(writings[0].updated == Date(timeIntervalSince1970: 2))
  }
}

nonisolated private let bread = URL(string: "https://example.com/bread") ?? URL(filePath: "/")
nonisolated private let flour = URL(string: "https://example.com/flour") ?? URL(filePath: "/")

/// A store whose every save fails.
private struct RefusingStore: WritingStore {
  struct Refused: Error {}

  func all() throws -> [Writing] { [] }

  func save(_ writing: Writing) throws {
    throw Refused()
  }
}
