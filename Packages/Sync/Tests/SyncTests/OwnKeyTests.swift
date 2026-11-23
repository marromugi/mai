import Foundation
import Sync
import Testing

struct OwnKeyTests {
  @Test func twoKeysMadeAreNotTheSame() {
    #expect(OwnKey.generate() != OwnKey.generate())
  }

  @Test func keepsItsBytes() throws {
    let ownKey = OwnKey.generate()
    #expect(try OwnKey(rawRepresentation: ownKey.rawRepresentation) == ownKey)
  }

  @Test(arguments: [0, 16, 31, 33])
  func isMadeOnlyFrom32Bytes(_ count: Int) {
    #expect(throws: OwnKeyLengthError.self) { try OwnKey(rawRepresentation: Data(count: count)) }
  }

  @Test func theAccessTokenIsDerivedFromTheKeyAndIsNotTheKey() throws {
    let ownKey = try OwnKey(rawRepresentation: Data(0..<32))
    #expect(ownKey.accessToken == "H2y3_e_IvcRnpXnK7EYlvzcWanK1Pu6Rr8N0ZpwgH-E")
    #expect(ownKey.accessToken == (try OwnKey(rawRepresentation: Data(0..<32))).accessToken)
    #expect(OwnKey.generate().accessToken != ownKey.accessToken)
  }

  /// The value `Server/README.md` makes with `shasum -a 256` from the token.
  @Test func theServerKeepsTheTokensSHA256() throws {
    let ownKey = try OwnKey(rawRepresentation: Data(0..<32))
    #expect(
      ownKey.accessTokenSHA256
        == "69038d7abd7ec3ded89bee1fbc5af3f5a1f7ceb386135e373b867b4e18c1c5a2")
  }
}
