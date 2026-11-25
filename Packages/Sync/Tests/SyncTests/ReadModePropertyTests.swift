import CryptoKit
import Foundation
import Sync
import SyncFakes
import Synchronization
import Testing

/// The properties of `Specs/ReadMode` on the device's side, checked over random runs of the
/// model's operations: two devices of one account, agents, keys nobody approved, the server's clock and its sweep. Each device acts through
/// `ReadMode` and `Synchronizer` on `FakeWritingServer`, which `ReadModeContract` holds to the
/// Worker. The Worker's side of the same properties is `Server/test/read-mode-properties.test.ts`.
///
/// After every step:
/// - `NeverWrapForUnsignedKey`: every copy a device sent is for an agent the account's own key
///   signed (`KeyIsTrusted`).
/// - `DeviceWraps`: no device sent a copy for a writing excluded or an agent revoked before it
///   sent, nor while the server held no read mode on until the copy's expiry.
/// - `NoCopyOfExcluded`, `NoCopyForRevokedKey`, `CopyIsOfCurrentVersion`, `NoCopyOutsideMode`,
///   and after the sweep `ExpiredCopiesSwept` and `ModeEndsOnTime`, on what the server holds.
/// - `NoServedCopyPastExpiry`, and every copy the agent is given opens, with the agent's key, to
///   the writing's current save.
struct ReadModePropertyTests {
  @Test(arguments: 0..<150)
  func everyRunKeepsTheProperties(seed: UInt64) async throws {
    var run = try Run(seed: seed)
    for step in 0..<40 {
      let operation = run.nextOperation()
      try await run.apply(operation)
      try await run.checkProperties(after: "\(step): \(operation)")
    }
  }
}

private enum Operation: CustomStringConvertible {
  case save(device: Int, writing: Int)
  case turnOn(device: Int, minutes: Int)
  case turnOff(device: Int)
  case exclude(device: Int, writing: Int)
  case include(device: Int, writing: Int)
  case approve(device: Int)
  /// A key put on the server in an agent's place, with a signature no own key of the account made.
  case postForgedKey
  /// A key signed with another own key than the account's.
  case postKeySignedElsewhere
  case revoke(device: Int, agent: Int)
  case tick
  case sweep
  case fetch(agent: Int, writing: Int)

  var description: String {
    switch self {
    case .save(let d, let w): "Save(d\(d), w\(w))"
    case .turnOn(let d, let minutes): "TurnOn(d\(d), +\(minutes))"
    case .turnOff(let d): "TurnOff(d\(d))"
    case .exclude(let d, let w): "Exclude(d\(d), w\(w))"
    case .include(let d, let w): "Include(d\(d), w\(w))"
    case .approve(let d): "Approve(d\(d))"
    case .postForgedKey: "PostForgedKey"
    case .postKeySignedElsewhere: "PostKeySignedElsewhere"
    case .revoke(let d, let a): "Revoke(d\(d), a\(a))"
    case .tick: "Tick"
    case .sweep: "Sweep"
    case .fetch(let a, let w): "Fetch(a\(a), w\(w))"
    }
  }
}

/// One random run: the server, two devices, and every agent put on the server.
private struct Run {
  /// One step of the server's clock.
  static let minute: TimeInterval = 60

  var random: SplitMix64
  let ownKey = OwnKey.generate()
  let server = TestClock()
  let fake: FakeWritingServer
  let devices: [ReadModeSetUp]
  let recorders: [Recorder]
  let writings = [UUID(), UUID()]
  /// Every agent put on the server: its private key, its server ID and token, and whether the
  /// account's own key signed it.
  var agents: [(key: P256.KeyAgreement.PrivateKey, id: UUID, token: String, signed: Bool)] = []
  var revoked: Set<UUID> = []
  var excluded: Set<UUID> = []
  var saves = 0
  var swept = false
  var log: [String] = []

  init(seed: UInt64) throws {
    random = SplitMix64(seed: seed)
    let server = server
    fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { server.now })
    var devices: [ReadModeSetUp] = []
    var recorders: [Recorder] = []
    for _ in 0..<2 {
      let recorder = Recorder(fake: fake, clock: server)
      recorders.append(recorder)
      devices.append(
        ReadModeSetUp(
          ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
          transport: recorder))
    }
    self.devices = devices
    self.recorders = recorders
  }

  mutating func nextOperation() -> Operation {
    let device = Int.random(in: 0..<2, using: &random)
    let writing = Int.random(in: 0..<2, using: &random)
    switch Int.random(in: 0..<14, using: &random) {
    case 0, 1: return .save(device: device, writing: writing)
    case 2: return .turnOn(device: device, minutes: Int.random(in: 0...3, using: &random))
    case 3: return .turnOff(device: device)
    case 4: return .exclude(device: device, writing: writing)
    case 5: return .include(device: device, writing: writing)
    case 6: return .approve(device: device)
    case 7: return Bool.random(using: &random) ? .postForgedKey : .postKeySignedElsewhere
    case 8:
      return agents.isEmpty
        ? .tick : .revoke(device: device, agent: Int.random(in: 0..<agents.count, using: &random))
    case 9: return .tick
    case 11: return .sweep
    default:
      return agents.isEmpty
        ? .sweep : .fetch(agent: Int.random(in: 0..<agents.count, using: &random), writing: writing)
    }
  }

  mutating func apply(_ operation: Operation) async throws {
    log.append(operation.description)
    switch operation {
    case .save(let d, let w):
      saves += 1
      try devices[d].writings.save(
        PlainWriting(
          id: writings[w], updated: Date(timeIntervalSince1970: 1_700_000_000 + Double(saves)),
          contents: Data("版 \(saves)".utf8)))
      _ = try await devices[d].synchronizer.sync()
    case .turnOn(let d, let minutes):
      do {
        _ = try await devices[d].readMode.turnOn(
          until: server.now + Double(minutes) * Self.minute)
      } catch ServerError.refused(status: 400, _) {
        #expect(minutes == 0, "only a time the server's clock has passed is refused: \(log)")
      }
    case .turnOff(let d):
      try await devices[d].readMode.turnOff()
    case .exclude(let d, let w):
      try await devices[d].readMode.exclude(writings[w])
      excluded.insert(writings[w])
    case .include(let d, let w):
      excluded.remove(writings[w])
      _ = try await devices[d].readMode.include(writings[w])
    case .approve(let d):
      let key = P256.KeyAgreement.PrivateKey()
      if let approved = try await devices[d].readMode.approve(AgentKey(key.publicKey)) {
        agents.append((key, approved.id, approved.token, true))
      }
    case .postForgedKey:
      try await post(signature: { _ in Data(repeating: 0xa5, count: 32) })
    case .postKeySignedElsewhere:
      let elsewhere = OwnKey.generate()
      try await post(signature: { elsewhere.signature(approving: $0) })
    case .revoke(let d, let a):
      _ = try await devices[d].readMode.revoke(agents[a].id)
      revoked.insert(agents[a].id)
    case .tick:
      server.advance(by: Self.minute)
      swept = false
    case .sweep:
      await fake.sweep()
      swept = true
    case .fetch(let a, let w):
      try await fetch(agent: a, writing: writings[w])
    }
  }

  /// Puts a key on the server as someone other than the account's devices would.
  private mutating func post(signature: (AgentKey) -> Data) async throws {
    let key = P256.KeyAgreement.PrivateKey()
    let agent = AgentKey(key.publicKey)
    let server = ReadModeServer(
      url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken, transport: fake)
    if let approved = try await server.approve(agent, signature: signature(agent)) {
      agents.append((key, approved.id, approved.token, false))
    }
  }

  /// `Fetch(a, w)`: what the server hands out has not expired, and opens to the current save.
  private func fetch(agent a: Int, writing: UUID) async throws {
    let agent = agents[a]
    guard !revoked.contains(agent.id) else {
      #expect(try await devices[0].agentStatus(token: agent.token) == 401, "\(log)")
      return
    }
    guard let read = try await devices[0].agentRead(writing, token: agent.token) else { return }
    let held = await fake.heldCopies().first {
      $0.writing == writing.uuidString.lowercased() && $0.agent == agent.id.uuidString.lowercased()
    }
    let expires = try #require(held?.expires, "a copy handed out is held: \(log)")
    #expect(
      Double(expires) / 1000 > server.now.timeIntervalSince1970,
      "NoServedCopyPastExpiry: \(log)")
    let current = try #require(
      try await WritingServer(
        url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken, transport: fake
      ).read(writing))
    #expect(
      try AgentCopy(id: writing, bytes: read.bytes, wrapped: read.wrapped).open(with: agent.key)
        == ownKey.open(current.envelope),
      "a copy handed out opens to the current save: \(log)")
  }

  func checkProperties(after step: String) async throws {
    let context = "\(step) in \(log)"
    let copies = await fake.heldCopies()
    let mode = await fake.heldReadMode()
    let revisions = await fake.heldRevisions()
    let now = Int64((server.now.timeIntervalSince1970 * 1000).rounded())
    for copy in copies {
      #expect(!excluded.contains(UUID(uuidString: copy.writing)!), "NoCopyOfExcluded: \(context)")
      #expect(
        !revoked.contains(UUID(uuidString: copy.agent)!), "NoCopyForRevokedKey: \(context)")
      #expect(revisions[copy.writing] == copy.revision, "CopyIsOfCurrentVersion: \(context)")
      #expect(mode == copy.expires, "NoCopyOutsideMode: \(context)")
      if swept {
        #expect(copy.expires > now, "ExpiredCopiesSwept: \(context)")
      }
    }
    if swept, let mode {
      #expect(mode > now, "ModeEndsOnTime: \(context)")
    }
    for recorder in recorders {
      for sent in await recorder.copiesSent() {
        #expect(
          sent.modeBefore == sent.expires && sent.serverNow < sent.expires,
          "DeviceWraps, read mode on: \(context)")
        for copy in sent.copies {
          let agent = agents.first { $0.id == copy.agent }
          #expect(agent?.signed == true, "NeverWrapForUnsignedKey: \(context)")
          #expect(!sent.revokedBefore.contains(copy.agent), "DeviceWraps, revoked: \(context)")
          #expect(!sent.excludedBefore.contains(copy.writing), "DeviceWraps, excluded: \(context)")
        }
      }
    }
  }
}

/// Passes a device's requests on to the fake, and keeps each `POST /copies` with the device's
/// what the server held just before: its clock, its read mode, and the writings excluded and agents
/// revoked.
private actor Recorder: HTTPTransport {
  struct Sent {
    let serverNow: Date
    let modeBefore: Date?
    let expires: Date
    let copies: [(writing: UUID, agent: UUID)]
    let excludedBefore: Set<UUID>
    let revokedBefore: Set<UUID>
  }

  let fake: FakeWritingServer
  let clock: TestClock
  private var sent: [Sent] = []

  init(fake: FakeWritingServer, clock: TestClock) {
    self.fake = fake
    self.clock = clock
  }

  func copiesSent() -> [Sent] {
    sent
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.httpMethod == "POST", request.url?.lastPathComponent == "copies",
      let body = request.httpBody
    {
      let posted = try JSONDecoder().decode(Posted.self, from: body)
      let excluded = Set(await fake.heldExclusions().compactMap(UUID.init(uuidString:)))
      let agents = try await ReadModeServer(
        url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken, transport: fake
      ).agents()
      sent.append(
        Sent(
          serverNow: clock.now,
          modeBefore: await fake.heldReadMode().map {
            Date(timeIntervalSince1970: Double($0) / 1000)
          },
          expires: Date(timeIntervalSince1970: Double(posted.expires) / 1000),
          copies: posted.copies.map { ($0.writing, $0.agent) }, excludedBefore: excluded,
          revokedBefore: Set(agents.filter(\.revoked).map(\.id))))
    }
    return try await fake.send(request)
  }

  private struct Posted: Decodable {
    struct Copy: Decodable {
      let writing: UUID
      let agent: UUID
    }
    let expires: Int64
    let copies: [Copy]
  }
}

/// A random number generator that gives the same numbers for the same seed, so a failing run can
/// be run again.
struct SplitMix64: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9e37_79b9_7f4a_7c15
    var z = state
    z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
    z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
    return z ^ (z >> 31)
  }
}
