import UIKit

/// Where the photos taken on the device are kept: each photo and a thumbnail of it, as JPEG files
/// in a directory of their own named by the photo's ID, under complete file protection, so they
/// can be read only while the device is unlocked. A writing points at its photos by these IDs.
nonisolated struct PhotoStore: Sendable {
  let directory: URL

  /// The store in the app's Application Support directory.
  static let onDevice = PhotoStore(
    directory: .applicationSupportDirectory.appending(path: "Photos", directoryHint: .isDirectory))

  /// The longest side of a thumbnail, in pixels: enough for the largest print in a `PhotoStack`.
  static let thumbnailSide: CGFloat = 1200

  /// Keeps `image` and a thumbnail of it, and answers the new photo's ID. The photo is there with
  /// its thumbnail, or not at all.
  @concurrent func keep(_ image: UIImage) async throws -> UUID {
    guard let photo = image.jpegData(compressionQuality: 0.9),
      let thumbnail = Self.thumbnail(of: image).jpegData(compressionQuality: 0.8)
    else {
      throw UnencodablePhoto()
    }
    let id = UUID()
    let partial = directory.appending(
      path: ".\(id.uuidString).partial", directoryHint: .isDirectory)
    let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: protection)
    try FileManager.default.createDirectory(
      at: partial, withIntermediateDirectories: false, attributes: protection)
    do {
      try photo.write(to: partial.appending(path: Self.photo), options: .completeFileProtection)
      try thumbnail.write(
        to: partial.appending(path: Self.thumbnail), options: .completeFileProtection)
      try FileManager.default.moveItem(at: partial, to: folder(of: id))
    } catch {
      try? FileManager.default.removeItem(at: partial)
      throw error
    }
    return id
  }

  /// The photo with `id`, or nil when the device has no such photo or can't read it now.
  func photo(_ id: UUID) -> UIImage? {
    UIImage(contentsOfFile: folder(of: id).appending(path: Self.photo).path(percentEncoded: false))
  }

  /// The thumbnail of the photo with `id`, or nil when the device has no such photo or can't read
  /// it now.
  func thumbnail(_ id: UUID) -> UIImage? {
    UIImage(
      contentsOfFile: folder(of: id).appending(path: Self.thumbnail).path(percentEncoded: false))
  }

  /// Removes every photo but those in `kept`, and what a keep that stopped part way left.
  func sweep(keeping kept: Set<UUID>) throws {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    } catch CocoaError.fileReadNoSuchFile {
      return
    }
    for entry in entries {
      let name = entry.lastPathComponent
      let partial = name.hasPrefix(".") && name.hasSuffix(".partial")
      guard partial || UUID(uuidString: name).map({ !kept.contains($0) }) == true else { continue }
      try FileManager.default.removeItem(at: entry)
    }
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
      width: (pixels.width * fit).rounded(), height: (pixels.height * fit).rounded())
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }
  }
}

/// A photo that couldn't be made into a JPEG.
nonisolated struct UnencodablePhoto: LocalizedError {
  var errorDescription: String? {
    "写真を JPEG にできませんでした。"
  }
}
