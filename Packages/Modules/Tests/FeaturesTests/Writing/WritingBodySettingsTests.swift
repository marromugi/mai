import Foundation
import Testing
import Typesetting

@testable import Features

struct WritingBodySettingsTests {
  @Test func aWritingNeverSetReadsAsStandard() {
    #expect(WritingBodySettings()[UUID(sample: 1)] == .standard)
  }

  @Test func eachWritingKeepsItsOwnSetting() throws {
    let first = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    let second = try #require(BodySetting(base: 12, lineHeight: 16, tracking: -50))
    var settings = WritingBodySettings()
    settings[UUID(sample: 1)] = first
    settings[UUID(sample: 2)] = second
    #expect(settings[UUID(sample: 1)] == first)
    #expect(settings[UUID(sample: 2)] == second)
    #expect(settings[UUID(sample: 3)] == .standard)
  }
}
