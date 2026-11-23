import SwiftUI

public struct RootView: View {
  private let store: any WritingStore
  private let fonts: FontLibrary
  /// Nil until the store has been read.
  @State private var writings: Result<[Writing], any Error>?
  @State private var path: [Writing.ID] = []
  @State private var settings = WritingBodySettings()
  @State private var photos = WritingPhotos()
  @State private var opened = Date.now
  @State private var showingSettings = false
  /// The last save that failed, until it is shown and dismissed.
  @State private var unsaved: UnsavedWriting?
  @AppStorage(StoredBodySetting.key) private var defaultSetting = StoredBodySetting.standard
  @AppStorage(ColorTheme.key) private var theme = ColorTheme.system
  @AppStorage(StoredFontStack.key) private var fontStack = StoredFontStack.standard

  /// The writings kept on the device, set in the families of `fonts`.
  public init(fonts: FontLibrary) {
    self.init(store: FileWritingStore.onDevice, fonts: fonts)
  }

  /// Opened on the writings in `path`, the last one on top.
  init(store: any WritingStore, fonts: FontLibrary = FontLibrary(server: nil), path: [Writing.ID] = []) {
    self.store = store
    self.fonts = fonts
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
            edit: { edit(id, $0) },
            photos: photos[id],
            setting: $settings[id, default: defaultSetting.setting],
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
    .environment(\.fontFamilies, fontStack.stack.families(from: fonts.available))
    .sheet(isPresented: $showingSettings) {
      SettingsView(fonts: fonts)
    }
    .alert(
      "保存できませんでした", isPresented: Binding(get: { unsaved != nil }, set: { _ in unsaved = nil }),
      presenting: unsaved
    ) { _ in
    } message: { unsaved in
      Text(verbatim: unsaved.localizedDescription)
    }
    .colorTheme(theme)
  }

  /// Makes `change` to the writing with `id` and saves it.
  private func edit(_ id: Writing.ID, _ change: (inout Writing) -> Void) {
    guard case .success(var all) = writings else { return }
    do {
      try store.edit(id, in: &all, at: .now, change)
    } catch {
      unsaved = UnsavedWriting(reason: error)
    }
    writings = .success(all)
  }
}

/// A save that failed: the edit is on screen but not on the device.
private struct UnsavedWriting: LocalizedError {
  let reason: any Error

  var errorDescription: String? {
    "この編集は画面に出ていますが、端末には残っていません。\(reason.localizedDescription)"
  }
}

#Preview {
  RootView(fonts: FontLibrary(server: nil))
}
