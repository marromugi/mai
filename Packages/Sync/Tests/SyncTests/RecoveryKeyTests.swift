import Foundation
import Sync
import Testing

struct RecoveryKeyTests {
  /// The own key 00 01 02 … 1f.
  private let counting: RecoveryKey

  init() throws {
    counting = RecoveryKey(try OwnKey(rawRepresentation: Data(0..<32)))
  }

  @Test func isFourteenGroupsOfFourInCrockfordsBase32() {
    #expect(
      counting.text == "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFP-63ED")
  }

  @Test(arguments: 0..<50)
  func restoresTheOwnKeyItWasWrittenFrom(_ round: Int) throws {
    let ownKey = OwnKey.generate()
    #expect(try RecoveryKey(text: RecoveryKey(ownKey).text).ownKey == ownKey)
  }

  @Test(arguments: [
    "000g-40r4-0m30-e209-185g-r38e-1w81-24gk-2gah-c5rr-34d1-p70x-3rfp-63ed",
    "000G 40R4 0M30 E209 185G R38E 1W81 24GK 2GAH C5RR 34D1 P70X 3RFP 63ED",
    "000G40R40M30E209185GR38E1W8124GK2GAHC5RR34D1P70X3RFP63ED",
    "OOOG-4OR4-OM3O-E2O9-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P7OX-3RFP-63ED",
    "000G-40R4-0M30-E209-I85G-R38E-lW81-24GK-2GAH-C5RR-34DI-P70X-3RFP-63ED",
    "000G-40R4-0M30-E209\n185G-R38E-1W81-24GK\n2GAH-C5RR-34D1-P70X\n3RFP-63ED",
  ])
  func isReadAsAPersonMightTypeIt(_ typed: String) throws {
    #expect(try RecoveryKey(text: typed) == counting)
  }

  @Test(arguments: 0..<56)
  func aMistypedCharacterIsCaught(at position: Int) throws {
    var digits = Array(counting.text.filter { $0 != "-" })
    digits[position] = digits[position] == "Z" ? "Y" : "Z"
    #expect(throws: RecoveryKeyError.mistyped) { try RecoveryKey(text: String(digits)) }
  }

  @Test(arguments: [
    ("0004-0G20", RecoveryKeyError.wrongLength(8)),
    (String(repeating: "0", count: 57), .wrongLength(57)),
    ("", .wrongLength(0)),
    (
      "000G-40R4-0M30-E209-185G-R38E-1W81-24GK-2GAH-C5RR-34D1-P70X-3RFP-63EU",
      .unknownCharacter("U")
    ),
    ("0004_0G20", .unknownCharacter("_")),
  ])
  func textThatIsNotARecoveryKeyIsRefused(_ typed: String, _ error: RecoveryKeyError) {
    #expect(throws: error) { try RecoveryKey(text: typed) }
  }
}
