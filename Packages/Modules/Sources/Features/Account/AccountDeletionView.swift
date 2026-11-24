import StoreKit
import SwiftUI

/// The page that deletes the account (App Review Guidelines 5.1.1(v)): what goes from the server
/// and what stays on the device, that the App Store subscription goes on, with 「購読を管理」, and
/// 「アカウントを削除」, asked once more before `deleteAccount` runs. The page closes once
/// `deleteAccount` answers that the device is signed out; what went wrong is said by the settings'
/// alert.
struct AccountDeletionView: View {
  let deleteAccount: () async -> Bool
  @State private var confirming = false
  @State private var deleting = false
  @State private var managing = false
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
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
      } header: {
        Text("残るもの")
      } footer: {
        Text("削除すると、この端末はサインインしていない状態に戻り、同期をやめます。ほかの端末も同期をやめ、文書はそれぞれの端末に残ります。")
      }
      Section {
        Button("購読を管理") { managing = true }
          .manageSubscriptionsSheet(isPresented: $managing)
      } header: {
        Text("購読")
      } footer: {
        Text("アカウントを削除しても、App Store の購読は止まりません。購読は「購読を管理」か、設定の App Store から解約してください。")
      }
      Section {
        Button(role: .destructive) {
          confirming = true
        } label: {
          HStack {
            Text("アカウントを削除")
            if deleting {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(deleting)
        .confirmationDialog(
          "アカウントを削除しますか？", isPresented: $confirming, titleVisibility: .visible
        ) {
          Button("削除", role: .destructive) {
            deleting = true
            Task {
              let signedOut = await deleteAccount()
              deleting = false
              if signedOut {
                dismiss()
              }
            }
          }
        } message: {
          Text("サーバーの文書と写真、読み取りモードの写しが消えます。元に戻せません。")
        }
      }
    }
    .navigationTitle("アカウントを削除")
    .navigationBarTitleDisplayMode(.inline)
  }
}
