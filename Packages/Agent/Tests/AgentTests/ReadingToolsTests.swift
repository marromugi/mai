@testable import Agent
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
    #expect(
      tools.allSatisfy {
        $0.annotations.readOnlyHint == true && $0.annotations.destructiveHint == false
          && $0.annotations.idempotentHint == true && $0.annotations.openWorldHint == false
      })
    #expect(tools[0].inputSchema == .object(["type": "object", "properties": .object([:])]))
    #expect(tools[1].inputSchema.objectValue?["required"] == .array(["id"]))
    #expect(tools[1].inputSchema.objectValue?["properties"]?.objectValue?["id"] != nil)
    #expect(tools[2].inputSchema.objectValue?["required"] == .array(["query"]))
    #expect(tools[2].inputSchema.objectValue?["properties"]?.objectValue?["query"] != nil)
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
    let unopenable = "文書 \(letter.id.uuidString.lowercased()) の写しはありますが、この Mac の鍵では開けませんでした。"
    for (name, broken) in [
      (
        "no wrapped key",
        { @Sendable (request: URLRequest, body: Data) in
          Tampering.answer(request, 200, body: body)
        }
      ),
      (
        "not a sealed writing",
        { @Sendable (request: URLRequest, _: Data) in
          Tampering.answer(request, 200, headers: ["Mai-Wrapped-Key": "00"], body: Data([1, 2, 3]))
        }
      ),
    ] {
      let tampering = Tampering(account.fake) { request, data, response in
        Tampering.isCopy(request, of: letter.id) ? broken(request, data) : (data, response)
      }
      let client = try await client(transport: tampering)
      _ = try await turnOn(forSeconds: 600)

      let listed = try await call(client, "list_writings")
      #expect(listed.isError == false, "\(name)")
      #expect(listed.text.contains("散歩の記録"), "\(name)")
      #expect(listed.text.contains(unopenable), "\(name)")
      #expect(
        try await call(client, "read_writing", ["id": .string(walk.id.uuidString)]).text
          .hasPrefix("# 散歩の記録"), "\(name)")
      #expect(
        try await call(client, "read_writing", ["id": .string(letter.id.uuidString)]).text
          .hasPrefix(unopenable), "\(name)")
      let found = try await call(client, "search_writings", ["query": "川"])
      #expect(found.text.contains(unopenable), "\(name)")
      #expect(
        try await call(client, "search_writings", ["query": "無い言葉"]).text.contains(unopenable),
        "\(name)")
    }
  }

  @Test func aCopyGoneBetweenTheListAndTheReadIsNotRead() async throws {
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    let (_, line) = try await account.approve(key)
    _ = try await account.file.pair(key, line: line, transport: account.fake)
    let tampering = Tampering(account.fake) { request, data, response in
      Tampering.isCopy(request, of: walk.id) ? Tampering.answer(request, 404) : (data, response)
    }
    let client = try await client(transport: tampering)
    _ = try await turnOn(forSeconds: 600)

    let listed = try await call(client, "list_writings")
    #expect(listed.text.hasPrefix("いま読める文書はありません。"))
    #expect(!listed.text.contains("開けませんでした"))
    #expect(
      try await call(client, "read_writing", ["id": .string(walk.id.uuidString)]).text.hasPrefix(
        "文書 \(walk.id.uuidString.lowercased()) は読めません。"))
  }

  @Test func aRefusedCopyIsAnErrorAndNotUnopenable() async throws {
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    let (_, line) = try await account.approve(key)
    _ = try await account.file.pair(key, line: line, transport: account.fake)
    let tampering = Tampering(account.fake) { request, data, response in
      Tampering.isCopy(request, of: walk.id) ? Tampering.answer(request, 401) : (data, response)
    }
    let client = try await client(transport: tampering)
    _ = try await turnOn(forSeconds: 600)

    let listed = try await call(client, "list_writings")
    #expect(listed.isError)
    #expect(listed.text.hasPrefix("このエージェントは iPhone で取り消されたか"))
  }

  @Test func aListingOfAnotherShapeIsAnError() async throws {
    let (agent, line) = try await account.approve(key)
    _ = agent
    _ = try await account.file.pair(key, line: line, transport: account.fake)
    let tampering = Tampering(account.fake) { request, data, response in
      request.url?.lastPathComponent == "writings"
        ? Tampering.answer(request, 200, body: Data(#"{"writings":5}"#.utf8)) : (data, response)
    }
    let client = try await client(transport: tampering)
    let listed = try await call(client, "list_writings")
    #expect(listed.isError)
    #expect(listed.text.hasPrefix("Cotoma のサーバーの答えが読めませんでした"))
  }

  @Test func eachRevisionIsFetchedOnceAcrossCalls() async throws {
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    try account.write("手紙の下書き", "拝啓", at: 60)
    let (_, line) = try await account.approve(key)
    _ = try await account.file.pair(key, line: line, transport: account.fake)
    let tampering = Tampering(account.fake)
    let client = try await client(transport: tampering)
    _ = try await turnOn(forSeconds: 600)

    _ = try await call(client, "list_writings")
    #expect(tampering.paths.count == 3)
    _ = try await call(client, "search_writings", ["query": "川"])
    _ = try await call(client, "read_writing", ["id": .string(walk.id.uuidString)])
    #expect(tampering.paths.count == 5)
    #expect(tampering.paths.dropFirst(3).allSatisfy { $0.hasSuffix("/agent/writings") })
  }

  @Test func searchIgnoresCaseWidthAndAccentsInTitlesAndBodies() async throws {
    let (client, _) = try await connect()
    try account.write("Café の ABC", "本文", at: 0)
    try account.write("手紙", "résumé を書く", at: 60)
    _ = try await turnOn(forSeconds: 600)

    #expect(
      try await call(client, "search_writings", ["query": "cafe"]).text.contains("Café の ABC"))
    #expect(try await call(client, "search_writings", ["query": "ａｂｃ"]).text.contains("Café の ABC"))
    let body = try await call(client, "search_writings", ["query": "  RESUME "])
    #expect(body.text.hasPrefix("「RESUME」を含む文書は 1 件"))
    #expect(body.text.contains("手紙"))
  }

  @Test func anExcerptShowsFortyCharactersEachSideOnOneLine() async throws {
    let (client, _) = try await connect()
    let before = String(repeating: "あ", count: 45)
    let after = String(repeating: "い", count: 45)
    try account.write("長い", before + "鷺" + after, at: 0)
    try account.write("短い", "浅瀬に\n鷹が一羽", at: 60)
    _ = try await turnOn(forSeconds: 600)

    let long = try await call(client, "search_writings", ["query": "鷺"])
    #expect(
      long.text.hasSuffix(
        "\n  …" + String(repeating: "あ", count: 40) + "鷺" + String(repeating: "い", count: 40) + "…")
    )
    let short = try await call(client, "search_writings", ["query": "鷹"])
    #expect(short.text.hasSuffix("\n  浅瀬に 鷹が一羽"))
  }

  @Test func aWritingWithoutATitleIsNamedUntitled() async throws {
    let (client, _) = try await connect()
    let writing = try account.write("", "題のない文書", at: 0)
    _ = try await turnOn(forSeconds: 600)
    #expect(try await call(client, "list_writings").text.contains("- （無題）（ID: "))
    #expect(
      try await call(client, "read_writing", ["id": .string(writing.id.uuidString)]).text
        .hasPrefix("# （無題）"))
  }

  @Test func onlyLinksThatFitTheBodyAreShown() async throws {
    let (client, _) = try await connect()
    let fitting = try account.write(
      contents: [
        "title": "リンク", "body": "全体を見る", "photos": [String](),
        "links": [
          ["range": [-1, 2], "url": "https://example.com/a"],
          ["range": [3, 3], "url": "https://example.com/b"],
          ["range": [0, 999], "url": "https://example.com/c"],
          ["range": [1, 2, 3], "url": "https://example.com/d"],
          ["range": "x", "url": "https://example.com/e"],
          ["range": [3, 2], "url": "https://example.com/f"],
          ["range": [1, 3], "url": "https://example.com/ok"],
          ["range": [3, 5], "url": "https://example.com/end"],
        ],
      ], at: 0)
    let unreadableLinks = try account.write(
      contents: ["title": "壊れたリンク", "body": "本文", "links": "x"], at: 60)
    _ = try await turnOn(forSeconds: 600)

    let read = try await call(client, "read_writing", ["id": .string(fitting.id.uuidString)])
    #expect(
      read.text.hasSuffix(
        "全体を見る\n\nリンク:\n- 体を: https://example.com/ok\n- 見る: https://example.com/end"))
    let other = try await call(
      client, "read_writing", ["id": .string(unreadableLinks.id.uuidString)])
    #expect(other.text.hasSuffix("\n\n本文"))
  }

  @Test func anUnreadablePairingFileIsNamed() async throws {
    try FileManager.default.createDirectory(
      at: account.file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{".utf8).write(to: account.file.url)
    let answer = try await call(try await client(), "list_writings")
    #expect(answer.isError)
    #expect(answer.text.hasPrefix("ペアリングのファイル \(account.file.url.path) が読めません"))
  }
}

struct LibraryTests {
  @Test func whatWasOpenedIsDroppedOnceItIsNoLongerListed() async throws {
    let account = Account()
    let key = P256.KeyAgreement.PrivateKey()
    let (_, line) = try await account.approve(key)
    let handoff = try Handoff(line: line)
    let library = Library(
      server: AgentServer(url: handoff.server, token: handoff.token, transport: account.fake),
      key: key)
    let walk = try account.write("散歩の記録", "川沿いを歩いた。", at: 0)
    _ = try await account.synchronizer.sync()
    _ = try await account.readMode.turnOn(until: account.clock.now + 600)
    _ = try await library.shelf()
    #expect(await library.openedIDs == [walk.id])

    try await account.readMode.turnOff()
    _ = try await library.shelf()
    #expect(await library.openedIDs.isEmpty)
  }
}
