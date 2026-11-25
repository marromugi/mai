import Foundation
import Testing
import UIKit

@testable import Features

/// A photo store in a directory of its own that doesn't exist yet, removed when the test ends.
private func withEmptyStore(_ test: (PhotoStore) async throws -> Void) async throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "PhotoStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  try await test(PhotoStore(directory: directory))
}

/// The size of `image` in pixels, upright.
private func pixels(_ image: UIImage?) -> CGSize? {
  image.map { CGSize(width: $0.size.width * $0.scale, height: $0.size.height * $0.scale) }
}

/// A photo `size` pixels, of one colour.
private func photo(_ size: CGSize) -> UIImage {
  let format = UIGraphicsImageRendererFormat()
  format.scale = 1
  return UIGraphicsImageRenderer(size: size, format: format).image { context in
    UIColor.systemTeal.setFill()
    context.fill(CGRect(origin: .zero, size: size))
  }
}

#if targetEnvironment(simulator)
  nonisolated private let onADevice = false
#else
  nonisolated private let onADevice = true
#endif

struct PhotoStoreTests {
  @Test func aKeptPhotoIsReadBackByTheNextLaunch() async throws {
    try await withEmptyStore { store in
      let id = try await store.keep(.portrait)
      let relaunched = PhotoStore(directory: store.directory)
      #expect(pixels(relaunched.photo(id)) == CGSize(width: 300, height: 400))
      #expect(pixels(relaunched.thumbnail(id)) == CGSize(width: 300, height: 400))
    }
  }

  @Test func eachPhotoKeptGetsAnIDOfItsOwn() async throws {
    try await withEmptyStore { store in
      let first = try await store.keep(.portrait)
      let second = try await store.keep(.portrait)
      #expect(first != second)
      #expect(store.photo(first) != nil)
      #expect(store.photo(second) != nil)
    }
  }

  @Test func aPhotoTheStoreDoesntHaveReadsAsNil() async throws {
    try await withEmptyStore { store in
      #expect(store.photo(UUID(sample: 1)) == nil)
      #expect(store.thumbnail(UUID(sample: 1)) == nil)
    }
  }

  /// A photo the camera took on its side is read back the way it was held.
  @Test func aPhotoKeepsWhichWayUpItWasTaken() async throws {
    try await withEmptyStore { store in
      let sideways = try #require(photo(CGSize(width: 400, height: 300)).cgImage)
      let id = try await store.keep(UIImage(cgImage: sideways, scale: 1, orientation: .right))
      #expect(pixels(store.photo(id)) == CGSize(width: 300, height: 400))
      #expect(pixels(store.thumbnail(id)) == CGSize(width: 300, height: 400))
    }
  }

  /// A photo larger than a thumbnail is kept whole, and its thumbnail fits `thumbnailSide`.
  @Test(arguments: [
    (CGSize(width: 2400, height: 1800), CGSize(width: 1200, height: 900)),
    (CGSize(width: 1500, height: 3000), CGSize(width: 600, height: 1200)),
  ])
  func theThumbnailFitsItsSide(_ size: CGSize, _ thumbnail: CGSize) async throws {
    try await withEmptyStore { store in
      let id = try await store.keep(photo(size))
      #expect(pixels(store.photo(id)) == size)
      #expect(pixels(store.thumbnail(id)) == thumbnail)
    }
  }

  /// The photo, its thumbnail, and the directories over them can be read only while the device is
  /// unlocked. The simulator keeps no file protection, so this runs on a device only.
  @Test(.enabled(if: onADevice, "The simulator keeps no file protection"))
  func photosAreUnderCompleteProtection() async throws {
    try await withEmptyStore { store in
      let id = try await store.keep(.portrait)
      let folder = store.folder(of: id)
      for item in [
        store.directory, folder, folder.appending(path: "photo.jpg"),
        folder.appending(path: "thumbnail.jpg"),
      ] {
        let attributes = try FileManager.default.attributesOfItem(
          atPath: item.path(percentEncoded: false))
        #expect(
          attributes[.protectionKey] as? FileProtectionType == .complete,
          "\(item.lastPathComponent)")
      }
    }
  }

  /// A sweep removes the photos not kept, and what a keep that stopped part way left; it leaves
  /// anything else in the directory alone.
  @Test func aSweepRemovesThePhotosNotKept() async throws {
    try await withEmptyStore { store in
      let kept = try await store.keep(.portrait)
      let dropped = try await store.keep(.landscape)
      let partial = store.directory.appending(path: ".\(UUID().uuidString).partial")
      try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: false)
      let other = store.directory.appending(path: "notes.txt")
      try Data("メモ".utf8).write(to: other)

      try store.sweep(keeping: [kept, UUID(sample: 9)])

      #expect(store.photo(kept) != nil)
      #expect(store.photo(dropped) == nil)
      #expect(!FileManager.default.fileExists(atPath: store.folder(of: dropped).path()))
      #expect(!FileManager.default.fileExists(atPath: partial.path()))
      #expect(FileManager.default.fileExists(atPath: other.path()))
    }
  }

  @Test func sweepingAStoreNeverKeptToDoesNothing() async throws {
    try await withEmptyStore { store in
      try store.sweep(keeping: [])
      #expect(!FileManager.default.fileExists(atPath: store.directory.path()))
    }
  }
}

@MainActor
struct WritingPhotosTests {
  /// The page shows the photos in the writing's order, leaving out one the device doesn't have.
  @Test func thePageShowsThePhotosTheDeviceHas() async throws {
    try await withEmptyStore { store in
      let first = try await store.keep(.portrait)
      let second = try await store.keep(.landscape)
      let photos = WritingPhotos(store: store)
      let shown = photos.shown([second, UUID(sample: 1), first])
      #expect(shown.map(\.id) == [second, first])
      #expect(pixels(shown.first?.thumbnail) == CGSize(width: 400, height: 300))
      #expect(pixels(shown.first?.photo) == CGSize(width: 400, height: 300))
    }
  }

  /// A photo read once is shown again without reading the store.
  @Test func aPhotoIsReadOnce() async throws {
    try await withEmptyStore { store in
      let id = try await store.keep(.portrait)
      let photos = WritingPhotos(store: store)
      let first = try #require(photos.shown([id]).first)
      try FileManager.default.removeItem(at: store.folder(of: id))
      #expect(photos.shown([id]).first === first)
    }
  }
}

@MainActor
struct LaunchSweepTests {
  /// At launch, the photos no writing points at are removed, and those a writing points at stay.
  @Test func theLaunchRemovesPhotosNoWritingPointsAt() async throws {
    try await withEmptyStore { photos in
      let writings = FileWritingStore(directory: photos.directory.appending(path: "Writings"))
      let kept = try await photos.keep(.portrait)
      let dropped = try await photos.keep(.landscape)
      try writings.save(Writing(title: "写真", body: "一枚", photos: [kept]))

      let page = HostedPage(RootView(store: writings, photoStore: photos))
      try await page.settle { photos.photo(dropped) == nil }

      #expect(photos.photo(dropped) == nil)
      #expect(photos.photo(kept) != nil)
    }
  }

  /// When the writings can't be read, no photo is removed.
  @Test func theLaunchRemovesNoPhotoWhenTheWritingsCantBeRead() async throws {
    try await withEmptyStore { photos in
      let writings = FileWritingStore(directory: photos.directory.appending(path: "Writings"))
      let id = try await photos.keep(.portrait)
      try FileManager.default.createDirectory(
        at: writings.directory, withIntermediateDirectories: true)
      try Data("文書ではない".utf8).write(to: writings.file(for: UUID(sample: 1)))

      let page = HostedPage(RootView(store: writings, photoStore: photos))
      try await page.settle { false }

      #expect(photos.photo(id) != nil)
    }
  }
}
