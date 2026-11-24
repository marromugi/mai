import Foundation
import Sync
import Testing

/// How `WritingServer` takes answers the Worker isn't meant to give.
struct WritingServerAnswerTests {
  private let ownKey = OwnKey.generate()

  private func server(answering status: Int, body: String = "{}", headers: [String: String] = [:])
    throws -> WritingServer
  {
    try WritingServer(
      url: #require(URL(string: "https://fake.test")), token: "t",
      transport: Answering(status: status, body: Data(body.utf8), headers: headers))
  }

  private func isRefused(_ status: Int) -> (any Error) -> Bool {
    { error in
      guard case .refused(status, "nope") = error as? ServerError else { return false }
      return true
    }
  }

  @Test func aSaveAnsweredWithAnotherStatusIsRefused() async throws {
    let server = try server(answering: 400, body: #"{"error":"nope"}"#)
    let sealed = try ownKey.seal(PlainWriting(id: UUID(), updated: .now, contents: Data()))
    await #expect(performing: { try await server.save(sealed, over: nil) }, throws: isRefused(400))
  }

  @Test func aReadAnsweredWithAnotherStatusIsRefused() async throws {
    let server = try server(answering: 500, body: #"{"error":"nope"}"#)
    await #expect(performing: { try await server.read(UUID()) }, throws: isRefused(500))
  }

  @Test func aListingAnsweredWith401IsRefused() async throws {
    let server = try server(answering: 401, body: #"{"error":"nope"}"#)
    await #expect(performing: { try await server.list() }, throws: isRefused(401))
  }

  @Test func aSavedAnswerWithoutItsRevisionIsUnexpected() async throws {
    let server = try server(answering: 200, body: #"{"revision":null}"#)
    let sealed = try ownKey.seal(PlainWriting(id: UUID(), updated: .now, contents: Data()))
    await #expect {
      try await server.save(sealed, over: nil)
    } throws: { error in
      guard case .unexpectedAnswer = error as? ServerError else { return false }
      return true
    }
  }

  @Test func aWritingReadWithoutItsRevisionIsUnexpected() async throws {
    let server = try server(answering: 200, body: "")
    await #expect {
      try await server.read(UUID())
    } throws: { error in
      guard case .unexpectedAnswer = error as? ServerError else { return false }
      return true
    }
  }
}

private struct Answering: HTTPTransport {
  let status: Int
  let body: Data
  let headers: [String: String]

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
    else { preconditionFailure("A request sent here always has a URL") }
    return (body, response)
  }
}
