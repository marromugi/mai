import SwiftUI

/// The page for when no device holds the own key and its recovery key is lost too: the server's
/// writings can't be opened by anyone, so they are deleted and the account starts over with a new
/// own key. What goes and what stays, then 「サーバーの文書を消してやり直す」, asked once more
/// before `startOver` runs. The page closes once `startOver` answers that the own key no longer
/// needs bringing back; what went wrong is said by the settings' alert.
struct StartOverView: View {
  let startOver: () async -> Bool
  @State private var confirming = false
  @State private var starting = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      Section {
      } footer: {
        Text(
          "自分の鍵がどの端末にもなく、リカバリーキーもなくしたときは、サーバーの文書を誰も開けません。開けない文書を消して、新しい自分の鍵で最初からやり直せます。"
        )
      }
      Section {
        Label("サーバーの文書", systemImage: "doc.text")
        Label("サーバーの写真", systemImage: "photo")
        Label("読み取りモードの写し", systemImage: "eye")
      } header: {
        Text("サーバーから消えるもの")
      } footer: {
        Text("消したものは、元に戻せません。")
      }
      Section {
        Label("この端末の文書", systemImage: "iphone")
        Label("アカウントと購読", systemImage: "person.crop.circle")
      } header: {
        Text("残るもの")
      } footer: {
        Text(
          "この端末の文書は、新しい自分の鍵で暗号化して送り直します。新しいリカバリーキーを書き留めてください。ほかの端末はサインアウトし、サインインし直すと新しいリカバリーキーを求めます。"
        )
      }
      Section {
        Button(role: .destructive) {
          confirming = true
        } label: {
          HStack {
            Text("サーバーの文書を消してやり直す")
            if starting {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(starting)
        .confirmationDialog(
          "サーバーの文書を消しますか？", isPresented: $confirming, titleVisibility: .visible
        ) {
          Button("消してやり直す", role: .destructive) {
            starting = true
            Task {
              let stillNeeded = await startOver()
              starting = false
              if !stillNeeded {
                dismiss()
              }
            }
          }
        } message: {
          Text("サーバーの文書と写真、読み取りモードの写しが消え、新しい自分の鍵を作ります。元に戻せません。")
        }
      }
    }
    .navigationTitle("最初からやり直す")
    .navigationBarTitleDisplayMode(.inline)
  }
}
