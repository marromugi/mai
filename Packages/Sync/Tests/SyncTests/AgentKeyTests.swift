import CryptoKit
import Foundation
import Sync
import SyncFakes
import Testing

struct AgentKeyTests {
  private let agent = P256.KeyAgreement.PrivateKey()

  @Test func thePairingCodeIsFourteenGroupsOfFourAndReadsBack() throws {
    let key = AgentKey(agent.publicKey)
    let code = key.pairingCode
    #expect(code.split(separator: "-").map(\.count) == Array(repeating: 4, count: 14))
    #expect(try AgentKey(pairingCode: code) == key)
    #expect(try AgentKey(pairingCode: code.lowercased().replacing("-", with: " ")) == key)
    #expect(key.rawRepresentation == agent.publicKey.compressedRepresentation)
  }

  @Test(arguments: 0..<56)
  func aMistypedCharacterIsCaught(at position: Int) throws {
    var digits = Array(AgentKey(agent.publicKey).pairingCode.replacing("-", with: ""))
    digits[position] = digits[position] == "Z" ? "Y" : "Z"
    #expect(throws: AgentKeyError.mistyped) { try AgentKey(pairingCode: String(digits)) }
  }

  @Test func aRecoveryKeyIsNotAnAgentsCode() {
    let text = RecoveryKey(OwnKey.generate()).text
    #expect(throws: AgentKeyError.self) { try AgentKey(pairingCode: text) }
  }

  @Test func textThatIsNotACodeIsRefused() {
    #expect(throws: AgentKeyError.wrongLength(8)) { try AgentKey(pairingCode: "0000-0000") }
    #expect(throws: AgentKeyError.unknownCharacter("U")) { try AgentKey(pairingCode: "U") }
    #expect(throws: AgentKeyError.notAPublicKey) {
      try AgentKey(rawRepresentation: Data(repeating: 7, count: 33))
    }
  }

  @Test func onlyTheOwnKeyThatSignedApprovesTheKeyItSigned() {
    let ownKey = OwnKey.generate()
    let key = AgentKey(agent.publicKey)
    let other = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    let signature = ownKey.signature(approving: key)
    #expect(signature.count == 32)
    #expect(ownKey.approved(key, signature: signature))
    #expect(!ownKey.approved(other, signature: signature))
    #expect(!OwnKey.generate().approved(key, signature: signature))
    #expect(!ownKey.approved(key, signature: Data(signature.dropLast())))
  }

  @Test func theAgentOpensItsCopyWithItsPrivateKey() async throws {
    let copy = try await Copy.made(for: agent.publicKey)
    #expect(copy.wrapped.count == 65 + 48)
    let opened = try AgentCopy(id: copy.writing.id, bytes: copy.bytes, wrapped: copy.wrapped)
      .open(with: agent)
    #expect(opened == copy.writing)
  }

  @Test func anotherAgentCantOpenTheCopy() async throws {
    let copy = try await Copy.made(for: agent.publicKey)
    let other = P256.KeyAgreement.PrivateKey()
    #expect(throws: OpeningError.self) {
      try AgentCopy(id: copy.writing.id, bytes: copy.bytes, wrapped: copy.wrapped).open(with: other)
    }
  }

  /// The key is wrapped for one save of one writing: the server can't hand it out with another.
  @Test func aKeyHandedOutWithAnotherSaveDoesntOpen() async throws {
    let first = try await Copy.made(for: agent.publicKey)
    let second = try await Copy.made(for: agent.publicKey, id: first.writing.id)
    #expect(throws: OpeningError.self) {
      try AgentCopy(id: first.writing.id, bytes: second.bytes, wrapped: first.wrapped)
        .open(with: agent)
    }
    let other = try await Copy.made(for: agent.publicKey)
    #expect(throws: OpeningError.self) {
      try AgentCopy(id: other.writing.id, bytes: other.bytes, wrapped: first.wrapped)
        .open(with: agent)
    }
  }

  @Test func aWritingGivenForAnotherIDIsRefused() async throws {
    let copy = try await Copy.made(for: agent.publicKey)
    #expect(throws: EnvelopeError.notASealedWriting) {
      try AgentCopy(id: UUID(), bytes: copy.bytes, wrapped: copy.wrapped)
    }
  }

  /// A writing synced and copied for an agent through the fake, as the agent reads it.
  private struct Copy {
    let writing: PlainWriting
    let bytes: Data
    let wrapped: Data

    static func made(for publicKey: P256.KeyAgreement.PublicKey, id: UUID = UUID()) async throws
      -> Copy
    {
      let ownKey = OwnKey.generate()
      let (setUp, clock) = ReadModeSetUp.onFake(ownKey: ownKey)
      let key = AgentKey(publicKey)
      let approved = try #require(try await setUp.readMode.approve(key))
      let writing = PlainWriting(
        id: id, updated: Date(timeIntervalSince1970: 1_790_000_000), contents: Data("原稿".utf8))
      try setUp.writings.save(writing)
      _ = try await setUp.synchronizer.sync()
      let sent = try await setUp.readMode.turnOn(until: clock.now + 3600)
      #expect(sent.kept == 1)
      let read = try #require(try await setUp.agentRead(id, token: approved.token))
      return Copy(writing: writing, bytes: read.bytes, wrapped: read.wrapped)
    }
  }
}
