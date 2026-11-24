import AuthenticationServices
import SwiftUI
internal import Sync

extension EnvironmentValues {
  /// The account a plan pays for; nil where there is no server to sign in to.
  @Entry var account: AccountModel?
  /// The sync of the writings with the account; nil where there is no server to sign in to.
  @Entry var writingSync: WritingSync?
}

/// Apple's 「Appleでサインイン」 button, which calls `action`.
struct AppleSignInButton: View {
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    AppleIDButton(style: colorScheme == .dark ? .white : .black, action: action)
      .id(colorScheme)
      .frame(height: 50)
      .accessibilityIdentifier("signInWithApple")
  }
}

private struct AppleIDButton: UIViewRepresentable {
  let style: ASAuthorizationAppleIDButton.Style
  let action: () -> Void

  func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
    let button = ASAuthorizationAppleIDButton(type: .signIn, style: style)
    button.cornerRadius = 25
    button.addTarget(
      context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
    return button
  }

  func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
    context.coordinator.action = action
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) {
      self.action = action
    }

    @objc func tapped() {
      action()
    }
  }
}

/// The settings' section for the account, under 「同期」: signing in once a plan is bought, the
/// recovery key when the own key isn't here, how the sync went with 「今すぐ同期」 while signed in,
/// and signing out. Nothing while signed out with no plan bought.
struct AccountRows: View {
  let phase: AccountPhase
  let canSignIn: Bool
  let signIn: () -> Void
  let signOut: () -> Void
  let restore: (String) async -> String?
  /// Nil where nothing syncs.
  var syncStatus: WritingSync.Status?
  var syncNow: () -> Void = {}
  @State private var confirmingSignOut = false

  var body: some View {
    if phase != .signedOut || canSignIn {
      Section {
        rows
      } footer: {
        Text(Self.footer(phase))
      }
    }
  }

  @ViewBuilder private var rows: some View {
    switch phase {
    case .signedOut:
      AppleSignInButton(action: signIn)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      if case .sessionEnded(let message) = syncStatus {
        Text(verbatim: message)
          .font(.footnote)
          .foregroundStyle(.red)
      }
    case .working:
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
    case .signedIn, .recoveryKeyNeeded:
      LabeledContent("Apple でサインイン", value: "サインイン中")
      if phase == .signedIn, let syncStatus {
        SyncRows(status: syncStatus, syncNow: syncNow)
      }
      if phase == .recoveryKeyNeeded {
        NavigationLink("リカバリーキーを入力") {
          RecoveryKeyEntryView(restore: restore)
        }
      }
      Button("サインアウト", role: .destructive) { confirmingSignOut = true }
        .confirmationDialog(
          "サインアウトしますか？", isPresented: $confirmingSignOut, titleVisibility: .visible
        ) {
          Button("サインアウト", role: .destructive, action: signOut)
        } message: {
          Text("この端末では同期をやめます。文書はこの端末に残ります。")
        }
    }
  }

  private static func footer(_ phase: AccountPhase) -> String {
    switch phase {
    case .signedOut, .working:
      "プランに入りました。Apple でサインインすると、同期のアカウントができます。"
    case .signedIn:
      "Apple でサインインしています。サインアウトしても、文書はこの端末に残ります。"
    case .recoveryKeyNeeded:
      "このアカウントの自分の鍵が、この端末にありません。プランに入ったときに書き留めたリカバリーキーを入力してください。"
    }
  }
}

/// How the last sync went, and 「今すぐ同期」.
private struct SyncRows: View {
  let status: WritingSync.Status
  let syncNow: () -> Void

  var body: some View {
    LabeledContent("同期") {
      switch status {
      case .notYet:
        Text("まだしていません")
      case .syncing:
        Text("同期しています…")
      case .synced(let date):
        Text("\(date, format: .dateTime.hour().minute()) に同期しました")
      case .failed, .stopped, .sessionEnded:
        Text("同期できませんでした")
      }
    }
    switch status {
    case .failed(let message), .stopped(let message), .sessionEnded(let message):
      Text(verbatim: message)
        .font(.footnote)
        .foregroundStyle(.red)
    case .notYet, .syncing, .synced:
      EmptyView()
    }
    Button("今すぐ同期", action: syncNow)
      .disabled(status == .syncing)
  }
}

/// The settings' section for `account`, with how `sync` went.
struct AccountSection: View {
  let account: AccountModel
  let sync: WritingSync?

  var body: some View {
    AccountRows(
      phase: account.phase, canSignIn: account.canSignIn,
      signIn: { Task { await account.signIn() } },
      signOut: { Task { await account.signOut() } },
      restore: { await account.restore(from: $0) },
      syncStatus: sync?.status,
      syncNow: { Task { await sync?.syncNow() } }
    )
    .task { await account.refresh() }
  }
}

/// The recovery key, set in groups for a person to write down, until `done`.
struct RecoveryKeyView: View {
  let recoveryKey: RecoveryKey
  let done: () -> Void

  var body: some View {
    Form {
      Section {
        Text(verbatim: lines)
          .font(.title3.monospaced())
          .speechSpellsOutCharacters()
          .accessibilityIdentifier("recoveryKey")
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity)
      } footer: {
        Text(
          "すべての端末をなくしたとき、このキーを入力すると自分の鍵が戻り、文書を開けるようになります。紙に書き留めて、人に見られない場所にしまってください。このキーはサーバーには置かれず、あとから作り直すこともできません。"
        )
      }
      Section {
        Button("書き留めました", action: done)
          .frame(maxWidth: .infinity)
      }
    }
    .navigationTitle("リカバリーキー")
    .navigationBarTitleDisplayMode(.inline)
    .interactiveDismissDisabled()
  }

  /// Two groups of 4 to a line.
  private var lines: String {
    let groups = recoveryKey.text.split(separator: "-")
    return stride(from: 0, to: groups.count, by: 2)
      .map { groups[$0..<min($0 + 2, groups.count)].joined(separator: "-") }
      .joined(separator: "\n")
  }
}

/// Where the recovery key is typed to bring the own key back to this device. `restore` answers
/// what went wrong, or nil once the key is back.
struct RecoveryKeyEntryView: View {
  let restore: (String) async -> String?
  @State private var text = ""
  @State private var problem: String?
  @State private var restoring = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      Section {
        TextField("XXXX-XXXX-XXXX-…", text: $text, axis: .vertical)
          .font(.body.monospaced())
          .lineLimit(3...8)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
          .accessibilityIdentifier("recoveryKeyEntry")
      } footer: {
        if let problem {
          Text(verbatim: problem).foregroundStyle(.red)
        } else {
          Text("書き留めておいた 56 文字を入力します。ハイフンや空白はあってもなくてもかまいません。")
        }
      }
      Section {
        Button("自分の鍵を戻す") {
          restoring = true
          Task {
            problem = await restore(text)
            restoring = false
            if problem == nil {
              dismiss()
            }
          }
        }
        .disabled(text.isEmpty || restoring)
      }
    }
    .navigationTitle("リカバリーキーを入力")
    .navigationBarTitleDisplayMode(.inline)
  }
}
