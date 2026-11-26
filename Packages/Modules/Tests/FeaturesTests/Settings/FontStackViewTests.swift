import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

extension Writing {
  /// Latin and Japanese mixed in each paragraph, to see each set in its own family.
  static let mixedBody = """
    Cotoma で書く。朝の光が desk に届くころ、書きかけの draft をもう一度読み返す。
    The quick brown fox jumps over the lazy dog. 素早い茶色の狐が、のろまな犬を飛び越える。
    2026 年 11 月 24 日、Typography は font-family の順に組まれる。
    """
}

struct FontStackViewTests {
  /// Inter first, then Zen Kaku Gothic New not fetched yet, then Lora, and the bundled family last.
  @Test func theStackScreen() {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "FontStackViewTests-\(UUID())")
    let fonts = FontLibrary(server: URL(filePath: "/server"), folder: folder) { _ in
      throw URLError(.notConnectedToInternet)
    }
    let page = HostedPage(
      NavigationStack {
        FontStackView(
          stack: .constant(FontStack(names: ["Inter", "Zen Kaku Gothic New", "Lora"])),
          fonts: fonts)
      }
      .environment(\.colorScheme, .light))
    assertSnapshot(of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// A stack naming the bundled family first, and a name the app doesn't know: the bundled family
  /// is listed once, where it is named.
  @Test func aStackNamingTheBundledFamily() {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "FontStackViewTests-\(UUID())")
    let fonts = FontLibrary(server: nil, folder: folder) { _ in
      throw URLError(.notConnectedToInternet)
    }
    let page = HostedPage(
      NavigationStack {
        FontStackView(
          stack: .constant(FontStack(names: ["Noto Sans JP", "Nobody Sans", "Inter"])),
          fonts: fonts)
      }
      .environment(\.colorScheme, .light))
    assertSnapshot(of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// A family being fetched shows 「取得しています」 and a spinner; one whose fetch failed shows why,
  /// and 「もう一度」.
  @Test func rowsWhileFetchingAndAfterAFailure() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "FontStackViewTests-\(UUID())")
    let slow = FontLibraryTests.standIn
    let fonts = FontLibrary(
      families: [.notoSansJP, slow, .zenKakuGothicNew], server: URL(filePath: "/server"),
      folder: folder
    ) { url in
      if url.lastPathComponent == slow.files[0].name {
        try await Task.sleep(for: .seconds(3))
      }
      throw URLError(.notConnectedToInternet)
    }
    let fetching = Task { await fonts.fetch(slow) }
    await fonts.fetch(.zenKakuGothicNew)
    let page = HostedPage(
      NavigationStack {
        FontStackView(
          stack: .constant(FontStack(names: [slow.name, FontFamily.zenKakuGothicNew.name])),
          fonts: fonts)
      }
      .environment(\.colorScheme, .light))
    try await page.settle { fonts.state(of: slow) == .fetching }
    assertSnapshot(of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
    await fetching.value
  }

  /// With Inter in the stack: Lora alone under 欧文, and the server's three under 和文, in the
  /// catalog's order, each with its size.
  @Test func thePicker() {
    let folder = FileManager.default.temporaryDirectory.appending(
      path: "FontStackViewTests-\(UUID())")
    let fonts = FontLibrary(server: URL(filePath: "/server"), folder: folder) { _ in
      throw URLError(.notConnectedToInternet)
    }
    let page = HostedPage(
      FontPicker(fonts: fonts, excluded: ["Inter"]) { _ in }
        .environment(\.colorScheme, .light))
    assertSnapshot(of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// The header's title is set in the stack's bold: Inter for the Latin.
  @Test func theHeaderTitleIsSetInTheStack() {
    assertSnapshot(
      of: WritingHeader(title: "Morning Pages と朝の光", width: 402, close: {}, toTop: {})
        .frame(width: 402)
        .background(Color(.systemBackground))
        .environment(\.fontFamilies, [.inter, .notoSansJP])
        .environment(\.colorScheme, .light),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  /// The mixed passage set in Inter, then the bundled family, on the page and typeset.
  @Test(arguments: ["reading", "typesetting"])
  func aLatinFamilyFirst(_ mode: String) {
    let page = HostedPage(
      WritingScreen(
        writing: Writing(title: "Morning Pages と朝の光", body: Writing.mixedBody), others: [],
        open: { _ in }, edit: { _ in }, photos: [], setting: .constant(.standard),
        typesetting: .constant(mode == "typesetting"),
        takingPhoto: .constant(false), camera: .standIn(taking: nil), photoTaken: { _ in }
      )
      .environment(\.fontFamilies, [.inter, .notoSansJP])
      .environment(\.colorScheme, .light))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), named: mode)
  }
}
