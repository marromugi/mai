import CryptoKit
import Foundation
import Sync
import SyncFakes
import Testing

struct ReadModeTests {
  private let ownKey = OwnKey.generate()

  @Test func fakeAnswersAsTheWorkerDoes() async throws {
    let (device, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
    try await ReadModeContract.check(device, ownKey: ownKey, now: { clock.now })
  }

  /// With read mode off, a sync that sent a writing asks only whether it is on.
  @Test func aSyncWithReadModeOffSendsNoCopy() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let device = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    try device.writings.save(
      PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8)))
    _ = try await device.synchronizer.sync()
    let paths = await fake.requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" }
    #expect(paths.filter { !$0.contains("/writings") } == ["GET /read-mode"])
  }

  /// A sync that sent nothing doesn't ask about read mode at all.
  @Test func aSyncThatSentNothingAsksNothingOfReadMode() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let device = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    _ = try await device.synchronizer.sync()
    #expect(await fake.requests.map { $0.url?.path() } == ["/writings"])
  }

  /// A writing taken in from another device is copied with the key it was sealed with there.
  @Test func aWritingReceivedIsCopiedWithItsKey() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let first = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let second = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let agent = P256.KeyAgreement.PrivateKey()
    let approved = try #require(try await first.readMode.approve(AgentKey(agent.publicKey)))
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    try first.writings.save(writing)
    _ = try await first.synchronizer.sync()
    #expect(try await second.synchronizer.sync().received == [writing.id])

    var one = CopiesSent()
    one.kept = 1
    #expect(try await second.readMode.turnOn(until: clock.now + 60) == one)
    let read = try #require(try await second.agentRead(writing.id, token: approved.token))
    #expect(
      try AgentCopy(id: writing.id, bytes: read.bytes, wrapped: read.wrapped).open(with: agent)
        == writing)
  }

  /// No device wraps for an agent the server lists but no device of the account signed: put in by
  /// someone else, or signed with another own key.
  @Test func anAgentNoDeviceSignedGetsNoCopy() async throws {
    let (device, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
    let server = ReadModeServer(
      url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken, transport: device.transport)
    let forged = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    let otherOwnKey = OwnKey.generate()
    _ = try #require(try await server.approve(forged, signature: Data(repeating: 1, count: 32)))
    let signedElsewhere = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    _ = try #require(
      try await server.approve(
        signedElsewhere, signature: otherOwnKey.signature(approving: signedElsewhere)))
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data()))
    _ = try await device.synchronizer.sync()

    #expect(try await device.readMode.turnOn(until: clock.now + 60) == CopiesSent())
    #expect(try await device.readMode.view().trustedAgents(ownKey).isEmpty)
  }

  /// The server keeps an expired copy until its sweep, and never hands it out.
  @Test func anExpiredCopyIsNotHandedOut() async throws {
    let (device, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
    let agent = P256.KeyAgreement.PrivateKey()
    let approved = try #require(try await device.readMode.approve(AgentKey(agent.publicKey)))
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    try device.writings.save(writing)
    _ = try await device.synchronizer.sync()
    _ = try await device.readMode.turnOn(until: clock.now + 60)
    clock.advance(by: 60)
    #expect(try await device.agentRead(writing.id, token: approved.token) == nil)
    #expect(try await device.readMode.view().until == nil)
  }

  /// A state file kept before writing keys were has no key: the server's save is read for it.
  @Test func aWritingSyncedWithoutItsKeyIsCopiedFromTheServersSave() async throws {
    let (device, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
    let agent = P256.KeyAgreement.PrivateKey()
    let approved = try #require(try await device.readMode.approve(AgentKey(agent.publicKey)))
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    try device.writings.save(writing)
    _ = try await device.synchronizer.sync()
    try device.forgetWritingKeys()

    var one = CopiesSent()
    one.kept = 1
    #expect(try await device.readMode.turnOn(until: clock.now + 60) == one)
    let read = try #require(try await device.agentRead(writing.id, token: approved.token))
    #expect(
      try AgentCopy(id: writing.id, bytes: read.bytes, wrapped: read.wrapped).open(with: agent)
        == writing)
  }

  /// Copies a sync failed to send go with the next sync, even one that sends no writing.
  @Test func copiesThatFailedGoWithTheNextSync() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let failing = FailingCopies(fake: fake)
    let device = ReadModeSetUp(
      ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
      transport: failing)
    let approved = try #require(
      try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey)))
    _ = try await device.readMode.turnOn(until: clock.now + 600)
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    try device.writings.save(writing)
    await failing.fail(true)
    await #expect(throws: ServerError.self) { _ = try await device.synchronizer.sync() }
    #expect(try await device.agentRead(writing.id, token: approved.token) == nil)

    await failing.fail(false)
    let next = try await device.synchronizer.sync()
    #expect(next.sent.isEmpty)
    #expect(next.copies.kept == 1)
    #expect(try await device.agentRead(writing.id, token: approved.token) != nil)
    #expect(try await device.synchronizer.sync().copies == CopiesSent())
  }

  /// When a writing failed alone too, the sync says which, not that the copies failed.
  @Test func aWritingsFailureIsSaidOverTheCopies() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let failing = FailingCopies(fake: fake)
    let device = ReadModeSetUp(
      ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
      transport: failing)
    _ = try #require(
      try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey)))
    _ = try await device.readMode.turnOn(until: clock.now + 600)
    let sent = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    let tooLarge = PlainWriting(
      id: UUID(), updated: clock.now, contents: Data(repeating: 0, count: 2_000_000))
    try device.writings.save(sent)
    try device.writings.save(tooLarge)
    await failing.fail(true)

    let error = await #expect(throws: SyncFailures.self) {
      _ = try await device.synchronizer.sync()
    }
    #expect(error.map { Array($0.failures.keys) } == [tooLarge.id])
    #expect(error?.report.sent == [sent.id])
  }
}

/// Passes requests on to the fake, answering `POST /copies` with a 500 while told to fail.
private actor FailingCopies: HTTPTransport {
  let fake: FakeWritingServer
  private var failing = false

  init(fake: FakeWritingServer) {
    self.fake = fake
  }

  func fail(_ failing: Bool) {
    self.failing = failing
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard failing, request.httpMethod == "POST", request.url?.lastPathComponent == "copies",
      let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)
    else {
      return try await fake.send(request)
    }
    return (Data(#"{"error":"down"}"#.utf8), response)
  }
}
