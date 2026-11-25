import CoreGraphics

/// The height of each paragraph of a text whose paragraphs end at `"\n"`, kept through edits so
/// the text's height is known without setting it all again. A text ending in a line break has an
/// empty last paragraph, starting at the text's end. An edit forgets the heights of the paragraphs
/// it touched, until they are measured again.
public struct ParagraphHeights: Equatable, Sendable {
  /// Where each paragraph starts, in the text's offsets; the first at 0.
  public private(set) var starts: [Int]
  /// Each paragraph's height, nil until it is measured.
  public private(set) var heights: [CGFloat?]
  /// The text's length.
  public private(set) var length: Int

  /// The paragraphs starting at `starts`, each `heights` tall, of a text `length` long.
  public init(starts: [Int], heights: [CGFloat], length: Int) {
    precondition(
      starts.first == 0 && starts.count == heights.count, "Each paragraph needs a height.")
    self.starts = starts
    self.heights = heights
    self.length = length
  }

  /// The text's height: every paragraph's, once each is measured.
  public var total: CGFloat? {
    var sum: CGFloat = 0
    for height in heights {
      guard let height else { return nil }
      sum += height
    }
    return sum
  }

  /// Each run of paragraphs not yet measured, as the stretch of the text they cover. The empty
  /// last paragraph starts at its run's end.
  public var unmeasured: [Range<Int>] {
    var runs: [Range<Int>] = []
    var index = 0
    while index < heights.count {
      guard heights[index] == nil else {
        index += 1
        continue
      }
      let first = index
      while index < heights.count, heights[index] == nil { index += 1 }
      runs.append(starts[first]..<end(ofParagraph: index - 1))
    }
    return runs
  }

  /// Gives the paragraph starting at `start` its `height`. One that starts nowhere is ignored.
  public mutating func measured(_ height: CGFloat, startingAt start: Int) {
    guard let index = index(startingAt: start) else { return }
    heights[index] = height
  }

  /// `old` replaced by `count` characters. The paragraphs it touches, and the one after it when
  /// it ends where that one starts, are replaced by those of the new text in their place, unmeasured:
  /// `lineBreaks(in:)` answers where the new text's line breaks are in a stretch of it.
  public mutating func replace(
    _ old: Range<Int>, with count: Int, lineBreaks: (Range<Int>) -> [Int]
  ) {
    let delta = count - old.count
    let first = paragraph(containing: old.lowerBound)
    let last = paragraph(containing: old.upperBound)
    let spanStart = starts[first]
    let spanEnd = end(ofParagraph: last) + delta
    length += delta
    // A line break at the end starts the empty last paragraph, unless one is kept after the span.
    let endsTheText = last == starts.count - 1
    var replaced = [spanStart]
    for lineBreak in lineBreaks(spanStart..<spanEnd)
    where lineBreak + 1 < spanEnd || (endsTheText && lineBreak + 1 == length) {
      replaced.append(lineBreak + 1)
    }
    starts.replaceSubrange(first...last, with: replaced)
    heights.replaceSubrange(first...last, with: Array(repeating: nil, count: replaced.count))
    for index in (first + replaced.count)..<starts.count {
      starts[index] += delta
    }
  }

  /// The last paragraph starting at or before `offset`.
  private func paragraph(containing offset: Int) -> Int {
    var low = 0
    var high = starts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if starts[middle] <= offset { low = middle } else { high = middle - 1 }
    }
    return low
  }

  private func index(startingAt start: Int) -> Int? {
    let index = paragraph(containing: start)
    return starts[index] == start ? index : nil
  }

  private func end(ofParagraph index: Int) -> Int {
    index + 1 < starts.count ? starts[index + 1] : length
  }
}
