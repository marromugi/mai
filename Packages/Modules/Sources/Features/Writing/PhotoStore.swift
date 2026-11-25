import UIKit
import os

/// Where the photos taken on the device are kept: each photo and a thumbnail of it, as JPEG files
/// in a directory of their own named by the photo's ID, under complete file protection, so they
/// can be read only while the device is unlocked. A writing points at its photos by these IDs.
nonisolated struct PhotoStore: Sendable {
  let directory: URL

  /// The store in the app's Application Support directory.
  static let onDevice = PhotoStore(
    directory: .applicationSupportDirectory.appending(path: "Photos", directoryHint: .isDirectory))

  /// The longest side of a thumbnail, in pixels: more than the largest print in a `PhotoStack`.
  static let thumbnailSide: CGFloat = 1200

  /// Keeps `image` and a thumbnail of it, and answers the new photo's ID. The photo is there with
  /// its thumbnail, or not at all.
  @concurrent func keep(_ image: UIImage) async throws(UnkeptPhoto) -> UUID {
    guard let photo = image.jpegData(compressionQuality: 0.9),
      let thumbnail = Self.thumbnail(of: image).jpegData(compressionQuality: 0.8)
    else {
      throw UnkeptPhoto(reason: UnencodablePhoto())
    }
    let id = UUID()
    try write(photo: photo, thumbnail: thumbnail, as: id)
    return id
  }

  /// Writes `photo` and `thumbnail`, both JPEG, as the photo with `id`: there with both files, or
  /// not at all.
  func write(photo: Data, thumbnail: Data, as id: UUID) throws(UnkeptPhoto) {
    let partial = directory.appending(
      path: ".\(id.uuidString).partial", directoryHint: .isDirectory)
    let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: protection)
      try FileManager.default.createDirectory(
        at: partial, withIntermediateDirectories: false, attributes: protection)
    } catch {
      throw UnkeptPhoto(reason: error)
    }
    do {
      try photo.write(to: partial.appending(path: Self.photo), options: .completeFileProtection)
      try thumbnail.write(
        to: partial.appending(path: Self.thumbnail), options: .completeFileProtection)
      try FileManager.default.moveItem(at: partial, to: folder(of: id))
    } catch {
      do {
        try FileManager.default.removeItem(at: partial)
      } catch let removal {
        photoLogger.error("A photo not kept left \(partial.lastPathComponent): \(removal)")
      }
      throw UnkeptPhoto(reason: error)
    }
  }

  /// The photo with `id` as a page shows it, its thumbnail decoded, or nil when the device has no
  /// such photo or can't read it now.
  @concurrent func read(_ id: UUID) async -> PagePhoto? {
    guard let photo = photo(id),
      let thumbnail = await thumbnail(id)?.byPreparingForDisplay()
    else { return nil }
    return PagePhoto(id: id, thumbnail: thumbnail, photo: photo)
  }

  /// The photo with `id`, decoded only when drawn, or nil when the device has no such photo or
  /// can't read it now.
  func photo(_ id: UUID) -> UIImage? {
    UIImage(contentsOfFile: folder(of: id).appending(path: Self.photo).path(percentEncoded: false))
  }

  /// The thumbnail of the photo with `id`, or nil when the device has no such photo or can't read
  /// it now.
  func thumbnail(_ id: UUID) -> UIImage? {
    UIImage(
      contentsOfFile: folder(of: id).appending(path: Self.thumbnail).path(percentEncoded: false))
  }

  /// The photo with `id` and its thumbnail as kept, JPEG, or nil when the device has no such
  /// photo.
  @concurrent func files(of id: UUID) async throws -> (photo: Data, thumbnail: Data)? {
    let folder = folder(of: id)
    do {
      return (
        try Data(contentsOf: folder.appending(path: Self.photo)),
        try Data(contentsOf: folder.appending(path: Self.thumbnail))
      )
    } catch CocoaError.fileReadNoSuchFile {
      return nil
    }
  }

  /// Whether the device has the photo with `id`.
  func has(_ id: UUID) -> Bool {
    FileManager.default.fileExists(atPath: folder(of: id).path(percentEncoded: false))
  }

  func folder(of id: UUID) -> URL {
    directory.appending(path: id.uuidString, directoryHint: .isDirectory)
  }

  private static let photo = "photo.jpg"
  private static let thumbnail = "thumbnail.jpg"

  /// `image` scaled down to fit `thumbnailSide`, upright; `image` itself when it is no larger.
  private static func thumbnail(of image: UIImage) -> UIImage {
    let pixels = CGSize(
      width: image.size.width * image.scale, height: image.size.height * image.scale)
    let fit = thumbnailSide / max(pixels.width, pixels.height)
    guard fit < 1 else { return image }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let size = CGSize(
      width: max(1, (pixels.width * fit).rounded()), height: max(1, (pixels.height * fit).rounded())
    )
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }
}

/// A photo taken that couldn't be kept on the device, so it isn't added to the writing.
nonisolated struct UnkeptPhoto: LocalizedError {
  let reason: any Error

  var errorDescription: String? {
    "撮った写真を端末に残せませんでした。端末の空き容量を確かめて、もう一度撮ってください。"
  }
}

/// A photo that couldn't be made into a JPEG.
nonisolated struct UnencodablePhoto: Error {}

nonisolated let photoLogger = Logger(subsystem: "com.marromugi.mai", category: "photos")
