import Testing
import Typesetting

@testable import Features

struct WritingBodySettingsTests {
  @Test func aWritingNeverSetReadsAsTheDefaultItIsReadWith() throws {
    let defaultSetting = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    let settings = WritingBodySettings()
    #expect(settings[1, default: .standard] == .standard)
    #expect(settings[1, default: defaultSetting] == defaultSetting)
  }

  @Test func eachWritingKeepsItsOwnSettingWhateverTheDefault() throws {
    let first = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    let second = try #require(BodySetting(base: 12, lineHeight: 16, tracking: -50))
    let defaultSetting = try #require(BodySetting(base: 24, lineHeight: 44, tracking: 200))
    var settings = WritingBodySettings()
    settings[1, default: .standard] = first
    settings[2, default: .standard] = second
    #expect(settings[1, default: defaultSetting] == first)
    #expect(settings[2, default: defaultSetting] == second)
    #expect(settings[3, default: defaultSetting] == defaultSetting)
  }
}
