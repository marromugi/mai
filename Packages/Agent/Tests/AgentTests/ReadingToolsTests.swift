import Agent
import CryptoKit
import Foundation
import MCP
import Sync
import SyncFakes
import Testing

/// The tools as an MCP client calls them, over the agent's pairing with an account on the fake
/// server.
struct ReadingToolsTests {
  let account = Account()
  let key = P256.KeyAgreement.PrivateKey()

  /// A client connected to the tools, with the agent approved and paired.
  private func connect() async throws -> (client: Client, agent: UUID) {
    let (agent, line) = try await account.approve(key)
    _ = try await account.file.pair(key, line: line, transport: account.fake)
    return (try await client(), agent)
  }

  private func client(transport: (any HTTPTransport)? = nil) async throws -> Client {
    let server = Server(
      name: "mai-mcp", version: "test", capabilities: .init(tools: .init(listChanged: false)))
    await ReadingTools<P256.KeyAgreement.PrivateKey>(
      file: account.file, transport: transport ?? account.fake, timeZone: Self.tokyo
    ).register(on: server)
    let (clientEnd, serverEnd) = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: serverEnd)
    let client = Client(name: "test", version: "test")
    _ = try await client.connect(transport: clientEnd)
    return client
  }

  private static let tokyo: TimeZone = {
    guard let zone = TimeZone(identifier: "Asia/Tokyo") else {
      preconditionFailure("Asia/Tokyo is a time zone")
    }
    return zone
  }()

  private func call(
    _ client: Client, _ name: String, _ arguments: [String: Value]? = nil
  ) async throws -> (text: String, isError: Bool) {
    let (content, isError) = try await client.callTool(name: name, arguments: arguments)
    let text = content.compactMap { content -> String? in
      guard case .text(let text, _, _) = content else { return nil }
      return text
    }.joined()
    return (text, isError ?? false)
  }

  private func turnOn(forSeconds seconds: TimeInterval) async throws -> Date {
    _ = try await account.synchronizer.sync()
    let until = account.clock.now + seconds
    _ = try await account.readMode.turnOn(until: until)
    return until
  }

  @Test func offersThreeReadOnlyTools() async throws {
    let (client, _) = try await connect()
    let tools = try await client.listTools().tools
    #expect(tools.map(\.name) == ["list_writings", "read_writing", "search_writings"])
    #expect(tools.allSatisfy { $0.annotations.readOnlyHint == true })
  }

  @Test func listsReadsAndSearchesWhileReadModeIsOn() async throws {
    let (client, _) = try await connect()
    let walk = try account.write("散歩の記録", "川沿いを歩いた。鷺が一羽、浅瀬に立っていた。", at: 0)
    let shopping = try account.write(
      "買い物の覚え書き", "牛乳、卵、ＡＢＣのノート。", links: [(0..<2, "https://example.com/milk")], at: 60)
    _ = try await turnOn(forSeconds: 3600)

    let listed = try await call(client, "list_writings")
    #expect(listed.isError == false)
    #expect(
      listed.text == """
        読み取りモードは 2026-09-22T00:13:20+09:00 まで。読める文書は 2 件（新しい順）:
        - 買い物の覚え書き（ID: \(shopping.id.uuidString.lowercased())、更新: 2026-09-21T23:14:20+09:00）
        - 散歩の記録（ID: \(walk.id.uuidString.lowercased())、更新: 2026-09-21T23:13:20+09:00）
        """)

    let read = try await call(client, "read_writing", ["id": .string(shopping.id.uuidString)])
    #expect(read.isError == false)
    #expect(
      read.text == """
        # 買い物の覚え書き

        ID: \(shopping.id.uuidString.lowercased())
        更新: 2026-09-21T23:14:20+09:00
        読み取りモードの終わり: 2026-09-22T00:13:20+09:00

        牛乳、卵、ＡＢＣのノート。

        リンク:
        - 牛乳: https://example.com/milk
        """)

    let found = try await call(client, "search_writings", ["query": "abc"])
    #expect(found.isError == false)
    #expect(found.text.contains("「abc」を含む文書は 1 件（読める 2 件のうち、新しい順）"))
    #expect(found.text.contains("買い物の覚え書き"))
    #expect(found.text.contains("牛乳、卵、ＡＢＣのノート。"))
    #expect(!found.text.contains("散歩の記録"))

    let byTitle = try await call(client, "search_writings", ["query": "散歩"])
    #expect(byTitle.text.contains("散歩の記録"))
    let none = try await call(client, "search_writings", ["query": "手紙"])
    #expect(none.text == "「手紙」を含む文書はありません（読める 2 件のうち）。")
  }

  @Test func readsNothingOnceReadModeIsOffOrPastItsEnd() async throws {
    let (client, _) = try await connect()
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await turnOn(forSeconds: 600)
    #expect(
      try await call(client, "read_writing", ["id": .string(walk.id.uuidString)]).text
        .hasPrefix("# 散歩の記録"))

    // Past its end, before the server's sweep: the copy is still held, but nothing is served,
    // the writing already opened included.
    account.clock.advance(by: 601)
    let listed = try await call(client, "list_writings")
    #expect(listed.isError == false)
    #expect(listed.text.hasPrefix("いま読める文書はありません。iPhone の Cotoma で読み取りモードがオフか、終わる時刻を過ぎています。"))
    let read = try await call(client, "read_writing", ["id": .string(walk.id.uuidString)])
    #expect(read.text.hasPrefix("文書 \(walk.id.uuidString.lowercased()) は読めません。"))
    #expect(
      try await call(client, "search_writings", ["query": "川"]).text.hasPrefix("いま読める文書はありません。"))

    // Turned off.
    _ = try await turnOn(forSeconds: 600)
    #expect(try await call(client, "list_writings").text.contains("散歩の記録"))
    try await account.readMode.turnOff()
    #expect(try await call(client, "list_writings").text.hasPrefix("いま読める文書はありません。"))
  }

  @Test func anExcludedWritingIsNotRead() async throws {
    let (client, _) = try await connect()
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    try account.write("手紙の下書き", "拝啓", at: 60)
    _ = try await turnOn(forSeconds: 600)
    try await account.readMode.exclude(walk.id)

    #expect(!(try await call(client, "list_writings").text.contains("散歩の記録")))
    #expect(
      try await call(client, "read_writing", ["id": .string(walk.id.uuidString)]).text
        .hasPrefix("文書 \(walk.id.uuidString.lowercased()) は読めません。"))
  }

  @Test func aRevokedAgentIsToldToPairAgain() async throws {
    let (client, agent) = try await connect()
    try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await turnOn(forSeconds: 600)
    #expect(try await account.readMode.revoke(agent))

    for (name, arguments): (String, [String: Value]?) in [
      ("list_writings", nil), ("read_writing", ["id": .string(UUID().uuidString)]),
      ("search_writings", ["query": "川"]),
    ] {
      let answer = try await call(client, name, arguments)
      #expect(answer.isError)
      #expect(answer.text.hasPrefix("このエージェントは iPhone で取り消されたか、トークンが違います。"))
    }
  }

  @Test func beforePairingItSaysHowToPair() async throws {
    let client = try await client()
    let answer = try await call(client, "list_writings")
    #expect(answer.isError)
    #expect(answer.text.hasPrefix("この Mac はまだ Cotoma とペアリングしていません。ターミナルで `mai-mcp pair` を実行し"))
  }

  @Test func aCopyWrappedForAnotherKeyIsNamedUnopenable() async throws {
    let (agent, line) = try await account.approve(key)
    _ = agent
    // The pairing keeps another key than the one the device wraps for.
    try account.file.write(
      Pairing(key: P256.KeyAgreement.PrivateKey(), handoff: Handoff(line: line)))
    let client = try await client()
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await turnOn(forSeconds: 600)

    let listed = try await call(client, "list_writings")
    #expect(listed.text.hasPrefix("いま読める文書はありません。"))
    #expect(
      listed.text.contains("文書 \(walk.id.uuidString.lowercased()) の写しはありますが、この Mac の鍵では開けませんでした。"))
  }

  @Test(arguments: [
    ("read_writing", ["id": Value.string("not-an-id")], "「not-an-id」は文書の ID（UUID）ではありません。"),
    ("read_writing", [:], "read_writing には id（文書の ID の文字列）が要ります。"),
    ("read_writing", ["id": Value.int(5)], "read_writing には id（文書の ID の文字列）が要ります。"),
    ("search_writings", ["query": Value.string("  ")], "探す言葉（query）が空です。"),
    ("search_writings", ["query": Value.bool(true)], "search_writings には query（探す言葉の文字列）が要ります。"),
    ("write_writing", [:], "write_writing というツールはありません。"),
  ])
  func refusesAWrongCall(_ name: String, _ arguments: [String: Value], _ answer: String)
    async throws
  {
    let (client, _) = try await connect()
    let called = try await call(client, name, arguments)
    #expect(called.isError)
    #expect(called.text.hasPrefix(answer))
  }

  @Test func aWritingSavedAgainIsReadAtItsNewRevision() async throws {
    let (client, _) = try await connect()
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await turnOn(forSeconds: 600)
    #expect(
      try await call(client, "read_writing", ["id": .string(walk.id.uuidString)]).text
        .contains("川沿いを歩いた。"))

    let edited = PlainWriting(
      id: walk.id, updated: walk.updated + 60,
      contents: try JSONSerialization.data(withJSONObject: [
        "title": "散歩の記録", "body": "夕方にもう一度歩いた。", "links": [], "photos": [],
      ]))
    account.writings.save(edited)
    _ = try await account.synchronizer.sync()

    let read = try await call(client, "read_writing", ["id": .string(walk.id.uuidString)])
    #expect(read.text.contains("夕方にもう一度歩いた。"))
    #expect(!read.text.contains("川沿いを歩いた。"))
  }

  @Test func anIDWithANewlineAfterItIsRead() async throws {
    let (client, _) = try await connect()
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await turnOn(forSeconds: 600)
    let read = try await call(client, "read_writing", ["id": .string(walk.id.uuidString + "\n")])
    #expect(read.text.hasPrefix("# 散歩の記録"))
  }

  @Test func aRunningServerReadsWithTheKeyOfANewPairing() async throws {
    let (client, _) = try await connect()
    try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await turnOn(forSeconds: 600)
    #expect(try await call(client, "list_writings").text.contains("散歩の記録"))

    let second = P256.KeyAgreement.PrivateKey()
    let (_, line) = try await account.approve(second)
    _ = try await account.readMode.sendCopies(of: Set(account.writings.all().map(\.id)))
    _ = try await account.file.pair(second, line: line, transport: account.fake)

    let listed = try await call(client, "list_writings")
    #expect(listed.text.contains("散歩の記録"))
    #expect(!listed.text.contains("開けませんでした"))
  }

  @Test func aCopyTheServerSendsBrokenIsNamedAndTheRestRead() async throws {
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    let letter = try account.write("手紙の下書き", "拝啓", at: 60)
    let (_, line) = try await account.approve(key)
    _ = try await account.file.pair(key, line: line, transport: account.fake)
    let client = try await client(transport: Breaking(fake: account.fake, copy: letter.id))
    _ = try await turnOn(forSeconds: 600)

    let listed = try await call(client, "list_writings")
    #expect(listed.isError == false)
    #expect(listed.text.contains("散歩の記録"))
    #expect(listed.text.contains("文書 \(letter.id.uuidString.lowercased()) の写しはありますが"))
    #expect(
      try await call(client, "read_writing", ["id": .string(walk.id.uuidString)]).text.hasPrefix(
        "# 散歩の記録"))
  }
}

/// The fake server, with the copy of one writing sent without its wrapped key.
struct Breaking: HTTPTransport {
  let fake: FakeWritingServer
  let copy: UUID

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await fake.send(request)
    guard request.url?.lastPathComponent == copy.uuidString.lowercased(),
      let url = response.url,
      let broken = HTTPURLResponse(
        url: url, statusCode: response.statusCode, httpVersion: nil, headerFields: [:])
    else {
      return (data, response)
    }
    return (data, broken)
  }
}
