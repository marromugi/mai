import Foundation
import SwiftUI
import Testing

@testable import Features

struct BodyLinkTests {
  @Test(arguments: [
    ("https://example.com/bread", "https://example.com/bread"),
    ("  http://example.com\n", "http://example.com"),
    ("HTTPS://Example.com/パン", "HTTPS://Example.com/%E3%83%91%E3%83%B3"),
  ])
  func aPastedWebAddressIsALink(_ pasted: String, _ expected: String) {
    #expect(URL(pastedLink: pasted)?.absoluteString == expected)
  }

  @Test(arguments: [
    "example.com", "パンの店", "see https://example.com", "https://example.com and more",
    "https://example.com/bread and butter", "https://example.com/パン 夕方",
    "https://example.com/bread\n二行目",
    "mailto:baker@example.com", "ftp://example.com", "https://", "",
  ])
  func otherPastedTextIsNoLink(_ pasted: String) {
    #expect(URL(pastedLink: pasted) == nil)
  }

  /// A link is widened to the whole characters it touches as Swift counts them, a character that
  /// joins scalars across what other counts split included.
  @Test(arguments: [
    ("กำ", 0..<1, 0..<2), ("ab\n\u{301}", 3..<4, 3..<4), ("a\u{200D}b", 2..<3, 2..<3),
    ("\u{600}\u{661}", 1..<2, 0..<2), ("a\r\nb", 2..<3, 1..<3), ("🇯🇵🇯🇵", 1..<2, 0..<4),
  ])
  func aLinkIsWidenedToWholeCharacters(
    _ body: String, _ range: Range<Int>, _ expected: Range<Int>
  ) {
    #expect([BodyLink(range: range, url: bread)].fitted(to: body).map(\.range) == [expected])
  }

  /// Fitted from the start of each link's line, links land where fitting them against every
  /// character of the body lands them.
  @Test func linksAreFittedAsAgainstTheWholeBody() {
    var random = SeededRandom(seed: 117)
    let pieces = [
      "a", "朝", "\n", "\r", "\r\n", "\u{301}", "か\u{3099}", "กำ", "\u{600}", "\u{200D}", "🍞",
      "🇯🇵", "👩\u{200D}💻",
    ]
    for _ in 0..<2_000 {
      let body = (0..<Int.random(in: 0...12, using: &random)).map { _ in
        pieces.randomElement(using: &random) ?? "a"
      }.joined()
      let length = body.utf16.count
      let links = (0..<Int.random(in: 1...3, using: &random)).map { _ in
        let lower = Int.random(in: -1...length, using: &random)
        let upper = Int.random(in: lower...length + 1, using: &random)
        return BodyLink(range: lower..<upper, url: bread)
      }
      #expect(
        links.fitted(to: body) == fittedAgainstEveryCharacter(links, body),
        "\(body.debugDescription) \(links.map(\.range))")
    }
  }

  /// A link is set in the text's colour under a solid line; a title mention inside it is not
  /// linked, and one outside it keeps its dotted line.
  /// A title mention only partly covered by a link is not linked to its writing.
  @Test func aMentionPartlyInALinkIsNotLinked() {
    let body = "朝の夜の机に向かう"
    let text = AttributedString(
      body: body, links: [BodyLink(range: 0..<4, url: bread)],
      mentions: body.titleMentions(of: [nightDesk]))
    #expect(text.runs.map(\.link) == [bread, nil])
  }

  @Test func theBodyDrawsLinksSolidAndMentionsDotted() {
    let body = "夜の机に向かうと夜の机に向かう"
    let link = BodyLink(range: 0..<7, url: bread)
    let text = AttributedString(
      body: body, links: [link], mentions: body.titleMentions(of: [nightDesk]))
    let runs = text.runs.map { run in
      Run(
        text: String(text[run.range].characters), link: run.link, color: run.foregroundColor,
        underline: run.underlineStyle)
    }
    #expect(
      runs == [
        Run(text: "夜の机に向かう", link: bread, color: .primary, underline: .single),
        Run(text: "と", link: nil, color: nil, underline: nil),
        Run(
          text: "夜の机に向かう", link: nightDesk.link, color: .primary,
          underline: Text.LineStyle(pattern: .dot)),
      ])
  }
}

private struct Run: Equatable {
  let text: String
  let link: URL?
  let color: Color?
  let underline: Text.LineStyle?
}

private let bread = URL(string: "https://example.com/bread") ?? URL(filePath: "/")
private let nightDesk = Writing(
  id: UUID(sample: 4), title: "夜の机に向かう", body: "", updated: Date(timeIntervalSince1970: 0))

/// `links` fitted to `body` by every character edge in it, as fitting worked before it looked only
/// at each link's line.
private func fittedAgainstEveryCharacter(_ links: [BodyLink], _ body: String) -> [BodyLink] {
  var boundaries = body.indices.map { $0.utf16Offset(in: body) }
  boundaries.append(body.utf16.count)
  var fitted: [BodyLink] = []
  for link in links where !link.range.isEmpty && link.range.lowerBound >= 0 {
    guard let end = boundaries.first(where: { $0 >= link.range.upperBound }) else { continue }
    let start = boundaries.last { $0 <= link.range.lowerBound } ?? 0
    let lower = max(start, fitted.last?.range.upperBound ?? 0)
    guard lower < end else { continue }
    fitted.append(BodyLink(range: lower..<end, url: link.url))
  }
  return fitted
}

/// A seeded generator, so a failing run can be repeated.
private struct SeededRandom: RandomNumberGenerator {
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
