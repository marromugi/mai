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

  /// `role`'s font from `stack`'s first family, falling back through the rest in order.
  func font(_ role: TextRole, in stack: FontStack) -> UIFont {
    font(role, in: stack.families())
  }

  /// `role`'s font from the first of `families`, falling back through the rest in order.
  func font(_ role: TextRole, in families: [FontFamily]) -> UIFont {
    BundledFonts.register()
    let fonts = families.map { family in
      let name = family.postScriptName(role)
      guard let font = UIFont(name: name, size: size(role)) else {
        fatalError("\(name) is known as a family's face but UIFont can't load it.")
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
