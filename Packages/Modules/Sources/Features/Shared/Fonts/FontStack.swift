import CoreGraphics
import SwiftUI

/// Families in order of preference, as CSS's `font-family`: a character the first lacks is set in
/// the next. Holds names only, so a stack made elsewhere can be taken in as it is.
struct FontStack: Codable, Hashable {
  var names: [String]

  /// The bundled family alone.
  static let standard = FontStack(names: [])

  /// The families text is set in, in order: each of `known` the stack names, then the bundled
  /// family unless named already, so Japanese never falls back to a system font.
  func families(from known: [FontFamily] = FontFamily.known) -> [FontFamily] {
    var families: [FontFamily] = []
    for name in names {
      guard let family = known.first(where: { $0.name == name }), !families.contains(family)
      else { continue }
      families.append(family)
    }
    if !families.contains(.notoSansJP) {
      families.append(.notoSansJP)
    }
    return families
  }

  /// The em box's descent of the first family with Japanese, which sets the Japanese text.
  func emBoxDescent(from known: [FontFamily] = FontFamily.known) -> CGFloat {
    guard let descent = families(from: known).lazy.compactMap(\.emBoxDescent).first else {
      preconditionFailure("A stack always ends in the bundled family, which has Japanese.")
    }
    return descent
  }
}

extension EnvironmentValues {
  /// The families the text in this subtree is set in.
  @Entry var fontStack: FontStack = .standard
}
