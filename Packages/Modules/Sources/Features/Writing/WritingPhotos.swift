import UIKit

/// The photos taken on each writing's page, oldest first, kept while the app runs.
struct WritingPhotos {
  private var photos: [WritingRow.ID: [UIImage]] = [:]

  subscript(id: WritingRow.ID) -> [UIImage] {
    get { photos[id, default: []] }
    set { photos[id] = newValue }
  }
}
