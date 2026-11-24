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
      "プランの期限が切れているため、この端末の変更をサーバーに送れません。ほかの端末の変更は受け取ります。文書はこの端末に残っています。"
    ),
    (
      .refused(status: 429, reason: "x"),
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
