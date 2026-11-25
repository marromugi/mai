import Foundation
import SwiftUI
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

  /// A photo that can't be written isn't kept, and says so for a person.
  @Test func aPhotoThatCantBeWrittenIsNotKept() async throws {
    try await withEmptyStore { store in
      // A file where the store's directory goes.
      try FileManager.default.createDirectory(
        at: store.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("ファイル".utf8).write(to: store.directory)
      let error = await #expect(throws: UnkeptPhoto.self) {
        try await store.keep(.portrait)
      }
      #expect(
        error?.localizedDescription
          == "撮った写真を端末に残せませんでした。端末の空き容量を確かめて、もう一度撮ってください。")
    }
  }

  /// A photo is read for a page with its thumbnail, and not when the device doesn't have it.
  @Test func aPhotoIsReadForAPage() async throws {
    try await withEmptyStore { store in
      let id = try await store.keep(.landscape)
      let read = try #require(await store.read(id))
      #expect(read.id == id)
      #expect(pixels(read.thumbnail) == CGSize(width: 400, height: 300))
      #expect(pixels(read.photo) == CGSize(width: 400, height: 300))
      #expect(await store.read(UUID()) == nil)
    }
  }
}

@MainActor
struct WritingPhotosTests {
  /// The page gets the photos in the writing's order, leaving out one the device doesn't have.
  @Test func thePageGetsThePhotosTheDeviceHas() async throws {
    try await withEmptyStore { store in
      let first = try await store.keep(.portrait)
      let second = try await store.keep(.landscape)
      let photos = WritingPhotos(store: store)
      let read = await photos.read([second, UUID(), first])
      #expect(read.map(\.id) == [second, first])
    }
  }

  /// A photo read once is given again without reading the store.
  @Test func aPhotoIsReadOnce() async throws {
    try await withEmptyStore { store in
      let id = try await store.keep(.portrait)
      let photos = WritingPhotos(store: store)
      let first = try #require(await photos.read([id]).first)
      try FileManager.default.removeItem(at: store.folder(of: id))
      #expect(await photos.read([id]).first === first)
    }
  }

  /// The view is given the photos once they are read, and read again when the IDs change.
  @Test func theViewIsGivenThePhotosRead() async throws {
    try await withEmptyStore { store in
      let first = try await store.keep(.portrait)
      let second = try await store.keep(.landscape)
      let photos = WritingPhotos(store: store)
      let given = Given()
      func view(_ ids: [UUID]) -> some View {
        ReadPhotos(ids: ids, photos: photos) { read in
          Text(verbatim: "\(read.count)")
            .onAppear { given.ids = read.map(\.id) }
            .onChange(of: read.map(\.id)) { given.ids = $1 }
        }
      }
      let page = HostedPage(view([first]))
      try await page.settle { given.ids == [first] }
      #expect(given.ids == [first])
      page.show(view([first, second]))
      try await page.settle { given.ids == [first, second] }
      #expect(given.ids == [first, second])
    }
  }

  private final class Given {
    var ids: [UUID] = []
  }
}
