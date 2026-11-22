import SwiftUI

public struct RootView: View {
  @State private var path: [WritingRow] = []
  @State private var settings = WritingBodySettings()

  public init() {}

  public var body: some View {
    NavigationStack(path: $path) {
      WritingListView(rows: WritingRow.samples) { path.append($0) }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: WritingRow.self) { row in
          WritingView(
            writing: .sample(titled: row.title),
            setting: $settings[row.id])
        }
    }
  }
}

#Preview {
  RootView()
}
