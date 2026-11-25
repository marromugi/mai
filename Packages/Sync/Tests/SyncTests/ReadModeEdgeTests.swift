import CryptoKit
import Foundation
import Sync
import SyncFakes
import Testing

/// Read mode where devices, the server and failures meet: what poke-it found on #112.
struct ReadModeEdgeTests {
  private let ownKey = OwnKey.generate()

  private func setUp() -> (ReadModeSetUp, Rewriting, FakeWritingServer, TestClock) {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let rewriting = Rewriting(fake: fake)
    let device = ReadModeSetUp(
      ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
      transport: rewriting)
    return (device, rewriting, fake, clock)
  }

  private func approveAnAgent(on device: ReadModeSetUp) async throws -> ApprovedAgent {
    try #require(
      try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey)))
  }

  /// Turning on copies what another device synced and this one hasn't taken in yet.
  @Test func turningOnCopiesWritingsThisDeviceHasntReceived() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let first = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let second = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let approved = try await approveAnAgent(on: second)
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    try first.writings.save(writing)
    _ = try await first.synchronizer.sync()

    var one = CopiesSent()
    one.kept = 1
    #expect(try await second.readMode.turnOn(until: clock.now + 600) == one)
    #expect(try await second.agentList(token: approved.token) == [writing.id])
  }

  /// Turning on copies the server's save, not an older one this device kept the key of.
  @Test func turningOnCopiesTheServersSaveOverAnOlderOneKept() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let first = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let second = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let agent = P256.KeyAgreement.PrivateKey()
    let approved = try #require(try await second.readMode.approve(AgentKey(agent.publicKey)))
    let id = UUID()
    try first.writings.save(PlainWriting(id: id, updated: clock.now, contents: Data("一".utf8)))
    _ = try await first.synchronizer.sync()
    _ = try await second.synchronizer.sync()
    let edited = PlainWriting(id: id, updated: clock.now + 1, contents: Data("二".utf8))
    try first.writings.save(edited)
    _ = try await first.synchronizer.sync()

    _ = try await second.readMode.turnOn(until: clock.now + 600)
    let read = try #require(try await second.agentRead(id, token: approved.token))
    #expect(
      try AgentCopy(id: id, bytes: read.bytes, wrapped: read.wrapped).open(with: agent) == edited)
  }

  /// A copy refused because read mode changed between the read and the sending is owed.
  @Test func copiesRefusedForAnotherReadModeAreSentAgain() async throws {
    let (device, rewriting, fake, clock) = setUp()
    let other = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let approved = try await approveAnAgent(on: device)
    _ = try await device.readMode.turnOn(until: clock.now + 600)
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("一".utf8))
    try device.writings.save(writing)
    let until = clock.now + 1200
    await rewriting.set(before: { request in
      guard request.url?.lastPathComponent == "copies" else { return }
      try? await other.readMode.turnOff()
      _ = try? await other.readMode.turnOn(until: until)
    })
    let report = try await device.synchronizer.sync()
    await rewriting.set()
    #expect(report.copies.refused[.readMode] == 1)

    #expect(try await device.synchronizer.sync().copies.kept == 1)
    #expect(try await device.agentRead(writing.id, token: approved.token) != nil)
  }

  /// An include sent while a sync's copies fail keeps what the sync came to owe.
  @Test func anIncludeDuringAFailedSyncKeepsTheSyncsOwedCopies() async throws {
    let (device, rewriting, _, clock) = setUp()
    let approved = try await approveAnAgent(on: device)
    _ = try await device.readMode.turnOn(until: clock.now + 600)
    let included = PlainWriting(id: UUID(), updated: clock.now, contents: Data("in".utf8))
    try device.writings.save(included)
    _ = try await device.synchronizer.sync()
    try await device.readMode.exclude(included.id)
    await rewriting.holdTheNextCopies()
    let including = Task { try await device.readMode.include(included.id) }
    while await !rewriting.held { await Task.yield() }
    let edited = PlainWriting(id: UUID(), updated: clock.now, contents: Data("new".utf8))
    try device.writings.save(edited)
    await rewriting.setFailCopies(true)
    await #expect(throws: ServerError.self) { _ = try await device.synchronizer.sync() }
    await rewriting.setFailCopies(false)
    await rewriting.letGo()
    _ = try await including.value

    _ = try await device.synchronizer.sync()
    #expect(try await device.agentRead(edited.id, token: approved.token) != nil)
  }

  /// A save on the server this own key can't open is left out; the others are copied.
  @Test func oneUnopenableSaveDoesntStopTheOtherCopies() async throws {
    let (device, rewriting, _, clock) = setUp()
    let approved = try await approveAnAgent(on: device)
    let good = PlainWriting(id: UUID(), updated: clock.now, contents: Data("good".utf8))
    let other = PlainWriting(id: UUID(), updated: clock.now, contents: Data("other".utf8))
    try device.writings.save(good)
    try device.writings.save(other)
    _ = try await device.synchronizer.sync()
    try device.forgetWritingKeys()
    let writings = WritingServer(
      url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken, transport: rewriting)
    let (_, base) = try #require(try await writings.read(other.id))
    _ = try await writings.save(OwnKey.generate().seal(other), over: base)

    var one = CopiesSent()
    one.kept = 1
    #expect(try await device.readMode.turnOn(until: clock.now + 600) == one)
    #expect(try await device.agentRead(good.id, token: approved.token) != nil)
  }

  /// A refusal the device doesn't know yet is counted, not a failure of the whole sending.
  @Test func aRefusalReasonTheDeviceDoesntKnowIsCounted() async throws {
    let (device, rewriting, _, clock) = setUp()
    _ = try await approveAnAgent(on: device)
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data()))
    _ = try await device.synchronizer.sync()
    await rewriting.set(rewrite: { request, data, response in
      guard request.url?.lastPathComponent == "copies" else { return (data, response) }
      let text = String(decoding: data, as: UTF8.self)
        .replacing(#""refused":null"#, with: #""refused":"expired""#)
      return (Data(text.utf8), response)
    })
    let sent = try await device.readMode.turnOn(until: clock.now + 600)
    #expect(sent.refused == [.other("expired"): 1])
  }

  /// An owed-copies file that can't be read owes nothing, and the sync goes on.
  @Test func anUnreadableOwedCopiesFileDoesntStopTheSync() async throws {
    let (device, _, _, clock) = setUp()
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data()))
    _ = try await device.synchronizer.sync()
    try Data().write(
      to: device.stateFile.deletingPathExtension().appendingPathExtension("copies.json"))
    _ = try await device.synchronizer.sync()
  }
}
