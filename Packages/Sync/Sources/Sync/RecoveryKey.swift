import CryptoKit
import Foundation

/// The own key written for a person to keep: its 32 bytes and a 3-byte check, in Crockford's
/// Base32 as 14 groups of 4. Typing it back on a new device restores the own key when every device
/// holding it is lost.
public struct RecoveryKey: Sendable, Equatable {
  public let ownKey: OwnKey

  public init(_ ownKey: OwnKey) {
    self.ownKey = ownKey
  }

  /// Reads a recovery key as a person typed or pasted it, as `Base32` reads.
  public init(text: String) throws(RecoveryKeyError) {
    let bytes: Data
    do {
      bytes = try Base32.bytes(of: text, count: Self.length)
    } catch {
      switch error {
      case .unknownCharacter(let character): throw .unknownCharacter(character)
      case .wrongLength(let count): throw .wrongLength(count)
      }
    }
    let key = bytes.prefix(32)
    guard Data(bytes.suffix(3)) == Self.check(of: key) else {
      throw .mistyped
    }
    do {
      ownKey = try OwnKey(rawRepresentation: Data(key))
    } catch {
      preconditionFailure("A recovery key's first 32 bytes are always an own key: \(error)")
    }
  }

  public var text: String {
    let raw = ownKey.rawRepresentation
    return Base32.text(of: raw + Self.check(of: raw))
  }

  /// 35 bytes are 280 bits, exactly 56 digits of 5 bits.
  private static let length = 35

  private static func check(of key: some DataProtocol) -> Data {
    Data(SHA256.hash(data: key).prefix(3))
  }
}

public enum RecoveryKeyError: LocalizedError, Equatable {
  case unknownCharacter(Character)
  case wrongLength(Int)
  case mistyped

  public var errorDescription: String? {
    switch self {
    case .unknownCharacter(let character):
      "リカバリーキーに使わない文字「\(character)」が入っています。"
    case .wrongLength(let count):
      "リカバリーキーは 56 文字ですが、\(count) 文字でした。"
    case .mistyped:
      "リカバリーキーが合いません。打ち間違いがないか確かめてください。"
    }
  }
}
