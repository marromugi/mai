import Testing
import UIKit

@testable import Features

struct IconAssetsTests {
  @Test(arguments: ["gesture-drag-base", "gesture-pinch-line-height", "gesture-pinch-tracking"])
  func gestureIconLoadsAsATemplate(_ name: String) throws {
    let image = try #require(UIImage(named: name, in: .module, compatibleWith: nil))
    #expect(image.renderingMode == .alwaysTemplate)
    #expect(image.size == CGSize(width: 24, height: 24))
  }
}
