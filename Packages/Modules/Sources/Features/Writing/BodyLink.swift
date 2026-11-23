import Foundation

/// A stretch of a writing's body that links to `url`, a page outside the app. `range` counts the
/// body's UTF-16 code units, as the text views that edit it do.
nonisolated struct BodyLink: Equatable, Codable, Sendable {
  let range: Range<Int>
  let url: URL
}

extension [BodyLink] {
  /// Whether each link covers whole characters of `body` and at least one, and the links come in
  /// order without overlapping.
  nonisolated func fit(_ body: String) -> Bool {
    var end = 0
    for link in self {
      guard link.range.lowerBound >= end, !link.range.isEmpty,
        let found = Range(NSRange(link.range), in: body),
        found.lowerBound.samePosition(in: body) != nil,
        found.upperBound.samePosition(in: body) != nil
      else { return false }
      end = link.range.upperBound
    }
    return true
  }
}

extension URL {
  /// The web address `pasted` is, when it is one and nothing else: an http or https URL with a
  /// host, with any space around it ignored.
  init?(pastedLink pasted: String) {
    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains(where: \.isWhitespace),
      let url = URL(string: trimmed),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host() != nil
    else { return nil }
    self = url
  }
}
