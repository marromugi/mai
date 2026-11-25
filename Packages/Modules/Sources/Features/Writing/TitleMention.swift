import Foundation

/// A place in a body where another writing's title appears, and the writing it names.
nonisolated struct TitleMention: Equatable, Sendable {
  let range: Range<String.Index>
  let writing: Writing
}

nonisolated extension String {
  /// Every place one of `writings`' titles appears, left to right and never overlapping. Where
  /// titles start at the same place, the longest is taken; where writings share a title, the first
  /// in `writings`. An untitled writing appears nowhere.
  func titleMentions(of writings: [Writing]) -> [TitleMention] {
    // Each character's titles that start with it, the longest first, then in `writings`' order.
    var startingWith: [Character: [(length: Int, order: Int, writing: Writing)]] = [:]
    for (order, writing) in writings.enumerated() {
      guard let first = writing.title.first else { continue }
      startingWith[first, default: []].append((writing.title.count, order, writing))
    }
    for first in startingWith.keys {
      startingWith[first]?.sort { ($0.length, $1.order) > ($1.length, $0.order) }
    }
    var mentions: [TitleMention] = []
    var index = startIndex
    while index < endIndex {
      guard let titles = startingWith[self[index]],
        let found = titles.first(where: { self[index...].hasPrefix($0.writing.title) })
      else {
        formIndex(after: &index)
        continue
      }
      let end = self.index(index, offsetBy: found.length)
      mentions.append(TitleMention(range: index..<end, writing: found.writing))
      index = end
    }
    return mentions
  }
}

extension Writing {
  /// The link a mention of this writing carries in the body.
  var link: URL {
    guard let url = URL(string: "mai-writing:\(id)") else {
      preconditionFailure("mai-writing:\(id) is not a URL.")
    }
    return url
  }
}

extension [TitleMention] {
  /// The writing a mention linked by `url` names, if any of these is.
  func writing(linkedBy url: URL) -> Writing? {
    first { $0.writing.link == url }?.writing
  }
}
