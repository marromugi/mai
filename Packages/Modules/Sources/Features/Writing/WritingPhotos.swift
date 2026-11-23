import UIKit

/// The photos taken on each writing's page, oldest first, kept while the app runs.
struct WritingPhotos {
  private var photos: [Writing.ID: [UIImage]] = [:]

  subscript(id: Writing.ID) -> [UIImage] {
    get { photos[id, default: []] }
    set { photos[id] = newValue }
  }
}
