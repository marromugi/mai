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
