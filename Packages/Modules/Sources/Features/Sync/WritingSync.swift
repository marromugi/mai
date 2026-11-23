import CryptoKit
import Foundation
import Observation
internal import Sync

/// Where the own key is kept: `OwnKeyKeychain` on a device.
nonisolated protocol OwnKeyStore: Sendable {
  /// The key kept, or nil when none is.
  func load() throws -> OwnKey?
  /// Keeps `key`, refusing when a key is already kept.
  func save(_ key: OwnKey) throws
}

extension OwnKeyKeychain: OwnKeyStore {}

/// Syncs the writings in the store with the server at the URL the settings hold, sealed with the
/// own key. Nothing leaves the device while no URL is set or the device holds no own key.
///
/// The own key is made only when the person says this is the first device to sync: a device that
/// made its own while another already had one would seal writings no other device can open.
@Observable final class WritingSync {
  /// The `UserDefaults` key of the server's URL. Empty or missing keeps writings on the device.
  static let serverURLKey = "syncServerURL"

  private let store: any WritingStore
  private let keys: any OwnKeyStore
  private let stateDirectory: URL
  private let transport: any HTTPTransport
  /// One per server and own key, so its syncs run one after the other.
  private var synchronizer: (id: String, synchronizer: Synchronizer)?

  /// Nil until `loadOwnKey()` finds one, or while the device holds none.
  private(set) var ownKey: OwnKey?
  /// Why the keychain couldn't be read, written for a person.
  private(set) var keyProblem: String?
  private(set) var status = Status.notYet

  enum Status: Equatable {
    case notYet
    case syncing
    case synced(Date)
    /// What went wrong, written for a person.
    case failed(String)
  }

  /// `stateDirectory` keeps what each server and own key last synced.
  init(
    store: any WritingStore, keys: any OwnKeyStore, stateDirectory: URL,
    transport: any HTTPTransport = URLSession.shared
  ) {
    self.store = store
    self.keys = keys
    self.stateDirectory = stateDirectory
    self.transport = transport
  }

  /// The writings kept on the device, with the own key in iCloud Keychain.
  static func onDevice(store: any WritingStore) -> WritingSync {
    WritingSync(
      store: store, keys: OwnKeyKeychain.standard,
      stateDirectory: .applicationSupportDirectory.appending(
        path: "Sync", directoryHint: .isDirectory))
  }

  /// Reads the own key from the keychain, which may have brought it from another device since.
  func loadOwnKey() {
    do {
      ownKey = try keys.load()
      keyProblem = nil
    } catch {
      ownKey = nil
      keyProblem = Self.message(for: error)
    }
  }

  /// Makes the own key, for the first device to sync, and gives back its recovery key.
  func makeOwnKey() throws -> RecoveryKey {
    let key = OwnKey.generate()
    do {
      try keys.save(key)
    } catch {
      loadOwnKey()
      throw error
    }
    ownKey = key
    keyProblem = nil
    return RecoveryKey(key)
  }

  /// Restores the own key from its recovery key as a person typed it.
  func restoreOwnKey(from text: String) throws {
    let key = try RecoveryKey(text: text).ownKey
    do {
      try keys.save(key)
    } catch {
      loadOwnKey()
      throw error
    }
    ownKey = key
    keyProblem = nil
  }

  /// Syncs with the server at `serverURL`, after any sync already running, and says whether it
  /// reached the server. Does nothing while `serverURL` is empty or the device holds no own key.
  @discardableResult
  func sync(serverURL text: String) async -> Bool {
    let url: URL
    do {
      guard let parsed = try ServerURL(text: text) else { return false }
      url = parsed.url
    } catch {
      status = .failed(Self.message(for: error))
      return false
    }
    if ownKey == nil {
      loadOwnKey()
    }
    guard let ownKey else { return false }
    let synchronizer = synchronizer(for: url, ownKey: ownKey)
    status = .syncing
    do {
      _ = try await synchronizer.sync()
      status = .synced(.now)
    } catch {
      status = .failed(Self.message(for: error))
    }
    return true
  }

  private func synchronizer(for url: URL, ownKey: OwnKey) -> Synchronizer {
    let id = SHA256.hash(data: Data((url.absoluteString + "\n" + ownKey.accessToken).utf8))
      .prefix(16).map { String(format: "%02x", $0) }.joined()
    if let synchronizer, synchronizer.id == id {
      return synchronizer.synchronizer
    }
    let made = Synchronizer(
      writings: SyncedWritings(store: store),
      stateFile: stateDirectory.appending(path: "\(id).json", directoryHint: .notDirectory),
      server: WritingServer(url: url, accessToken: ownKey.accessToken, transport: transport),
      ownKey: ownKey)
    synchronizer = (id, made)
    return made
  }

  private static func message(for error: any Error) -> String {
    (error as? any LocalizedError)?.errorDescription ?? "同期できませんでした。"
  }
}

/// The server's URL as the settings hold it: http or https, with a host.
nonisolated struct ServerURL: Equatable {
  let url: URL

  /// Nil when `text` is empty, which keeps writings on the device.
  init?(text: String) throws(ServerURLError) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http", url.host() != nil
    else { throw ServerURLError() }
    self.url = url
  }
}

nonisolated struct ServerURLError: LocalizedError {
  var errorDescription: String? {
    "サーバーの URL は https:// で始めて書いてください。"
  }
}
