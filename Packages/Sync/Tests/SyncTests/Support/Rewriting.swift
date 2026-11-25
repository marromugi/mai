import Foundation
import Sync
import SyncFakes

/// Passes requests on to the fake, with hooks: `before` runs ahead of each request, `rewrite`
/// changes each answer, `failCopies` answers `POST /copies` with a 500, and the next
/// `POST /copies` can be held until `letGo()`.
actor Rewriting: HTTPTransport {
  typealias Rewrite = @Sendable (URLRequest, Data, HTTPURLResponse) -> (Data, HTTPURLResponse)

  let fake: FakeWritingServer
  private var rewrite: Rewrite?
  private var before: (@Sendable (URLRequest) async -> Void)?
  private var failCopies = false
  private var holdNextCopies = false
  /// Whether a `POST /copies` is being held.
  private(set) var held = false
  private var release: CheckedContinuation<Void, Never>?

  init(fake: FakeWritingServer) {
    self.fake = fake
  }

  func set(rewrite: Rewrite? = nil, before: (@Sendable (URLRequest) async -> Void)? = nil) {
    self.rewrite = rewrite
    self.before = before
  }

  func setFailCopies(_ failing: Bool) {
    failCopies = failing
  }

  func holdTheNextCopies() {
    holdNextCopies = true
  }

  func letGo() {
    release?.resume()
    release = nil
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let isCopies = request.httpMethod == "POST" && request.url?.lastPathComponent == "copies"
    if isCopies, holdNextCopies {
      holdNextCopies = false
      held = true
      await withCheckedContinuation { release = $0 }
      held = false
    } else if isCopies, failCopies, let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)
    {
      return (Data(#"{"error":"down"}"#.utf8), response)
    }
    if let before {
      await before(request)
    }
    let (data, response) = try await fake.send(request)
    return rewrite?(request, data, response) ?? (data, response)
  }
}
