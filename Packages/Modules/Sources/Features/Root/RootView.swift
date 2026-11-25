import SwiftUI
internal import Typesetting

public struct RootView: View {
  private let fonts: FontLibrary
  private let account: AccountModel?
  @State private var library: WritingLibrary
  /// Nil where there is no account to sync with.
  @State private var sync: WritingSync?
  @Environment(\.scenePhase) private var scenePhase
  @State private var path: [Writing.ID] = []
  @State private var settings = WritingBodySettings()
  @State private var photos: WritingPhotos
  @State private var opened = Date.now
  @State private var showingSettings = false
  /// Whether the launch check is done, after which coming to the front syncs.
  @State private var launchChecked = false
  /// The last save that failed, until it is shown and dismissed.
  @State private var unsaved: Unsaved?
  @AppStorage(StoredBodySetting.key) private var defaultSetting = StoredBodySetting.standard
  @AppStorage(ColorTheme.key) private var theme = ColorTheme.system
  @AppStorage(StoredFontStack.key) private var fontStack = StoredFontStack.standard

  /// The writings and their photos kept on the device, set in the families of `fonts`, with the
  /// account a plan pays for when there is a server to sign in to, and synced with it while signed
  /// in.
  public init(fonts: FontLibrary, account: AccountModel?) {
    self.init(
      store: FileWritingStore.onDevice, photoStore: .onDevice, fonts: fonts, account: account)
  }

  /// Opened on the writings in `path`, the last one on top.
  init(
    store: any WritingStore, photoStore: PhotoStore, fonts: FontLibrary = FontLibrary(server: nil),
    account: AccountModel? = nil, path: [Writing.ID] = []
  ) {
    self.fonts = fonts
    self.account = account
    _photos = State(initialValue: WritingPhotos(store: photoStore))
    let library = WritingLibrary(store: store)
    _library = State(initialValue: library)
    _sync = State(
      initialValue: account.map { WritingSync(account: $0, library: library, photos: photoStore) })
    _path = State(initialValue: path)
  }

  public var body: some View {
    NavigationStack(path: $path) {
      Group {
        switch library.rows {
        case nil:
          Color.clear
        case .failure(let error):
          ContentUnavailableView(
            "文書を読み込めませんでした", systemImage: "exclamationmark.triangle",
            description: Text(verbatim: error.localizedDescription))
        case .success(let rows):
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
        OpenWriting(
          id: id, library: library, photos: photos,
          setting: $settings[id, default: defaultSetting.setting],
          open: { path.append($0.id) }, edit: edit,
          photoTaken: { image in Task { await add(image, to: id) } })
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
      guard phase == .active else {
        Task { await library.saveNow() }
        return
      }
      guard launchChecked else { return }
      Task { await sync?.syncNow() }
    }
    .sheet(isPresented: $showingSettings) {
      SettingsView(fonts: fonts)
        .environment(\.account, account)
        .environment(\.writingSync, sync)
        .environment(\.writingLibrary, library)
    }
    .alert(
      "保存できませんでした",
      isPresented: Binding(get: { shownUnsaved != nil }, set: { _ in dismissUnsaved() }),
      presenting: shownUnsaved
    ) { _ in
    } message: { unsaved in
      Text(verbatim: unsaved.localizedDescription)
    }
    .colorTheme(theme)
  }

  /// The photo that wasn't kept, or else the edits the library couldn't save.
  private var shownUnsaved: Unsaved? {
    unsaved ?? library.unsaved.map(Unsaved.writing)
  }

  private func dismissUnsaved() {
    if unsaved != nil {
      unsaved = nil
    } else {
      library.dismissUnsaved()
    }
  }

  /// Makes `change` to the writing with `id`, which the library saves once edits rest.
  private func edit(_ id: Writing.ID, _ change: (inout Writing) -> Void) {
    guard library.edit(id, at: .now, change) else { return }
    sync?.edited()
  }

  /// Keeps `image` in the photo store, then adds it to the writing with `id`.
  private func add(_ image: UIImage, to id: Writing.ID) async {
    do {
      try await photos.add(image, to: id, edit: edit)
    } catch {
      photoLogger.error("A photo taken wasn't kept: \(error.reason)")
      unsaved = .photo(error)
    }
  }
}

/// The writing with `id` on its page, with its photos, while `library` holds it. Its own view, so
/// an edit updates the page and not the list under it.
struct OpenWriting: View {
  let id: Writing.ID
  let library: WritingLibrary
  let photos: WritingPhotos
  @Binding var setting: BodySetting
  let open: (Writing) -> Void
  let edit: (Writing.ID, (inout Writing) -> Void) -> Void
  let photoTaken: (UIImage) -> Void

  var body: some View {
    if case .success(let writings) = library.writings,
      let writing = writings.first(where: { $0.id == id })
    {
      ReadPhotos(ids: writing.photos, photos: photos) { read in
        WritingView(
          writing: writing,
          others: writings.filter { $0.id != id },
          open: open,
          edit: { edit(id, $0) },
          photos: read,
          setting: $setting,
          camera: .device,
          photoTaken: photoTaken)
      }
      // The page closing saves what was typed on it.
      .onDisappear {
        Task { await library.saveNow() }
      }
    }
  }
}

/// A save that failed.
private enum Unsaved: LocalizedError {
  /// The edit is on screen but not on the device.
  case writing(any Error)
  /// The photo taken isn't on the device, nor on the page.
  case photo(UnkeptPhoto)

  var errorDescription: String? {
    switch self {
    case .writing(let reason):
      "この編集は画面に出ていますが、端末には残っていません。\(reason.localizedDescription)"
    case .photo(let unkept):
      unkept.localizedDescription
    }
  }
}

#Preview {
  RootView(fonts: FontLibrary(server: nil), account: nil)
}
