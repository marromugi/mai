import Foundation
import Sync
import SyncFakes
import Testing

@testable import Features

/// A store in a directory of its own, removed when the test process's temporary files are.
private func emptyStore() -> FileWritingStore {
  FileWritingStore(
    directory: FileManager.default.temporaryDirectory.appending(
      path: "WritingSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory))
}

private let serverURL = "https://mai.example"

extension [Writing] {
  fileprivate func byID() -> [Writing] {
    sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

struct SyncedWritingsTests {
  @Test(arguments: [
    Writing(title: "", body: "", updated: Date(timeIntervalSince1970: 1)),
    Writing(
      title: "パンを焼く日 🍞", body: Writing.sampleBody,
      updated: Date(timeIntervalSince1970: 1_790_000_000.25)),
    Writing(
      title: "\"引用\" と \\ と\n改行", body: "\r\n\t\u{3000}",
      updated: Date(timeIntervalSince1970: 1_790_000_000)),
  ])
  func aWritingSentFromOneStoreIsTheSameWritingInAnother(_ writing: Writing) throws {
    let sending = emptyStore()
    try sending.save(writing)
    let receiving = emptyStore()
    for plain in try SyncedWritings(store: sending).all() {
      try SyncedWritings(store: receiving).save(plain)
    }
    #expect(try receiving.all() == [writing])
  }

  @Test func aWritingIsSentAsItsTitleAndBody() throws {
    let store = emptyStore()
    let writing = Writing(title: "朝", body: "一行目\n二行目", updated: Date(timeIntervalSince1970: 7))
    try store.save(writing)
    let sent = try #require(try SyncedWritings(store: store).all().first)
    #expect(sent.id == writing.id)
    #expect(sent.updated == writing.updated)
    #expect(String(decoding: sent.contents, as: UTF8.self) == #"{"body":"一行目\n二行目","title":"朝"}"#)
  }

  @Test func contentsWithAFieldThisDeviceDoesntKnowAreStillRead() throws {
    let store = emptyStore()
    let id = UUID()
    try SyncedWritings(store: store).save(
      PlainWriting(
        id: id, updated: Date(timeIntervalSince1970: 7),
        contents: Data(#"{"body":"本文","photos":[],"title":"題"}"#.utf8)))
    #expect(
      try store.all() == [
        Writing(id: id, title: "題", body: "本文", updated: Date(timeIntervalSince1970: 7))
      ])
  }

  @Test func contentsThatArentAWritingAreRefusedAndNothingIsSaved() throws {
    let store = emptyStore()
    let id = UUID()
    #expect {
      try SyncedWritings(store: store).save(
        PlainWriting(id: id, updated: .now, contents: Data("朝に書いた".utf8)))
    } throws: { error in
      (error as? UnreadableContents)?.id == id
    }
    #expect(try store.all().isEmpty)
  }

  @Test func theSamplesStayOnTheDevice() throws {
    let store = emptyStore()
    let samples = Writing.samples(now: .now, calendar: .current)
    let written = Writing(title: "朝", body: "", updated: Date(timeIntervalSince1970: 7))
    _ = try store.all(seedingWhenEmpty: samples)
    try store.save(written)
    #expect(try SyncedWritings(store: store).all().map(\.id) == [written.id])
  }
}

struct WritingSyncTests {
  /// Two devices seeded with the samples at their own first launches, a day apart.
  @Test func theFirstSyncOnTwoDevicesKeepsEachSampleOnce() async throws {
    let ownKey = OwnKey.generate()
    let server = FakeWritingServer(accepting: ownKey.accessToken)
    let first = emptyStore()
    let second = emptyStore()
    let firstSamples = Writing.samples(
      now: Date(timeIntervalSince1970: 1_790_000_000), calendar: .current)
    let secondSamples = Writing.samples(
      now: Date(timeIntervalSince1970: 1_790_086_400), calendar: .current)
    _ = try first.all(seedingWhenEmpty: firstSamples)
    _ = try second.all(seedingWhenEmpty: secondSamples)
    let written = Writing(
      title: "朝", body: "書いた", updated: Date(timeIntervalSince1970: 1_790_000_100))
    try first.save(written)

    for store in [first, second, first] {
      let sync = WritingSync.forTests(
        store: store, keys: MemoryOwnKeys(ownKey), transport: server)
      #expect(await sync.sync(serverURL: serverURL))
      #expect(sync.status != .notYet)
      if case .failed(let message) = sync.status {
        Issue.record("The sync failed: \(message)")
      }
    }

    #expect(try first.all().byID() == (firstSamples + [written]).byID())
    #expect(try second.all().byID() == (secondSamples + [written]).byID())
    let saved = await server.requests.filter { $0.httpMethod == "PUT" }.compactMap(\.url)
    #expect(saved.map(\.lastPathComponent) == [written.id.uuidString.lowercased()])
  }

  @Test func withNoServerSetNothingIsSent() async throws {
    let ownKey = OwnKey.generate()
    let server = FakeWritingServer(accepting: ownKey.accessToken)
    let store = emptyStore()
    try store.save(Writing(title: "朝", body: ""))
    let sync = WritingSync.forTests(store: store, keys: MemoryOwnKeys(ownKey), transport: server)
    #expect(await sync.sync(serverURL: "  ") == false)
    #expect(sync.status == .notYet)
    #expect(await server.requests.isEmpty)
  }

  @Test func withNoOwnKeyNothingIsSent() async throws {
    let server = FakeWritingServer(accepting: "token")
    let store = emptyStore()
    try store.save(Writing(title: "朝", body: ""))
    let sync = WritingSync.forTests(store: store, transport: server)
    #expect(await sync.sync(serverURL: serverURL) == false)
    #expect(sync.ownKey == nil)
    #expect(await server.requests.isEmpty)
  }

  @Test(arguments: ["mai.example", "ftp://mai.example", "https://"])
  func aURLThatIsNotAServersSaysSo(_ text: String) async throws {
    let server = FakeWritingServer(accepting: "token")
    let sync = WritingSync.forTests(
      store: emptyStore(), keys: MemoryOwnKeys(.generate()), transport: server)
    #expect(await sync.sync(serverURL: text) == false)
    #expect(sync.status == .failed("サーバーの URL は https:// で始めて書いてください。"))
    #expect(await server.requests.isEmpty)
  }

  @Test func aServerThatRefusesTheKeySaysSo() async throws {
    let server = FakeWritingServer(accepting: OwnKey.generate().accessToken)
    let sync = WritingSync.forTests(
      store: emptyStore(), keys: MemoryOwnKeys(.generate()), transport: server)
    #expect(await sync.sync(serverURL: serverURL))
    #expect(sync.status == .failed("サーバーがこの端末の鍵を受け付けませんでした。"))
  }

  @Test func theKeyMadeIsKeptAndItsRecoveryKeyGivesItBack() throws {
    let keys = MemoryOwnKeys()
    let sync = WritingSync.forTests(store: emptyStore(), keys: keys)
    let recoveryKey = try sync.makeOwnKey()
    #expect(sync.ownKey == recoveryKey.ownKey)
    #expect(try keys.load() == recoveryKey.ownKey)

    let otherKeys = MemoryOwnKeys()
    let otherDevice = WritingSync.forTests(store: emptyStore(), keys: otherKeys)
    try otherDevice.restoreOwnKey(from: recoveryKey.text.lowercased())
    #expect(otherDevice.ownKey == recoveryKey.ownKey)
    #expect(try otherKeys.load() == recoveryKey.ownKey)
  }

  /// iCloud Keychain may bring another device's key while the page is open.
  @Test func noKeyIsMadeOverOneAlreadyKept() throws {
    let kept = OwnKey.generate()
    let sync = WritingSync.forTests(store: emptyStore(), keys: MemoryOwnKeys(kept))
    #expect(throws: KeychainError.self) { try sync.makeOwnKey() }
    #expect(sync.ownKey == kept)
  }

  @Test func aMistypedRecoveryKeyRestoresNothing() throws {
    let keys = MemoryOwnKeys()
    let sync = WritingSync.forTests(store: emptyStore(), keys: keys)
    var text = RecoveryKey(.generate()).text
    text.replaceSubrange(text.startIndex...text.startIndex, with: text.first == "A" ? "B" : "A")
    #expect(throws: RecoveryKeyError.mistyped) { try sync.restoreOwnKey(from: text) }
    #expect(sync.ownKey == nil)
    #expect(try keys.load() == nil)
  }
}
