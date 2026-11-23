import Foundation
import Sync
import Testing

struct WritingServerTests {
  private let ownKey = OwnKey.generate()
  private let fake: FakeWritingServer

  init() {
    fake = FakeWritingServer(accepting: ownKey.accessToken)
  }

  private func server(token: String? = nil, transport: (any HTTPTransport)? = nil) -> WritingServer
  {
    guard let url = URL(string: "https://fake.test") else {
      preconditionFailure("https://fake.test is a URL")
    }
    return WritingServer(
      url: url, accessToken: token ?? ownKey.accessToken, transport: transport ?? fake)
  }

  @Test(arguments: ServerContract.allCases)
  func fakeAnswersAsTheWorkerDoes(_ contract: ServerContract) async throws {
    try await contract.check(
      server: server(), stranger: server(token: OwnKey.generate().accessToken), ownKey: ownKey)
  }

  @Test func twoDevicesSyncThroughTheFake() async throws {
    let server = server()
    try await TwoDevices(server: { server }, ownKey: ownKey).checkAWritingAndItsEditTravelBothWays()
  }

  @Test func aWritingChangedOnBothDevicesIsKeptTwice() async throws {
    let server = server()
    let devices = try TwoDevices(server: { server }, ownKey: ownKey)
    let id = UUID()
    let written = PlainWriting(
      id: id, updated: .init(timeIntervalSince1970: 1_000), contents: Data("a".utf8))
    try devices.first.writings.save(written)
    _ = try await devices.first.synchronizer.sync()
    _ = try await devices.second.synchronizer.sync()

    let firstEdit = PlainWriting(
      id: id, updated: .init(timeIntervalSince1970: 2_000), contents: Data("b".utf8))
    let secondEdit = PlainWriting(
      id: id, updated: .init(timeIntervalSince1970: 3_000), contents: Data("c".utf8))
    try devices.first.writings.save(firstEdit)
    try devices.second.writings.save(secondEdit)
    _ = try await devices.first.synchronizer.sync()
    let report = try await devices.second.synchronizer.sync()

    let copy = try #require(report.keptBoth[id])
    #expect(report.received == [id])
    #expect(report.sent == [copy])
    let expected = Set(
      [
        firstEdit,
        PlainWriting(id: copy, updated: secondEdit.updated, contents: secondEdit.contents),
      ].map(\.contents))
    #expect(Set(try devices.second.writings.all().map(\.contents)) == expected)

    #expect(try await devices.first.synchronizer.sync().received == [copy])
    #expect(try devices.first.writings.all().count == 2)
    #expect(Set(try devices.first.writings.all().map(\.contents)) == expected)
  }

  @Test func theSameWritingOnBothDevicesIsKeptOnce() async throws {
    let server = server()
    let devices = try TwoDevices(server: { server }, ownKey: ownKey)
    let same = PlainWriting(
      id: UUID(), updated: .init(timeIntervalSince1970: 1_000), contents: Data("同じ".utf8))
    try devices.first.writings.save(same)
    try devices.second.writings.save(same)
    _ = try await devices.first.synchronizer.sync()

    let report = try await devices.second.synchronizer.sync()
    #expect(report.keptBoth.isEmpty)
    #expect(try devices.second.writings.all() == [same])
  }

  @Test func aSyncWithNothingChangedOnlyLists() async throws {
    let server = server()
    let devices = try TwoDevices(server: { server }, ownKey: ownKey)
    try devices.first.writings.save(
      PlainWriting(
        id: UUID(), updated: .init(timeIntervalSince1970: 1_000), contents: Data("x".utf8)))
    _ = try await devices.first.synchronizer.sync()
    _ = try await devices.second.synchronizer.sync()
    let before = await fake.requests.count

    #expect(try await devices.first.synchronizer.sync() == SyncReport())
    #expect(try await devices.second.synchronizer.sync() == SyncReport())
    #expect(await fake.requests.dropFirst(before).map(\.httpMethod) == ["GET", "GET"])
  }

  @Test func twoSyncsAskedAtOnceRunOneAfterTheOther() async throws {
    let server = server()
    let device = try TwoDevices(server: { server }, ownKey: ownKey).first
    try device.writings.save(
      PlainWriting(
        id: UUID(), updated: .init(timeIntervalSince1970: 1_000), contents: Data("一度".utf8)))

    async let first = device.synchronizer.sync()
    async let second = device.synchronizer.sync()
    let reports = try await [first, second]

    #expect(reports.map(\.sent.count).sorted() == [0, 1])
    #expect(reports.allSatisfy { $0.left.isEmpty })
    #expect(await fake.requests.filter { $0.httpMethod == "PUT" }.count == 1)
  }

  @Test func aWritingSavedByAnotherDeviceDuringTheSyncIsLeftForTheNext() async throws {
    let id = UUID()
    let other = PlainWriting(
      id: id, updated: .init(timeIntervalSince1970: 1_000), contents: Data("他".utf8))
    let mine = PlainWriting(
      id: id, updated: .init(timeIntervalSince1970: 2_000), contents: Data("私".utf8))
    let ownKey = ownKey
    let fake = fake
    let racing = SaveFirst(fake) { _ = try await server().save(ownKey.seal(other), over: nil) }
    let devices = try TwoDevices(server: { server(transport: racing) }, ownKey: ownKey)
    try devices.first.writings.save(mine)

    #expect(try await devices.first.synchronizer.sync().left == [id])
    let next = try await devices.first.synchronizer.sync()
    #expect(next.received == [id])
    #expect(next.keptBoth[id] != nil)
  }

  @Test func aWritingTheServerGivesUnderAnotherIDIsRefused() async throws {
    let asked = UUID()
    let given = PlainWriting(
      id: UUID(), updated: .init(timeIntervalSince1970: 1_000), contents: Data("別".utf8))
    _ = try await server().save(ownKey.seal(given), over: nil)
    let swapping = ReadInstead(fake, asked: asked, given: given.id)
    let device = try TwoDevices(server: { server(transport: swapping) }, ownKey: ownKey).first
    _ = try await server().save(
      ownKey.seal(PlainWriting(id: asked, updated: given.updated, contents: given.contents)),
      over: nil)

    await #expect {
      try await device.synchronizer.sync()
    } throws: { error in
      guard let error = error as? SyncFailures,
        case .unexpectedAnswer = error.failures[asked] as? ServerError
      else { return false }
      return error.failures.count == 1 && error.report.received == [given.id]
    }
    #expect(try device.writings.all().map(\.id) == [given.id])
  }

  @Test func aWritingThatFailsAloneLeavesTheOthersToSync() async throws {
    let device = try TwoDevices(server: { server() }, ownKey: ownKey).first
    let tooLarge = try PlainWriting(
      id: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
      updated: .init(timeIntervalSince1970: 1_000), contents: Data(count: 1_900_000))
    let small = try PlainWriting(
      id: #require(UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")),
      updated: .init(timeIntervalSince1970: 1_000), contents: Data("小".utf8))
    try device.writings.save(tooLarge)
    try device.writings.save(small)

    await #expect {
      try await device.synchronizer.sync()
    } throws: { error in
      guard let error = error as? SyncFailures else { return false }
      return error.failures[tooLarge.id] is SealingError && error.failures.count == 1
        && error.report.sent == [small.id]
    }
    #expect(try await server().list().map(\.id) == [small.id])
  }

  @Test func aKeptBothSyncCutOffBeforeTheCopyIsSentMakesNoSecondCopy() async throws {
    let id = UUID()
    let cutting = CutOffFirstNewSave(fake)
    let devices = try TwoDevices(server: { server() }, ownKey: ownKey)
    let cutOff = try TwoDevices.Device(server: server(transport: cutting), ownKey: ownKey)
    try devices.first.writings.save(
      PlainWriting(id: id, updated: .init(timeIntervalSince1970: 1_000), contents: Data("b".utf8)))
    _ = try await devices.first.synchronizer.sync()
    try cutOff.writings.save(
      PlainWriting(id: id, updated: .init(timeIntervalSince1970: 2_000), contents: Data("c".utf8)))

    await #expect(throws: ServerError.self) { try await cutOff.synchronizer.sync() }
    let retried = try await cutOff.synchronizer.sync()

    #expect(retried.keptBoth.isEmpty)
    #expect(Set(try cutOff.writings.all().map(\.contents)) == [Data("b".utf8), Data("c".utf8)])
    #expect(try cutOff.writings.all().count == 2)
    #expect(try await server().list().count == 2)
  }

  @Test func aListingThatNamesAWritingTwiceIsRefused() async throws {
    _ = try await server().save(
      ownKey.seal(
        PlainWriting(id: UUID(), updated: .init(timeIntervalSince1970: 1_000), contents: Data())),
      over: nil)
    let device = try TwoDevices(server: { server(transport: ListTwice(fake)) }, ownKey: ownKey)
      .first

    await #expect {
      try await device.synchronizer.sync()
    } throws: { error in
      guard case ServerError.unexpectedAnswer = error else { return false }
      return true
    }
  }
}

/// Loses the answer to the first save of a new writing, as a dropped connection would.
private actor CutOffFirstNewSave: HTTPTransport {
  private let next: any HTTPTransport
  private var cut = false

  init(_ next: any HTTPTransport) {
    self.next = next
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if !cut, request.httpMethod == "PUT",
      request.value(forHTTPHeaderField: "Mai-Base-Revision") == "none"
    {
      cut = true
      throw URLError(.networkConnectionLost)
    }
    return try await next.send(request)
  }
}

/// Lists every writing twice.
private struct ListTwice: HTTPTransport {
  let next: any HTTPTransport

  init(_ next: any HTTPTransport) {
    self.next = next
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await next.send(request)
    guard request.httpMethod ?? "GET" == "GET", request.url?.lastPathComponent == "writings",
      let listing = try JSONSerialization.jsonObject(with: data) as? [String: [Any]],
      let writings = listing["writings"]
    else { return (data, response) }
    return (try JSONSerialization.data(withJSONObject: ["writings": writings + writings]), response)
  }
}

/// Runs `first` before passing on the first save, as if another device saved just then.
private actor SaveFirst: HTTPTransport {
  private let next: any HTTPTransport
  private var first: (@Sendable () async throws -> Void)?

  init(_ next: any HTTPTransport, first: @escaping @Sendable () async throws -> Void) {
    self.next = next
    self.first = first
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.httpMethod == "PUT", let first {
      self.first = nil
      try await first()
    }
    return try await next.send(request)
  }
}

/// Answers a read of one writing with another's.
private struct ReadInstead: HTTPTransport {
  let next: any HTTPTransport
  let asked: UUID
  let given: UUID

  init(_ next: any HTTPTransport, asked: UUID, given: UUID) {
    self.next = next
    self.asked = asked
    self.given = given
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var request = request
    if request.httpMethod ?? "GET" == "GET", let url = request.url,
      url.lastPathComponent == asked.uuidString.lowercased()
    {
      request.url = url.deletingLastPathComponent().appending(path: given.uuidString.lowercased())
    }
    return try await next.send(request)
  }
}
