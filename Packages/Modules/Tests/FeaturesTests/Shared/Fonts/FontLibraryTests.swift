import CoreText
import Foundation
import Testing
import UIKit

@testable import Features

/// Serialized, and each test unregisters what it registered: a font is registered once per process.
@Suite(.serialized)
@MainActor
final class FontLibraryTests {
  /// A family the app doesn't bundle, standing in for one the server holds.
  nonisolated static let standIn = FontFamily(
    name: "Lora Italic", title: "Lora Italic", regular: "Lora-Italic", bold: .weight(700),
    emBoxDescent: nil,
    files: [
      FontFile(
        name: "Lora-Italic.ttf",
        sha256: "22d8d8854b53807aa664ca34f2031a9ed57a1d0dea296b8b96cdd3aad937a2b3",
        size: 221_232)
    ],
    isBundled: false)
  /// Never reached: each test's download stands in for it.
  static let server = URL(filePath: "/server", directoryHint: .isDirectory)
  /// Beside this file, with its license; read from the Mac, as the snapshots are.
  static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(
    path: "Fixtures")
  static let source = fixtures.appending(path: "Lora-Italic.ttf")

  let folder = FileManager.default.temporaryDirectory.appending(path: "FontLibraryTests-\(UUID())")
  var requested: [URL] = []

  deinit {
    let kept = folder.appending(path: Self.standIn.name).appending(path: "Lora-Italic.ttf")
    CTFontManagerUnregisterFontsForURL(kept as CFURL, .process, nil)
    try? FileManager.default.removeItem(at: folder)
  }

  /// A library offering the stand-in and the bundled families, whose downloads give `answer`.
  /// Loaded, as the app's is at launch.
  func library(_ answer: @escaping (URL) throws -> URL) -> FontLibrary {
    let fonts = FontLibrary(
      families: [.notoSansJP, .inter, Self.standIn], server: Self.server, folder: folder
    ) { url in
      self.requested.append(url)
      return try answer(url)
    }
    fonts.load()
    return fonts
  }

  /// A copy of `source` in a temporary file of its own, as a download leaves it.
  static func downloaded(_ source: URL) throws -> URL {
    let copy = FileManager.default.temporaryDirectory.appending(path: "download-\(UUID())")
    try FileManager.default.copyItem(at: source, to: copy)
    return copy
  }

  @Test func theServersFamiliesStartMissing() {
    let fonts = library { _ in throw URLError(.notConnectedToInternet) }
    #expect(fonts.state(of: Self.standIn) == .missing)
    #expect(fonts.state(of: .inter) == .available)
    #expect(fonts.available == [.notoSansJP, .inter])
  }

  @Test func withNoServerOnlyTheBundledFamiliesAreOffered() {
    let fonts = FontLibrary(server: nil, folder: folder) { _ in
      throw URLError(.notConnectedToInternet)
    }
    #expect(fonts.families == FontFamily.known.filter(\.isBundled))
  }

  @Test func fetchesKeepsAndRegistersAFamily() async throws {
    let source = Self.source
    let fonts = library { _ in try Self.downloaded(source) }
    #expect(UIFont(name: "Lora-Italic", size: 16) == nil)

    await fonts.fetch(Self.standIn)

    #expect(requested == [Self.server.appending(path: "fonts/Lora-Italic.ttf")])
    #expect(fonts.state(of: Self.standIn) == .available)
    #expect(fonts.available.contains(Self.standIn))
    #expect(UIFont(name: "Lora-Italic", size: 16) != nil)
    let kept = folder.appending(path: "Lora Italic/Lora-Italic.ttf")
    #expect(FileManager.default.fileExists(atPath: kept.path))
    #expect(
      try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
  }

  @Test func aLaterLaunchRegistersWhatWasKeptWithoutFetching() async throws {
    let source = Self.source
    await library { _ in try Self.downloaded(source) }.fetch(Self.standIn)
    requested = []

    let relaunched = library { _ in throw URLError(.notConnectedToInternet) }

    #expect(relaunched.state(of: Self.standIn) == .available)
    #expect(requested.isEmpty)
  }

  /// A kept file Core Text won't take shows as failed, not as never fetched, and is removed.
  @Test func aKeptFileThatIsNoLongerAFontFailsAtLaunch() throws {
    let kept = folder.appending(path: "Lora Italic")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: Self.fixtures.appending(path: "OFL.txt"), to: kept.appending(path: "Lora-Italic.ttf"))

    let fonts = library { _ in throw URLError(.notConnectedToInternet) }

    #expect(fonts.state(of: Self.standIn) == .failed(FontFetchError.notAFont.message))
    #expect(!FileManager.default.fileExists(atPath: kept.path))
  }

  /// A family with one of its files gone is fetched anew, and the file that was there is
  /// unregistered before its folder is removed.
  @Test func aFamilyMissingAFileIsUnregisteredAndFetchedAnew() throws {
    let partly = FontFamily(
      name: Self.standIn.name, title: Self.standIn.title, regular: Self.standIn.regular,
      bold: .face("Lora-Italic-Bold"), emBoxDescent: nil,
      files: Self.standIn.files + [FontFile(name: "Lora-Italic-Bold.ttf", sha256: "", size: 0)],
      isBundled: false)
    let kept = folder.appending(path: partly.name)
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    let regular = kept.appending(path: "Lora-Italic.ttf")
    try FileManager.default.copyItem(at: Self.source, to: regular)

    let fonts = FontLibrary(families: [partly], server: Self.server, folder: folder) { _ in
      throw URLError(.notConnectedToInternet)
    }
    fonts.load()

    #expect(fonts.state(of: partly) == .missing)
    #expect(!FileManager.default.fileExists(atPath: kept.path))
    #expect(!CTFontManagerUnregisterFontsForURL(regular as CFURL, .process, nil))
  }

  @Test func refusesAFileThatIsNotTheOneNamed() async throws {
    let other = Self.fixtures.appending(path: "OFL.txt")
    let fonts = library { _ in try Self.downloaded(other) }

    await fonts.fetch(Self.standIn)

    #expect(fonts.state(of: Self.standIn) == .failed("Lora-Italic.ttf の中身が、アプリの知っているものと違いました。"))
    #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Lora Italic").path))
  }

  @Test func anAnswerThatIsNot200Fails() async {
    let fonts = library { _ in throw FontFetchError.answered(404) }
    await fonts.fetch(Self.standIn)
    #expect(fonts.state(of: Self.standIn) == .failed("サーバーが 404 を返しました。"))
  }

  @Test func aServerOutOfReachFailsAndCanBeFetchedAgain() async throws {
    var reachable = false
    let source = Self.source
    let fonts = library { _ in
      guard reachable else { throw URLError(.notConnectedToInternet) }
      return try Self.downloaded(source)
    }

    await fonts.fetch(Self.standIn)
    guard case .failed(let reason) = fonts.state(of: Self.standIn) else {
      Issue.record("A fetch that can't reach the server fails.")
      return
    }
    #expect(reason == FontFetchError.unreachable.message)

    reachable = true
    await fonts.fetch(Self.standIn)
    #expect(fonts.state(of: Self.standIn) == .available)
  }
}
