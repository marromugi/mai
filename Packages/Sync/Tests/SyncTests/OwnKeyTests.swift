import Foundation
@testable import Sync
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

  /// The vector is HKDF-SHA256 (no salt, info "mai own key check", 32 bytes) of bytes 0 to 31,
  /// then SHA-256, worked out apart from CryptoKit with Python's hmac and hashlib.
  @Test func theCheckIsTheSHA256OfAValueDerivedFromTheKey() throws {
    let ownKey = try OwnKey(rawRepresentation: Data(0..<32))
    #expect(
      ownKey.check
        == Data(hex: "50a6d6ef720013959e1bdd9790e4c196bd210169fcd321ce794f3fa21ca02260"))
    #expect(ownKey.check.count == 32)
    #expect(OwnKey.generate().check != ownKey.check)
  }
}
