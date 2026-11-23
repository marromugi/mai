import SwiftUI

public struct RootView: View {
  private let store: any WritingStore
  /// Nil until the store has been read.
  @State private var writings: Result<[Writing], any Error>?
  @State private var path: [Writing.ID] = []
  @State private var settings = WritingBodySettings()
  @State private var photos = WritingPhotos()
  @State private var opened = Date.now

  /// The writings kept on the device.
  public init() {
    self.init(store: FileWritingStore.onDevice)
  }

  /// Opened on the writings in `path`, the last one on top.
  init(store: any WritingStore, path: [Writing.ID] = []) {
    self.store = store
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
            WritingListView(rows: rows, now: context.date) { path.append($0.id) }
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
            photos: photos[id],
            setting: $settings[id],
            camera: .device,
            photoTaken: { photos[id].append($0) })
        }
      }
    }
    .task {
      writings = Result {
        try store.all(seedingWhenEmpty: Writing.samples(now: opened, calendar: .current))
      }
    }
  }
}

#Preview {
  RootView()
}
