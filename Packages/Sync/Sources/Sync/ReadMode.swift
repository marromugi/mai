import Foundation
import Synchronization

/// The read-mode settings as a device read them from the server: `view[d]` of `Specs/ReadMode`.
/// A device reads them just before it wraps; whatever changed since, the server refuses.
public struct ReadModeView: Sendable, Equatable {
  /// When read mode ends; nil when it is off.
  public var until: Date?
  public var excluded: Set<UUID>
  public var agents: [ServerAgent]

  public init(until: Date?, excluded: Set<UUID>, agents: [ServerAgent]) {
    self.until = until
    self.excluded = excluded
    self.agents = agents
  }

  /// The agents a writing key may be wrapped for (`KeyIsTrusted`): those whose key is an agent's
  /// key, signed with `ownKey` by a device of the account, and not revoked.
  public func trustedAgents(_ ownKey: OwnKey) -> [(id: UUID, key: AgentKey)] {
    agents.compactMap { agent in
      guard !agent.revoked, let key = agent.key, ownKey.approved(key, signature: agent.signature)
      else { return nil }
      return (agent.id, key)
    }
  }

  /// The copies a device sends of `writings` (`DeviceWraps`): each one's key wrapped for each
  /// trusted agent, while read mode is on and the writing isn't excluded. Whether it is on is
  /// the server's answer, by its clock: the device's clock decides nothing (`IsOn(s.mode, clock[d])`
  /// of `DeviceWraps` holds whenever the server says it is on, as no device's clock is ahead of it).
  func copies(of writings: [KeyedRevision], ownKey: OwnKey) -> [CopyToSend] {
    guard until != nil else { return [] }
    let agents = trustedAgents(ownKey)
    return writings.filter { !excluded.contains($0.id) }.flatMap { writing in
      agents.map { agent in
        CopyToSend(
          writing: writing.id, agent: agent.id, revision: writing.revision,
          wrapped: agent.key.wrap(writing.key, of: writing.id, at: writing.revision))
      }
    }
  }
}

/// A writing at a revision the server holds, with the key its contents were sealed with there.
struct KeyedRevision: Sendable {
  let id: UUID
  let revision: Revision
  let key: WritingKey
}

/// What one sending of copies did.
public struct CopiesSent: Sendable, Equatable {
  /// Copies the server kept.
  public var kept = 0
  /// Copies the server refused, by why.
  public var refused: [CopyRefusal: Int] = [:]

  public init() {}
}

/// Read mode from this device (#26): approving and revoking agents, turning read mode on and off,
/// excluding writings, and sending the copies of the writings the sync put on the server.
///
/// The writing keys come from the sync's state file (`Synchronizer`), which keeps the key of each
/// writing at the revision the server last had from or gave this device. For a writing synced
/// before keys were kept there, the server's save is read and opened for its key. The writings
/// whose copies failed to go are kept beside it and sent with the next ones.
public struct ReadMode: Sendable {
  let server: ReadModeServer
  let ownKey: OwnKey
  let state: SyncState
  let owed: OwedCopies

  public init(server: ReadModeServer, ownKey: OwnKey, stateFile: URL) {
    self.server = server
    self.ownKey = ownKey
    state = SyncState(file: stateFile)
    owed = OwedCopies(beside: stateFile)
  }

  /// The settings as the server holds them now.
  public func view() async throws(ServerError) -> ReadModeView {
    async let until = server.readMode()
    async let excluded = server.exclusions()
    async let agents = server.agents()
    do {
      return try await ReadModeView(until: until, excluded: excluded, agents: agents)
    } catch let error as ServerError {
      throw error
    } catch {
      preconditionFailure("The server's calls throw only ServerError: \(error)")
    }
  }

  /// Approves the agent whose pairing code is `agent`: signs its key with the own key and puts it
  /// on the server. Nil when the server refuses it (`ReadModeServer.approve`).
  public func approve(_ agent: AgentKey) async throws(ServerError) -> ApprovedAgent? {
    try await server.approve(agent, signature: ownKey.signature(approving: agent))
  }

  /// The line the agent is handed once approved: `<server URL>#<token>` (`Server/README.md`,
  /// 「エージェントの側」).
  public func handoff(_ approved: ApprovedAgent) -> String {
    "\(server.url.absoluteString)#\(approved.token)"
  }

  /// The agents in `view` a device of the account signed, revoked ones included.
  public func approvedAgents(in view: ReadModeView) -> Set<UUID> {
    Set(
      view.agents.filter { agent in
        agent.key.map { ownKey.approved($0, signature: agent.signature) } ?? false
      }.map(\.id))
  }

  public func revoke(_ agent: UUID) async throws(ServerError) -> Bool {
    try await server.revoke(agent)
  }

  /// Turns read mode on until `until`, then sends a copy of every writing on the server that isn't
  /// excluded, for every trusted agent: those this device synced with the key it kept, and the
  /// rest, synced by another device or before keys were kept, read from the server for theirs.
  public func turnOn(until: Date) async throws -> CopiesSent {
    _ = try await server.turnOn(until: until)
    return try await send(of: nil, in: view()).sent
  }

  public func turnOff() async throws(ServerError) {
    try await server.turnOff()
  }

  public func exclude(_ writing: UUID) async throws(ServerError) {
    try await server.exclude(writing)
  }

  /// Takes the exclusion of `writing` off and, while read mode is on, sends its copies.
  public func include(_ writing: UUID) async throws -> CopiesSent {
    try await server.include(writing)
    return try await sendCopies(of: [writing])
  }

  /// Sends the copies of `writings` at the revisions the sync last put on the server or took from
  /// it, as after a sync sent them, with those still owed from before: whose sending failed, or
  /// which the server refused for another read mode than the one read. While read mode is off,
  /// asks only that, and owes nothing: turning it on sends every writing.
  public func sendCopies(of writings: Set<UUID>) async throws -> CopiesSent {
    let all = writings.union(owed.load())
    guard !all.isEmpty else { return CopiesSent() }
    do {
      guard let until = try await server.readMode() else {
        owed.settle(all, owing: [])
        return CopiesSent()
      }
      async let excluded = server.exclusions()
      async let agents = server.agents()
      let (sent, refusedForMode) = try await send(
        of: all, in: ReadModeView(until: until, excluded: excluded, agents: agents))
      owed.settle(all, owing: refusedForMode)
      return sent
    } catch {
      owed.settle(all, owing: all)
      throw error
    }
  }

  /// Sends the copies `view` makes of `writings`, every writing on the server when nil. Answers
  /// what was sent, and the writings refused for another read mode.
  private func send(of writings: Set<UUID>?, in view: ReadModeView) async throws -> (
    sent: CopiesSent, refusedForMode: Set<UUID>
  ) {
    guard let until = view.until, !view.trustedAgents(ownKey).isEmpty else {
      return (CopiesSent(), [])
    }
    let synced = try state.load()
    // Each writing, with the server's revision when it was listed.
    let wanted: [(id: UUID, revision: Revision?)] =
      if let writings {
        writings.map { ($0, nil) }
      } else {
        try await writingServer.list().map { ($0.id, $0.revision) }
      }
    var keyed: [KeyedRevision] = []
    for (id, revision) in wanted where !view.excluded.contains(id) {
      if let entry = synced[id], let key = entry.writingKey,
        revision ?? entry.revision == entry.revision
      {
        keyed.append(KeyedRevision(id: id, revision: entry.revision, key: key))
      } else if let read = try await keyedFromServer(id) {
        keyed.append(read)
      }
    }
    let copies = view.copies(of: keyed, ownKey: ownKey)
    guard !copies.isEmpty else { return (CopiesSent(), []) }
    var sent = CopiesSent()
    var refusedForMode: Set<UUID> = []
    for (copy, refusal) in zip(copies, try await server.send(copies, expires: until)) {
      if let refusal {
        sent.refused[refusal, default: 0] += 1
        if refusal == .readMode { refusedForMode.insert(copy.writing) }
      } else {
        sent.kept += 1
      }
    }
    return (sent, refusedForMode)
  }

  private var writingServer: WritingServer {
    WritingServer(url: server.url, token: server.token, transport: server.transport)
  }

  /// The server's save of the writing with `id` and its key, opened with the own key; nil when the
  /// server has none, or has one this own key can't open, which no agent could read either.
  private func keyedFromServer(_ id: UUID) async throws -> KeyedRevision? {
    guard let (envelope, revision) = try await writingServer.read(id) else { return nil }
    guard envelope.id == id else {
      throw ServerError.unexpectedAnswer(
        "the server gave writing \(envelope.id.uuidString) for \(id.uuidString)")
    }
    do {
      return KeyedRevision(id: id, revision: revision, key: try ownKey.openWithKey(envelope).key)
    } catch {
      syncLogger.error(
        "A writing on the server wasn't copied, as the own key can't open it: \(error)")
      return nil
    }
  }
}

/// The writings whose copies are owed: their sending failed, or the server refused them for
/// another read mode than the one read. Every device's read mode of one account shares the file,
/// so each change is made under one lock, from what the file holds then.
struct OwedCopies {
  let file: URL
  private static let lock = Mutex(())

  /// Kept beside the sync's `stateFile`.
  init(beside stateFile: URL) {
    file = stateFile.deletingPathExtension().appendingPathExtension("copies.json")
  }

  func load() -> Set<UUID> {
    Self.lock.withLock { _ in read() }
  }

  /// Takes `sent` off what is owed, then owes `owing` again.
  func settle(_ sent: Set<UUID>, owing: Set<UUID>) {
    Self.lock.withLock { _ in
      write(read().subtracting(sent).union(owing))
    }
  }

  /// Owes nothing.
  func clear() {
    Self.lock.withLock { _ in write([]) }
  }

  /// What the file holds; none when it can't be read, which leaves those copies to the next save
  /// of each writing.
  private func read() -> Set<UUID> {
    do {
      return try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: file))
    } catch CocoaError.fileReadNoSuchFile {
      return []
    } catch {
      syncLogger.error("The owed read-mode copies couldn't be read, and are dropped: \(error)")
      return []
    }
  }

  private func write(_ writings: Set<UUID>) {
    do {
      if writings.isEmpty {
        try FileManager.default.removeItem(at: file)
      } else {
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(writings).write(to: file, options: .atomic)
      }
    } catch CocoaError.fileNoSuchFile {
      // Owed nothing already.
    } catch {
      syncLogger.error("The owed read-mode copies couldn't be kept: \(error)")
    }
  }
}
