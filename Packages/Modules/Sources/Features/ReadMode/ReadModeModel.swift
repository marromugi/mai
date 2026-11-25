import Foundation
import Observation
internal import Sync
import os

/// Where the read-mode screens log what went wrong.
let readModeLogger = Logger(subsystem: "com.marromugi.mai", category: "read-mode")

/// An agent as the read-mode screen lists it.
struct AgentRow: Identifiable, Equatable {
  let id: UUID
  /// The first group of the agent's pairing code, which the agent shows too; nil when the server's
  /// key isn't an agent's key.
  let code: String?
  /// Whether a device of the account approved it, so its key is wrapped for.
  let approved: Bool
  let revoked: Bool
}

/// Read mode as the screens show it (#26): the agents, whether it is on and until when, and the
/// writings excluded from it, as the server last said; and the actions that change them.
@Observable final class ReadModeModel {
  @ObservationIgnored private let readMode: ReadMode
  /// When read mode ends; nil while off.
  private(set) var until: Date?
  private(set) var agents: [AgentRow] = []
  private(set) var excluded: Set<UUID> = []
  /// Whether the server's settings have been read.
  private(set) var loaded = false
  /// Whether the last read of the settings, before any was read, failed.
  private(set) var unreadable = false
  /// Whether an action is waiting on the server.
  private(set) var working = false
  /// What the last copies sent did, said for a person; nil before any.
  private(set) var sent: String?
  /// What went wrong, written for a person, until it is dismissed.
  var problem: String?

  init(readMode: ReadMode) {
    self.readMode = readMode
  }

  /// Reads the settings from the server.
  func load() async {
    working = true
    defer { working = false }
    do {
      try await read()
    } catch {
      readModeLogger.error("Read mode couldn't be read: \(error)")
      problem = Self.message(for: error)
    }
    unreadable = !loaded
  }

  /// Approves the agent whose pairing code is `code`, answering the line to hand it, or what went
  /// wrong, written for a person.
  func approve(code: String) async -> Result<String, ApprovalProblem> {
    let key: AgentKey
    do {
      key = try AgentKey(pairingCode: code)
    } catch {
      return .failure(ApprovalProblem(message: error.localizedDescription))
    }
    working = true
    defer { working = false }
    do {
      guard let approved = try await readMode.approve(key) else {
        return .failure(
          ApprovalProblem(
            message:
              "このエージェントは承認できません。同じ鍵のエージェントを前に承認したか、取り消していないエージェントが 10 あります。エージェントに新しい鍵を作らせるか、使っていないエージェントを取り消してください。"
          ))
      }
      await readAgain()
      return .success(readMode.handoff(approved))
    } catch {
      readModeLogger.error("An agent couldn't be approved: \(error)")
      return .failure(ApprovalProblem(message: Self.message(for: error)))
    }
  }

  func revoke(_ agent: UUID) async {
    await act { () async throws in
      _ = try await self.readMode.revoke(agent)
    }
  }

  /// Turns read mode on until `until`, sending the copies of the writings synced.
  func turnOn(until: Date) async {
    await act { () async throws in
      let copies = try await self.readMode.turnOn(until: until)
      self.sent = Self.said(copies)
    }
  }

  func turnOff() async {
    await act { () async throws in
      try await self.readMode.turnOff()
      self.sent = nil
    }
  }

  /// Excludes the writing with `id` (「AI に読ませない」) or takes its exclusion off.
  func setExcluded(_ id: UUID, _ excluding: Bool) async {
    await act { () async throws in
      if excluding {
        try await self.readMode.exclude(id)
      } else {
        _ = try await self.readMode.include(id)
      }
    }
  }

  private func read() async throws {
    let view = try await readMode.view()
    let approved = readMode.approvedAgents(in: view)
    until = view.until
    excluded = view.excluded
    agents = view.agents.map { agent in
      AgentRow(
        id: agent.id, code: agent.key.map { String($0.pairingCode.prefix(4)) },
        approved: approved.contains(agent.id), revoked: agent.revoked)
    }
    loaded = true
  }

  /// Runs `action`, then reads the settings again whether it went through or not, since a failure
  /// part way, such as turning on with the copies not sent, leaves the server changed.
  private func act(_ action: () async throws -> Void) async {
    working = true
    defer { working = false }
    do {
      try await action()
    } catch {
      readModeLogger.error("Read mode couldn't be changed: \(error)")
      problem = Self.message(for: error)
    }
    await readAgain()
  }

  /// Reads the settings, after a change; a failure is logged, and the page keeps what it showed.
  private func readAgain() async {
    do {
      try await read()
    } catch {
      readModeLogger.error("Read mode couldn't be read again: \(error)")
      if problem == nil {
        problem = Self.message(for: error)
      }
    }
  }

  /// What went wrong with read mode, for a person, by the kind of failure.
  static func message(for error: any Error) -> String {
    guard let error = error as? ServerError else {
      return "この端末の同期の記録が読めなかったため、読み取りモードを変えられませんでした。一度同期してから、もう一度お試しください。"
    }
    switch error {
    case .unreachable:
      return "サーバーにつながりませんでした。ネットワークを確かめて、もう一度お試しください。"
    case .refused(status: 400, _):
      return "終わる時刻がもう過ぎています。これから先の時刻を選んでください。"
    case .refused(status: 401, _):
      return "サインインが切れました。もう一度 Apple でサインインしてください。"
    case .refused(status: 402, _):
      return "プランの期限が切れているため、読み取りモードは変えられません。プランに入り直すと、また使えます。"
    case .limitReached:
      return "今日のリクエストの回数がプランの上限に達しました。日付が変わると（協定世界時の 0 時、日本時間の 9 時）また使えます。"
    case .refused(let status, _):
      return "サーバーが読み取りモードの変更を断りました（\(status)）。"
    case .unexpectedAnswer:
      return "サーバーの答えが読めませんでした。"
    }
  }

  /// What sending `copies` did, for a person.
  static func said(_ copies: CopiesSent) -> String {
    let refused = copies.refused.values.reduce(0, +)
    let kept = "\(copies.kept) 件の写しをエージェントあてに置きました。"
    guard refused > 0 else { return kept }
    return kept + "\(refused) 件は、ほかの端末で設定か文書が変わったため置いていません。"
  }
}

/// Why an agent wasn't approved, written for a person.
struct ApprovalProblem: Error, Equatable {
  let message: String
}
