import Foundation
import Security

/// Where the own key is kept: `OwnKeyKeychain` on a device.
public protocol OwnKeyStore: Sendable {
  /// The key kept, or nil when none is.
  func load() throws(KeychainError) -> OwnKey?
  /// Keeps `key`, refusing with `alreadyKept` when a key is kept.
  func save(_ key: OwnKey) throws(KeychainError)
  /// Keeps `key` in place of the one kept, which the account's own key check showed isn't the
  /// account's.
  func replace(with key: OwnKey) throws(KeychainError)
  /// Forgets the key kept, as when its account is deleted; nothing when none is kept.
  func remove() throws(KeychainError)
}

/// The own key in iCloud Keychain, which carries it to the user's other devices.
public struct OwnKeyKeychain: OwnKeyStore {
  let service: String

  public static let standard = OwnKeyKeychain(service: "com.marromugi.mai.own-key")

  init(service: String) {
    self.service = service
  }

  /// The key kept, or nil when none is: not made yet, or not yet carried here by iCloud Keychain.
  public func load() throws(KeychainError) -> OwnKey? {
    var query = base
    query[kSecReturnData] = true
    query[kSecMatchLimit] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else {
        preconditionFailure("A keychain item asked for its data returns Data")
      }
      do {
        return try OwnKey(rawRepresentation: data)
      } catch {
        throw .unreadable(error)
      }
    case errSecItemNotFound:
      return nil
    default:
      throw .failed(status)
    }
  }

  /// Keeps `key`, and never replaces a key already kept: every writing sealed with that one
  /// would become unreadable.
  public func save(_ key: OwnKey) throws(KeychainError) {
    var item = base
    item[kSecValueData] = key.rawRepresentation
    item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
    let status = SecItemAdd(item as CFDictionary, nil)
    switch status {
    case errSecSuccess:
      return
    case errSecDuplicateItem:
      throw .alreadyKept
    default:
      throw .failed(status)
    }
  }

  public func replace(with key: OwnKey) throws(KeychainError) {
    let status = SecItemUpdate(
      base as CFDictionary, [kSecValueData: key.rawRepresentation] as CFDictionary)
    switch status {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      try save(key)
    default:
      throw .failed(status)
    }
  }

  /// Forgets the key here and, through iCloud Keychain, on the user's other devices.
  public func remove() throws(KeychainError) {
    let status = SecItemDelete(base as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw .failed(status)
    }
  }

  var base: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: "own-key",
      kSecAttrSynchronizable: true,
      kSecUseDataProtectionKeychain: true,
    ]
  }
}

public enum KeychainError: LocalizedError {
  case alreadyKept
  case unreadable(OwnKeyLengthError)
  case unreadableSession
  case failed(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .alreadyKept:
      "キーチェーンにはもう自分の鍵があります。"
    case .unreadable:
      "キーチェーンの自分の鍵が読めませんでした。"
    case .unreadableSession:
      "キーチェーンのサインインの情報が読めませんでした。"
    case .failed(let status):
      "キーチェーンを使えませんでした（\(status)）。"
    }
  }
}
