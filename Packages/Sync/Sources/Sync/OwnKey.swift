import CryptoKit
import Foundation

/// The user's own key. It seals every writing's key, so whoever holds it can open every writing.
/// Kept in iCloud Keychain (`OwnKeyKeychain`), and restored from the `RecoveryKey`.
public struct OwnKey: Sendable, Equatable {
  let key: SymmetricKey

  public static func generate() -> OwnKey {
    OwnKey(key: SymmetricKey(size: .bits256))
  }

  init(key: SymmetricKey) {
    self.key = key
  }

  public init(rawRepresentation: Data) throws(OwnKeyLengthError) {
    guard rawRepresentation.count == 32 else {
      throw OwnKeyLengthError(count: rawRepresentation.count)
    }
    key = SymmetricKey(data: rawRepresentation)
  }

  public var rawRepresentation: Data {
    key.withUnsafeBytes { Data($0) }
  }

  /// The account's own key check (`PUT /account/own-key-check`): the SHA-256 of a value derived
  /// one way from the key, so the server can tell one own key from another and learns nothing of
  /// either.
  public var check: Data {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: Data("mai own key check".utf8), outputByteCount: 32)
    return Data(derived.withUnsafeBytes { SHA256.hash(data: $0) })
  }

  /// What the server is shown to let this user in. It is derived one way from the own key, so the
  /// server, which keeps only its SHA-256, learns nothing of the key.
  public var accessToken: String {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: Data("mai server access token".utf8), outputByteCount: 32)
    return derived.withUnsafeBytes { Data($0) }.base64EncodedString()
      .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
  }
}

public struct OwnKeyLengthError: LocalizedError {
  public let count: Int

  public var errorDescription: String? {
    "自分の鍵は 32 バイトですが、\(count) バイトでした。"
  }
}
