import SwiftUI
internal import Sync

/// The settings' 「同期」 page: the server's URL, syncing now, and the own key. With no own key on
/// the device, it offers to type the recovery key or, on the first device, to make the key.
struct SyncSettingsView: View {
  let sync: WritingSync
  let syncNow: () async -> Void
  @AppStorage(WritingSync.serverURLKey) private var serverURL = ""
  @State private var confirmingNewKey = false
  @State private var madeKey: RecoveryKey?
  @State private var problem: String?

  var body: some View {
    Form {
      Section {
        TextField("https://", text: $serverURL)
          .keyboardType(.URL)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      } header: {
        Text("サーバー")
      } footer: {
        if case .failure(let error) = Result(catching: { try ServerURL(text: serverURL) }) {
          Text(verbatim: error.localizedDescription).foregroundStyle(.red)
        } else {
          Text("文書は暗号化してから送られ、サーバーには中身が分かりません。空のままなら、文書はこの端末にだけ置かれます。")
        }
      }

      if let ownKey = sync.ownKey {
        Section {
          LabeledContent("最後の同期", value: statusText)
          Button("今すぐ同期") {
            Task { await syncNow() }
          }
          .disabled((try? ServerURL(text: serverURL)) == nil || sync.status == .syncing)
        } header: {
          Text("同期")
        } footer: {
          if case .failed(let message) = sync.status {
            Text(verbatim: message).foregroundStyle(.red)
          }
        }
        Section {
          NavigationLink("リカバリーキーを表示") {
            RecoveryKeyView(recoveryKey: RecoveryKey(ownKey))
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("サーバーに置く値")
            Text(verbatim: ownKey.accessTokenSHA256)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .accessibilityIdentifier("accessTokenSHA256")
          }
        } header: {
          Text("自分の鍵")
        } footer: {
          Text("サーバーの秘密の値 ACCESS_TOKEN_SHA256 に、この値を置きます。鍵そのものではないので、知られても文書は開けません。")
        }
      } else {
        Section {
          NavigationLink("リカバリーキーを入力") {
            RecoveryKeyEntryView(sync: sync)
          }
          Button("新しい鍵を作る") { confirmingNewKey = true }
        } header: {
          Text("自分の鍵")
        } footer: {
          if let keyProblem = sync.keyProblem {
            Text(verbatim: keyProblem).foregroundStyle(.red)
          } else {
            Text("この端末にはまだ自分の鍵がありません。ほかの端末で同期しているなら、iCloud キーチェーンで鍵が届くのを待つか、リカバリーキーを入力してください。")
          }
        }
      }
    }
    .navigationTitle("同期")
    .navigationBarTitleDisplayMode(.inline)
    .confirmationDialog(
      "新しい鍵を作りますか？", isPresented: $confirmingNewKey, titleVisibility: .visible
    ) {
      Button("作る") { makeKey() }
    } message: {
      Text("ほかの端末で同期を使っていないときだけ作ってください。ほかの端末の文書は、この鍵では開けません。")
    }
    .navigationDestination(
      isPresented: Binding(get: { madeKey != nil }, set: { if !$0 { madeKey = nil } })
    ) {
      if let madeKey {
        RecoveryKeyView(recoveryKey: madeKey)
      }
    }
    .alert(
      "自分の鍵を作れませんでした",
      isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })
    ) {
    } message: {
      Text(verbatim: problem ?? "")
    }
    .onAppear { sync.loadOwnKey() }
  }

  private var statusText: String {
    switch sync.status {
    case .notYet: "まだ"
    case .syncing: "同期しています…"
    case .synced(let date): date.formatted(date: .abbreviated, time: .shortened)
    case .failed: "できませんでした"
    }
  }

  private func makeKey() {
    do {
      madeKey = try sync.makeOwnKey()
    } catch {
      problem = (error as? any LocalizedError)?.errorDescription ?? "キーチェーンを使えませんでした。"
    }
  }
}

/// The recovery key, set in groups for a person to write down.
struct RecoveryKeyView: View {
  let recoveryKey: RecoveryKey

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
          "すべての端末をなくしたとき、このキーを入力すると自分の鍵が戻り、文書を開けるようになります。紙に書き留めて、人に見られない場所にしまってください。このキーはサーバーには置かれません。"
        )
      }
    }
    .navigationTitle("リカバリーキー")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// Two groups of 4 to a line.
  private var lines: String {
    let groups = recoveryKey.text.split(separator: "-")
    return stride(from: 0, to: groups.count, by: 2)
      .map { groups[$0..<min($0 + 2, groups.count)].joined(separator: "-") }
      .joined(separator: "\n")
  }
}

/// Where the recovery key is typed to bring the own key back to this device.
struct RecoveryKeyEntryView: View {
  let sync: WritingSync
  @State private var text = ""
  @State private var problem: String?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      Section {
        TextField("XXXX-XXXX-XXXX-…", text: $text, axis: .vertical)
          .font(.body.monospaced())
          .lineLimit(3...8)
          .textInputAutocapitalization(.characters)
          .autocorrectionDisabled()
      } footer: {
        if let problem {
          Text(verbatim: problem).foregroundStyle(.red)
        } else {
          Text("書き留めておいた 56 文字を入力します。ハイフンや空白はあってもなくてもかまいません。")
        }
      }
      Section {
        Button("自分の鍵を戻す") { restore() }
          .disabled(text.isEmpty)
      }
    }
    .navigationTitle("リカバリーキーを入力")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func restore() {
    do {
      try sync.restoreOwnKey(from: text)
      dismiss()
    } catch {
      problem = (error as? any LocalizedError)?.errorDescription ?? "キーチェーンを使えませんでした。"
    }
  }
}
