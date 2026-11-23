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

  /// Reads a recovery key as a person typed it: any case, with or without hyphens and spaces, and
  /// O, I and L taken for 0, 1 and 1.
  public init(text: String) throws(RecoveryKeyError) {
    var digits: [UInt8] = []
    for character in text.uppercased() where !Self.separators.contains(character) {
      guard let digit = Self.digit(of: character) else {
        throw .unknownCharacter(character)
      }
      digits.append(digit)
    }
    guard digits.count == Self.length else {
      throw .wrongLength(digits.count)
    }
    let bytes = Self.bytes(fromDigits: digits)
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
    let digits = Self.digits(of: raw + Self.check(of: raw))
    let characters = digits.map { Self.alphabet[Int($0)] }
    return stride(from: 0, to: characters.count, by: 4)
      .map { String(characters[$0..<$0 + 4]) }
      .joined(separator: "-")
  }

  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  private static let separators: Set<Character> = ["-", " ", "\n"]
  /// 35 bytes are 280 bits, exactly 56 digits of 5 bits.
  private static let length = 56

  private static func check(of key: some DataProtocol) -> Data {
    Data(SHA256.hash(data: key).prefix(3))
  }

  private static func digit(of character: Character) -> UInt8? {
    let read: Character =
      switch character {
      case "O": "0"
      case "I", "L": "1"
      default: character
      }
    return alphabet.firstIndex(of: read).map { UInt8($0) }
  }

  private static func digits(of bytes: Data) -> [UInt8] {
    var digits: [UInt8] = []
    var buffer = 0
    var bits = 0
    for byte in bytes {
      buffer = buffer << 8 | Int(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        digits.append(UInt8(buffer >> bits & 0x1f))
      }
    }
    return digits
  }

  private static func bytes(fromDigits digits: [UInt8]) -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = 0
    var bits = 0
    for digit in digits {
      buffer = buffer << 5 | Int(digit)
      bits += 5
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8(buffer >> bits & 0xff))
      }
    }
    return bytes
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
