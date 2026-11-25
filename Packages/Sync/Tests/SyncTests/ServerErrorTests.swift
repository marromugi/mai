import Foundation
import Sync
import Testing

struct ServerErrorTests {
  @Test(arguments: [
    (
      ServerError.refused(status: 401, reason: "x"),
      "サインインが切れました。もう一度 Apple でサインインしてください。文書はこの端末に残っています。"
    ),
    (
      .refused(status: 402, reason: "x"),
      "プランの期限が切れているため、この端末の変更をサーバーに送れません。ほかの端末の変更は受け取ります。プランに入り直すと、また送れます。文書はこの端末に残っています。"
    ),
    (
      .limitReached(.saves),
      "今日の保存の回数がプランの上限に達したため、同期を止めました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。文書はこの端末に残っています。"
    ),
    (
      .limitReached(.lists),
      "今日の一覧の回数がプランの上限に達したため、同期を止めました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。文書はこの端末に残っています。"
    ),
    (
      .limitReached(.requests),
      "今日のリクエストの回数がプランの上限に達したため、同期を止めました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。文書はこの端末に残っています。"
    ),
    (
      .limitReached(.photos),
      "今日の写真の枚数がプランの上限に達したため、同期を止めました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。文書はこの端末に残っています。"
    ),
    (
      .limitReached(.storage),
      "文書の容量か本数がプランの上限に達したため、同期を止めました。文書を減らすか、上のプランに変えてください。文書はこの端末に残っています。"
    ),
    (
      .limitReached(.photoStorage),
      "写真の容量がプランの上限に達したため、同期を止めました。写真を減らすか、上のプランに変えてください。文書はこの端末に残っています。"
    ),
    (
      .limitReached(nil),
      "プランの上限に達したため、同期を止めました。1 日の回数の上限なら、日付が変わると（協定世界時の 0 時、日本時間の 9 時）また同期できます。容量の上限なら、文書を減らすか、上のプランに変えてください。文書はこの端末に残っています。"
    ),
    (.refused(status: 400, reason: "x"), "サーバーが同期を断りました（400）。"),
    (.unreachable(URLError(.notConnectedToInternet)), "サーバーにつながりませんでした。ネットワークを確かめて、もう一度同期してください。"),
    (.unexpectedAnswer("x"), "サーバーの答えが読めませんでした。"),
  ])
  func tellsAPersonWhatWentWrong(_ error: ServerError, _ message: String) {
    #expect(error.localizedDescription == message)
  }
}
