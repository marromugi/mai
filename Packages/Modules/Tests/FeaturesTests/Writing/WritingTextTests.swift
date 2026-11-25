import Foundation
import Testing

@testable import Features

struct WritingTextTests {
  /// The first line is the title and the lines after the first line break the body; the text
  /// put together again is the same.
  @Test(arguments: [
    ("朝\n本文\n二行目", "朝", "本文\n二行目"),
    ("朝", "朝", ""),
    ("朝\n", "朝", ""),
    ("\n本文", "", "本文"),
    ("", "", ""),
    ("\n\n本文", "", "\n本文"),
  ])
  func theFirstLineIsTheTitle(_ text: String, _ title: String, _ body: String) {
    let split = WritingText(text: text, links: [])
    #expect(split.title == title)
    #expect(split.body == body)
    #expect(WritingText(text: split.text, links: []) == split)
  }

  /// A writing with no body is its title alone; one with a body puts it after a line break.
  @Test func theTextIsTheTitleThenTheBody() {
    #expect(WritingText(title: "朝", body: "", links: []).text == "朝")
    #expect(WritingText(title: "朝", body: "本文", links: []).text == "朝\n本文")
    #expect(WritingText(title: "", body: "本文", links: []).text == "\n本文")
  }

  /// Links move between the body's offsets and the text's by the title and its line break, in
  /// UTF-16 units.
  @Test func linksAreKeptInTheBodysOffsets() {
    let link = BodyLink(range: 0..<2, url: bread)
    let writing = WritingText(title: "🍞朝", body: "本文と", links: [link])
    #expect(writing.bodyStart == 4)
    #expect(writing.textLinks == [BodyLink(range: 4..<6, url: bread)])
    #expect(WritingText(text: writing.text, links: writing.textLinks) == writing)
  }

  /// The title holds no links: a link in it is dropped, and one across the line break keeps only
  /// its part in the body.
  @Test func theTitleHoldsNoLinks() {
    let text = "朝の机\n本文"
    #expect(WritingText(text: text, links: [BodyLink(range: 0..<2, url: bread)]).links.isEmpty)
    #expect(
      WritingText(text: text, links: [BodyLink(range: 1..<6, url: bread)]).links == [
        BodyLink(range: 0..<2, url: bread)
      ])
    #expect(WritingText(text: "朝の机", links: [BodyLink(range: 0..<2, url: bread)]).links.isEmpty)
  }
}

nonisolated private let bread = URL(string: "https://example.com/bread") ?? URL(filePath: "/")
