import SwiftUI

/// Families in order of preference, as CSS's `font-family`: a character the first lacks is set in
/// the next. Holds names only, so a stack made elsewhere can be taken in as it is.
struct FontStack: Codable, Hashable {
  var names: [String]

  /// The bundled family alone.
  static let standard = FontStack(names: [])

  /// The families text is set in, in order: each of `available` the stack names, then the bundled
  /// family unless named already, so Japanese never falls back to a system font.
  func families(from available: [FontFamily] = FontFamily.known) -> [FontFamily] {
    var families: [FontFamily] = []
    for name in names {
      guard let family = available.first(where: { $0.name == name }), !families.contains(family)
      else { continue }
      families.append(family)
    }
    if !families.contains(.notoSansJP) {
      families.append(.notoSansJP)
    }
    return families
  }
}

extension EnvironmentValues {
  /// The families the text in this subtree is set in, as `FontStack.families(from:)` gives them.
  @Entry var fontFamilies: [FontFamily] = FontStack.standard.families()
}
