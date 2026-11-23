import CoreText
import CryptoKit
import Foundation
import Observation

/// The families text can be set in on this device: the bundled ones, and those fetched from the
/// server as `GET <server>/fonts/<file>` and kept in `folder`, one folder per family. Fetched
/// files are registered for this process when fetched and again at each launch.
@Observable
public final class FontLibrary {
  /// Where a family stands on this device.
  enum State: Equatable {
    case available
    /// Not fetched yet, or with no server to fetch it from.
    case missing
    case fetching
    /// The last fetch failed, for the reason given, written for the person reading it.
    case failed(String)
  }

  /// Every family that can be added to a stack: the bundled ones, and the server's when there is
  /// a server.
  let families: [FontFamily]
  private(set) var states: [String: State] = [:]
  @ObservationIgnored private let server: URL?
  @ObservationIgnored private let folder: URL
  @ObservationIgnored private let download: (URL) async throws -> URL

  /// Fetches from `server`, and keeps what it fetched in the app's Application Support.
  /// With no server, only the bundled families are offered.
  public convenience init(server: URL?) {
    guard
      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else {
      preconditionFailure("iOS gives every app an Application Support directory.")
    }
    self.init(
      server: server, folder: support.appending(path: "Fonts"), download: Self.download)
  }

  /// `download` fetches a URL to a temporary file of its own and returns where it is, or throws
  /// `FontFetchError` for an answer that isn't 200.
  init(
    families: [FontFamily] = FontFamily.known, server: URL?, folder: URL,
    download: @escaping (URL) async throws -> URL
  ) {
    BundledFonts.register()
    self.families = families.filter { $0.isBundled || server != nil }
    self.server = server
    self.folder = folder
    self.download = download
    for family in self.families {
      states[family.name] = family.isBundled || registerKept(family) ? .available : .missing
    }
  }

  func state(of family: FontFamily) -> State {
    states[family.name] ?? .missing
  }

  /// The families text can be set in now.
  var available: [FontFamily] {
    families.filter { state(of: $0) == .available }
  }

  /// Fetches `family`'s files, keeps them, and registers them. Does nothing for one available or
  /// being fetched already.
  func fetch(_ family: FontFamily) async {
    switch state(of: family) {
    case .available, .fetching: return
    case .missing, .failed: break
    }
    guard let server else {
      preconditionFailure("Only a library with a server offers families that aren't bundled.")
    }
    states[family.name] = .fetching
    do {
      try await fetchFiles(of: family, from: server)
      states[family.name] = registerKept(family) ? .available : .failed(FontFetchError.notAFont.message)
    } catch let error as FontFetchError {
      states[family.name] = .failed(error.message)
    } catch {
      states[family.name] = .failed(FontFetchError.unreachable(error).message)
    }
  }

  private func fetchFiles(of family: FontFamily, from server: URL) async throws {
    let staging = folder.appending(path: ".\(family.name).\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    for file in family.files {
      let fetched = try await download(server.appending(path: "fonts").appending(path: file.name))
      defer { try? FileManager.default.removeItem(at: fetched) }
      let data = try Data(contentsOf: fetched, options: .mappedIfSafe)
      let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard data.count == file.size, digest == file.sha256 else {
        throw FontFetchError.notTheFile(file.name)
      }
      try FileManager.default.moveItem(at: fetched, to: staging.appending(path: file.name))
    }
    try excludeFromBackup()
    let kept = folder.appending(path: family.name)
    if FileManager.default.fileExists(atPath: kept.path) {
      try FileManager.default.removeItem(at: kept)
    }
    try FileManager.default.moveItem(at: staging, to: kept)
  }

  /// Registers `family`'s kept files, if each is there. A file Core Text won't take is removed
  /// with the rest of the family's, to be fetched again.
  private func registerKept(_ family: FontFamily) -> Bool {
    let kept = folder.appending(path: family.name)
    let urls = family.files.map { kept.appending(path: $0.name) }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return false }
    for url in urls {
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
        guard code == CTFontManagerError.alreadyRegistered.rawValue else {
          try? FileManager.default.removeItem(at: kept)
          return false
        }
      }
    }
    return true
  }

  /// Fetched fonts can be fetched again, so they stay out of the device's backups.
  private func excludeFromBackup() throws {
    var folder = folder
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)
  }

  private static func download(_ url: URL) async throws -> URL {
    let (file, response) = try await URLSession.shared.download(from: url)
    guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
      try? FileManager.default.removeItem(at: file)
      throw FontFetchError.answered((response as? HTTPURLResponse)?.statusCode)
    }
    return file
  }
}

/// Why a family couldn't be fetched.
enum FontFetchError: Error {
  /// The server answered with this status, or with something that isn't HTTP.
  case answered(Int?)
  /// What came back isn't the file the app knows by that name.
  case notTheFile(String)
  /// Core Text wouldn't register a file that matched.
  case notAFont
  case unreachable(any Error)

  var message: String {
    switch self {
    case .answered(let status?):
      "サーバーが \(status) を返しました。"
    case .answered(nil):
      "サーバーの答えを読めませんでした。"
    case .notTheFile(let name):
      "\(name) の中身が、アプリの知っているものと違いました。"
    case .notAFont:
      "取得したファイルを書体として使えませんでした。"
    case .unreachable(let error):
      "サーバーに届きませんでした（\(error.localizedDescription)）。"
    }
  }
}
