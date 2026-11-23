import Foundation
import SwiftUI
import Testing

@testable import Features

struct TitleMentionTests {
  @Test func findsEachTitleWhereItAppears() {
    let body = "朝に書いた。夜の机に向かうの続きを、朝にまた。"
    #expect(
      mentions(in: body, of: [morning, nightDesk]) == [
        Found(text: "朝", id: 7), Found(text: "夜の机に向かう", id: 4), Found(text: "朝", id: 7),
      ])
  }

  @Test func findsNothingWhereNoTitleAppears() {
    #expect(mentions(in: "パンを焼いた。", of: [morning, nightDesk]).isEmpty)
  }

  /// An untitled writing's empty title would otherwise appear everywhere.
  @Test func skipsAnUntitledWriting() {
    #expect(mentions(in: "朝", of: [row(id: 5, "")]).isEmpty)
  }

  /// 「夜」 inside 「夜の机に向かう」 is part of the longer title, not a mention of its own.
  @Test func takesTheLongestTitleStartingAtTheSamePlace() {
    let night = row(id: 2, "夜")
    #expect(
      mentions(in: "夜の机に向かう", of: [night, nightDesk]) == [Found(text: "夜の机に向かう", id: 4)])
  }

  /// Of two titles that overlap, the one starting first is taken, and the other is not cut short.
  @Test func takesTheEarlierOfTwoOverlappingTitles() {
    let first = row(id: 1, "読書メモ")
    let second = row(id: 2, "メモ帳")
    #expect(mentions(in: "読書メモ帳", of: [second, first]) == [Found(text: "読書メモ", id: 1)])
  }

  @Test func takesTheFirstOfWritingsThatShareATitle() {
    let twin = row(id: 40, "夜の机に向かう")
    #expect(mentions(in: "夜の机に向かう", of: [nightDesk, twin]) == [Found(text: "夜の机に向かう", id: 4)])
  }

  @Test func matchesWholeCharacters() {
    // 「が」 written as か and a combining voiced mark is one character, not 「か」.
    #expect(mentions(in: "か\u{3099}", of: [row(id: 1, "か")]).isEmpty)
  }

  @Test func findsTheWritingALinkOpens() {
    let found = "朝と夜の机に向かう".titleMentions(of: [morning, nightDesk])
    #expect(found.writing(linkedBy: nightDesk.link) == nightDesk)
    #expect(found.writing(linkedBy: morning.link) == morning)
  }

  @Test func aTapOnAMentionOpensItsWriting() {
    var opened: [Writing] = []
    let action = OpenURLAction.opening(
      "朝と夜の机に向かう".titleMentions(of: [morning, nightDesk]), with: { opened.append($0) })
    action(nightDesk.link)
    #expect(opened == [nightDesk])
  }

  @Test func findsNoWritingForALinkNoMentionCarries() throws {
    let found = "朝".titleMentions(of: [morning, nightDesk])
    #expect(found.writing(linkedBy: nightDesk.link) == nil)
    #expect(found.writing(linkedBy: try #require(URL(string: "https://example.com"))) == nil)
  }
}

private struct Found: Equatable {
  let text: String
  let id: UUID

  init(text: String, id: Int) {
    self.text = text
    self.id = UUID(sample: id)
  }

  init(text: String, id: UUID) {
    self.text = text
    self.id = id
  }
}

private func mentions(in body: String, of writings: [Writing]) -> [Found] {
  body.titleMentions(of: writings).map { Found(text: String(body[$0.range]), id: $0.writing.id) }
}

private func row(id: Int, _ title: String) -> Writing {
  Writing(id: UUID(sample: id), title: title, body: "", updated: Date(timeIntervalSince1970: 0))
}

private let morning = row(id: 7, "朝")
private let nightDesk = row(id: 4, "夜の机に向かう")
