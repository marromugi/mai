import SwiftUI
internal import Typesetting

extension View {
  /// Sets this text in `role` at the environment's Dynamic Type size and body setting.
  /// Body text is made with `Text(body:)`, which holds its line-breaking rules.
  /// Every line box is exactly `lineHeight(role)` tall, with the em box centred in it, and the
  /// body is tracked as its setting says.
  func textStyle(_ role: TextRole) -> some View {
    modifier(TextStyleModifier(role: role))
  }
}

extension Text {
  /// `string` as body text, broken by the strict rules: no line starts with ー, a small kana, or
  /// anything else 行頭禁則 forbids, and no break rests on a guessed language (#23). Each of
  /// `mentions` links to its writing, under a dotted line in the text's colour.
  init(body string: String, mentions: [TitleMention] = []) {
    self.init(AttributedString(body: string, mentions: mentions))
  }
}

extension AttributedString {
  /// `string` as `Text(body:mentions:)` sets it.
  init(body string: String, mentions: [TitleMention]) {
    self.init(string)
    self.languageIdentifier = Self.bodyLanguage
    for mention in mentions {
      guard let range = Range(mention.range, in: self) else {
        preconditionFailure("A mention's range is not in the body it was found in.")
      }
      self[range].link = mention.writing.link
      self[range].foregroundColor = .primary
      self[range].underlineStyle = Text.LineStyle(pattern: .dot)
    }
  }

  /// Undetermined, not `ja`: Japanese also turns on the text system's own spacing, which sets
  /// brackets half wide and moves characters off the type area's columns.
  /// `Locale.Language` and `typesettingLanguage` drop the `lb` keyword; `languageIdentifier` keeps it.
  static let bodyLanguage = "und-u-lb-strict"
}

private struct TextStyleModifier: ViewModifier {
  let role: TextRole
  @EnvironmentTypeScale private var scale

  func body(content: Content) -> some View {
    let shift = scale.emBoxShift(role)
    content
      .font(Font(scale.font(role)))
      .lineHeight(.exact(points: scale.lineHeight(role)))
      .tracking(scale.tracking(role))
      .offset(y: shift)
      .alignmentGuide(.firstTextBaseline) { $0[.firstTextBaseline] + shift }
      .alignmentGuide(.lastTextBaseline) { $0[.lastTextBaseline] + shift }
  }
}

extension TypeScale {
  /// How far down `role`'s text is moved to centre its em box in the line box. `.exact` puts the
  /// baseline `size` below the top of the line box, so the em box starts `emBoxDescent × size`
  /// below it.
  func emBoxShift(_ role: TextRole) -> CGFloat {
    let size = size(role)
    return (lineHeight(role) - size) / 2 - BundledFonts.emBoxDescent * size
  }
}
