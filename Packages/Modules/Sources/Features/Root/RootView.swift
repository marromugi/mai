import SwiftUI

public struct RootView: View {
  @State private var path: [WritingRow] = []
  @State private var settings = WritingBodySettings()
  @State private var opened: Date
  @State private var rows: [WritingRow]

  public init() {
    let now = Date.now
    _opened = State(initialValue: now)
    _rows = State(initialValue: WritingRow.samples(now: now, calendar: .current))
  }

  public var body: some View {
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
