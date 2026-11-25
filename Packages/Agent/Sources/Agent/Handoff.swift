import Foundation

/// The line the iPhone shows once it approves the agent, `<Worker URL>#agent.<ID>.<secret>`
/// (`Server/README.md`, 「エージェントの側」), split at its last `#`.
public struct Handoff: Sendable, Equatable {
  public let server: URL
  public let token: String

  public init(line: String) throws(HandoffError) {
    let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let mark = line.lastIndex(of: "#") else { throw .notALine }
    let token = String(line[line.index(after: mark)...])
    guard let server = URL(string: String(line[..<mark])), let host = server.host(),
      server.scheme == "https" || (server.scheme == "http" && Self.loopback.contains(host))
    else {
      throw .notAServer
    }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "agent", UUID(uuidString: String(parts[1])) != nil,
      !parts[2].isEmpty
    else {
      throw .notAToken
    }
    self.server = server
    self.token = token
  }

  /// The hosts a token may go to over plain HTTP: this Mac's own, where the local Worker runs.
  private static let loopback: Set<String> = ["127.0.0.1", "localhost", "::1"]
}

public enum HandoffError: LocalizedError, Equatable {
  case notALine
  case notAServer
  case notAToken

  public var errorDescription: String? {
    switch self {
    case .notALine:
      "iPhone が承認のあとに出した 1 行ではありません。「コピー」で写した行を、そのまま貼り付けてください。"
    case .notAServer:
      "行の「#」より前が、サーバーの https の URL ではありません。iPhone が出した行を、そのまま貼り付けてください。"
    case .notAToken:
      "行の「#」より後ろが、エージェントのトークン（agent. で始まるもの）ではありません。iPhone が出した行を、そのまま貼り付けてください。"
    }
  }
}
