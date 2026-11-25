import Foundation
import MCP
import Sync

/// The MCP server's three read-only tools, `list_writings`, `read_writing` and `search_writings`,
/// over the pairing kept in `file`. The pairing is read again on every call, so a `mai-mcp pair`
/// run while the server runs is taken up at once.
public actor ReadingTools<Key: AgentPrivateKey> {
  private let file: PairingFile
  private let transport: any HTTPTransport
  private let timeZone: TimeZone
  private var current: (handoff: Handoff, library: Library<Key>)?

  public init(file: PairingFile, transport: any HTTPTransport, timeZone: TimeZone = .current) {
    self.file = file
    self.transport = transport
    self.timeZone = timeZone
  }

  /// Answers MCP's `tools/list` and `tools/call` on `server`.
  public func register(on server: Server) async {
    await server.withMethodHandler(ListTools.self) { _ in .init(tools: Self.tools) }
    await server.withMethodHandler(CallTool.self) { [self] call in await self.call(call) }
  }

  public static var tools: [Tool] {
    let readOnly = Tool.Annotations(
      readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    return [
      Tool(
        name: "list_writings", title: "文書の一覧",
        description:
          "Cotoma（執筆アプリ）の文書のうち、いま読めるものの一覧。タイトル・ID・更新時刻と、読み取りモードの終わる時刻を返す。iPhone で読み取りモードがオンの間だけ、「AI に読ませない」にしていない文書が読める。",
        inputSchema: .object(["type": "object", "properties": .object([:])]),
        annotations: readOnly),
      Tool(
        name: "read_writing", title: "文書を読む",
        description: "Cotoma の文書 1 つの本文を読む。ID は list_writings か search_writings が返すもの。",
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "id": .object(["type": "string", "description": "文書の ID（UUID）"])
          ]),
          "required": .array(["id"]),
        ]),
        annotations: readOnly),
      Tool(
        name: "search_writings", title: "文書を探す",
        description:
          "いま読める Cotoma の文書を、タイトルと本文に言葉を含むもので探す。大文字小文字・全角半角を区別しない。この Mac の上で復号してから探す。",
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "query": .object(["type": "string", "description": "探す言葉"])
          ]),
          "required": .array(["query"]),
        ]),
        annotations: readOnly),
    ]
  }

  public func call(_ call: CallTool.Parameters) async -> CallTool.Result {
    let answer: Answer
    do throws(Problem) {
      answer = try await self.answer(call)
    } catch {
      return .init(content: [.text(text: error.text, annotations: nil, _meta: nil)], isError: true)
    }
    return .init(content: [.text(text: answer.text, annotations: nil, _meta: nil)], isError: false)
  }

  private func answer(_ call: CallTool.Parameters) async throws(Problem) -> Answer {
    switch call.name {
    case "list_writings":
      let library = try library()
      return Answer(
        listing: try await served { () async throws(ServerError) in try await library.shelf() },
        in: timeZone)
    case "read_writing":
      guard let text = call.arguments?["id"]?.stringValue,
        let id = UUID(uuidString: text.trimmingCharacters(in: .whitespaces))
      else {
        throw .notAnID(call.arguments?["id"]?.stringValue)
      }
      let library = try library()
      return Answer(
        reading: try await served { () async throws(ServerError) in try await library.writing(id) },
        of: id, in: timeZone)
    case "search_writings":
      let words = (call.arguments?["query"]?.stringValue ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !words.isEmpty else { throw .noWords }
      let library = try library()
      let (matches, shelf) = try await served { () async throws(ServerError) in
        try await library.search(words)
      }
      return Answer(searching: words, found: matches, of: shelf, in: timeZone)
    default:
      throw .unknownTool(call.name)
    }
  }

  private func served<T>(_ read: () async throws(ServerError) -> T) async throws(Problem) -> T {
    do {
      return try await read()
    } catch {
      throw .server(error)
    }
  }

  private func library() throws(Problem) -> Library<Key> {
    let pairing: Pairing<Key>?
    do {
      pairing = try file.read()
    } catch {
      throw .unreadablePairing(error)
    }
    guard let pairing else { throw .notPaired }
    if let current, current.handoff == pairing.handoff {
      return current.library
    }
    let made = Library(
      server: AgentServer(
        url: pairing.handoff.server, token: pairing.handoff.token, transport: transport),
      key: pairing.key)
    current = (pairing.handoff, made)
    return made
  }
}

/// A tool's answer, as text for the agent to read.
struct Answer {
  let text: String

  init(listing shelf: Shelf, in timeZone: TimeZone) {
    guard let first = shelf.writings.first else {
      text = Self.nothingReadable + Self.unopenable(shelf)
      return
    }
    text =
      "読み取りモードは \(Self.time(first.expires, timeZone)) まで。読める文書は \(shelf.writings.count) 件（新しい順）:\n"
      + shelf.writings.map { Self.line($0, timeZone) }.joined(separator: "\n")
      + Self.unopenable(shelf)
  }

  init(reading: Library<some AgentPrivateKey>.Reading, of id: UUID, in timeZone: TimeZone) {
    switch reading {
    case .opened(let writing):
      var parts = [
        "# \(Self.title(writing))",
        "ID: \(Self.id(writing.id))\n更新: \(Self.time(writing.updated, timeZone))\n読み取りモードの終わり: \(Self.time(writing.expires, timeZone))",
        writing.body,
      ]
      if !writing.links.isEmpty {
        parts.append(
          "リンク:\n"
            + writing.links.map { "- \($0.text): \($0.url.absoluteString)" }.joined(
              separator: "\n"))
      }
      text = parts.joined(separator: "\n\n")
    case .unopenable:
      text = Self.cantOpen(id)
    case .gone:
      text =
        "文書 \(Self.id(id)) は読めません。読み取りモードがオフか期限が過ぎた、「AI に読ませない」にした、または ID が違う、のどれかです。読める文書は list_writings で確かめてください。"
    }
  }

  init(searching words: String, found matches: [Match], of shelf: Shelf, in timeZone: TimeZone) {
    guard !shelf.writings.isEmpty else {
      text = Self.nothingReadable + Self.unopenable(shelf)
      return
    }
    guard !matches.isEmpty else {
      text = "「\(words)」を含む文書はありません（読める \(shelf.writings.count) 件のうち）。" + Self.unopenable(shelf)
      return
    }
    text =
      "「\(words)」を含む文書は \(matches.count) 件（読める \(shelf.writings.count) 件のうち、新しい順）:\n"
      + matches.map { match in
        Self.line(match.writing, timeZone)
          + (match.excerpt.map { "\n  " + $0.replacingOccurrences(of: "\n", with: " ") } ?? "")
      }.joined(separator: "\n") + Self.unopenable(shelf)
  }

  private static let nothingReadable =
    "いま読める文書はありません。iPhone の Cotoma で読み取りモードがオフか、終わる時刻を過ぎています。オンにすると、「AI に読ませない」にしていない文書が読めるようになります。"

  private static func line(_ writing: OpenedWriting, _ timeZone: TimeZone) -> String {
    "- \(title(writing))（ID: \(id(writing.id))、更新: \(time(writing.updated, timeZone))）"
  }

  private static func unopenable(_ shelf: Shelf) -> String {
    shelf.unopenable.isEmpty
      ? "" : "\n\n" + shelf.unopenable.map { cantOpen($0) }.joined(separator: "\n")
  }

  private static func cantOpen(_ id: UUID) -> String {
    "文書 \(self.id(id)) の写しはありますが、この Mac の鍵では開けませんでした。iPhone でこのエージェントを承認し直すと、新しい写しが届きます。"
  }

  private static func title(_ writing: OpenedWriting) -> String {
    writing.title.isEmpty ? "（無題）" : writing.title
  }

  private static func id(_ id: UUID) -> String {
    id.uuidString.lowercased()
  }

  private static func time(_ date: Date, _ timeZone: TimeZone) -> String {
    date.formatted(Date.ISO8601FormatStyle(timeZoneSeparator: .colon, timeZone: timeZone))
  }
}

/// Why a tool couldn't answer, as text for the agent to read.
enum Problem: Error {
  case notPaired
  case unreadablePairing(PairingFileError)
  case server(ServerError)
  case notAnID(String?)
  case noWords
  case unknownTool(String)

  var text: String {
    switch self {
    case .notPaired:
      "この Mac はまだ Cotoma とペアリングしていません。ターミナルで `mai-mcp pair` を実行し、iPhone の Cotoma で承認してください。"
    case .unreadablePairing(let error):
      error.localizedDescription
    case .server(.refused(status: 401, _)):
      "このエージェントは iPhone で取り消されたか、トークンが違います。iPhone の Cotoma で新しく承認し、ターミナルで `mai-mcp pair` をやり直してください。"
    case .server(.unreachable):
      "Cotoma のサーバーにつながりませんでした。ネットワークを確かめて、もう一度試してください。"
    case .server(.limitReached):
      "Cotoma のアカウントの今日のリクエスト数が上限に達しました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また読めます。"
    case .server(.refused(let status, _)):
      "Cotoma のサーバーが断りました（\(status)）。"
    case .server(.unexpectedAnswer(let reason)):
      "Cotoma のサーバーの答えが読めませんでした（\(reason)）。"
    case .notAnID(let given):
      "「\(given ?? "")」は文書の ID（UUID）ではありません。ID は list_writings か search_writings が返すものを使ってください。"
    case .noWords:
      "探す言葉（query）が空です。"
    case .unknownTool(let name):
      "\(name) というツールはありません。使えるのは list_writings・read_writing・search_writings です。"
    }
  }
}
