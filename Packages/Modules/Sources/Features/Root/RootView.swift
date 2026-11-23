import SwiftUI

public struct RootView: View {
  private let store: any WritingStore
  @State private var sync: WritingSync
  @AppStorage(WritingSync.serverURLKey) private var serverURL = ""
  @Environment(\.scenePhase) private var scenePhase
  /// Nil until the store has been read.
  @State private var writings: Result<[Writing], any Error>?
  @State private var path: [Writing.ID] = []
  @State private var settings = WritingBodySettings()
  @State private var photos = WritingPhotos()
  @State private var opened = Date.now
  @State private var showingSettings = false
  @AppStorage(StoredBodySetting.key) private var defaultSetting = StoredBodySetting.standard

  /// The writings kept on the device, synced with the server the settings name.
  public init() {
    self.init(store: FileWritingStore.onDevice)
  }

  /// Opened on the writings in `path`, the last one on top. `sync` defaults to the own key in
  /// iCloud Keychain, which nothing reads until a server's URL is set.
  init(store: any WritingStore, sync: WritingSync? = nil, path: [Writing.ID] = []) {
    self.store = store
    _sync = State(initialValue: sync ?? .onDevice(store: store))
    _path = State(initialValue: path)
  }

  public var body: some View {
    NavigationStack(path: $path) {
      Group {
        switch writings {
        case nil:
          Color.clear
        case .failure(let error):
          ContentUnavailableView(
            "文書を読み込めませんでした", systemImage: "exclamationmark.triangle",
            description: Text(verbatim: error.localizedDescription))
        case .success(let writings):
          let rows = writings.map(WritingRow.init)
          // Every minute, so the wording keeps up with the clock while the list is on screen.
          TimelineView(.periodic(from: opened, by: 60)) { context in
            WritingListView(
              rows: rows, now: context.date, open: { path.append($0.id) },
              openSettings: { showingSettings = true })
          }
        }
      }
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(for: Writing.ID.self) { id in
        if case .success(let writings) = writings,
          let writing = writings.first(where: { $0.id == id })
        {
          WritingView(
            writing: writing,
            others: writings.filter { $0.id != id },
            open: { path.append($0.id) },
            photos: photos[id],
            setting: $settings[id, default: defaultSetting.setting],
            camera: .device,
            photoTaken: { photos[id].append($0) })
        }
      }
    }
    .task {
      readWritings()
    }
    // Each time the app comes to the front, launch included.
    .task(id: scenePhase) {
      guard scenePhase == .active else { return }
      await syncNow()
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(sync: sync, syncNow: syncNow)
    }
  }

  private func readWritings() {
    writings = Result {
      try store.all(seedingWhenEmpty: Writing.samples(now: opened, calendar: .current))
    }
  }

  /// Syncs, then reads the store again for what the sync brought in.
  private func syncNow() async {
    if await sync.sync(serverURL: serverURL) {
      readWritings()
    }
  }
}

#Preview {
  RootView()
}
