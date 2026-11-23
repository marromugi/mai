import SwiftUI

public struct RootView: View {
  @State private var path: [WritingRow] = []
  @State private var settings = WritingBodySettings()
  @State private var opened = Date.now

  public init() {}

  public var body: some View {
    let rows = WritingRow.samples(now: opened, calendar: .current)
    NavigationStack(path: $path) {
      // Every minute, so the wording keeps up with the clock while the list is on screen.
      TimelineView(.periodic(from: opened, by: 60)) { context in
        WritingListView(rows: rows, now: context.date) { path.append($0) }
      }
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
