import Foundation
import Sync
import Testing

@testable import Features

struct SyncedPhotosTests {
  private let photo = PlainPhoto(
    id: UUID(), photo: Data("写真".utf8), thumbnail: Data("サムネイル".utf8))

  /// Photos in a directory of their own that doesn't exist yet, removed when the test ends.
  private func withEmptyStore(_ test: (SyncedPhotos) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "SyncedPhotosTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await test(SyncedPhotos(store: PhotoStore(directory: directory)))
  }

  @Test func aPhotoReceivedIsReadBackAsItCame() async throws {
    try await withEmptyStore { photos in
      #expect(try await photos.read(photo.id) == nil)
      try await photos.keep(photo)
      #expect(try await photos.read(photo.id) == photo)
    }
  }

  @Test func aPhotoReceivedTwiceIsKeptAsItCameFirst() async throws {
    try await withEmptyStore { photos in
      try await photos.keep(photo)
      try await photos.keep(
        PlainPhoto(id: photo.id, photo: Data("別".utf8), thumbnail: photo.thumbnail))
      #expect(try await photos.read(photo.id) == photo)
    }
  }

  /// A keep of the same photo cut off before (the app quit mid-write) leaves its partial
  /// directory; the next keep clears it.
  @Test func aPhotoWhoseKeepWasCutOffIsKeptTheNextTime() async throws {
    try await withEmptyStore { photos in
      let partial = photos.store.directory.appending(
        path: ".\(photo.id.uuidString).partial", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
      try Data("途中".utf8).write(to: partial.appending(path: "photo.jpg"))

      try await photos.keep(photo)

      #expect(try await photos.read(photo.id) == photo)
      #expect(
        try FileManager.default.contentsOfDirectory(atPath: photos.store.directory.path())
          == [photo.id.uuidString])
    }
  }
}
