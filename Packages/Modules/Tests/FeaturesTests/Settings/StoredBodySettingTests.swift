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

  @Test(arguments: [
    BodySetting.standard,
    BodySetting(base: 12, lineHeight: 16, tracking: -50),
    BodySetting(base: 24, lineHeight: 44, tracking: 200),
  ])
  func readsBackWhatItStores(_ setting: BodySetting?) throws {
    let setting = try #require(setting)
    #expect(StoredBodySetting(rawValue: StoredBodySetting(setting).rawValue)?.setting == setting)
  }

  /// Out of range, off a step, too few or too many values, or not numbers: nothing stored.
  @Test(arguments: [
    "", " ", "16 28", "16 28 0 0", "16  28 0", " 16 28 0", "16 28 0 ", "a b c", "16 28 x",
    "11 28 0", "25 28 0", "16 12 0", "16 48 0", "16 30 0", "16 28 -60", "16 28 210", "16 28 5",
    "16,28,0", "16.0 28 0",
  ])
  func readsAnInvalidValueAsNothingStored(_ rawValue: String) {
    #expect(StoredBodySetting(rawValue: rawValue) == nil)
  }
}
