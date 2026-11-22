import SwiftUI
internal import Typesetting
import UIKit

extension TypeScale {
  /// For `body`, at the factor by which the system enlarges body text at `size`, and never less
  /// than 1.
  init(_ size: DynamicTypeSize, body: BodySetting) {
    func bodySize(_ category: UIContentSizeCategory) -> CGFloat {
      UIFont.preferredFont(
        forTextStyle: .body,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: category)
      ).pointSize
    }
    self.init(
      factor: max(1, bodySize(UIContentSizeCategory(size)) / bodySize(.large)), body: body)
  }

  func font(_ role: TextRole) -> UIFont {
    BundledFonts.register()
    guard let font = UIFont(name: role.postScriptName, size: size(role)) else {
      fatalError("\(role.postScriptName) is registered by BundledFonts but UIFont can't load it.")
    }
    return font
  }
}
