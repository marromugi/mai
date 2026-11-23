import SwiftUI

/// The sheet a web address pasted with nothing selected opens: a title field, focused as it opens,
/// over the address. 「追加」 or Return hands `done` the title; 「キャンセル」 hands it nil.
struct LinkTitleSheet: View {
  let url: URL
  let done: (String?) -> Void
  @State private var title = ""
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("タイトル", text: $title)
            .focused($focused)
            .submitLabel(.done)
            .onSubmit { done(title) }
        } footer: {
          Text(verbatim: url.absoluteString)
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      .navigationTitle("リンク")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("キャンセル") { done(nil) }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("追加") { done(title) }
        }
      }
    }
    .presentationDetents([.medium])
    .onAppear { focused = true }
  }
}

#Preview {
  Text("").sheet(isPresented: .constant(true)) {
    if let url = URL(string: "https://example.com/bread") {
      LinkTitleSheet(url: url) { _ in }
    }
  }
}
