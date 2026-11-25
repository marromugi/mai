import SwiftUI

extension EnvironmentValues {
  /// The writings on the device, for the 「AI に読ませない」 list.
  @Entry var writingLibrary: WritingLibrary?
}

/// The settings' row that opens the read-mode page, while signed in with the own key.
struct ReadModeSection: View {
  let account: AccountModel

  var body: some View {
    Section {
      NavigationLink("AI に読ませる") { ReadModePage(account: account) }
    } footer: {
      Text("期間を決めて、承認した AI のエージェントに文書を読ませます。")
    }
  }
}

/// The read-mode page of the session the account has when it opens.
private struct ReadModePage: View {
  let account: AccountModel
  @Environment(\.writingLibrary) private var library
  @State private var model: ReadModeModel?

  var body: some View {
    Group {
      if let model {
        ReadModeSettingsView(model: model, library: library)
          .id(ObjectIdentifier(model))
      } else {
        ContentUnavailableView(
          "サインインしていません", systemImage: "person.crop.circle.badge.exclamationmark",
          description: Text("読み取りモードは、同期のアカウントにサインインしているときに使えます。"))
      }
    }
    // A sign-out or another sign-in while the page is open brings another session.
    .task(id: account.phase) {
      model = account.readMode().map(ReadModeModel.init)
    }
  }
}

/// The read-mode page of the settings, for `model`, listing the writings of `library` to exclude.
struct ReadModeSettingsView: View {
  let model: ReadModeModel
  let library: WritingLibrary?
  @State private var approving = false

  var body: some View {
    Group {
      if model.loaded {
        ReadModeForm(
          until: model.until, agents: model.agents, writings: writings, excluded: model.excluded,
          sent: model.sent, working: model.working, now: .now,
          turnOn: { until in Task { await model.turnOn(until: until) } },
          turnOff: { Task { await model.turnOff() } },
          approve: { approving = true },
          revoke: { id in Task { await model.revoke(id) } },
          setExcluded: { id, excluding in Task { await model.setExcluded(id, excluding) } })
      } else if model.unreadable, !model.working {
        ContentUnavailableView {
          Label("読み込めませんでした", systemImage: "exclamationmark.triangle")
        } actions: {
          Button("もう一度読み込む") { Task { await model.load() } }
        }
      } else {
        ProgressView()
      }
    }
    .navigationTitle("AI に読ませる")
    .navigationBarTitleDisplayMode(.inline)
    .task { await model.load() }
    .refreshable { await model.load() }
    .sheet(isPresented: $approving) {
      NavigationStack {
        AgentApprovalView(approve: model.approve(code:))
      }
    }
    .alert(
      "読み取りモード",
      isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })
    ) {
    } message: {
      Text(verbatim: model.problem ?? "")
    }
  }

  /// The writings that sync, newest first; the samples stay on the device.
  private var writings: [ExcludableWriting] {
    guard case .success(let all) = library?.writings else { return [] }
    return all.filter { !$0.id.isSample }.sorted { $0.updated > $1.updated }.map {
      ExcludableWriting(id: $0.id, title: $0.title)
    }
  }
}
