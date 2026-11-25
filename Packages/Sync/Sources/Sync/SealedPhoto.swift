import CryptoKit
import Foundation

/// A photo as the device keeps it: its ID, and the photo and its thumbnail in plain bytes.
public struct PlainPhoto: Sendable, Equatable {
  public let id: UUID
  public let photo: Data
  public let thumbnail: Data

  public init(id: UUID, photo: Data, thumbnail: Data) {
    self.id = id
    self.photo = photo
    self.thumbnail = thumbnail
  }
}

/// The two parts a photo is sealed and kept in, each apart (`Server/README.md`, 「写真」).
public enum PhotoPart: UInt8, Sendable, CaseIterable {
  case photo = 1
  case thumbnail = 2

  /// The most bytes the server takes of this part sealed.
  public var largest: Int {
    switch self {
    case .photo: 50_000_000
    case .thumbnail: 1_000_000
    }
  }
}

/// One part of a photo sealed on this device, ready for the server. Only `OwnKey.seal(_:)` makes
/// one, and `WritingServer.send(_:)` takes nothing else, so nothing but ciphertext is ever sent.
///
/// Its bytes are laid out as `Server/README.md` says (「封じた写真の形」): the header (magic, the
/// photo's ID, the part), the photo key sealed with the own key, then the part sealed with the
/// photo key. Both seals are AES-256-GCM and take the header as authenticated data.
public struct SealedPhoto: Sendable {
  public let id: UUID
  public let part: PhotoPart
  let bytes: Data

  fileprivate init(id: UUID, part: PhotoPart, bytes: Data) {
    self.id = id
    self.part = part
    self.bytes = bytes
  }
}

/// One part of a sealed photo read from the server, of the one shape but not yet opened.
public struct PhotoEnvelope: Sendable, Equatable {
  public let id: UUID
  public let part: PhotoPart
  let bytes: Data

  public init(bytes: Data) throws(PhotoEnvelopeError) {
    let bytes = Data(bytes)
    guard bytes.count >= PhotoLayout.smallest, bytes.prefix(4) == PhotoLayout.magic,
      let part = PhotoPart(rawValue: bytes[20])
    else {
      throw PhotoEnvelopeError()
    }
    guard bytes.count <= part.largest else { throw PhotoEnvelopeError() }
    id = UUID(uuid: Layout.uuid(bytes[4..<20]))
    self.part = part
    self.bytes = bytes
  }
}

extension OwnKey {
  /// Seals `photo`'s two parts apart, each with a photo key made for this seal, and seals that key
  /// with this one.
  public func seal(_ photo: PlainPhoto) throws(SealingError) -> (
    photo: SealedPhoto, thumbnail: SealedPhoto
  ) {
    let photoKey = SymmetricKey(size: .bits256)
    return (
      try seal(photo.photo, as: .photo, of: photo.id, with: photoKey),
      try seal(photo.thumbnail, as: .thumbnail, of: photo.id, with: photoKey)
    )
  }

  private func seal(_ contents: Data, as part: PhotoPart, of id: UUID, with photoKey: SymmetricKey)
    throws(SealingError) -> SealedPhoto
  {
    let header = PhotoLayout.header(of: id, part)
    let bytes: Data
    do {
      let sealedKey = try AES.GCM.seal(
        photoKey.withUnsafeBytes { Data($0) }, using: key, authenticating: header)
      let sealedContents = try AES.GCM.seal(contents, using: photoKey, authenticating: header)
      guard let sealedKey = sealedKey.combined, let sealedContents = sealedContents.combined else {
        preconditionFailure("A box sealed with the default 12-byte nonce always has combined bytes")
      }
      bytes = header + sealedKey + sealedContents
    } catch {
      preconditionFailure("AES-GCM fails only on a nonce or key of the wrong size: \(error)")
    }
    guard bytes.count <= part.largest else {
      throw .photoTooLarge(bytes.count, largest: part.largest)
    }
    return SealedPhoto(id: id, part: part, bytes: bytes)
  }

  /// Opens one part of a sealed photo, failing when it wasn't sealed with this key or was altered
  /// since.
  public func open(_ envelope: PhotoEnvelope) throws(PhotoOpeningError) -> Data {
    let bytes = envelope.bytes
    let header = bytes.prefix(PhotoLayout.header)
    do {
      let sealedKey = try AES.GCM.SealedBox(
        combined: bytes[PhotoLayout.header..<PhotoLayout.header + Layout.sealedKey])
      let photoKey = try AES.GCM.open(sealedKey, using: key, authenticating: header)
      let sealedContents = try AES.GCM.SealedBox(
        combined: bytes[(PhotoLayout.header + Layout.sealedKey)...])
      return try AES.GCM.open(
        sealedContents, using: SymmetricKey(data: photoKey), authenticating: header)
    } catch {
      throw PhotoOpeningError(id: envelope.id)
    }
  }
}

enum PhotoLayout {
  static let magic = Data([0x6d, 0x61, 0x70, 0x01])
  static let header = 21
  static let smallest = header + Layout.sealedKey + 12 + 16

  static func header(of id: UUID, _ part: PhotoPart) -> Data {
    magic + withUnsafeBytes(of: id.uuid) { Data($0) } + Data([part.rawValue])
  }
}

/// What the server gave for a photo is not a sealed photo's part.
public struct PhotoEnvelopeError: LocalizedError, Equatable {
  public var errorDescription: String? {
    "サーバーから届いたものは、暗号化した写真ではありません。"
  }
}

/// A sealed photo this own key can't open: sealed with another key, or altered since.
public struct PhotoOpeningError: LocalizedError, Equatable {
  public let id: UUID

  public var errorDescription: String? {
    "写真 \(id.uuidString) を開けませんでした。別の鍵で暗号化されたか、途中で書き換えられています。"
  }
}
