import SwiftUI

public struct RootView: View {
  private let fonts: FontLibrary
  private let account: AccountModel?
  @State private var library: WritingLibrary
  /// Nil where there is no account to sync with.
  @State private var sync: WritingSync?
  @Environment(\.scenePhase) private var scenePhase
  @State private var path: [Writing.ID] = []
  @State private var settings = WritingBodySettings()
  @State private var photos = WritingPhotos()
  @State private var opened = Date.now
  @State private var showingSettings = false
  /// Whether the launch check is done, after which coming to the front syncs.
  @State private var launchChecked = false
  /// The last save that failed, until it is shown and dismissed.
  @State private var unsaved: UnsavedWriting?
  @AppStorage(StoredBodySetting.key) private var defaultSetting = StoredBodySetting.standard
  @AppStorage(ColorTheme.key) private var theme = ColorTheme.system
  @AppStorage(StoredFontStack.key) private var fontStack = StoredFontStack.standard

  /// The writings kept on the device, set in the families of `fonts`, with the account a plan pays
  /// for when there is a server to sign in to, and synced with it while signed in.
  public init(fonts: FontLibrary, account: AccountModel?) {
    self.init(store: FileWritingStore.onDevice, fonts: fonts, account: account)
  }

  /// Opened on the writings in `path`, the last one on top.
  init(
    store: any WritingStore, fonts: FontLibrary = FontLibrary(server: nil),
    account: AccountModel? = nil, path: [Writing.ID] = []
  ) {
    self.fonts = fonts
    self.account = account
    let library = WritingLibrary(store: store)
    _library = State(initialValue: library)
    _sync = State(initialValue: account.map { WritingSync(account: $0, library: library) })
    _path = State(initialValue: path)
  }

  public var body: some View {
    NavigationStack(path: $path) {
      Group {
        switch library.writings {
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
        if case .success(let writings) = library.writings,
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
    .environment(\.fontFamilies, fontStack.stack.families(from: fonts.available))
    .task {
      library.load(seedingWhenEmpty: Writing.samples(now: opened, calendar: .current))
      await account?.checkAtLaunch()
      launchChecked = true
      await sync?.syncNow()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, launchChecked else { return }
      Task { await sync?.syncNow() }
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(fonts: fonts)
        .environment(\.account, account)
        .environment(\.writingSync, sync)
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
    do {
      guard try library.edit(id, at: .now, change) else { return }
    } catch {
      unsaved = UnsavedWriting(reason: error)
    }
    sync?.edited()
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
  RootView(fonts: FontLibrary(server: nil), account: nil)
}
