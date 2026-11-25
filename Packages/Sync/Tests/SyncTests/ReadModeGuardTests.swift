import CryptoKit
import Foundation
import Sync
import SyncFakes
import Testing

/// What break-it found nothing guarding on #112: the formats as `Server/README.md` writes them,
/// read here without the package's own code, and the requests read mode makes or doesn't.
struct ReadModeGuardTests {
  private let ownKey = OwnKey.generate()

  // MARK: The formats, read as an agent written from the README would

  /// The wrapped key opens with HPKE as the README says: info `mai read-mode copy 1`, and the
  /// writing's ID and the SHA-256 of the sealed writing as authenticated data.
  @Test func theWrappedKeyIsAsTheReadmeSays() async throws {
    let (device, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
    let agent = P256.KeyAgreement.PrivateKey()
    let approved = try #require(try await device.readMode.approve(AgentKey(agent.publicKey)))
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("原稿".utf8))
    try device.writings.save(writing)
    _ = try await device.synchronizer.sync()
    _ = try await device.readMode.turnOn(until: clock.now + 600)
    let read = try #require(try await device.agentRead(writing.id, token: approved.token))

    #expect(read.wrapped.count == 113)
    var recipient = try HPKE.Recipient(
      privateKey: agent, ciphersuite: .P256_SHA256_AES_GCM_256,
      info: Data("mai read-mode copy 1".utf8), encapsulatedKey: read.wrapped.prefix(65))
    let authenticated =
      withUnsafeBytes(of: writing.id.uuid) { Data($0) } + Data(SHA256.hash(data: read.bytes))
    let key = try recipient.open(read.wrapped.dropFirst(65), authenticating: authenticated)
    let contents = try AES.GCM.open(
      AES.GCM.SealedBox(combined: read.bytes.dropFirst(88)), using: SymmetricKey(data: key),
      authenticating: read.bytes.prefix(28))
    #expect(contents == writing.contents)
  }

  /// The signature is an HMAC-SHA256 of the 33-byte key, under HKDF-SHA256 of the own key with
  /// the info `mai agent approval`.
  @Test func theSignatureIsAsTheReadmeSays() {
    let key = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    #expect(ownKey.signature(approving: key) == Self.signature(of: key.rawRepresentation, ownKey))
  }

  /// The pairing code is the key and the first 2 bytes of its SHA-256, in Crockford's Base32.
  @Test func thePairingCodeIsAsTheReadmeSays() throws {
    let key = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    var bits = ""
    for character in key.pairingCode where character != "-" {
      let value = try #require(alphabet.firstIndex(of: character))
      let binary = String(value, radix: 2)
      bits += String(repeating: "0", count: 5 - binary.count) + binary
    }
    let bytes = stride(from: 0, to: bits.count, by: 8).map { start in
      let from = bits.index(bits.startIndex, offsetBy: start)
      return UInt8(bits[from..<bits.index(from, offsetBy: 8)], radix: 2) ?? 0
    }
    #expect(
      Data(bytes) == key.rawRepresentation + SHA256.hash(data: key.rawRepresentation).prefix(2))
  }

  private static func signature(of bytes: Data, _ ownKey: OwnKey) -> Data {
    let approval = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: ownKey.rawRepresentation),
      info: Data("mai agent approval".utf8), outputByteCount: 32)
    return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: approval))
  }

  // MARK: Agents

  /// A key that isn't a point is neither approved nor trusted, even signed with the own key.
  @Test func aKeyThatIsntAKeyIsNotApproved() async throws {
    let (device, _) = ReadModeSetUp.onFake(ownKey: ownKey)
    let bytes = Data([0x02] + Array(repeating: 0x11, count: 32))
    #expect(throws: AgentKeyError.notAPublicKey) { try AgentKey(rawRepresentation: bytes) }
    var request = URLRequest(url: ReadModeSetUp.fakeURL.appending(path: "agents"))
    request.httpMethod = "POST"
    request.setValue("Bearer \(ReadModeSetUp.fakeToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "publicKey": Self.hex(bytes), "signature": Self.hex(Self.signature(of: bytes, ownKey)),
    ])
    #expect(try await device.transport.send(request).1.statusCode == 201)

    let view = try await device.readMode.view()
    #expect(view.agents.count == 1)
    #expect(view.agents.first?.key == nil)
    #expect(device.readMode.approvedAgents(in: view).isEmpty)
    #expect(view.trustedAgents(ownKey).isEmpty)
  }

  @Test func agentsAreListedInTheServersOrder() async throws {
    let (device, _) = ReadModeSetUp.onFake(ownKey: ownKey)
    var approved: [UUID] = []
    for _ in 0..<3 {
      approved.append(
        try #require(
          try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
        ).id)
    }
    #expect(try await device.readMode.view().agents.map(\.id) == approved)
  }

  /// More than 100 copies go 100 to a request.
  @Test func copiesGoAHundredToARequest() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let device = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    for _ in 0..<2 {
      _ = try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
    }
    for index in 0..<51 {
      try device.writings.save(
        PlainWriting(id: UUID(), updated: clock.now, contents: Data("\(index)".utf8)))
    }
    _ = try await device.synchronizer.sync()
    var all = CopiesSent()
    all.kept = 102
    #expect(try await device.readMode.turnOn(until: clock.now + 600) == all)
    let posts = await fake.requests.filter {
      $0.httpMethod == "POST" && $0.url?.lastPathComponent == "copies"
    }
    let counts = try posts.map { request in
      let body = try #require(request.httpBody)
      let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
      return (json["copies"] as? [Any])?.count ?? 0
    }
    #expect(counts == [100, 2])
  }

  // MARK: The requests read mode makes

  /// The keys kept by the sync, of saves sent and received, are wrapped without reading the
  /// writings again.
  @Test func turningOnUsesTheKeysTheSyncKept() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let first = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    let second = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    _ = try await second.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
    try first.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data("a".utf8)))
    _ = try await first.synchronizer.sync()
    try second.writings.save(
      PlainWriting(id: UUID(), updated: clock.now, contents: Data("b".utf8)))
    _ = try await second.synchronizer.sync()
    let before = await fake.requests.count

    var two = CopiesSent()
    two.kept = 2
    #expect(try await second.readMode.turnOn(until: clock.now + 600) == two)
    #expect(await Self.writingsRead(fake.requests.dropFirst(before)).isEmpty)
  }

  /// An excluded writing whose key isn't kept isn't read from the server for one.
  @Test func anExcludedWritingIsNotReadForItsKey() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let device = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    _ = try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
    let writing = PlainWriting(id: UUID(), updated: clock.now, contents: Data("a".utf8))
    try device.writings.save(writing)
    _ = try await device.synchronizer.sync()
    try device.forgetWritingKeys()
    try await device.readMode.exclude(writing.id)
    let before = await fake.requests.count

    #expect(try await device.readMode.turnOn(until: clock.now + 600) == CopiesSent())
    #expect(await Self.writingsRead(fake.requests.dropFirst(before)).isEmpty)
  }

  /// With no agent to wrap for, turning on reads no writing.
  @Test func turningOnWithNoAgentReadsNoWriting() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let device = ReadModeSetUp.onFake(ownKey: ownKey, fake: fake)
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data("a".utf8)))
    _ = try await device.synchronizer.sync()
    let before = await fake.requests.count

    #expect(try await device.readMode.turnOn(until: clock.now + 600) == CopiesSent())
    #expect(
      await fake.requests.dropFirst(before).filter { $0.url?.path().hasPrefix("/writings") == true }
        .isEmpty)
  }

  /// Copies owed while read mode is off are dropped: later syncs that send nothing ask nothing.
  @Test func copiesOwedWhileReadModeIsOffAreDropped() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let rewriting = Rewriting(fake: fake)
    let device = ReadModeSetUp(
      ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
      transport: rewriting)
    _ = try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
    _ = try await device.readMode.turnOn(until: clock.now + 600)
    try device.writings.save(PlainWriting(id: UUID(), updated: clock.now, contents: Data("a".utf8)))
    await rewriting.setFailCopies(true)
    await #expect(throws: ServerError.self) { _ = try await device.synchronizer.sync() }
    await rewriting.setFailCopies(false)
    try await device.readMode.turnOff()

    _ = try await device.synchronizer.sync()
    let before = await fake.requests.count
    _ = try await device.synchronizer.sync()
    #expect(await fake.requests.dropFirst(before).map { $0.url?.path() } == ["/writings"])
  }

  /// A writing given for another ID when its key is read is an answer of the wrong shape.
  @Test func aWritingGivenForAnotherIsUnexpected() async throws {
    let clock = TestClock()
    let fake = FakeWritingServer(accepting: ReadModeSetUp.fakeToken, now: { clock.now })
    let rewriting = Rewriting(fake: fake)
    let device = ReadModeSetUp(
      ownKey: ownKey, url: ReadModeSetUp.fakeURL, token: ReadModeSetUp.fakeToken,
      transport: rewriting)
    _ = try await device.readMode.approve(AgentKey(P256.KeyAgreement.PrivateKey().publicKey))
    let first = PlainWriting(id: UUID(), updated: clock.now, contents: Data("a".utf8))
    let second = PlainWriting(id: UUID(), updated: clock.now, contents: Data("b".utf8))
    try device.writings.save(first)
    try device.writings.save(second)
    _ = try await device.synchronizer.sync()
    try device.forgetWritingKeys()
    let firstPath = "/writings/\(first.id.uuidString.lowercased())"
    var secondRequest = URLRequest(
      url: ReadModeSetUp.fakeURL.appending(path: "writings/\(second.id.uuidString.lowercased())"))
    secondRequest.setValue(
      "Bearer \(ReadModeSetUp.fakeToken)", forHTTPHeaderField: "Authorization")
    let (secondBody, _) = try await fake.send(secondRequest)
    await rewriting.set(rewrite: { request, data, response in
      guard request.httpMethod ?? "GET" == "GET", request.url?.path() == firstPath else {
        return (data, response)
      }
      return (secondBody, response)
    })

    await #expect(throws: ServerError.self) {
      _ = try await device.readMode.turnOn(until: clock.now + 600)
    }
  }

  private static func writingsRead(_ requests: some Sequence<URLRequest>) -> [URLRequest] {
    requests.filter {
      ($0.httpMethod ?? "GET") == "GET" && $0.url?.pathComponents.count == 3
        && $0.url?.pathComponents[1] == "writings"
    }
  }

  private static func hex(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
