import Agent
import CryptoKit
import Foundation
import Sync
import Testing

struct HandoffTests {
  @Test func splitsTheLineAtItsLastMark() throws {
    let token = "agent.3f2504e0-4f89-11d3-9a0c-0305e82c3301.c2VjcmV0"
    let handoff = try Handoff(line: "  https://mai.example.workers.dev#\(token)\n")
    #expect(handoff.server.absoluteString == "https://mai.example.workers.dev")
    #expect(handoff.token == token)
    #expect(try Handoff(line: "http://127.0.0.1:8787#\(token)").token == token)
    #expect(try Handoff(line: "http://localhost:8787#\(token)").token == token)
  }

  @Test(arguments: [
    ("https://mai.example.workers.dev", HandoffError.notALine),
    ("http://mai.example.workers.dev#agent.3f2504e0-4f89-11d3-9a0c-0305e82c3301.c2Vj", .notAServer),
    ("mai.example.workers.dev#agent.3f2504e0-4f89-11d3-9a0c-0305e82c3301.c2Vj", .notAServer),
    ("https://mai.example.workers.dev#s1.session.token", .notAToken),
    ("https://mai.example.workers.dev#agent.not-an-id.c2Vj", .notAToken),
    ("https://mai.example.workers.dev#agent.3f2504e0-4f89-11d3-9a0c-0305e82c3301.", .notAToken),
  ])
  func refusesALineOfAnotherShape(_ line: String, _ problem: HandoffError) {
    #expect(throws: problem) { try Handoff(line: line) }
  }
}

struct PairingFileTests {
  @Test func keepsTheKeyAndTheTokenSealedToIt() async throws {
    let account = Account()
    let key = P256.KeyAgreement.PrivateKey()
    let (_, line) = try await account.approve(key)
    let handoff = try Handoff(line: line)
    try account.file.write(Pairing(key: key, handoff: handoff))

    let read: Pairing<P256.KeyAgreement.PrivateKey> = try #require(try account.file.read())
    #expect(read.key.rawRepresentation == key.rawRepresentation)
    #expect(read.handoff == handoff)
    let kept = try Data(contentsOf: account.file.url)
    #expect(kept.range(of: Data(handoff.token.utf8)) == nil)
    #expect(kept.range(of: Data(handoff.token.split(separator: ".")[2].utf8)) == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: account.file.url.path)[
      .posixPermissions]
    #expect(permissions as? Int == 0o600)
  }

  @Test func aTokenSealedToAnotherKeyDoesntRead() async throws {
    let account = Account()
    let (_, line) = try await account.approve(P256.KeyAgreement.PrivateKey())
    try account.file.write(
      Pairing(key: P256.KeyAgreement.PrivateKey(), handoff: Handoff(line: line)))
    var kept = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: account.file.url)) as? [String: Any])
    kept["key"] = P256.KeyAgreement.PrivateKey().rawRepresentation.base64EncodedString()
    try JSONSerialization.data(withJSONObject: kept).write(to: account.file.url)

    #expect(throws: PairingFileError.self) {
      let _: Pairing<P256.KeyAgreement.PrivateKey>? = try account.file.read()
    }
  }

  @Test func nothingIsKeptBeforePairingOrAfterForgetting() async throws {
    let account = Account()
    let none: Pairing<P256.KeyAgreement.PrivateKey>? = try account.file.read()
    #expect(none == nil)
    #expect(try account.file.remove() == false)
    let key = P256.KeyAgreement.PrivateKey()
    let (_, line) = try await account.approve(key)
    try account.file.write(Pairing(key: key, handoff: Handoff(line: line)))
    #expect(try account.file.remove())
    let forgotten: Pairing<P256.KeyAgreement.PrivateKey>? = try account.file.read()
    #expect(forgotten == nil)
  }
}

struct PairTests {
  @Test func keepsThePairingOnceTheTokenReads() async throws {
    let account = Account()
    let key = P256.KeyAgreement.PrivateKey()
    let (_, line) = try await account.approve(key)

    let pairing = try await account.file.pair(key, line: line, transport: account.fake)

    #expect(pairing.handoff == (try Handoff(line: line)))
    let read: Pairing<P256.KeyAgreement.PrivateKey> = try #require(try account.file.read())
    #expect(read.handoff == pairing.handoff)
  }

  @Test func aRevokedTokenKeepsThePairingBefore() async throws {
    let account = Account()
    let first = P256.KeyAgreement.PrivateKey()
    let (_, firstLine) = try await account.approve(first)
    _ = try await account.file.pair(first, line: firstLine, transport: account.fake)
    let second = P256.KeyAgreement.PrivateKey()
    let (secondID, secondLine) = try await account.approve(second)
    #expect(try await account.readMode.revoke(secondID))

    await #expect {
      _ = try await account.file.pair(second, line: secondLine, transport: account.fake)
    } throws: {
      guard case .server(.refused(status: 401, _)) = $0 as? PairingProblem else { return false }
      return true
    }
    let kept: Pairing<P256.KeyAgreement.PrivateKey> = try #require(try account.file.read())
    #expect(kept.handoff == (try Handoff(line: firstLine)))
  }

  @Test func aLineOfAnotherShapeKeepsNothing() async throws {
    let account = Account()
    await #expect {
      _ = try await account.file.pair(
        P256.KeyAgreement.PrivateKey(), line: "s1.session.token", transport: account.fake)
    } throws: {
      guard case .handoff(.notALine) = $0 as? PairingProblem else { return false }
      return true
    }
    let none: Pairing<P256.KeyAgreement.PrivateKey>? = try account.file.read()
    #expect(none == nil)
  }
}
