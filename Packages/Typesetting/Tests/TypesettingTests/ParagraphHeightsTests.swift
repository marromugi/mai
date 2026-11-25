import CoreGraphics
import Testing
import Typesetting

struct ParagraphHeightsTests {
  @Test func aTextEndingInALineBreakHasAnEmptyLastParagraph() {
    let heights = ParagraphHeights(lineBreaks: lineBreaks(in: "ab\ncd\n"), length: 6)
    #expect(heights.starts == [0, 3, 6])
    #expect(heights.total == nil)
    #expect(heights.unmeasured == [0..<6])
  }

  @Test func theTotalIsEveryParagraphsOnceEachIsMeasured() {
    var heights = ParagraphHeights(lineBreaks: lineBreaks(in: "ab\ncd"), length: 5)
    heights.measured(20, startingAt: 0)
    #expect(heights.total == nil)
    #expect(heights.unmeasured == [3..<5])
    heights.measured(30, startingAt: 3)
    // A paragraph starting nowhere is ignored.
    heights.measured(99, startingAt: 4)
    #expect(heights.total == 50)
  }

  /// (text, edit, inserted, paragraphs then unmeasured)
  static let edits: [(String, Range<Int>, String, [Range<Int>])] = [
    // Typed at the end: only the last paragraph.
    ("ab\ncd", 5..<5, "x", [3..<6]),
    // A line break typed at the end: the last paragraph and the empty one after it.
    ("ab\ncd", 5..<5, "\n", [3..<6]),
    // Typed into the empty last paragraph.
    ("ab\ncd\n", 6..<6, "e", [6..<7]),
    // A line break taken out: the two paragraphs it joins.
    ("ab\ncd\nef", 2..<3, "", [0..<5]),
    // Typed at a paragraph's start: that paragraph, not the one before.
    ("ab\ncd\nef", 3..<3, "z", [3..<7]),
    // Pasted across paragraphs.
    ("ab\ncd\nef", 1..<4, "1\n2\n3", [0..<8]),
  ]

  @Test(arguments: edits)
  func anEditForgetsOnlyTheParagraphsItTouches(
    _ text: String, _ old: Range<Int>, _ inserted: String, _ unmeasured: [Range<Int>]
  ) {
    var heights = measured(text)
    let edited = replacing(old, in: text, with: inserted)
    heights.replace(old, with: inserted.utf16.count) { lineBreaks(in: edited, within: $0) }
    #expect(heights.starts == [0] + lineBreaks(in: edited).map { $0 + 1 })
    #expect(heights.length == edited.utf16.count)
    #expect(heights.unmeasured == unmeasured)
  }

  /// However the text is edited, the paragraphs are the text's own, and those no edit touched keep
  /// their heights.
  @Test func anyEditsKeepTheTextsParagraphs() {
    var random = SplitMix(seed: 116)
    var text = "朝\n本文の一行目\n二行目\n"
    var heights = measured(text)
    for _ in 0..<2_000 {
      let length = text.utf16.count
      let lower = Int.random(in: 0...length, using: &random)
      let upper = Int.random(in: lower...min(length, lower + 6), using: &random)
      let inserted = String(
        (0..<Int.random(in: 0...4, using: &random)).map { _ in
          "ab\n".randomElement(using: &random) ?? "a"
        })
      let before = Dictionary(
        zip(heights.starts, heights.heights).map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
      text = replacing(lower..<upper, in: text, with: inserted)
      heights.replace(lower..<upper, with: inserted.utf16.count) {
        lineBreaks(in: text, within: $0)
      }
      #expect(heights.starts == [0] + lineBreaks(in: text).map { $0 + 1 })
      #expect(heights.length == text.utf16.count)
      let delta = inserted.utf16.count - (upper - lower)
      for (start, height) in zip(heights.starts, heights.heights) {
        guard let height else { continue }
        // Kept from before the edit, under the start it had then.
        let then = start < lower ? start : start - delta
        #expect(before[then] == height)
      }
      for run in heights.unmeasured {
        // As the editor measures them: every paragraph starting in the run, its end included.
        for start in heights.starts where run.lowerBound <= start && start <= run.upperBound {
          heights.measured(CGFloat(start), startingAt: start)
        }
      }
      #expect(heights.total != nil)
    }
  }
}

/// `text`'s paragraphs, each as tall as its start.
private func measured(_ text: String) -> ParagraphHeights {
  let starts = [0] + lineBreaks(in: text).map { $0 + 1 }
  return ParagraphHeights(
    starts: starts, heights: starts.map { CGFloat($0) }, length: text.utf16.count)
}

/// Where `text`'s line breaks are, in UTF-16 offsets, within `range` when it is given.
private func lineBreaks(in text: String, within range: Range<Int>? = nil) -> [Int] {
  let units = Array(text.utf16)
  let range = range ?? 0..<units.count
  return range.filter { units[$0] == 10 }
}

private func replacing(_ range: Range<Int>, in text: String, with inserted: String) -> String {
  var units = Array(text.utf16)
  units.replaceSubrange(range, with: Array(inserted.utf16))
  return String(decoding: units, as: UTF16.self)
}

/// A seeded generator, so a failing run can be repeated.
private struct SplitMix: RandomNumberGenerator {
  var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
