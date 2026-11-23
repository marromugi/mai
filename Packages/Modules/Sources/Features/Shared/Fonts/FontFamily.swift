import CoreGraphics
internal import Typesetting

/// A family text can be set in, named as Google Fonts names it: `regular` sets the body roles and
/// `bold` the headings.
struct FontFamily: Hashable {
  let name: String
  let regular: String
  let bold: String
  /// How far below the baseline its ideographic em box ends, in em; nil for a family with no
  /// Japanese.
  let emBoxDescent: CGFloat?

  /// The bundled Source Han Sans JP, under the name of the same design on Google Fonts.
  static let notoSansJP = FontFamily(
    name: "Noto Sans JP", regular: BundledFonts.regular, bold: BundledFonts.bold,
    emBoxDescent: 0.12)

  /// Every family the app can set text in.
  static let known: [FontFamily] = [notoSansJP]

  func postScriptName(_ role: TextRole) -> String {
    switch role {
    case .display, .heading, .title: bold
    case .body, .meta, .caption: regular
    }
  }
}
