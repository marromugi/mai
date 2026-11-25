import Foundation

/// A writing's title, body, and the body's links, read from the one text the editor holds: the
/// first line is the title, and the lines after the first line break are the body. The editor's
/// line breaks are all `"\n"` (`String.withLineBreaks`), so the title never holds another.
nonisolated struct WritingText: Equatable {
  var title: String
  var body: String
  /// In the body's UTF-16 offsets, as `Writing.links` keeps them.
  var links: [BodyLink]

  /// Texts compared by their bytes, as `String.isSameText(as:)` compares them.
  static func == (lhs: WritingText, rhs: WritingText) -> Bool {
    lhs.links == rhs.links && lhs.title.isSameText(as: rhs.title)
      && lhs.body.isSameText(as: rhs.body)
  }

  /// A line break that came in with `title` from elsewhere is taken as a space: the title is one
  /// line.
  init(title: String, body: String, links: [BodyLink]) {
    self.title = String(title.map { $0.isNewline ? " " : $0 })
    self.body = body
    self.links = links
  }

  /// Splits `text` at its first line break. `links`, in `text`'s UTF-16 offsets, keep only their
  /// part in the body: the title has none.
  init(text: String, links: [BodyLink]) {
    let string = text as NSString
    let lineBreak = Self.firstLineBreak(in: string)
    guard lineBreak.location != NSNotFound else {
      self.init(title: text, body: "", links: [])
      return
    }
    let start = NSMaxRange(lineBreak)
    let body = string.substring(from: start).contiguous
    let shifted = links.compactMap { link -> BodyLink? in
      let lower = max(link.range.lowerBound, start) - start
      let upper = link.range.upperBound - start
      guard lower < upper else { return nil }
      return BodyLink(range: lower..<upper, url: link.url)
    }
    self.init(
      title: string.substring(to: lineBreak.location).contiguous, body: body,
      links: shifted.fitted(to: body))
  }

  /// Where `text` splits into the title and the body.
  static func firstLineBreak(in text: NSString) -> NSRange {
    text.range(of: "\n")
  }

  /// The title, then the body on the lines after it. A writing with no body is its title alone.
  var text: String {
    body.isEmpty ? title : title + "\n" + body
  }

  /// Where the body starts in `text`, in UTF-16 offsets.
  var bodyStart: Int {
    (title as NSString).length + 1
  }

  /// The links in `text`'s UTF-16 offsets.
  var textLinks: [BodyLink] {
    links.map {
      BodyLink(
        range: $0.range.lowerBound + bodyStart..<$0.range.upperBound + bodyStart, url: $0.url)
    }
  }
}

extension String {
  /// With each line break, `"\r\n"`, `"\r"`, and the line and paragraph separators included, as
  /// `"\n"`: the one the editor splits the title from the body at.
  nonisolated var withLineBreaks: String {
    String(map { $0.isNewline ? "\n" : $0 })
  }
}
