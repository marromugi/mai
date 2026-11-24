import Foundation
import Sync
import Synchronization

/// Keeps the own key in memory as the keychain does: `save` refuses to replace a key. The Mac's
/// `swift test` can't use the keychain.
final class MemoryOwnKeys: OwnKeyStore {
  private let kept: Mutex<OwnKey?>

  init(_ key: OwnKey? = nil) {
    kept = Mutex(key)
  }

  func load() throws(KeychainError) -> OwnKey? {
    kept.withLock { $0 }
  }

  func save(_ key: OwnKey) throws(KeychainError) {
    try kept.withLock { kept throws(KeychainError) in
      guard kept == nil else { throw .alreadyKept }
      kept = key
    }
  }

  func replace(with key: OwnKey) throws(KeychainError) {
    kept.withLock { $0 = key }
  }

  func remove() throws(KeychainError) {
    kept.withLock { $0 = nil }
  }
}

/// Keeps the session in memory.
final class MemorySessions: SessionStore {
  private let kept = Mutex<Session?>(nil)

  func load() throws(KeychainError) -> Session? {
    kept.withLock { $0 }
  }

  func save(_ session: Session) throws(KeychainError) {
    kept.withLock { $0 = session }
  }

  func remove() throws(KeychainError) {
    kept.withLock { $0 = nil }
  }
}
