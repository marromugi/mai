import Foundation

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
/// writing at the revision the server last had from or gave this device. A writing synced before
/// keys were kept there gets its copies once it is saved again.
public struct ReadMode: Sendable {
  let server: ReadModeServer
  let ownKey: OwnKey
  let state: SyncState

  public init(server: ReadModeServer, ownKey: OwnKey, stateFile: URL) {
    self.server = server
    self.ownKey = ownKey
    state = SyncState(file: stateFile)
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

  /// Turns read mode on until `until`, then sends a copy of every writing the device has synced
  /// and isn't excluded, for every trusted agent.
  public func turnOn(until: Date) async throws -> CopiesSent {
    _ = try await server.turnOn(until: until)
    return try await send(of: nil, in: view())
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
  /// it, as after a sync sent them. While read mode is off, asks only that.
  public func sendCopies(of writings: Set<UUID>) async throws -> CopiesSent {
    guard !writings.isEmpty else { return CopiesSent() }
    guard let until = try await server.readMode() else { return CopiesSent() }
    async let excluded = server.exclusions()
    async let agents = server.agents()
    return try await send(
      of: writings, in: ReadModeView(until: until, excluded: excluded, agents: agents))
  }

  /// Sends the copies `view` makes of `writings`, every synced one when nil.
  private func send(of writings: Set<UUID>?, in view: ReadModeView) async throws -> CopiesSent {
    guard let until = view.until else { return CopiesSent() }
    let synced = try state.load().compactMap { id, entry -> KeyedRevision? in
      guard writings?.contains(id) ?? true, let key = entry.writingKey else { return nil }
      return KeyedRevision(id: id, revision: entry.revision, key: key)
    }
    let copies = view.copies(of: synced, ownKey: ownKey)
    guard !copies.isEmpty else { return CopiesSent() }
    var sent = CopiesSent()
    for refusal in try await server.send(copies, expires: until) {
      if let refusal {
        sent.refused[refusal, default: 0] += 1
      } else {
        sent.kept += 1
      }
    }
    return sent
  }
}
