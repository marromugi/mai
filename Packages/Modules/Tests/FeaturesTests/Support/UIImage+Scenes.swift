import UIKit

extension UIImage {
  /// A new photo 3 wide by 4 tall: a sky over a hill, with a sun at the top leading corner. Each is
  /// its own image, as each photo the camera takes is.
  static var portrait: UIImage {
    scene(CGSize(width: 300, height: 400), sky: .systemTeal)
  }

  /// A new photo 3 wide by 4 tall under a dusk sky, told apart from `portrait`.
  static var dusk: UIImage {
    scene(CGSize(width: 300, height: 400), sky: .systemIndigo)
  }

  /// A new photo 4 wide by 3 tall, in other colours.
  static var landscape: UIImage {
    scene(CGSize(width: 400, height: 300), sky: .systemOrange)
  }

  /// A new photo 1 wide by 4 tall, taller than any screen's shape.
  static var tall: UIImage {
    scene(CGSize(width: 100, height: 400), sky: .systemPink)
  }

  private static func scene(_ size: CGSize, sky: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      sky.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.systemGreen.setFill()
      context.fill(CGRect(x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4))
      UIColor.systemYellow.setFill()
      context.cgContext.fillEllipse(
        in: CGRect(x: size.width * 0.1, y: size.height * 0.1, width: 60, height: 60))
    }
  }
}
