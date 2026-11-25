import Foundation

/// A stretch of a writing's body that links to `url`, a page outside the app. `range` counts the
/// body's UTF-16 code units, as the text views that edit it do.
nonisolated struct BodyLink: Equatable, Codable, Sendable {
  let range: Range<Int>
  let url: URL
}

extension [BodyLink] {
  /// These links made to fit `body`: each widened to the whole characters it touches and started
  /// after the one before it. One that is empty, starts before the body or runs past its end, or
  /// has nothing left is dropped.
  nonisolated func fitted(to body: String) -> [BodyLink] {
    guard !isEmpty else { return [] }
    let length = body.utf16.count
    var fitted: [BodyLink] = []
    for link in self
    where !link.range.isEmpty && link.range.lowerBound >= 0 && link.range.upperBound <= length {
      let start = body.characterBounds(around: link.range.lowerBound).lower
      let end = body.characterBounds(around: link.range.upperBound).upper
      let lower = Swift.max(start, fitted.last?.range.upperBound ?? 0)
      guard lower < end else { continue }
      fitted.append(BodyLink(range: lower..<end, url: link.url))
    }
    return fitted
  }
}

nonisolated extension String {
  /// The edges of whole characters nearest `offset`, in UTF-16 offsets: the last at or before it
  /// and the first at or after it. Found from the start of its line, since a character never spans
  /// the start of a line, and not from the start of a long body.
  func characterBounds(around offset: Int) -> (lower: Int, upper: Int) {
    let text = self as NSString
    let lineBreak = text.range(
      of: "\n", options: .backwards, range: NSRange(location: 0, length: offset))
    var edge = lineBreak.location == NSNotFound ? 0 : NSMaxRange(lineBreak)
    var index = String.Index(utf16Offset: edge, in: self)
    while edge < offset, index < endIndex {
      let next = self.index(after: index)
      let nextEdge = next.utf16Offset(in: self)
      if nextEdge > offset { return (edge, nextEdge) }
      edge = nextEdge
      index = next
    }
    return (edge, edge)
  }
}

extension URL {
  /// The web address `pasted` is, when it is one and nothing else: an http or https URL with a
  /// host, with any space around it ignored.
  init?(pastedLink pasted: String) {
    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    // `URL(string:)` takes a space in a path or query as `%20`.
    guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host() != nil
    else { return nil }
    self = url
  }
}
