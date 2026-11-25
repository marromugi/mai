import Foundation
import Sync
import Testing

/// `ServerContract` and `ReadModeContract` on the Worker in `Server/`, run under `wrangler dev` by
/// `scripts/server-contract-test.sh`, which gives the server's URL and token. Left out of the
/// ordinary run by `--skip Contract`.
struct WritingServerContractTests {
  private let url: URL?
  private let token: String?

  init() {
    let environment = ProcessInfo.processInfo.environment
    url = environment["MAI_SERVER_URL"].flatMap(URL.init(string:))
    token = environment["MAI_SERVER_TOKEN"]
  }

  private func server(token: String) throws -> WritingServer {
    try WritingServer(
      url: #require(url, "MAI_SERVER_URL names the local Worker"), token: token)
  }

  @Test(arguments: ServerContract.allCases)
  func workerKeepsTheContract(_ contract: ServerContract) async throws {
    let token = try #require(token, "MAI_SERVER_TOKEN is the local Worker's token")
    try await contract.check(
      server: server(token: token),
      stranger: server(token: String(token.dropLast()) + (token.hasSuffix("A") ? "B" : "A")),
      ownKey: OwnKey.generate())
  }

  @Test func twoDevicesSyncThroughTheWorker() async throws {
    let token = try #require(token, "MAI_SERVER_TOKEN is the local Worker's token")
    let server = try server(token: token)
    try await TwoDevices(server: { server }, ownKey: OwnKey.generate())
      .checkAWritingAndItsEditTravelBothWays()
  }

  @Test func readModeReachesAnAgentThroughTheWorker() async throws {
    let token = try #require(token, "MAI_SERVER_TOKEN is the local Worker's token")
    let url = try #require(url, "MAI_SERVER_URL names the local Worker")
    let ownKey = OwnKey.generate()
    try await ReadModeContract.check(
      ReadModeSetUp(ownKey: ownKey, url: url, token: token, transport: URLSession.shared),
      ownKey: ownKey, now: Date.init)
  }

  @Test func aPhotoTravelsWithItsWritingThroughTheWorker() async throws {
    let token = try #require(token, "MAI_SERVER_TOKEN is the local Worker's token")
    let server = try server(token: token)
    try await TwoDevices(server: { server }, ownKey: OwnKey.generate())
      .checkAPhotoTravelsWithItsWriting()
  }
}
