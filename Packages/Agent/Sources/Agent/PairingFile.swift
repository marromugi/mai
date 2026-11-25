import CryptoKit
import Foundation
import Sync

/// An agent paired with an account: its key, and the line the iPhone handed it.
public struct Pairing<Key: AgentPrivateKey>: Sendable {
  public let key: Key
  public let handoff: Handoff

  public init(key: Key, handoff: Handoff) {
    self.key = key
    self.handoff = handoff
  }
}

/// The one file `mai-mcp` keeps: the key as `AgentPrivateKey.kept` gives it, the Worker's URL, and
/// the token sealed to the key itself, so the file reads only where the key opens.
public struct PairingFile: Sendable {
  public let url: URL

  public init(directory: URL) {
    url = directory.appending(path: "pairing.json", directoryHint: .notDirectory)
  }

  /// In `MAI_MCP_HOME` when it is set, and otherwise in `~/Library/Application Support/mai-mcp`.
  public static func standard(environment: [String: String]) -> PairingFile {
    if let home = environment["MAI_MCP_HOME"], !home.isEmpty {
      return PairingFile(directory: URL(filePath: home, directoryHint: .isDirectory))
    }
    return PairingFile(directory: URL.applicationSupportDirectory.appending(path: "mai-mcp"))
  }

  /// The pairing kept, or nil before `mai-mcp pair`.
  public func read<Key: AgentPrivateKey>() throws(PairingFileError) -> Pairing<Key>? {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    } catch {
      throw .unreadable(url, error.localizedDescription)
    }
    do {
      let kept = try JSONDecoder().decode(Kept.self, from: data)
      let key = try Key(kept: kept.key)
      var recipient = try HPKE.Recipient(
        privateKey: key, ciphersuite: Self.suite, info: Self.info,
        encapsulatedKey: kept.token.prefix(Self.encapsulatedKey))
      let line = try recipient.open(kept.token.dropFirst(Self.encapsulatedKey))
      let handoff = try Handoff(
        line: "\(kept.server.absoluteString)#\(String(decoding: line, as: UTF8.self))")
      return Pairing(key: key, handoff: handoff)
    } catch {
      throw .unreadable(url, error.localizedDescription)
    }
  }

  /// Keeps `pairing` in place of any kept before, readable by this user alone.
  public func write<Key: AgentPrivateKey>(_ pairing: Pairing<Key>) throws(PairingFileError) {
    do {
      var sender = try HPKE.Sender(
        recipientKey: pairing.key.publicKey, ciphersuite: Self.suite, info: Self.info)
      let sealed = try sender.seal(Data(pairing.handoff.token.utf8))
      let kept = Kept(
        key: pairing.key.kept, server: pairing.handoff.server,
        token: sender.encapsulatedKey + sealed)
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      try JSONEncoder().encode(kept).write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
      throw .unwritable(url, error.localizedDescription)
    }
  }

  /// Removes the pairing; false when there was none.
  public func remove() throws(PairingFileError) -> Bool {
    do {
      let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type]
      guard type as? FileAttributeType == .typeRegular else {
        throw CocoaError(.fileWriteUnknown)
      }
      try FileManager.default.removeItem(at: url)
      return true
    } catch CocoaError.fileReadNoSuchFile {
      return false
    } catch {
      throw .unwritable(url, error.localizedDescription)
    }
  }

  private struct Kept: Codable {
    let key: Data
    let server: URL
    /// The token sealed to the key: HPKE's encapsulated key (65 bytes), then the sealed token.
    let token: Data
  }

  private static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
  private static let info = Data("mai-mcp token 1".utf8)
  private static let encapsulatedKey = 65
}

extension PairingFile {
  /// Keeps `key` paired by the handoff `line`, once the token it carries reads from the server
  /// and, when the agent holds a copy, the copy opens with `key`. The pairing kept before stays
  /// until then, and its own line is refused: it belongs to the key kept before.
  public func pair<Key: AgentPrivateKey>(
    _ key: Key, line: String, transport: any HTTPTransport
  ) async throws(PairingProblem) -> Pairing<Key> {
    let handoff: Handoff
    do {
      handoff = try Handoff(line: line)
    } catch {
      throw .handoff(error)
    }
    let kept: Pairing<Key>? = try? read()
    guard kept?.handoff != handoff else { throw .lineOfThePairingKept }
    let server = AgentServer(url: handoff.server, token: handoff.token, transport: transport)
    do {
      if let first = try await server.list().first,
        let copy = try await server.copy(of: first.id), (try? copy.open(with: key)) == nil
      {
        throw PairingProblem.anotherKeysLine
      }
    } catch let problem as PairingProblem {
      throw problem
    } catch let error as ServerError {
      throw .server(error)
    } catch {
      preconditionFailure("Only the server's errors and the check above are thrown: \(error)")
    }
    let pairing = Pairing(key: key, handoff: handoff)
    do {
      try write(pairing)
    } catch {
      throw .file(error)
    }
    return pairing
  }
}

public enum PairingProblem: LocalizedError {
  case handoff(HandoffError)
  case lineOfThePairingKept
  case anotherKeysLine
  case server(ServerError)
  case file(PairingFileError)

  public var errorDescription: String? {
    switch self {
    case .handoff(let error): error.localizedDescription
    case .lineOfThePairingKept, .anotherKeysLine:
      "この行は前に承認したエージェントのもので、いま作った鍵のものではありません。iPhone でいまのコードを承認し、そのあとに出た行を貼り付けてください。"
    case .server(.refused(status: 401, _)):
      "サーバーがこのトークンを受け付けません。iPhone でいま承認したエージェントの行か確かめてください。"
    case .server(.unreachable):
      "サーバーにつながりませんでした。ネットワークを確かめて、同じ行をもう一度貼り付けてください。"
    case .server(let error): "サーバーで確かめられませんでした（\(error)）。"
    case .file(let error): error.localizedDescription
    }
  }
}

public enum PairingFileError: LocalizedError, Equatable {
  case unreadable(URL, String)
  case unwritable(URL, String)

  public var errorDescription: String? {
    switch self {
    case .unreadable(let url, let reason):
      "ペアリングのファイル \(url.path) が読めません（\(reason)）。別の Mac から写したものは読めません。`mai-mcp pair` でペアリングし直してください。"
    case .unwritable(let url, let reason):
      "ペアリングのファイル \(url.path) に書けません（\(reason)）。"
    }
  }
}
