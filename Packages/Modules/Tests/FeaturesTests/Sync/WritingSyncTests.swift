import Foundation
import Sync
import SyncFakes
import Synchronization
import Testing

@testable import Features

/// `WritingSync` over the account model, the library, and a stand-in Worker: the writings routes
/// kept by `FakeWritingServer`, the account's routes scripted.
@Suite(.serialized)
struct WritingSyncTests {
  private let suite = "WritingSyncTests.\(UUID().uuidString)"
  private let accountID = UUID()
  private let token = "s1.session.token"
  private let ownKey = OwnKey.generate()

  /// A device signed in with `ownKey` when `signedIn`, its library read from `kept`, and every
  /// request it sends kept in `sent`; `DELETE /account` is answered with `deletion`.
  private struct Device {
    let account: AccountModel
    let library: WritingLibrary
    let sync: WritingSync
    let sent: Requests
    let ownKeys: MemoryOwnKeys
  }

  private func device(
    _ kept: [Writing] = [], signedIn: Bool = true, server: FakeWritingServer? = nil,
    deviceKey: OwnKey? = nil, refusingWritings: Int? = nil, holdingFirstListing: Bool = false,
    pause: Duration = .zero,
    interval: Duration = .zero, deletion: ScriptedWorker.Answer? = nil
  ) throws -> Device {
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    let sessions = MemorySessions()
    let ownKeys = MemoryOwnKeys()
    if signedIn {
      try sessions.save(Session(token: token, account: accountID, appleUser: "user"))
    }
    if signedIn || deviceKey != nil {
      try ownKeys.save(deviceKey ?? ownKey)
    }
    var answers: [String: [ScriptedWorker.Answer]] = [
      // The launch check's, then the one a sync refused with 401 asks for, which the Worker
      // refuses too.
      "PUT /account/subscription": [.status(200), .status(401)],
      "GET /account": Array(repeating: ScriptedWorker.account(check: ownKey.check), count: 3),
      "POST /challenges": [.status(201, json: #"{"challenge":"c"}"#)],
      "POST /account": [.status(201, json: #"{"token":"\#(token)"}"#)],
    ]
    answers["DELETE /account"] = deletion.map { [$0] }
    let sent = Requests(
      writings: server ?? FakeWritingServer(accepting: token), account: ScriptedWorker(answers),
      refusing: refusingWritings, holdingFirstListing: holdingFirstListing)
    let account = AccountModel(
      account: SyncAccount(
        server: AccountServer(
          url: try #require(URL(string: "https://worker.test")), transport: sent),
        apple: ScriptedApple(), purchases: ScriptedApple(), sessions: sessions, ownKeys: ownKeys),
      kept: bought(defaults),
      syncState: FileManager.default.temporaryDirectory.appending(
        path: "WritingSyncTests-\(UUID().uuidString)", directoryHint: .isDirectory))
    let library = WritingLibrary(store: MemoryWritingStore(kept))
    library.load(seedingWhenEmpty: [])
    return Device(
      account: account, library: library,
      sync: WritingSync(account: account, library: library, pause: pause, interval: interval),
      sent: sent, ownKeys: ownKeys)
  }

  /// The account ID a plan was bought for, kept.
  private func bought(_ defaults: UserDefaults) -> KeptAccountID {
    let kept = KeptAccountID(defaults: defaults)
    kept.keep(accountID)
    return kept
  }

  private func writing(_ title: String, at seconds: Double) -> Writing {
    Writing(
      title: title, body: "\(title)の本文", links: [BodyLink(range: 0..<1, url: link)],
      updated: Date(timeIntervalSince1970: seconds))
  }

  private let link = URL(string: "https://example.com/bread") ?? URL(filePath: "/")

  /// The free app: no session at launch, and nothing sent at launch, on coming to the front, after
  /// an edit, or on 「今すぐ同期」.
  @Test func withNoAccountNothingIsSent() async throws {
    let written = writing("朝", at: 1_000)
    let device = try device([written], signedIn: false)

    await device.account.checkAtLaunch()
    await device.sync.syncNow()
    try device.library.edit(written.id, at: .now) { $0.title = "夜" }
    device.sync.edited()
    #expect(device.sync.pending == nil)
    await device.sync.syncNow()

    #expect(device.account.phase == .signedOut)
    #expect(device.sync.pending == nil)
    #expect(device.sync.status == .notYet)
    #expect(device.sent.all.isEmpty)
  }

  /// Signed in, the first sync settles the own key with the account's, sends the device's
  /// writings but the samples, and takes in another device's into the library.
  @Test func aSyncSendsTheWritingsButTheSamplesAndTakesInAnotherDevices() async throws {
    let server = FakeWritingServer(accepting: token)
    let mine = writing("朝", at: 1_000)
    let sample = Writing(
      id: UUID(sample: 1), title: "見本", body: "見本の本文",
      updated: Date(timeIntervalSince1970: 1_000))
    let first = try device([mine, sample], server: server)
    let theirs = writing("夜", at: 2_000)
    let second = try device([theirs], server: server)
    await first.account.checkAtLaunch()
    await second.account.checkAtLaunch()

    await first.sync.syncNow()
    await second.sync.syncNow()
    await first.sync.syncNow()

    guard case .synced = first.sync.status else {
      Issue.record("the first device synced: \(first.sync.status)")
      return
    }
    let listed = try await WritingServer(
      url: try #require(URL(string: "https://worker.test")), token: token, transport: server
    ).list()
    #expect(Set(listed.map(\.id)) == [mine.id, theirs.id])
    let shown = try first.library.forSync()
    #expect(shown.count == 3)
    #expect(shown.contains(theirs))
    #expect(try second.library.forSync().contains(mine))
    #expect(try second.library.store.all().contains(mine))
  }

  /// An edit made while a sync runs is kept: the writing the sync brings is not saved over it.
  @Test func aWritingEditedWhileTheSyncRunsIsNotSavedOver() async throws {
    let written = writing("朝", at: 1_000)
    let library = WritingLibrary(store: MemoryWritingStore([written]))
    library.load(seedingWhenEmpty: [])
    let synced = SyncedWritings(library: library)
    _ = try await synced.all()
    try library.edit(written.id, at: Date(timeIntervalSince1970: 2_000)) { $0.body = "書き足した" }
    let fromServer = PlainWriting(
      id: written.id, updated: Date(timeIntervalSince1970: 1_500),
      contents: try Writing.Contents(writing("昼", at: 0)).encoded())

    await #expect(throws: EditedDuringSync.self) { try await synced.save(fromServer) }
    #expect(try library.forSync().map(\.body) == ["書き足した"])
    #expect(try library.store.all().map(\.body) == ["書き足した"])
  }

  /// What is sealed is the title, the body, and the links; a writing from another device opens
  /// to the same, and contents that aren't a writing's fail that writing alone.
  @Test func aWritingsContentsTravelWhole() async throws {
    let library = WritingLibrary(store: MemoryWritingStore([]))
    library.load(seedingWhenEmpty: [])
    let synced = SyncedWritings(library: library)
    let written = writing("朝", at: 1_000)
    _ = try await synced.all()
    try await synced.save(
      PlainWriting(
        id: written.id, updated: written.updated, contents: try Writing.Contents(written).encoded())
    )
    #expect(try library.forSync() == [written])
    #expect(try await synced.all().map(\.contents) == [try Writing.Contents(written).encoded()])

    let outOfRange = PlainWriting(
      id: UUID(), updated: written.updated,
      contents: Data(
        #"{"body":"短い","links":[{"range":[0,9],"url":"https://example.com/"}],"title":"題"}"#.utf8
      ))
    try await synced.save(outOfRange)
    #expect(try library.forSync().first { $0.id == outOfRange.id }?.links == [])

    await #expect(throws: UnreadableContents.self) {
      try await synced.save(
        PlainWriting(id: UUID(), updated: written.updated, contents: Data("平文".utf8)))
    }
  }

  /// An edit sets a sync once edits pause, which sends it.
  @Test func anEditSetsASyncThatSendsIt() async throws {
    let written = writing("朝", at: 1_000)
    let device = try device([written])
    await device.account.checkAtLaunch()
    await device.sync.syncNow()

    try device.library.edit(written.id, at: Date(timeIntervalSince1970: 2_000)) {
      $0.title = "夜"
    }
    device.sync.edited()
    await device.sync.pending?.value

    #expect(device.sync.pending == nil)
    let saves = device.sent.all.filter {
      $0.httpMethod == "PUT" && $0.url?.lastPathComponent == written.id.uuidString.lowercased()
    }
    #expect(saves.count == 2)
  }

  /// Edits made one after another set one sync, once they pause.
  @Test func editsOneAfterAnotherSetOneSync() async throws {
    let written = writing("朝", at: 1_000)
    let device = try device([written], pause: .milliseconds(200))
    await device.account.checkAtLaunch()

    for _ in 1...3 {
      device.sync.edited()
    }
    await device.sync.pending?.value

    #expect(
      device.sent.all.filter { $0.httpMethod == "GET" && $0.url?.path() == "/writings" }.count == 1)
  }

  @Test func aSyncSetByAnEditWaitsForThePauseAndTheInterval() {
    let now = ContinuousClock.now
    let pause = Duration.seconds(30)
    let interval = Duration.seconds(300)
    #expect(
      WritingSync.due(editedAt: now, lastStarted: nil, pause: pause, interval: interval)
        == now + pause)
    #expect(
      WritingSync.due(
        editedAt: now, lastStarted: now - .seconds(10), pause: pause, interval: interval)
        == now + .seconds(290))
    #expect(
      WritingSync.due(
        editedAt: now, lastStarted: now - .seconds(600), pause: pause, interval: interval)
        == now + pause)
  }

  /// A plan's limit (429) or lapse (402) stops the sync, says so, and edits set no sync until the
  /// person asks.
  @Test(arguments: [402, 429])
  func aPlansRefusalStopsSyncingOnEdits(status: Int) async throws {
    let written = writing("朝", at: 1_000)
    let device = try device([written], refusingWritings: status)
    await device.account.checkAtLaunch()

    await device.sync.syncNow()
    let error = status == 429 ? ServerError.limitReached(.saves) : .refused(status: 402, reason: "")
    #expect(device.sync.status == .stopped(error.localizedDescription))
    try device.library.edit(written.id, at: .now) { $0.title = "夜" }
    device.sync.edited()
    #expect(device.sync.pending == nil)

    let asked = device.sent.all.count
    await device.sync.syncNow()
    #expect(device.sent.all.count > asked)
  }

  /// A sync waits for the one before it, even when the own key changed between them and it runs
  /// on another `Synchronizer`: both share the account's state file and the library.
  @Test func aSyncOnNewKeysWaitsForTheOneRunning() async throws {
    let device = try device([writing("朝", at: 1_000)], holdingFirstListing: true)
    await device.account.checkAtLaunch()
    let first = Task { await device.sync.syncNow() }
    while device.sent.listings == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    try device.ownKeys.replace(with: OwnKey.generate())

    let second = Task { await device.sync.syncNow() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(device.sent.listings == 1)
    device.sent.release()
    await first.value
    await second.value
    #expect(device.sent.listings == 2)
  }

  /// When the person edits the writing between the copy of their edit and the other device's
  /// save, neither is saved, and the next sync keeps one copy, of the latest edit.
  @Test func anEditWhileKeepingBothSavesNeither() async throws {
    let written = writing("朝", at: 1_000)
    let library = WritingLibrary(store: MemoryWritingStore([written]))
    library.load(seedingWhenEmpty: [])
    let synced = SyncedWritings(library: library)
    _ = try await synced.all()
    try library.edit(written.id, at: Date(timeIntervalSince1970: 3_000)) { $0.body = "二度目" }
    let received = PlainWriting(
      id: written.id, updated: Date(timeIntervalSince1970: 2_000),
      contents: try Writing.Contents(writing("他の端末", at: 0)).encoded())
    let copy = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 2_500),
      contents: try Writing.Contents(writing("一度目", at: 0)).encoded())

    await #expect(throws: EditedDuringSync.self) {
      try await synced.keepBoth(received, copy: copy)
    }
    #expect(try library.forSync().map(\.body) == ["二度目"])
    #expect(try library.store.all().map(\.body) == ["二度目"])
  }

  /// A session the Worker ended is dropped, so the section offers signing in again, as the
  /// message says.
  @Test func anEndedSessionIsDroppedAndSaysSo() async throws {
    let device = try device([writing("朝", at: 1_000)], refusingWritings: 401)
    await device.account.checkAtLaunch()

    await device.sync.syncNow()

    #expect(
      device.sync.status
        == .sessionEnded(ServerError.refused(status: 401, reason: "").localizedDescription))
    #expect(device.account.phase == .signedOut)
  }

  /// An edit sets no sync sooner than `interval` after the last one started.
  @Test func anEditSoonAfterASyncWaitsForTheInterval() async throws {
    let device = try device([writing("朝", at: 1_000)], interval: .seconds(3_600))
    await device.account.checkAtLaunch()
    await device.sync.syncNow()

    device.sync.edited()
    try await Task.sleep(for: .milliseconds(200))
    #expect(device.sent.listings == 1)
    device.sync.pending?.cancel()
  }

  /// A writing edited while the sync that brings another device's save of it runs keeps the
  /// edit; the sync is shown as done, since the edit set the next one.
  @Test func anEditDuringTheSyncIsKeptAndTheSyncShownDone() async throws {
    let server = FakeWritingServer(accepting: token)
    let written = writing("朝", at: 1_000)
    let first = try device([written], server: server, pause: .seconds(3_600))
    let second = try device([], server: server)
    await first.account.checkAtLaunch()
    await second.account.checkAtLaunch()
    await first.sync.syncNow()
    await second.sync.syncNow()
    try second.library.edit(written.id, at: Date(timeIntervalSince1970: 2_000)) {
      $0.body = "他の端末"
    }
    await second.sync.syncNow()

    first.sent.holdNextListing()
    let syncing = Task { await first.sync.syncNow() }
    while first.sent.listings < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    try first.library.edit(written.id, at: Date(timeIntervalSince1970: 3_000)) {
      $0.body = "書き足した"
    }
    first.sent.release()
    await syncing.value

    guard case .synced = first.sync.status else {
      Issue.record("the sync is shown done: \(first.sync.status)")
      return
    }
    #expect(try first.library.forSync().map(\.body) == ["書き足した"])
  }

  /// The device's edit is kept as a copy before the other device's save replaces it, so a save
  /// that fails between them loses no edit.
  @Test func theCopyIsSavedBeforeTheWritingItKeeps() async throws {
    let written = writing("朝", at: 1_000)
    let store = RefusingOne(id: written.id, [written])
    let library = WritingLibrary(store: store)
    library.load(seedingWhenEmpty: [])
    let synced = SyncedWritings(library: library)
    _ = try await synced.all()
    store.refusing = true
    let received = PlainWriting(
      id: written.id, updated: Date(timeIntervalSince1970: 2_000),
      contents: try Writing.Contents(writing("他の端末", at: 0)).encoded())
    let copy = PlainWriting(
      id: UUID(), updated: written.updated, contents: try Writing.Contents(written).encoded())

    await #expect(throws: RefusingOne.Refused.self) {
      try await synced.keepBoth(received, copy: copy)
    }
    #expect(try store.all().contains { $0.id == copy.id })
  }

  /// 「今すぐ同期」 reads the account again once the sync is done, for what it used.
  @Test func aSyncAskedForReadsTheAccountAfter() async throws {
    let device = try device([writing("朝", at: 1_000)])
    await device.account.checkAtLaunch()

    await device.sync.syncAsked()

    let routes = device.sent.all.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" }
    #expect(routes.filter { $0 == "GET /account" }.count == 2)
    #expect(routes.last == "GET /account")
    #expect(device.account.state != nil)
  }

  /// Signing in, on a device that holds the account's key, syncs at once.
  @Test func signingInSyncs() async throws {
    let device = try device([writing("朝", at: 1_000)], signedIn: false, deviceKey: ownKey)
    await device.account.checkAtLaunch()
    #expect(device.account.phase == .signedOut)

    await device.sync.signIn()

    #expect(device.account.phase == .signedIn)
    #expect(device.sent.listings == 1)
  }

  /// The device's key isn't the account's: nothing syncs until the recovery key brings the
  /// account's back, which syncs at once.
  @Test func bringingTheKeyBackSyncs() async throws {
    let device = try device([writing("朝", at: 1_000)], deviceKey: OwnKey.generate())
    await device.account.checkAtLaunch()
    await device.sync.syncNow()
    #expect(device.account.phase == .recoveryKeyNeeded)
    #expect(device.sent.listings == 0)

    #expect(await device.sync.restore(from: RecoveryKey(ownKey).text) == nil)

    #expect(device.account.phase == .signedIn)
    #expect(device.sent.listings == 1)
    guard case .synced = device.sync.status else {
      Issue.record("the sync ran: \(device.sync.status)")
      return
    }
  }

  /// Any other failure is shown, and an edit still sets the next sync.
  @Test func anUnreachableServerIsShownAndEditsStillSync() async throws {
    let written = writing("朝", at: 1_000)
    let device = try device([written], refusingWritings: 0, pause: .seconds(3_600))
    await device.account.checkAtLaunch()

    await device.sync.syncNow()
    #expect(
      device.sync.status
        == .failed(ServerError.unreachable(URLError(.cannotConnectToHost)).localizedDescription))
    device.sync.edited()
    #expect(device.sync.pending != nil)
    device.sync.pending?.cancel()
  }

  /// The deletion waits for the sync running, so none writes the sync's state after it, and
  /// then the device shows no sync, drops the one an edit set, and sends nothing more.
  @Test func aDeletionWaitsForTheSyncRunningAndLeavesNothingToSync() async throws {
    let written = writing("朝", at: 1_000)
    let device = try device(
      [written], holdingFirstListing: true, pause: .seconds(3_600), deletion: .status(204))
    await device.account.checkAtLaunch()
    let syncing = Task { await device.sync.syncNow() }
    while device.sent.listings == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    device.sync.edited()
    let deleting = Task { await device.sync.deleteAccount() }
    try await Task.sleep(for: .milliseconds(200))
    #expect(!device.sent.routes.contains("DELETE /account"))

    device.sent.release()
    await syncing.value
    await deleting.value
    #expect(device.sent.routes.last == "DELETE /account")
    #expect(device.account.phase == .signedOut)
    #expect(device.sync.status == .notYet)
    #expect(device.sync.pending == nil)
    await device.sync.syncNow()
    #expect(device.sent.routes.last == "DELETE /account")
  }

  /// A deletion the server refuses leaves the sync an edit set to run.
  @Test func aDeletionTheServerRefusesKeepsTheSyncAnEditSet() async throws {
    let written = writing("朝", at: 1_000)
    let device = try device([written], pause: .seconds(3_600), deletion: .status(502))
    await device.account.checkAtLaunch()
    device.sync.edited()

    await device.sync.deleteAccount()
    #expect(device.account.phase == .signedIn)
    #expect(device.sync.pending != nil)
    device.sync.pending?.cancel()
  }
}

/// Writings kept in memory, refusing to save the one with `id` while `refusing`.
nonisolated final class RefusingOne: WritingStore {
  struct Refused: Error {}

  private let id: Writing.ID
  private let kept: MemoryWritingStore
  private let refuses = Mutex(false)

  init(id: Writing.ID, _ writings: [Writing]) {
    self.id = id
    kept = MemoryWritingStore(writings)
  }

  var refusing: Bool {
    get { refuses.withLock { $0 } }
    set { refuses.withLock { $0 = newValue } }
  }

  func all() throws -> [Writing] {
    try kept.all()
  }

  func save(_ writing: Writing) throws {
    guard !(refusing && writing.id == id) else { throw Refused() }
    try kept.save(writing)
  }
}

/// Writings kept in memory.
nonisolated final class MemoryWritingStore: WritingStore {
  private let kept: Mutex<[Writing.ID: Writing]>

  init(_ writings: [Writing]) {
    kept = Mutex(Dictionary(uniqueKeysWithValues: writings.map { ($0.id, $0) }))
  }

  func all() throws -> [Writing] {
    kept.withLock { Array($0.values) }
  }

  func save(_ writing: Writing) throws {
    kept.withLock { $0[writing.id] = writing }
  }
}

/// Sends the writings routes to `writings` and the rest to `account`, keeping every request. With
/// `refusing`, the writings routes answer that status instead (402 only the saves, as for a lapsed
/// plan), or fail as an unreachable server does when it is 0.
nonisolated final class Requests: HTTPTransport {
  private let writings: FakeWritingServer
  private let account: ScriptedWorker
  private let refusing: Int?
  private let held: Mutex<(holding: Bool, gate: CheckedContinuation<Void, Never>?)>
  private let sent = Mutex<[URLRequest]>([])

  /// With `holdingFirstListing`, the first listing of the writings waits until `release()`.
  init(
    writings: FakeWritingServer, account: ScriptedWorker, refusing: Int? = nil,
    holdingFirstListing: Bool = false
  ) {
    held = Mutex((holdingFirstListing, nil))
    self.writings = writings
    self.account = account
    self.refusing = refusing
  }

  var all: [URLRequest] { sent.withLock { $0 } }
  /// The routes asked, in order, `"DELETE /account"` for one.
  var routes: [String] { all.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" } }
  var listings: Int {
    all.filter { $0.httpMethod == "GET" && $0.url?.path() == "/writings" }.count
  }

  func release() {
    held.withLock { $0.gate?.resume() }
  }

  /// The next listing of the writings waits until `release()`.
  func holdNextListing() {
    held.withLock { $0.holding = true }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    sent.withLock { $0.append(request) }
    let holds =
      request.httpMethod == "GET" && request.url?.path() == "/writings"
      && held.withLock { held in
        defer { held.holding = false }
        return held.holding
      }
    if holds {
      await withCheckedContinuation { gate in held.withLock { $0.gate = gate } }
    }
    guard request.url?.pathComponents.dropFirst().first == "writings" else {
      return try await account.send(request)
    }
    guard let refusing, refusing != 402 || request.httpMethod == "PUT" else {
      return try await writings.send(request)
    }
    guard refusing != 0, let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: refusing, httpVersion: nil, headerFields: nil)
    else { throw URLError(.cannotConnectToHost) }
    return (Data(#"{"error":"refused","limit":"saves"}"#.utf8), response)
  }
}
