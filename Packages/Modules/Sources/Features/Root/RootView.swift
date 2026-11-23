import SwiftUI

public struct RootView: View {
  @State private var path: [WritingRow] = []
  @State private var settings = WritingBodySettings()
  @State private var photos = WritingPhotos()
  @State private var opened = Date.now
  @State private var showingSettings = false
  @AppStorage(StoredBodySetting.key) private var defaultSetting = StoredBodySetting(.standard)

  public init() {}

  public var body: some View {
    let rows = WritingRow.samples(now: opened, calendar: .current)
    NavigationStack(path: $path) {
      // Every minute, so the wording keeps up with the clock while the list is on screen.
      TimelineView(.periodic(from: opened, by: 60)) { context in
        WritingListView(
          rows: rows, now: context.date, open: { path.append($0) },
          openSettings: { showingSettings = true })
      }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: WritingRow.self) { row in
        WritingView(
          writing: .sample(titled: row.title),
          photos: photos[row.id],
          setting: $settings[row.id, default: defaultSetting.setting],
          camera: .device,
          photoTaken: { photos[row.id].append($0) })
      }
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView()
    }
  }
}

#Preview {
  RootView()
}
