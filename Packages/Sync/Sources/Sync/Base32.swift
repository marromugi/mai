import Foundation

/// Crockford's Base32, as a person reads and types it: groups of 4 digits joined by hyphens, read
/// back in any case, with or without hyphens and spaces, and with O, I and L taken for 0, 1 and 1.
enum Base32 {
  enum ReadError: Error, Equatable {
    case unknownCharacter(Character)
    case wrongLength(Int)
  }

  /// `bytes` in groups of 4 digits. Its bits are a whole number of digits.
  static func text(of bytes: Data) -> String {
    precondition(bytes.count * 8 % 5 == 0, "Base32 text holds a whole number of 5-bit digits")
    let characters = digits(of: bytes).map { alphabet[Int($0)] }
    return stride(from: 0, to: characters.count, by: 4)
      .map { String(characters[$0..<min($0 + 4, characters.count)]) }
      .joined(separator: "-")
  }

  /// The `count` bytes written in `text`.
  static func bytes(of text: String, count: Int) throws(ReadError) -> Data {
    precondition(count * 8 % 5 == 0, "Base32 text holds a whole number of 5-bit digits")
    var digits: [UInt8] = []
    for character in text.uppercased() where !separators.contains(character) {
      guard let digit = digit(of: character) else {
        throw .unknownCharacter(character)
      }
      digits.append(digit)
    }
    guard digits.count == count * 8 / 5 else {
      throw .wrongLength(digits.count)
    }
    return Data(bytes(fromDigits: digits))
  }

  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
  private static let separators: Set<Character> = ["-", " ", "\n"]

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
