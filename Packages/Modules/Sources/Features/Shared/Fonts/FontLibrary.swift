import CoreText
import CryptoKit
import Foundation
import Observation
import os

/// The families text can be set in on this device: the bundled ones, and those fetched from the
/// server as `GET <server>/fonts/<file>` and kept in `folder`, one folder per family. Fetched
/// files are registered for this process when fetched, and again by `load()` at each launch.
@Observable
public final class FontLibrary {
  /// Where a family stands on this device.
  enum State: Equatable {
    case available
    /// Not fetched yet, or with no server to fetch it from.
    case missing
    case fetching
    /// The last fetch, or registering what was kept, failed for the reason given, written for the
    /// person reading it.
    case failed(String)
  }

  /// Every family that can be added to a stack: the bundled ones, and the server's when there is
  /// a server.
  let families: [FontFamily]
  private var states: [String: State] = [:]
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
    self.families = families.filter { $0.isBundled || server != nil }
    self.server = server
    self.folder = folder
    self.download = download
  }

  /// Registers the bundled families, and the fetched ones kept from earlier launches.
  public func load() {
    BundledFonts.register()
    for family in families where !family.isBundled {
      states[family.name] = registerKept(family)
    }
  }

  func state(of family: FontFamily) -> State {
    family.isBundled ? .available : states[family.name] ?? .missing
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
      states[family.name] = registerKept(family)
    } catch let error as FontFetchError {
      states[family.name] = .failed(error.message)
    } catch let error as CocoaError {
      Self.log.error("Keeping \(family.name, privacy: .public) failed: \(error)")
      states[family.name] = .failed(FontFetchError.notKept.message)
    } catch {
      preconditionFailure("Fetching \(family.name) failed in a way not handled: \(error)")
    }
  }

  private func fetchFiles(of family: FontFamily, from server: URL) async throws {
    let staging = folder.appending(path: ".\(family.name).\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    for file in family.files {
      let fetched: URL
      do {
        fetched = try await download(server.appending(path: "fonts").appending(path: file.name))
      } catch let error as URLError {
        Self.log.error("Downloading \(file.name, privacy: .public) failed: \(error)")
        switch error.code {
        case .cannotCreateFile, .cannotOpenFile, .cannotWriteToFile, .cannotMoveFile:
          throw FontFetchError.notKept
        default:
          throw FontFetchError.unreachable
        }
      }
      defer { try? FileManager.default.removeItem(at: fetched) }
      guard try await Self.matches(fetched, file) else {
        throw FontFetchError.notTheFile(file.name)
      }
      try FileManager.default.moveItem(at: fetched, to: staging.appending(path: file.name))
    }
    try excludeFromBackup()
    let kept = folder.appending(path: family.name)
    do {
      try FileManager.default.moveItem(at: staging, to: kept)
    } catch CocoaError.fileWriteFileExists {
      try FileManager.default.removeItem(at: kept)
      try FileManager.default.moveItem(at: staging, to: kept)
    }
  }

  /// Whether `url` holds `file`: its size and SHA-256. Read off the main actor; a file is up to
  /// a few MB.
  @concurrent
  private nonisolated static func matches(_ url: URL, _ file: FontFile) async throws -> Bool {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return data.count == file.size && digest == file.sha256
  }

  /// Registers `family`'s kept files: available once each is registered, missing when none was
  /// kept. A file Core Text won't take is removed with the rest of the family's, to be fetched
  /// again.
  private func registerKept(_ family: FontFamily) -> State {
    let kept = folder.appending(path: family.name)
    var registered: [URL] = []
    /// Removes the family's files once none of them is registered: a registered file must stay.
    func discard() {
      for url in registered {
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
      }
      try? FileManager.default.removeItem(at: kept)
    }
    for file in family.files {
      let url = kept.appending(path: file.name)
      var error: Unmanaged<CFError>?
      guard !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
        registered.append(url)
        continue
      }
      guard let error = error?.takeRetainedValue() else {
        preconditionFailure("Core Text gives an error with every registration it refuses.")
      }
      switch CFErrorGetCode(error) {
      case CTFontManagerError.alreadyRegistered.rawValue:
        continue
      case CTFontManagerError.fileNotFound.rawValue:
        // A family's files are kept all together or not at all; a folder missing one is fetched anew.
        discard()
        return .missing
      default:
        Self.log.error("Registering \(url.lastPathComponent, privacy: .public) failed: \(error)")
        discard()
        return .failed(FontFetchError.notAFont.message)
      }
    }
    // A kept file can be another font under the family's file name: replaced, or kept by an
    // earlier version of the app. Only files that hold the family's faces are used.
    let names = Set(
      family.files.map { kept.appending(path: $0.name) }.flatMap { url in
        (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? [])
          .compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
      })
    guard names.isSuperset(of: family.faceNames) else {
      Self.log.error("\(family.name, privacy: .public)'s kept files don't hold its faces.")
      discard()
      return .failed(FontFetchError.notAFont.message)
    }
    return .available
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

  private static let log = Logger(subsystem: "com.marromugi.mai", category: "fonts")
}

/// Why a family couldn't be fetched or kept. The cause behind each is logged where it is met.
enum FontFetchError: Error {
  /// The server answered with this status, or with something that isn't HTTP.
  case answered(Int?)
  case unreachable
  /// What came back isn't the file the app knows by that name.
  case notTheFile(String)
  /// The files couldn't be written to the device.
  case notKept
  /// Core Text wouldn't register a file that matched.
  case notAFont

  var message: String {
    switch self {
    case .answered(let status?):
      "サーバーが \(status) を返しました。"
    case .answered(nil):
      "サーバーの答えを読めませんでした。"
    case .unreachable:
      "サーバーに届きませんでした。通信できるところで、もう一度試してください。"
    case .notTheFile(let name):
      "\(name) の中身が、アプリの知っているものと違いました。"
    case .notKept:
      "端末に保存できませんでした。空き容量を確かめて、もう一度試してください。"
    case .notAFont:
      "取得したファイルを書体として使えませんでした。もう一度取得してください。"
    }
  }
}
