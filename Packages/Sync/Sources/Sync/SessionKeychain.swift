import Foundation
import Security

/// The session in the keychain, on this device only: each device signs in on its own.
public struct SessionKeychain: SessionStore {
  let service: String

  public static let standard = SessionKeychain(service: "com.marromugi.mai.session")

  init(service: String) {
    self.service = service
  }

  public func load() throws(KeychainError) -> Session? {
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
        return try JSONDecoder().decode(Session.self, from: data)
      } catch {
        throw .unreadableSession
      }
    case errSecItemNotFound:
      return nil
    default:
      throw .failed(status)
    }
  }

  public func save(_ session: Session) throws(KeychainError) {
    let data: Data
    do {
      data = try JSONEncoder().encode(session)
    } catch {
      preconditionFailure("A session of strings always encodes as JSON: \(error)")
    }
    let updated = SecItemUpdate(
      base as CFDictionary, [kSecValueData: data] as CFDictionary)
    switch updated {
    case errSecSuccess:
      return
    case errSecItemNotFound:
      var item = base
      item[kSecValueData] = data
      item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw .failed(added) }
    default:
      throw .failed(updated)
    }
  }

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
      kSecAttrAccount: "session",
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
    ]
  }
}
