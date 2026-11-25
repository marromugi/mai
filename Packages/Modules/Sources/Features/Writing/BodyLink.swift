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
    let text = body as NSString
    var fitted: [BodyLink] = []
    for link in self
    where !link.range.isEmpty && link.range.lowerBound >= 0 && link.range.upperBound <= text.length
    {
      let start = text.rangeOfComposedCharacterSequence(at: link.range.lowerBound).location
      let end = NSMaxRange(text.rangeOfComposedCharacterSequence(at: link.range.upperBound - 1))
      let lower = Swift.max(start, fitted.last?.range.upperBound ?? 0)
      guard lower < end else { continue }
      fitted.append(BodyLink(range: lower..<end, url: link.url))
    }
    return fitted
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
