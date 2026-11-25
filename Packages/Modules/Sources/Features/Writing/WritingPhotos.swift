import UIKit

/// The photos in `store` as the writings' pages show them. Each is read from the store once, while
/// memory allows, and the photo itself is decoded only when drawn.
final class WritingPhotos {
  let store: PhotoStore
  private let read = NSCache<NSUUID, PagePhoto>()

  init(store: PhotoStore) {
    self.store = store
  }

  /// The photos with `ids`, in order, leaving out any the device doesn't have or can't read now.
  func shown(_ ids: [UUID]) -> [PagePhoto] {
    ids.compactMap { id in
      if let photo = read.object(forKey: id as NSUUID) { return photo }
      guard let thumbnail = store.thumbnail(id), let image = store.photo(id) else { return nil }
      let photo = PagePhoto(id: id, thumbnail: thumbnail, photo: image)
      read.setObject(photo, forKey: id as NSUUID)
      return photo
    }
  }
}

/// A photo as a writing's page shows it: its thumbnail in the stack, and the photo itself in the
/// viewer.
final class PagePhoto: Identifiable {
  let id: UUID
  let thumbnail: UIImage
  let photo: UIImage

  init(id: UUID, thumbnail: UIImage, photo: UIImage) {
    self.id = id
    self.thumbnail = thumbnail
    self.photo = photo
  }
}
