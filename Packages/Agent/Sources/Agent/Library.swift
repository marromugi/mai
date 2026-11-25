import Foundation
import Sync

/// A writing the agent opened: what the device sealed (`Server/README.md`, 「エージェントの側」, 6),
/// less its photos, which the agent never gets.
public struct OpenedWriting: Sendable, Equatable {
  public let id: UUID
  public let title: String
  public let body: String
  public let links: [Link]
  public let updated: Date
  /// When the agent's copy expires: the end of read mode.
  public let expires: Date

  public struct Link: Sendable, Equatable {
    /// The part of the body the link is on.
    public let text: String
    public let url: URL
  }
}

/// The writings the agent can read now, and those whose copies it can't open.
public struct Shelf: Sendable, Equatable {
  /// Newest first.
  public let writings: [OpenedWriting]
  public let unopenable: [UUID]
}

/// A part of the body around a search's first hit in it.
public struct Match: Sendable, Equatable {
  public let writing: OpenedWriting
  /// Nil when only the title holds the words.
  public let excerpt: String?
}

/// The agent's reads. Every read lists the copies first, so nothing is served once read mode
/// is off or past its end. Opened writings stay in this process alone, never on disk.
public actor Library<Key: AgentPrivateKey> {
  private let server: AgentServer
  private let key: Key
  private var opened: [UUID: (revision: Revision, writing: OpenedWriting)] = [:]

  public init(server: AgentServer, key: Key) {
    self.server = server
    self.key = key
  }

  public func shelf() async throws(ServerError) -> Shelf {
    let listed = try await server.list()
    forget(all: listed)
    var writings: [OpenedWriting] = []
    var unopenable: [UUID] = []
    for entry in listed {
      switch try await open(entry) {
      case .opened(let writing): writings.append(writing)
      case .unopenable: unopenable.append(entry.id)
      case .gone: break
      }
    }
    return Shelf(
      writings: writings.sorted { $0.updated > $1.updated }, unopenable: unopenable.sorted())
  }

  /// The writing with `id`, or nil when the agent holds no copy of it now.
  public func writing(_ id: UUID) async throws(ServerError) -> Reading {
    let listed = try await server.list()
    forget(all: listed)
    guard let entry = listed.first(where: { $0.id == id }) else { return .gone }
    return try await open(entry)
  }

  /// The writings whose title or body holds `words`, ignoring case, width and accents.
  public func search(_ words: String) async throws(ServerError) -> (matches: [Match], of: Shelf) {
    let shelf = try await shelf()
    let options: String.CompareOptions = [
      .caseInsensitive, .widthInsensitive, .diacriticInsensitive,
    ]
    let matches = shelf.writings.compactMap { writing -> Match? in
      if let hit = writing.body.range(of: words, options: options) {
        return Match(writing: writing, excerpt: Self.excerpt(of: writing.body, around: hit))
      }
      return writing.title.range(of: words, options: options) == nil
        ? nil : Match(writing: writing, excerpt: nil)
    }
    return (matches, shelf)
  }

  public enum Reading: Sendable, Equatable {
    case opened(OpenedWriting)
    /// The copy is there, but the agent's key doesn't open it, or what opens isn't a writing.
    case unopenable
    /// The agent holds no copy of it now.
    case gone
  }

  private func open(_ entry: AgentListedWriting) async throws(ServerError) -> Reading {
    if let kept = opened[entry.id], kept.revision == entry.revision {
      return .opened(kept.writing)
    }
    let copy: AgentCopy?
    do {
      copy = try await server.copy(of: entry.id)
    } catch {
      guard case .unexpectedAnswer = error else { throw error }
      return .unopenable
    }
    guard let copy else { return .gone }
    guard let plain = try? copy.open(with: key),
      let contents = try? JSONDecoder().decode(Contents.self, from: plain.contents)
    else {
      return .unopenable
    }
    let writing = OpenedWriting(
      id: entry.id, title: contents.title, body: contents.body,
      links: contents.links(in: contents.body), updated: plain.updated, expires: entry.expires)
    opened[entry.id] = (entry.revision, writing)
    return .opened(writing)
  }

  /// Drops what was opened of writings no longer listed.
  private func forget(all listed: [AgentListedWriting]) {
    let ids = Set(listed.map(\.id))
    opened = opened.filter { ids.contains($0.key) }
  }

  private static var excerptReach: Int { 40 }

  private static func excerpt(of body: String, around hit: Range<String.Index>) -> String {
    let start =
      body.index(hit.lowerBound, offsetBy: -excerptReach, limitedBy: body.startIndex)
      ?? body.startIndex
    let end =
      body.index(hit.upperBound, offsetBy: excerptReach, limitedBy: body.endIndex) ?? body.endIndex
    return (start == body.startIndex ? "" : "…") + body[start..<end]
      + (end == body.endIndex ? "" : "…")
  }
}

/// What the device seals as a writing's contents; fields the agent doesn't use are skipped.
private struct Contents: Decodable {
  let title: String
  let body: String
  let savedLinks: [SavedLink]

  enum CodingKeys: String, CodingKey {
    case title, body, links
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    body = try container.decode(String.self, forKey: .body)
    savedLinks = (try? container.decodeIfPresent([SavedLink].self, forKey: .links)) ?? []
  }

  /// The links whose range, in UTF-16 offsets as the device keeps it, lies in `body`.
  func links(in body: String) -> [OpenedWriting.Link] {
    let utf16 = body.utf16
    return savedLinks.compactMap { link in
      guard let range = link.range, let url = link.url, range.count == 2, range[0] >= 0,
        range[0] < range[1], range[1] <= utf16.count
      else { return nil }
      let start = utf16.index(utf16.startIndex, offsetBy: range[0])
      let end = utf16.index(utf16.startIndex, offsetBy: range[1])
      guard let text = String(utf16[start..<end]) else { return nil }
      return OpenedWriting.Link(text: text, url: url)
    }
  }

  /// A link as the device keeps it; one of another shape is skipped.
  struct SavedLink: Decodable {
    let range: [Int]?
    let url: URL?

    enum CodingKeys: String, CodingKey {
      case range, url
    }

    init(from decoder: any Decoder) throws {
      let container = try? decoder.container(keyedBy: CodingKeys.self)
      range = try? container?.decode([Int].self, forKey: .range)
      url = try? container?.decode(URL.self, forKey: .url)
    }
  }
}
