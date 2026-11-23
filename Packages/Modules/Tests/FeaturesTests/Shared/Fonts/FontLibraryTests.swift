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

  /// A kept file that registers as another font isn't taken for the family: setting text in the
  /// family would find no face.
  @Test func aKeptFileHoldingAnotherFontFailsAtLaunch() throws {
    let kept = folder.appending(path: "Lora Italic")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    var data = try Data(contentsOf: Self.source)
    for (from, to) in [("Lora-Italic", "Lxra-Italic")] {
      for encoding in [String.Encoding.ascii, .utf16BigEndian] {
        guard let old = from.data(using: encoding), let new = to.data(using: encoding) else {
          preconditionFailure("ASCII names encode in both.")
        }
        while let range = data.range(of: old) { data.replaceSubrange(range, with: new) }
      }
    }
    let renamed = kept.appending(path: "Lora-Italic.ttf")
    try data.write(to: renamed)

    let fonts = library { _ in throw URLError(.notConnectedToInternet) }

    #expect(fonts.state(of: Self.standIn) == .failed(FontFetchError.notAFont.message))
    #expect(!FileManager.default.fileExists(atPath: kept.path))
    #expect(!CTFontManagerUnregisterFontsForURL(renamed as CFURL, .process, nil))
  }

  @Test func aSecondFetchWhileOneIsUnderwayFetchesNothing() async throws {
    let source = Self.source
    let fonts = FontLibrary(families: [Self.standIn], server: Self.server, folder: folder) { url in
      self.requested.append(url)
      try await Task.sleep(for: .milliseconds(100))
      return try Self.downloaded(source)
    }
    async let first: Void = fonts.fetch(Self.standIn)
    try await Task.sleep(for: .milliseconds(10))
    #expect(fonts.state(of: Self.standIn) == .fetching)
    await fonts.fetch(Self.standIn)
    await first
    #expect(requested.count == 1)
    #expect(fonts.state(of: Self.standIn) == .available)
  }

  @Test func aFolderThatCantBeWrittenFailsAsNotKept() async throws {
    try Data().write(to: folder)
    let source = Self.source
    let fonts = library { _ in try Self.downloaded(source) }
    await fonts.fetch(Self.standIn)
    #expect(fonts.state(of: Self.standIn) == .failed(FontFetchError.notKept.message))
  }

  @Test func aDownloadThatCantBeWrittenFailsAsNotKept() async {
    let fonts = library { _ in throw URLError(.cannotWriteToFile) }
    await fonts.fetch(Self.standIn)
    #expect(fonts.state(of: Self.standIn) == .failed(FontFetchError.notKept.message))
  }

  /// The downloaded file and the folder it was gathered in are gone whether the fetch worked or not.
  @Test(arguments: [true, false])
  func nothingIsLeftOfTheDownload(_ works: Bool) async throws {
    let source = works ? Self.source : Self.fixtures.appending(path: "OFL.txt")
    var downloads: [URL] = []
    let fonts = library { _ in
      let file = try Self.downloaded(source)
      downloads.append(file)
      return file
    }
    await fonts.fetch(Self.standIn)
    #expect(fonts.state(of: Self.standIn) == .available || !works)
    #expect(downloads.count == 1)
    #expect(downloads.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    #expect(left == (works ? ["Lora Italic"] : []))
  }

  /// A folder already where the family's files go is replaced by the fetched files.
  @Test func aFolderLeftWhereTheFamilyGoesIsReplaced() async throws {
    let source = Self.source
    let fonts = library { _ in try Self.downloaded(source) }
    let kept = folder.appending(path: "Lora Italic")
    try FileManager.default.createDirectory(at: kept, withIntermediateDirectories: true)
    try Data("left".utf8).write(to: kept.appending(path: "left.txt"))

    await fonts.fetch(Self.standIn)

    #expect(fonts.state(of: Self.standIn) == .available)
    #expect(try FileManager.default.contentsOfDirectory(atPath: kept.path) == ["Lora-Italic.ttf"])
  }

  @Test func aFileOfTheRightSizeWithOtherBytesIsRefused() async throws {
    var data = try Data(contentsOf: Self.source)
    data[data.count / 2] ^= 0xFF
    let changed = FileManager.default.temporaryDirectory.appending(path: "changed-\(UUID())")
    try data.write(to: changed)
    defer { try? FileManager.default.removeItem(at: changed) }
    let fonts = library { _ in try Self.downloaded(changed) }

    await fonts.fetch(Self.standIn)

    #expect(
      fonts.state(of: Self.standIn)
        == .failed(FontFetchError.notTheFile("Lora-Italic.ttf").message))
  }

  /// The download the app makes: the file for a 200, and the status for anything else.
  @Test(arguments: [200, 404, 500])
  func theRealDownloadTakesOnly200(_ status: Int) async throws {
    ServerStandIn.status = status
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ServerStandIn.self]
    let session = URLSession(configuration: configuration)
    let url = try #require(URL(string: "https://fonts.test/fonts/Lora-Italic.ttf"))
    do {
      let file = try await FontLibrary.download(url, in: session)
      defer { try? FileManager.default.removeItem(at: file) }
      #expect(status == 200)
      #expect(try Data(contentsOf: file) == ServerStandIn.body)
    } catch FontFetchError.answered(let answered) {
      #expect(status != 200)
      #expect(answered == status)
    }
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

/// Answers every request with `status`, and `body` for a 200.
private nonisolated final class ServerStandIn: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var status = 200
  nonisolated static let body = Data("font bytes".utf8)

  override nonisolated class func canInit(with request: URLRequest) -> Bool { true }
  override nonisolated class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override nonisolated func startLoading() {
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)
    else {
      preconditionFailure("A request made by URLSession has a URL.")
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.status == 200 ? Self.body : Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override nonisolated func stopLoading() {}
}
