import Foundation
import Security
import Testing

@testable import Sync

/// Hosted in the app, since the keychain refuses a test bundle with no app around it.
struct OwnKeyKeychainTests {
  private let keychain = OwnKeyKeychain(service: "com.marromugi.mai.tests.\(UUID().uuidString)")

  @Test func holdsNoKeyBeforeOneIsSaved() throws {
    #expect(try keychain.load() == nil)
  }

  @Test func givesBackTheKeySaved() throws {
    defer { remove() }
    let ownKey = OwnKey.generate()
    try keychain.save(ownKey)
    #expect(try keychain.load() == ownKey)
  }

  @Test func neverReplacesAKeptKey() throws {
    defer { remove() }
    let first = OwnKey.generate()
    try keychain.save(first)
    #expect {
      try keychain.save(OwnKey.generate())
    } throws: { error in
      guard case KeychainError.alreadyKept = error else { return false }
      return true
    }
    #expect(try keychain.load() == first)
  }

  @Test func replacesAKeptKeyOnlyWhenToldTo() throws {
    defer { remove() }
    try keychain.save(OwnKey.generate())
    let restored = OwnKey.generate()
    try keychain.replace(with: restored)
    #expect(try keychain.load() == restored)
  }

  @Test func replacingWithNoKeyKeptKeepsTheKey() throws {
    defer { remove() }
    let restored = OwnKey.generate()
    try keychain.replace(with: restored)
    #expect(try keychain.load() == restored)
  }

  @Test func keepsTheKeyForICloudKeychainToCarry() throws {
    defer { remove() }
    try keychain.save(OwnKey.generate())
    var query = keychain.base
    query[kSecReturnAttributes] = true
    var item: CFTypeRef?
    #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
    let attributes = try #require(item as? [CFString: Any])
    #expect(attributes[kSecAttrSynchronizable] as? Bool == true)
    #expect(
      attributes[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlock as String)
  }

  private func remove() {
    SecItemDelete(keychain.base as CFDictionary)
  }
}
