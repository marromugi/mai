import Foundation
import Sync
import Testing

struct ServerErrorTests {
  @Test(arguments: [
    (ServerError.refused(status: 401, reason: "x"), "サーバーがこの端末の鍵を受け付けませんでした。"),
    (.refused(status: 400, reason: "x"), "サーバーが同期を断りました（400）。"),
    (.unreachable(URLError(.notConnectedToInternet)), "サーバーにつながりませんでした。ネットワークを確かめて、もう一度同期してください。"),
    (.unexpectedAnswer("x"), "サーバーの答えが読めませんでした。"),
  ])
  func tellsAPersonWhatWentWrong(_ error: ServerError, _ message: String) {
    #expect(error.localizedDescription == message)
  }
}
