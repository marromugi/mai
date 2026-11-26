import Testing
import Typesetting

@testable import Features

struct StoredBodySettingTests {
  /// The default setting is remembered under this key and in this form; changing either forgets it.
  @Test func isRememberedAsBaseLineHeightAndTracking() throws {
    let setting = try #require(BodySetting(base: 20, lineHeight: 36, tracking: -50))
    #expect(StoredBodySetting.key == "defaultBodySetting")
    #expect(StoredBodySetting(setting).rawValue == "20 36 -50")
    #expect(StoredBodySetting(rawValue: "20 36 -50")?.setting == setting)
  }

  /// A half-point base is written with its half; a whole one, as every version before half points
  /// wrote it, reads as the same size.
  @Test func writesAHalfPointBaseWithItsHalf() throws {
    let half = try #require(BodySetting(base: 16.5, lineHeight: 28, tracking: 0))
    #expect(StoredBodySetting(half).rawValue == "16.5 28 0")
    #expect(StoredBodySetting(rawValue: "16.5 28 0")?.setting == half)
    #expect(StoredBodySetting(rawValue: "16 28 0")?.setting.base == 16)
    #expect(StoredBodySetting(rawValue: "24 44 200")?.setting.base == 24)
  }

  @Test(arguments: [
    BodySetting.standard,
    BodySetting(base: 12, lineHeight: 16, tracking: -50),
    BodySetting(base: 24, lineHeight: 44, tracking: 200),
    BodySetting(base: 12.5, lineHeight: 28, tracking: 0),
    BodySetting(base: 23.5, lineHeight: 28, tracking: 0),
  ])
  func readsBackWhatItStores(_ setting: BodySetting?) throws {
    let setting = try #require(setting)
    #expect(StoredBodySetting(rawValue: StoredBodySetting(setting).rawValue)?.setting == setting)
  }

  /// Out of range, off a step, too few or too many values, or not numbers: nothing stored.
  @Test(arguments: [
    "", " ", "16 28", "16 28 0 0", "16  28 0", " 16 28 0", "16 28 0 ", "a b c", "16 28 x",
    "11 28 0", "25 28 0", "16 12 0", "16 48 0", "16 30 0", "16 28 -60", "16 28 210", "16 28 5",
    "16,28,0", "16.0 28 0", "16.50 28 0", "16.25 28 0", "11.5 28 0", "24.5 28 0", "nan 28 0",
    "inf 28 0",
  ])
  func readsAnInvalidValueAsNothingStored(_ rawValue: String) {
    #expect(StoredBodySetting(rawValue: rawValue) == nil)
  }
}
