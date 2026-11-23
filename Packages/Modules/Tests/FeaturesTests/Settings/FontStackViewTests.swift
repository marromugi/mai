import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

extension Writing {
  /// Latin and Japanese mixed in each paragraph, to see each set in its own family.
  static let mixedBody = """
    Mai で書く。朝の光が desk に届くころ、書きかけの draft をもう一度読み返す。
    The quick brown fox jumps over the lazy dog. 素早い茶色の狐が、のろまな犬を飛び越える。
    2026 年 11 月 24 日、Typography は font-family の順に組まれる。
    """
}

struct FontStackViewTests {
  /// Inter first, then Zen Kaku Gothic New not fetched yet, then Lora, and the bundled family last.
  @Test func theStackScreen() {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FontStackViewTests-\(UUID())")
    let fonts = FontLibrary(server: URL(string: "https://fonts.test"), folder: folder) { _ in
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

  /// The mixed passage set in Inter, then the bundled family, read, edited, and typeset.
  @Test(arguments: ["reading", "editing", "typesetting"])
  func aLatinFamilyFirst(_ mode: String) {
    let page = HostedPage(
      WritingScreen(
        writing: Writing(title: "Morning Pages と朝の光", body: Writing.mixedBody), others: [],
        open: { _ in }, edit: { _ in }, photos: [], setting: .constant(.standard),
        editing: .constant(mode == "editing"), typesetting: .constant(mode == "typesetting"),
        takingPhoto: .constant(false), camera: .standIn(taking: nil), photoTaken: { _ in }
      )
      .environment(\.fontFamilies, [.inter, .notoSansJP])
      .environment(\.colorScheme, .light))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), named: mode)
  }
}
