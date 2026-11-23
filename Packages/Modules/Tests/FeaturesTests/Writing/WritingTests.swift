import Foundation
import Testing

@testable import Features

struct WritingTests {
  @Test func sampleTakesTheTitle() {
    #expect(
      Writing.sample(titled: "朝")
        == Writing(title: "朝", body: Writing.sampleBody + "\n" + Writing.sampleMention))
  }

  /// The stand-in writings' body names one of them, so the app has a title link to show.
  @Test func sampleNamesAnotherSampleWriting() {
    let rows = WritingRow.samples(now: Date(timeIntervalSince1970: 0), calendar: .current)
    let named = Writing.sample(titled: "朝").body.titleMentions(of: rows).map(\.writing.title)
    #expect(named == ["夜の机に向かう"])
  }
}
