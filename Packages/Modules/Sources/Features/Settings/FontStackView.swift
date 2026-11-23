import SwiftUI
internal import Typesetting

/// The stack text is set in: a sample set in it, its families in order, which can be moved,
/// removed, fetched, and added to, and the bundled family last, which can't be moved or removed.
struct FontStackView: View {
  @Binding var stack: FontStack
  let fonts: FontLibrary
  @State private var adding = false

  var body: some View {
    List {
      Section("見本") {
        Text(body: Self.sample)
          .textStyle(.body)
          .padding(.vertical, 4)
      }
      Section {
        ForEach(stack.names, id: \.self) { name in
          FontStackRow(name: name, fonts: fonts)
        }
        .onMove { stack.names.move(fromOffsets: $0, toOffset: $1) }
        .onDelete { stack.names.remove(atOffsets: $0) }
        if !stack.names.contains(FontFamily.notoSansJP.name) {
          FontStackRow(name: FontFamily.notoSansJP.name, fonts: fonts, note: "標準。いつも最後に使います")
        }
        Button("書体を追加") { adding = true }
      } header: {
        Text("並び")
      } footer: {
        Text("上の書体にない文字は、その下の書体で組まれます。")
      }
      Section {
        NavigationLink("ライセンス") { FontLicensesView() }
      }
    }
    .navigationTitle("書体")
    .toolbar { EditButton() }
    .environment(\.fontFamilies, stack.families(from: fonts.available))
    .sheet(isPresented: $adding) {
      FontPicker(fonts: fonts, excluded: Set(stack.names)) { family in
        stack.names.append(family.name)
        Task { await fonts.fetch(family) }
      }
    }
  }

  static let sample = "朝の光が desk に届くころ、Mai で書きかけの draft をもう一度読み返す。"
}

/// One family of a stack: its title in its own regular face once it can be set in, and where it
/// stands on this device, with a button to fetch it while it can't be.
private struct FontStackRow: View {
  let name: String
  let fonts: FontLibrary
  var note: String?

  var body: some View {
    if let family = fonts.families.first(where: { $0.name == name }) {
      let state = fonts.state(of: family)
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          FamilyTitle(family: family, available: state == .available)
          if let detail = detail(state) {
            Text(detail)
              .font(.footnote)
              .foregroundStyle(state.isFailure ? .red : .secondary)
          }
        }
        Spacer()
        switch state {
        case .available:
          EmptyView()
        case .fetching:
          ProgressView()
        case .missing, .failed:
          Button(state.isFailure ? "もう一度" : "取得") {
            Task { await fonts.fetch(family) }
          }
          .buttonStyle(.borderless)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: name)
        Text("この端末では使えない書体です。飛ばして組みます")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func detail(_ state: FontLibrary.State) -> String? {
    switch state {
    case .available: note
    case .missing: "まだ取得していません。飛ばして組みます"
    case .fetching: "取得しています"
    case .failed(let reason): "取得できませんでした。\(reason)"
    }
  }
}

/// A family's title in its own regular face, or in the system's while it can't be set in.
private struct FamilyTitle: View {
  let family: FontFamily
  let available: Bool

  var body: some View {
    if available,
      let font = family.font(.body, size: UIFont.preferredFont(forTextStyle: .body).pointSize)
    {
      Text(verbatim: family.title).font(Font(font))
    } else {
      Text(verbatim: family.title)
    }
  }
}

extension FontLibrary.State {
  var isFailure: Bool {
    if case .failed = self { true } else { false }
  }
}

/// The families that can be added, Latin and Japanese apart, each with its size and whether it is
/// on this device. Choosing one hands it to `add` and closes the sheet.
private struct FontPicker: View {
  let fonts: FontLibrary
  let excluded: Set<String>
  let add: (FontFamily) -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        section("欧文", fonts.families.filter { !$0.hasJapanese })
        section("和文", fonts.families.filter { $0.hasJapanese && $0 != .notoSansJP })
      }
      .navigationTitle("書体を追加")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .close) { dismiss() }
        }
      }
    }
  }

  @ViewBuilder
  private func section(_ title: LocalizedStringKey, _ families: [FontFamily]) -> some View {
    let addable = families.filter { !excluded.contains($0.name) }
    if !addable.isEmpty {
      section(title, addable: addable)
    }
  }

  private func section(_ title: LocalizedStringKey, addable: [FontFamily]) -> some View {
    Section(title) {
      ForEach(addable) { family in
        Button {
          add(family)
          dismiss()
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            FamilyTitle(family: family, available: fonts.state(of: family) == .available)
              .foregroundStyle(Color.primary)
            Text(detail(family))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func detail(_ family: FontFamily) -> String {
    let size = family.size.formatted(.byteCount(style: .file))
    if family.isBundled { return "アプリに入っています" }
    return fonts.state(of: family) == .available ? "取得済み・\(size)" : "選ぶと取得します・\(size)"
  }
}

/// Each family's license, as it ships with the family's files.
private struct FontLicensesView: View {
  var body: some View {
    List(FontFamily.known) { family in
      NavigationLink(family.title) {
        ScrollView {
          Text(verbatim: family.license)
            .font(.footnote.monospaced())
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(family.title)
      }
    }
    .navigationTitle("ライセンス")
  }
}

extension FontFamily {
  /// Its license, from `Resources/Fonts/Licenses/<name>.txt`.
  var license: String {
    let url = BundledFonts.folder.appending(path: "Licenses").appending(path: "\(name).txt")
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch {
      preconditionFailure("\(name)'s license is missing from the Features bundle: \(error)")
    }
  }
}
