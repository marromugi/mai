import CryptoKit
import Foundation

/// A writing as the device keeps it: its ID, its updated time, and its contents in plain bytes.
public struct PlainWriting: Sendable, Equatable {
  public let id: UUID
  public var updated: Date
  public var contents: Data

  public init(id: UUID, updated: Date, contents: Data) {
    self.id = id
    self.updated = updated
    self.contents = contents
  }
}

/// A writing sealed on this device, ready for the server. Only `OwnKey.seal(_:)` makes one, and
/// `WritingServer.save` takes nothing else, so nothing but ciphertext is ever sent.
///
/// Its bytes are laid out as `Server/README.md` says: the header (magic, ID, updated time in
/// milliseconds), the writing key sealed with the own key, then the contents sealed with the
/// writing key. Both seals are AES-256-GCM and take the header as authenticated data.
public struct Sealed: Sendable {
  public let id: UUID
  let bytes: Data

  fileprivate init(id: UUID, bytes: Data) {
    self.id = id
    self.bytes = bytes
  }
}

/// A sealed writing read from the server, of the one shape but not yet opened.
public struct Envelope: Sendable, Equatable {
  public let id: UUID
  let bytes: Data

  public init(bytes: Data) throws(EnvelopeError) {
    let bytes = Data(bytes)
    guard (Layout.smallest...Layout.largest).contains(bytes.count) else {
      throw .wrongSize(bytes.count)
    }
    guard bytes.prefix(4) == Layout.magic else {
      throw .notASealedWriting
    }
    id = UUID(uuid: Layout.uuid(bytes[4..<20]))
    self.bytes = bytes
  }
}

extension OwnKey {
  /// Seals `writing` with a writing key made for this save alone, and seals that key with this one.
  public func seal(_ writing: PlainWriting) throws(SealingError) -> Sealed {
    guard let updated = Layout.milliseconds(of: writing.updated) else {
      throw .updatedOutOfRange(writing.updated)
    }
    let header =
      Layout.magic + withUnsafeBytes(of: writing.id.uuid) { Data($0) }
      + withUnsafeBytes(of: updated.bigEndian) { Data($0) }
    let writingKey = SymmetricKey(size: .bits256)
    let bytes: Data
    do {
      let sealedKey = try AES.GCM.seal(
        writingKey.withUnsafeBytes { Data($0) }, using: key, authenticating: header)
      let sealedContents = try AES.GCM.seal(
        writing.contents, using: writingKey, authenticating: header)
      guard let sealedKey = sealedKey.combined, let sealedContents = sealedContents.combined else {
        preconditionFailure("A box sealed with the default 12-byte nonce always has combined bytes")
      }
      bytes = header + sealedKey + sealedContents
    } catch {
      preconditionFailure("AES-GCM fails only on a nonce or key of the wrong size: \(error)")
    }
    guard bytes.count <= Layout.largest else {
      throw .tooLarge(bytes.count)
    }
    return Sealed(id: writing.id, bytes: bytes)
  }

  /// Opens a sealed writing, failing when it wasn't sealed with this key or was altered since.
  public func open(_ envelope: Envelope) throws(OpeningError) -> PlainWriting {
    let bytes = envelope.bytes
    let header = bytes.prefix(Layout.header)
    do {
      let sealedKey = try AES.GCM.SealedBox(
        combined: bytes[Layout.header..<Layout.header + Layout.sealedKey])
      let writingKey = try AES.GCM.open(sealedKey, using: key, authenticating: header)
      let sealedContents = try AES.GCM.SealedBox(
        combined: bytes[(Layout.header + Layout.sealedKey)...])
      let contents = try AES.GCM.open(
        sealedContents, using: SymmetricKey(data: writingKey), authenticating: header)
      let updated = bytes[20..<28].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      return PlainWriting(
        id: envelope.id, updated: Date(timeIntervalSince1970: Double(updated) / 1000),
        contents: contents)
    } catch {
      throw OpeningError(id: envelope.id)
    }
  }
}

enum Layout {
  static let magic = Data([0x6d, 0x61, 0x69, 0x01])
  static let header = 28
  static let sealedKey = 12 + 32 + 16
  static let smallest = header + sealedKey + 12 + 16
  /// The server's limit (`largestEnvelope` in `Server/src/envelope.ts`).
  static let largest = 1_900_000

  /// The time in whole milliseconds since 1970, when the server can hold it.
  static func milliseconds(of date: Date) -> UInt64? {
    let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
    guard milliseconds >= 1, milliseconds <= 9_007_199_254_740_991 else { return nil }
    return UInt64(milliseconds)
  }

  static func uuid(_ bytes: Data) -> uuid_t {
    let b = Array(bytes)
    precondition(b.count == 16, "A UUID is read from 16 bytes")
    return (
      b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13],
      b[14], b[15]
    )
  }
}

public enum SealingError: LocalizedError, Equatable {
  case updatedOutOfRange(Date)
  case tooLarge(Int)

  public var errorDescription: String? {
    switch self {
    case .updatedOutOfRange(let date):
      "更新時刻 \(date.formatted(.iso8601)) はサーバーに置けません。1970 年より後の時刻にしてください。"
    case .tooLarge(let count):
      "暗号化した文書が \(count) バイトになり、サーバーに置ける \(Layout.largest) バイトを超えました。"
    }
  }
}

public enum EnvelopeError: LocalizedError, Equatable {
  case wrongSize(Int)
  case notASealedWriting

  public var errorDescription: String? {
    switch self {
    case .wrongSize(let count):
      "サーバーから届いた文書は \(count) バイトで、暗号化した文書の大きさではありません。"
    case .notASealedWriting:
      "サーバーから届いたものは、暗号化した文書ではありません。"
    }
  }
}

/// A sealed writing this own key can't open: sealed with another key, or altered since.
public struct OpeningError: LocalizedError, Equatable {
  public let id: UUID

  public var errorDescription: String? {
    "文書 \(id.uuidString) を開けませんでした。別の鍵で暗号化されたか、途中で書き換えられています。"
  }
}
