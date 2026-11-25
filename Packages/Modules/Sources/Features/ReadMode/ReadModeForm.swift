import SwiftUI

/// A writing as the 「AI に読ませない」 list shows it.
struct ExcludableWriting: Identifiable, Equatable {
  let id: UUID
  let title: String
}

/// The read-mode settings (#26): whether read mode is on and until when, the agents approved, and
/// the writings no agent reads. Each change is handed to the closure for it.
struct ReadModeForm: View {
  /// When read mode ends; nil while off.
  let until: Date?
  let agents: [AgentRow]
  let writings: [ExcludableWriting]
  let excluded: Set<UUID>
  /// What the last copies sent did, said for a person.
  var sent: String?
  var working = false
  /// The time the end of read mode is first offered from.
  let now: Date
  let turnOn: (Date) -> Void
  let turnOff: () -> Void
  let approve: () -> Void
  let revoke: (UUID) -> Void
  let setExcluded: (UUID, Bool) -> Void
  @State private var chosenEnd: Date?
  @State private var revoking: AgentRow?

  var body: some View {
    Form {
      modeSection
      agentSection
      writingSection
    }
    .disabled(working)
    .confirmationDialog(
      "エージェントを取り消しますか？",
      isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
      titleVisibility: .visible, presenting: revoking
    ) { agent in
      Button("取り消す", role: .destructive) { revoke(agent.id) }
    } message: { _ in
      Text("このエージェントはもう文書を読めません。もう一度読ませるには、エージェントに新しい鍵を作らせて承認し直します。")
    }
  }

  @ViewBuilder private var modeSection: some View {
    Section {
      if let until {
        LabeledContent("読み取りモード") {
          Text("\(until, format: .dateTime.month().day().hour().minute()) まで")
        }
        Button("オフにする", role: .destructive, action: turnOff)
      } else {
        DatePicker(
          "終わる時刻",
          selection: Binding(get: { chosenEnd ?? Self.defaultEnd(now) }, set: { chosenEnd = $0 }),
          in: now...)
        Button("オンにする") { turnOn(chosenEnd ?? Self.defaultEnd(now)) }
          .disabled(!agents.contains { $0.approved && !$0.revoked })
      }
      if let sent {
        Text(verbatim: sent)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("読み取りモード")
    } footer: {
      Text(
        "オンの間、承認したエージェントが、「AI に読ませない」にしていない文書を読めます。終わる時刻を過ぎると読めなくなり、サーバーは預かった鍵を消します。"
      )
    }
  }

  @ViewBuilder private var agentSection: some View {
    Section {
      ForEach(agents) { agent in
        LabeledContent {
          Text(Self.state(of: agent))
        } label: {
          Text("エージェント \(agent.code ?? "----")")
            .font(.body.monospaced())
        }
        .swipeActions {
          if !agent.revoked {
            Button("取り消す", role: .destructive) { revoking = agent }
          }
        }
        .accessibilityActions {
          if !agent.revoked {
            Button("取り消す") { revoking = agent }
          }
        }
      }
      Button("エージェントを承認…", action: approve)
    } header: {
      Text("エージェント")
    } footer: {
      Text("エージェントが見せるコードを、カメラで読むか入力して承認します。左にスワイプすると取り消せます。")
    }
  }

  @ViewBuilder private var writingSection: some View {
    if !writings.isEmpty {
      Section {
        ForEach(writings) { writing in
          Toggle(
            isOn: Binding(
              get: { excluded.contains(writing.id) }, set: { setExcluded(writing.id, $0) })
          ) {
            if writing.title.isEmpty {
              Text("無題").foregroundStyle(.secondary)
            } else {
              Text(verbatim: writing.title)
            }
          }
        }
      } header: {
        Text("AI に読ませない")
      } footer: {
        Text("オンにした文書は、読み取りモードの間もエージェントに渡しません。")
      }
    }
  }

  /// A day after `now`, on the minute.
  static func defaultEnd(_ now: Date) -> Date {
    let end = now.addingTimeInterval(24 * 60 * 60)
    return Date(timeIntervalSince1970: (end.timeIntervalSince1970 / 60).rounded(.down) * 60)
  }

  private static func state(of agent: AgentRow) -> LocalizedStringKey {
    if agent.revoked { return "取り消し済み" }
    return agent.approved ? "承認済み" : "承認されていません"
  }
}
