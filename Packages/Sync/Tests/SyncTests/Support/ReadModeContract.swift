import CryptoKit
import Foundation
import Sync
import Testing

/// What `ReadMode` relies on from the server, from approving an agent to the agent opening its
/// copies: run on `FakeWritingServer` in `ReadModeTests` and on the Worker in
/// `WritingServerContractTests`. One walk on one new account, since read mode and the agents are
/// the account's.
enum ReadModeContract {
  static func check(_ device: ReadModeSetUp, ownKey: OwnKey, now: () -> Date) async throws {
    let server = device.readMode
    #expect(try await server.view() == ReadModeView(until: nil, excluded: [], agents: []))

    // Approving: the key once, with the device's signature, which every device can check.
    let agent = P256.KeyAgreement.PrivateKey()
    let key = AgentKey(agent.publicKey)
    let approved = try #require(try await server.approve(key))
    #expect(approved.token.hasPrefix("agent.\(approved.id.uuidString.lowercased()).") == true)
    #expect(try await server.approve(key) == nil)
    var view = try await server.view()
    #expect(view.agents.map(\.id) == [approved.id])
    #expect(view.trustedAgents(ownKey).map(\.key) == [key])
    #expect(view.trustedAgents(OwnKey.generate()).isEmpty)

    // Turning on sends a copy of every synced writing, which the agent opens.
    let first = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_000), contents: Data("一".utf8))
    let second = PlainWriting(
      id: UUID(), updated: Date(timeIntervalSince1970: 1_790_000_001), contents: Data("二".utf8))
    try device.writings.save(first)
    try device.writings.save(second)
    #expect(try await device.synchronizer.sync().copies == CopiesSent())
    let until = Date(timeIntervalSince1970: (now().timeIntervalSince1970 + 3600).rounded())
    var all = CopiesSent()
    all.kept = 2
    #expect(try await server.turnOn(until: until) == all)
    view = try await server.view()
    #expect(view.until == until)
    let listed = try await device.agent(token: approved.token).list()
    #expect(Set(listed.map(\.id)) == [first.id, second.id])
    #expect(listed.allSatisfy { $0.expires == until })
    try await expectOpened(first, by: agent, token: approved.token, on: device)

    // Excluding deletes the copy; including sends it again.
    try await server.exclude(first.id)
    #expect(try await server.view().excluded == [first.id])
    #expect(try await device.agent(token: approved.token).copy(of: first.id) == nil)
    var one = CopiesSent()
    one.kept = 1
    #expect(try await server.include(first.id) == one)
    #expect(try await server.view().excluded == [])
    try await expectOpened(first, by: agent, token: approved.token, on: device)

    // A save sends the copy of its new revision with the sync.
    let edited = PlainWriting(
      id: second.id, updated: Date(timeIntervalSince1970: 1_790_000_100), contents: Data("改".utf8))
    try device.writings.save(edited)
    let synced = try await device.synchronizer.sync()
    #expect(synced.sent == [second.id])
    #expect(synced.copies == one)
    try await expectOpened(edited, by: agent, token: approved.token, on: device)

    // Revoking deletes the agent's copies, and its token stops reading.
    #expect(try await server.revoke(approved.id))
    #expect(try await server.revoke(UUID()) == false)
    #expect(try await device.agentStatus(token: approved.token) == 401)
    await #expect {
      _ = try await device.agent(token: approved.token).list()
    } throws: {
      guard case .refused(status: 401, _) = $0 as? ServerError else { return false }
      return true
    }
    view = try await server.view()
    #expect(view.agents.map(\.revoked) == [true])
    #expect(view.trustedAgents(ownKey).isEmpty)
    #expect(try await server.approve(key) == nil)

    // Turning off; a time that has passed doesn't turn it on.
    try await server.turnOff()
    #expect(try await server.view().until == nil)
    await #expect(throws: ServerError.self) {
      _ = try await server.turnOn(until: now() - 60)
    }
    #expect(try await server.view().until == nil)
  }

  private static func expectOpened(
    _ writing: PlainWriting, by agent: P256.KeyAgreement.PrivateKey, token: String,
    on device: ReadModeSetUp
  ) async throws {
    let copy = try #require(try await device.agent(token: token).copy(of: writing.id))
    let opened = try copy.open(with: agent)
    #expect(opened == writing)
  }
}
