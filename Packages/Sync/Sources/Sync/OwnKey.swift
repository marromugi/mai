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

  /// What the server is shown to let this user in. It is derived one way from the own key, so the
  /// server, which keeps only its SHA-256, learns nothing of the key.
  public var accessToken: String {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: Data("mai server access token".utf8), outputByteCount: 32)
    return derived.withUnsafeBytes { Data($0) }.base64EncodedString()
      .replacing("+", with: "-").replacing("/", with: "_").replacing("=", with: "")
  }

  /// The SHA-256 of `accessToken` in lowercase hex: what the server keeps as its secret
  /// `ACCESS_TOKEN_SHA256` (`Server/README.md`).
  public var accessTokenSHA256: String {
    SHA256.hash(data: Data(accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

public struct OwnKeyLengthError: LocalizedError {
  public let count: Int

  public var errorDescription: String? {
    "自分の鍵は 32 バイトですが、\(count) バイトでした。"
  }
}
