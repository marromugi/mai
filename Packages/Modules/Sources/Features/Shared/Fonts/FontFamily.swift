import CoreGraphics
import CoreText
import Foundation
internal import Typesetting
import UIKit

/// A family text can be set in, named as Google Fonts names it: its regular face sets the body
/// roles and its bold the headings.
nonisolated struct FontFamily: Hashable, Identifiable, Sendable {
  /// How a family's bold face is made.
  enum Bold: Hashable {
    /// A face of its own, by PostScript name.
    case face(String)
    /// The regular face at this value of its `wght` axis: a variable font has no Bold by name.
    case weight(CGFloat)
  }

  /// What a stack and `FontFamily.known` hold it under.
  let name: String
  /// What the settings show it as.
  let title: String
  let regular: String
  let bold: Bold
  /// How far below the baseline its ideographic em box ends, in em; nil for a family with no
  /// Japanese.
  let emBoxDescent: CGFloat?
  let files: [FontFile]
  /// In the app's bundle, or else fetched from the server (`FontLibrary`).
  let isBundled: Bool

  var id: String { name }

  /// Whether it is listed with the Japanese families rather than the Latin ones.
  var hasJapanese: Bool { emBoxDescent != nil }

  /// The bundled Source Han Sans JP, under the name of the same design on Google Fonts. Every stack
  /// ends in it.
  static let notoSansJP = FontFamily(
    name: "Noto Sans JP", title: "源ノ角ゴシック", regular: "SourceHanSansJP-Regular",
    bold: .face("SourceHanSansJP-Bold"), emBoxDescent: 0.12,
    files: [
      FontFile(
        name: "SourceHanSansJP-Regular.otf",
        sha256: "40d1b760d1135539f6b6e0ee2b9f415de6d97576f7676840b06306c7c190c074",
        size: 4_562_224),
      FontFile(
        name: "SourceHanSansJP-Bold.otf",
        sha256: "3a2722f94c97a53b172579a10ef8fc34b3fa8a6bb4f7947a2ec709ab647fb755",
        size: 4_665_748),
    ],
    isBundled: true)

  static let inter = FontFamily(
    name: "Inter", title: "Inter", regular: "Inter-Regular", bold: .weight(700),
    emBoxDescent: nil,
    files: [
      FontFile(
        name: "Inter.ttf",
        sha256: "29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031",
        size: 876_576)
    ],
    isBundled: true)

  static let lora = FontFamily(
    name: "Lora", title: "Lora", regular: "Lora-Regular", bold: .weight(700), emBoxDescent: nil,
    files: [
      FontFile(
        name: "Lora.ttf",
        sha256: "822a6621ccbe8d97d20ac88c1c41f5615c9c2c202eaa75f272cd452aac6475a7",
        size: 212_196)
    ],
    isBundled: true)

  static let zenKakuGothicNew = FontFamily(
    name: "Zen Kaku Gothic New", title: "Zen角ゴシックNew", regular: "ZenKakuGothicNew-Regular",
    bold: .face("ZenKakuGothicNew-Bold"), emBoxDescent: 0.12,
    files: [
      FontFile(
        name: "ZenKakuGothicNew-Regular.ttf",
        sha256: "b840cd07a67d89cacca44249ae49aa99ee7640eb5ce623be8d8983d6aabac801",
        size: 2_360_248),
      FontFile(
        name: "ZenKakuGothicNew-Bold.ttf",
        sha256: "0081cedabc4921982fcd061f845a005664ac7fb642af2dd34b4007bc63ccd235",
        size: 2_314_424),
    ],
    isBundled: false)

  static let zenOldMincho = FontFamily(
    name: "Zen Old Mincho", title: "Zenオールド明朝", regular: "ZenOldMincho-Regular",
    bold: .face("ZenOldMincho-Bold"), emBoxDescent: 0.12,
    files: [
      FontFile(
        name: "ZenOldMincho-Regular.ttf",
        sha256: "4c051a78a21c4e8e9dccf1c754776d33f356b8cc6ef95d9b64761b9bae814b84",
        size: 5_442_512),
      FontFile(
        name: "ZenOldMincho-Bold.ttf",
        sha256: "d6b95c1ff45c8dac153d28961e4c37d7d03b648330c71f884d124dc652a13c0d",
        size: 5_436_460),
    ],
    isBundled: false)

  static let bizUDPMincho = FontFamily(
    name: "BIZ UDPMincho", title: "BIZ UDP明朝", regular: "BIZUDPMincho-Regular",
    bold: .face("BIZUDPMincho-Bold"), emBoxDescent: 0.12,
    files: [
      FontFile(
        name: "BIZUDPMincho-Regular.ttf",
        sha256: "dbcea04578ac1e9d3484525e870ce491bd04361768f4d2ba4b827d96e20f891d",
        size: 6_156_444),
      FontFile(
        name: "BIZUDPMincho-Bold.ttf",
        sha256: "99618e39b881597efc03d58706bd194757c968c1bf7a7017a893efead6b1b260",
        size: 7_109_432),
    ],
    isBundled: false)

  /// Every family the app can set text in.
  static let known: [FontFamily] = [
    notoSansJP, inter, lora, zenKakuGothicNew, zenOldMincho, bizUDPMincho,
  ]

  /// The PostScript names its files hold: its regular face, and its bold where that is a face of
  /// its own.
  var faceNames: Set<String> {
    switch bold {
    case .face(let name): [regular, name]
    case .weight: [regular]
    }
  }

  /// The bytes of all its files.
  var size: Int { files.map(\.size).reduce(0, +) }

  /// `role`'s face at `size`, or nil while its files aren't registered.
  func font(_ role: TextRole, size: CGFloat) -> UIFont? {
    switch role {
    case .body, .meta, .caption:
      return UIFont(name: regular, size: size)
    case .display, .heading, .title:
      switch bold {
      case .face(let name):
        return UIFont(name: name, size: size)
      case .weight(let weight):
        guard let font = UIFont(name: regular, size: size) else { return nil }
        let descriptor = font.fontDescriptor.addingAttributes([
          UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
            Self.weightAxis: weight
          ]
        ])
        return UIFont(descriptor: descriptor, size: size)
      }
    }
  }

  /// The `wght` axis's tag as a number, which is how Core Text names an axis.
  static let weightAxis = 0x7767_6874
}

/// One file of a family, as it is in the app's bundle or on the server: its name, the SHA-256 a
/// fetched copy has to match, and its size, shown before it is fetched.
nonisolated struct FontFile: Hashable, Sendable {
  let name: String
  let sha256: String
  let size: Int
}

nonisolated extension [FontFamily] {
  /// The em box's descent of the first family with Japanese, which sets the Japanese text.
  var emBoxDescent: CGFloat {
    guard let descent = lazy.compactMap(\.emBoxDescent).first else {
      preconditionFailure("A stack's families always end in one with Japanese.")
    }
    return descent
  }
}
