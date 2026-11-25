import SwiftUI

/// The photos in `store` as the writings' pages show them. Each is read from the store off the main
/// actor, once while memory allows; the photo itself is decoded only when drawn.
final class WritingPhotos {
  let store: PhotoStore
  private let cache = NSCache<NSUUID, PagePhoto>()

  init(store: PhotoStore) {
    self.store = store
  }

  /// The photos with `ids`, in order, leaving out any the device doesn't have or can't read now.
  func read(_ ids: [UUID]) async -> [PagePhoto] {
    var found: [PagePhoto] = []
    for id in ids {
      if let photo = cache.object(forKey: id as NSUUID) {
        found.append(photo)
      } else if let photo = await store.read(id) {
        cache.setObject(photo, forKey: id as NSUUID)
        found.append(photo)
      }
    }
    return found
  }
}

/// A photo as a writing's page shows it: its thumbnail in the stack, and the photo itself in the
/// viewer.
nonisolated final class PagePhoto: Identifiable, Sendable {
  let id: UUID
  let thumbnail: UIImage
  let photo: UIImage

  init(id: UUID, thumbnail: UIImage, photo: UIImage) {
    self.id = id
    self.thumbnail = thumbnail
    self.photo = photo
  }
}

/// `content` with the photos of `ids` read from `photos`: none until they are read, and read again
/// whenever `ids` change.
struct ReadPhotos<Content: View>: View {
  let ids: [UUID]
  let photos: WritingPhotos
  @ViewBuilder let content: ([PagePhoto]) -> Content
  @State private var read: [PagePhoto] = []

  var body: some View {
    content(read)
      .task(id: ids) {
        let found = await photos.read(ids)
        // A read for `ids` that have changed since is dropped.
        guard !Task.isCancelled else { return }
        read = found
      }
  }
}
