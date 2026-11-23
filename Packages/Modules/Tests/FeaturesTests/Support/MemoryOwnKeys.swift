import Foundation
import Sync
import Synchronization

@testable import Features

/// Keeps the own key in memory, refusing to replace it as the keychain does. Package tests can't
/// use the keychain.
nonisolated final class MemoryOwnKeys: OwnKeyStore {
  private let kept: Mutex<OwnKey?>

  init(_ key: OwnKey? = nil) {
    kept = Mutex(key)
  }

  func load() throws -> OwnKey? {
    kept.withLock { $0 }
  }

  func save(_ key: OwnKey) throws {
    try kept.withLock { kept throws(KeychainError) in
      guard kept == nil else { throw .alreadyKept }
      kept = key
    }
  }
}

extension WritingSync {
  /// A sync over `store`, keeping what it last synced in a new temporary directory.
  static func forTests(
    store: any WritingStore, keys: any OwnKeyStore = MemoryOwnKeys(),
    transport: any HTTPTransport = URLSession.shared
  ) -> WritingSync {
    WritingSync(
      store: store, keys: keys,
      stateDirectory: FileManager.default.temporaryDirectory.appending(
        path: "WritingSync-\(UUID().uuidString)", directoryHint: .isDirectory),
      transport: transport)
  }
}
