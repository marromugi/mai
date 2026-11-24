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

  /// `role`'s font from the first of `families`, falling back through the rest in order.
  func font(_ role: TextRole, in families: [FontFamily]) -> UIFont {
    BundledFonts.register()
    let fonts = families.map { family in
      guard let font = family.font(role, size: size(role)) else {
        fatalError("\(family.name) is set in before its files are registered.")
      }
      return font
    }
    guard let first = fonts.first else {
      preconditionFailure("A font is made from at least one family.")
    }
    guard fonts.count > 1 else { return first }
    let descriptor = first.fontDescriptor.addingAttributes([
      .cascadeList: fonts.dropFirst().map(\.fontDescriptor)
    ])
    return UIFont(descriptor: descriptor, size: size(role))
  }
}
