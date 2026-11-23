import SwiftUI
import UIKit

@testable import Features

extension Camera {
  /// A camera whose screen, the first time it is asked for, calls `shown` and then hands back
  /// `photo`, or cancels when there is none.
  ///
  /// It answers from a task, not from `onAppear`: a test's window belongs to no scene, so what it
  /// presents never appears. SwiftUI may ask for the screen more than once for one presentation.
  static func standIn(taking photo: UIImage?, shown: @escaping () -> Void = {}) -> Camera {
    let asked = Asked()
    return Camera(isAvailable: true) { taken, cancelled in
      if !asked.yet {
        asked.yet = true
        shown()
        Task {
          if let photo { taken(photo) } else { cancelled() }
        }
      }
      return AnyView(Color.black)
    }
  }

  /// A camera that can't take a photo, as on a device with none.
  static let none = Camera(isAvailable: false) { _, _ in
    preconditionFailure("A camera that isn't there was asked for its screen.")
  }

  private final class Asked {
    var yet = false
  }

  /// A 2 × 2 photo of one colour.
  static func photo(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }
  }
}
