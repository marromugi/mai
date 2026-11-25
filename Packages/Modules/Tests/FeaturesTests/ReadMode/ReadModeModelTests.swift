import CryptoKit
import Foundation
import Sync
import SyncFakes
import Testing

@testable import Features

/// `ReadModeModel` over `FakeWritingServer`, with an empty sync state: no writing synced yet.
struct ReadModeModelTests {
  private let url: URL = {
    guard let url = URL(string: "https://fake.test") else {
      preconditionFailure("https://fake.test is a URL")
    }
    return url
  }()
  private let token = "s1.session.token"
  private let ownKey = OwnKey.generate()
  private let fake: FakeWritingServer
  private let model: ReadModeModel

  init() {
    let fake = FakeWritingServer(accepting: token)
    self.fake = fake
    model = ReadModeModel(
      readMode: ReadMode(
        server: ReadModeServer(url: url, token: token, transport: fake), ownKey: ownKey,
        stateFile: FileManager.default.temporaryDirectory.appending(
          path: "mai-read-mode-model-\(UUID().uuidString).json")))
  }

  @Test func approvingHandsTheAgentTheServerAndItsToken() async throws {
    let agent = AgentKey(P256.KeyAgreement.PrivateKey().publicKey)
    let handoff = try await model.approve(code: agent.pairingCode).get()
    let parts = handoff.split(separator: "#", omittingEmptySubsequences: false)
    #expect(parts.count == 2)
    #expect(parts.first == "https://fake.test")
    #expect(parts.last?.hasPrefix("agent.") == true)
    #expect(model.agents.count == 1)
    #expect(model.agents.first?.code == String(agent.pairingCode.prefix(4)))
    #expect(model.agents.first?.approved == true)
    #expect(model.agents.first?.revoked == false)
  }

  @Test func aMistypedCodeIsSaidAndNothingIsSent() async throws {
    var digits = Array(
      AgentKey(P256.KeyAgreement.PrivateKey().publicKey).pairingCode.replacing("-", with: ""))
    digits[10] = digits[10] == "Z" ? "Y" : "Z"
    let result = await model.approve(code: String(digits))
    #expect(
      result == .failure(ApprovalProblem(message: AgentKeyError.mistyped.localizedDescription)))
    #expect(await fake.requests.isEmpty)
  }

  @Test func theSameKeyTwiceIsRefusedForAPerson() async throws {
    let code = AgentKey(P256.KeyAgreement.PrivateKey().publicKey).pairingCode
    _ = try await model.approve(code: code).get()
    guard case .failure(let problem) = await model.approve(code: code) else {
      Issue.record("the same key is approved once")
      return
    }
    #expect(problem.message.contains("新しい鍵"))
  }

  @Test func turningOnAndOffIsReadBack() async throws {
    _ = try await model.approve(
      code: AgentKey(P256.KeyAgreement.PrivateKey().publicKey).pairingCode
    )
    .get()
    let until = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 3600).rounded())
    await model.turnOn(until: until)
    #expect(model.problem == nil)
    #expect(model.until == until)
    #expect(model.sent == "0 件の写しをエージェントあてに置きました。")
    await model.turnOff()
    #expect(model.until == nil)
    #expect(model.sent == nil)
  }

  @Test func aTimePassedIsSaidAsAProblem() async {
    await model.turnOn(until: .now - 60)
    #expect(model.problem == "終わる時刻がもう過ぎています。これから先の時刻を選んでください。")
    #expect(model.until == nil)
  }

  /// A failure part way still reads the server again: turned on, with the copies not sent.
  @Test func aFailureAfterTurningOnShowsItOn() async throws {
    let failing = FailingAgents(fake: fake)
    let model = ReadModeModel(
      readMode: ReadMode(
        server: ReadModeServer(url: url, token: token, transport: failing), ownKey: ownKey,
        stateFile: FileManager.default.temporaryDirectory.appending(
          path: "mai-read-mode-model-\(UUID().uuidString).json")))
    let until = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 3600).rounded())
    await failing.failOnce()
    await model.turnOn(until: until)
    #expect(model.problem == "サーバーが読み取りモードの変更を断りました（500）。")
    #expect(model.until == until)
  }

  @Test(arguments: [
    (
      ServerError.unreachable(URLError(.notConnectedToInternet)),
      "サーバーにつながりませんでした。ネットワークを確かめて、もう一度お試しください。"
    ),
    (.refused(status: 401, reason: ""), "サインインが切れました。もう一度 Apple でサインインしてください。"),
    (
      .refused(status: 402, reason: ""),
      "プランの期限が切れているため、読み取りモードは変えられません。プランに入り直すと、また使えます。"
    ),
    (
      .limitReached(.requests),
      "今日のリクエストの回数がプランの上限に達しました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また使えます。"
    ),
    (.unexpectedAnswer("x"), "サーバーの答えが読めませんでした。"),
  ])
  func aServerFailureIsSaidForReadMode(_ error: ServerError, _ said: String) {
    #expect(ReadModeModel.message(for: error) == said)
  }

  @Test func aStateThatCantBeReadIsSaidAsTheDevices() {
    #expect(
      ReadModeModel.message(for: CocoaError(.fileReadCorruptFile)).hasPrefix("この端末の同期の記録"))
  }

  @Test func excludingAndIncludingAWriting() async {
    let id = UUID()
    await model.setExcluded(id, true)
    #expect(model.excluded == [id])
    await model.setExcluded(id, false)
    #expect(model.excluded.isEmpty)
  }

  @Test func revokingKeepsTheAgentListedAsRevoked() async throws {
    _ = try await model.approve(
      code: AgentKey(P256.KeyAgreement.PrivateKey().publicKey).pairingCode
    )
    .get()
    let agent = try #require(model.agents.first)
    await model.revoke(agent.id)
    #expect(model.agents.map(\.revoked) == [true])
    #expect(model.agents.map(\.approved) == [true])
  }

  /// A key the server lists that no device of the account signed shows as not approved.
  @Test func aKeyNoDeviceSignedIsShownAsNotApproved() async throws {
    let server = ReadModeServer(url: url, token: token, transport: fake)
    _ = try #require(
      try await server.approve(
        AgentKey(P256.KeyAgreement.PrivateKey().publicKey), signature: Data(repeating: 1, count: 32)
      ))
    await model.load()
    #expect(model.agents.map(\.approved) == [false])
  }

  @Test(arguments: [
    (0, [:], "0 件の写しをエージェントあてに置きました。"),
    (
      3, [CopyRefusal.revision: 1, .agent: 1],
      "3 件の写しをエージェントあてに置きました。2 件は、そのあいだに設定か文書が変わったため置いていません。"
    ),
  ])
  func whatWasSentIsSaid(kept: Int, refused: [CopyRefusal: Int], said: String) {
    var copies = CopiesSent()
    copies.kept = kept
    copies.refused = refused
    #expect(ReadModeModel.said(copies) == said)
  }
}

/// Passes requests on to the fake, answering the next `GET /agents` with a 500 once told to:
/// turning on goes through, and reading the agents for its copies fails.
private actor FailingAgents: HTTPTransport {
  let fake: FakeWritingServer
  private var failing = false

  init(fake: FakeWritingServer) {
    self.fake = fake
  }

  func failOnce() {
    failing = true
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard failing, request.httpMethod ?? "GET" == "GET",
      request.url?.lastPathComponent == "agents", let url = request.url,
      let response = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)
    else {
      return try await fake.send(request)
    }
    failing = false
    return (Data(#"{"error":"down"}"#.utf8), response)
  }
}
