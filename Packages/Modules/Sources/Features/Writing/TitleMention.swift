import Foundation

/// A place in a body where another writing's title appears, and the writing it names.
struct TitleMention: Equatable {
  let range: Range<String.Index>
  let writing: WritingRow
}

extension String {
  /// Every place one of `writings`' titles appears, left to right and never overlapping. Where
  /// titles start at the same place, the longest is taken; where writings share a title, the first
  /// in `writings`. An untitled writing appears nowhere.
  func titleMentions(of writings: [WritingRow]) -> [TitleMention] {
    var mentions: [TitleMention] = []
    var index = startIndex
    while index < endIndex {
      let rest = self[index...]
      var found: WritingRow?
      for writing in writings
      where !writing.title.isEmpty && writing.title.count > (found?.title.count ?? 0)
        && rest.hasPrefix(writing.title)
      {
        found = writing
      }
      guard let found else {
        formIndex(after: &index)
        continue
      }
      let end = self.index(index, offsetBy: found.title.count)
      mentions.append(TitleMention(range: index..<end, writing: found))
      index = end
    }
    return mentions
  }
}

extension WritingRow {
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
  func writing(linkedBy url: URL) -> WritingRow? {
    first { $0.writing.link == url }?.writing
  }
}
