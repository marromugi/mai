import Foundation
import Sync
import Synchronization
import Testing

/// Two devices of one account syncing its writings through the Worker with the stand-in Apple
/// (`Server/test/stand-in-apple.ts`), run under `wrangler dev` with sqld by
/// `scripts/server-contract-test.sh`, which gives the Worker's URL. Each device signs in on its
/// own and syncs with its own session. Left out of the ordinary run by `--skip Contract`.
struct AccountSyncContractTests {
  private let url: URL?

  init() {
    url = ProcessInfo.processInfo.environment["MAI_SERVER_URL"].flatMap(URL.init(string:))
  }

  /// One device signed in to the account, holding its own key, with what it sent.
  private struct Device {
    let writings: MemoryWritingStore
    let synchronizer: Synchronizer
    let sent: Recording
    let keys: SyncKeys
  }

  /// A new account, signed in on two devices of its Apple user, the second holding the own key
  /// the first made.
  private func twoDevices() async throws -> (first: Device, second: Device) {
    let url = try #require(url, "MAI_SERVER_URL names the local Worker")
    let user = "stand-in.\(UUID().uuidString)"
    let bought = UUID()
    let first = try await device(url: url, user: user, account: bought, ownKey: nil)
    let second = try await device(url: url, user: user, account: bought, ownKey: first.keys.ownKey)
    #expect(first.keys.session.account == second.keys.session.account)
    #expect(first.keys.session.token != second.keys.session.token)
    return (first, second)
  }

  private func device(url: URL, user: String, account: UUID, ownKey: OwnKey?) async throws
    -> Device
  {
    let sent = Recording()
    let server = AccountServer(url: url, transport: sent)
    let apple = StandInApple(url: url, user: user)
    let ownKeys = MemoryOwnKeys(ownKey)
    let syncAccount = SyncAccount(
      server: server, apple: apple, purchases: apple, sessions: MemorySessions(),
      ownKeys: ownKeys)
    let session = try await syncAccount.signIn(for: account)
    let settled = try await syncAccount.settleOwnKey(session)
    let made = try #require(try ownKeys.load())
    #expect(settled == (ownKey == nil ? .made(RecoveryKey(made)) : .ready))
    let keys = try #require(try syncAccount.syncKeys())
    let writings = MemoryWritingStore()
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return Device(
      writings: writings,
      synchronizer: syncAccount.synchronizer(
        writings: writings, stateDirectory: directory, keys: keys),
      sent: sent, keys: keys)
  }

  @Test func twoDevicesOfOneAccountSyncAWritingBothWays() async throws {
    let (first, second) = try await twoDevices()
    let written = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.25),
      contents: Data(#"{"body":"朝に書いた","title":"朝"}"#.utf8))
    try first.writings.save(written)
    #expect(try await first.synchronizer.sync().sent == [written.id])

    #expect(try await second.synchronizer.sync().received == [written.id])
    #expect(try second.writings.all() == [written])

    let edited = PlainWriting(
      id: written.id, updated: Date(timeIntervalSince1970: 1_790_000_600),
      contents: Data(#"{"body":"夜に書き足した","title":"朝"}"#.utf8))
    try second.writings.save(edited)
    #expect(try await second.synchronizer.sync().sent == [written.id])

    #expect(try await first.synchronizer.sync().received == [written.id])
    #expect(try first.writings.all() == [edited])
  }

  /// Design #22 §6: the second save over the revision both devices last read gets 409 with the
  /// first's revision, and nothing is written. That sync leaves the writing for the next, which
  /// keeps the first's save under the ID and the second's edit as a new writing it sends; the
  /// first then takes that in, so both devices keep both edits.
  @Test func aSaveRefusedWith409IsKeptTwiceOnBothDevices() async throws {
    let (first, second) = try await twoDevices()
    let id = UUID()
    let written = PlainWriting(
      id: id, updated: Date(timeIntervalSince1970: 1_790_000_000), contents: Data("一稿".utf8))
    try first.writings.save(written)
    _ = try await first.synchronizer.sync()
    _ = try await second.synchronizer.sync()

    let firstEdit = PlainWriting(
      id: id, updated: Date(timeIntervalSince1970: 1_790_000_100), contents: Data("一の二稿".utf8))
    let secondEdit = PlainWriting(
      id: id, updated: Date(timeIntervalSince1970: 1_790_000_200), contents: Data("二の二稿".utf8))
    try first.writings.save(firstEdit)
    try second.writings.save(secondEdit)
    // The first device's save lands after the second listed and before it saves.
    second.sent.afterNextListing { () async throws in
      #expect(try await first.synchronizer.sync().sent == [id])
    }
    let refused = try await second.synchronizer.sync()
    #expect(refused.left == [id])
    #expect(refused.sent.isEmpty)
    let saves = second.sent.answers.filter {
      $0.request.httpMethod == "PUT"
        && $0.request.url?.lastPathComponent == id.uuidString.lowercased()
    }
    #expect(saves.map(\.status) == [409])

    let resolved = try await second.synchronizer.sync()
    let copy = try #require(resolved.keptBoth[id])
    #expect(resolved.received == [id])
    #expect(resolved.sent == [copy])

    #expect(try await first.synchronizer.sync().received == [copy])
    for device in [first, second] {
      let kept = Dictionary(uniqueKeysWithValues: try device.writings.all().map { ($0.id, $0) })
      #expect(kept[id] == firstEdit)
      #expect(kept[copy]?.contents == secondEdit.contents)
      #expect(kept.count == 2)
    }
  }

  /// #25: what is sent holds no plaintext, doesn't open with another key, and the same contents
  /// saved twice are sent as other bytes.
  @Test func whatTheWorkerIsSentIsCiphertextOnly() async throws {
    let (first, _) = try await twoDevices()
    let title = "誰にも見せない題"
    let body = "まだ誰にも話していない、夜の机で書いた本文。"
    let contents = Data(#"{"body":"\#(body)","title":"\#(title)"}"#.utf8)
    let writing = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000.5), contents: contents)
    try first.writings.save(writing)
    _ = try await first.synchronizer.sync()
    var again = writing
    again.updated += 60
    try first.writings.save(again)
    _ = try await first.synchronizer.sync()

    let requests = first.sent.requests
    let saves = requests.filter {
      $0.httpMethod == "PUT" && $0.url?.path().contains("/writings/") == true
    }
    .compactMap(\.httpBody)
    try #require(saves.count == 2)
    let plaintexts = [Data(title.utf8), Data(body.utf8), contents]
    for request in requests {
      let sent =
        Data((request.url?.absoluteString ?? "").utf8)
        + Data((request.allHTTPHeaderFields ?? [:]).description.utf8) + (request.httpBody ?? Data())
      for plaintext in plaintexts + plaintexts.map({ Data($0.base64EncodedString().utf8) }) {
        #expect(sent.firstRange(of: plaintext) == nil)
      }
    }
    #expect(saves[0] != saves[1])
    #expect(saves[0][88...] != saves[1][88...])
    let stranger = OwnKey.generate()
    for save in saves {
      let envelope = try Envelope(bytes: save)
      #expect(throws: OpeningError.self) { try stranger.open(envelope) }
      #expect(try first.keys.ownKey.open(envelope).contents == contents)
    }
  }

  /// The Worker refuses a write that isn't a sealed writing of the one shape, and keeps nothing.
  @Test(arguments: [
    Data(#"{"body":"平文","title":"題"}"#.utf8), Data(count: 116), Data([0x6d, 0x61, 0x69, 0x01]),
  ])
  func theWorkerRefusesAWriteNotOfTheOneShape(_ bytes: Data) async throws {
    let (first, _) = try await twoDevices()
    let url = try #require(url)
    let id = UUID()
    var request = URLRequest(url: url.appending(path: "writings/\(id.uuidString.lowercased())"))
    request.httpMethod = "PUT"
    request.setValue("Bearer \(first.keys.session.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("none", forHTTPHeaderField: "Mai-Base-Revision")
    request.httpBody = bytes
    let (_, response) = try await URLSession.shared.send(request)
    #expect(response.statusCode == 400)
    let server = WritingServer(url: url, token: first.keys.session.token)
    #expect(try await server.read(id) == nil)
  }
}

/// Sends through `URLSession`, keeping every request it sent and the status it got.
private final class Recording: HTTPTransport {
  typealias Step = @Sendable () async throws -> Void

  private let state = Mutex<(answers: [(request: URLRequest, status: Int)], afterListing: Step?)>(
    ([], nil))

  var answers: [(request: URLRequest, status: Int)] { state.withLock { $0.answers } }
  var requests: [URLRequest] { answers.map(\.request) }

  /// Runs `step` once the next listing of the writings is answered, before the answer is given.
  func afterNextListing(_ step: @escaping Step) {
    state.withLock { $0.afterListing = step }
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let answer = try await URLSession.shared.send(request)
    let step = state.withLock { state -> Step? in
      state.answers.append((request, answer.1.statusCode))
      guard request.httpMethod == "GET", request.url?.path().hasSuffix("/writings") == true
      else { return nil }
      defer { state.afterListing = nil }
      return state.afterListing
    }
    try await step?()
    return answer
  }
}
