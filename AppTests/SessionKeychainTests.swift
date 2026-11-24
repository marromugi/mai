import Foundation
import Security
import Testing

@testable import Sync

/// Hosted in the app, since the keychain refuses a test bundle with no app around it.
struct SessionKeychainTests {
  private let keychain = SessionKeychain(service: "com.marromugi.mai.tests.\(UUID().uuidString)")

  private func session() -> Session {
    Session(token: "s1.\(UUID().uuidString).secret", account: UUID(), appleUser: "000123.abc")
  }

  @Test func holdsNoSessionBeforeOneIsSaved() throws {
    #expect(try keychain.load() == nil)
  }

  @Test func givesBackTheLastSessionSaved() throws {
    defer { remove() }
    try keychain.save(session())
    let second = session()
    try keychain.save(second)
    #expect(try keychain.load() == second)
  }

  @Test func holdsNoSessionOnceRemoved() throws {
    try keychain.save(session())
    try keychain.remove()
    #expect(try keychain.load() == nil)
    try keychain.remove()
  }

  @Test func keepsTheSessionOnThisDeviceOnly() throws {
    defer { remove() }
    try keychain.save(session())
    var query = keychain.base
    query[kSecReturnAttributes] = true
    var item: CFTypeRef?
    #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
    let attributes = try #require(item as? [CFString: Any])
    #expect(attributes[kSecAttrSynchronizable] as? Bool != true)
    #expect(
      attributes[kSecAttrAccessible] as? String
        == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
  }

  @Test func aSessionItCantReadIsSaid() throws {
    defer { remove() }
    var item = keychain.base
    item[kSecValueData] = Data("not a session".utf8)
    #expect(SecItemAdd(item as CFDictionary, nil) == errSecSuccess)
    #expect {
      try keychain.load()
    } throws: { error in
      guard case KeychainError.unreadableSession = error else { return false }
      return true
    }
  }

  private func remove() {
    SecItemDelete(keychain.base as CFDictionary)
  }
}
