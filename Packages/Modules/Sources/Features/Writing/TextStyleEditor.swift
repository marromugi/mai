import SwiftUI
internal import Typesetting
import UIKit

/// `text` as editable text in `role`, set as `textStyle(role)` sets it (and, for the body, as
/// `Text(body:)` breaks it), as tall as its text and never scrolling on its own. `changed` hears the
/// whole text after each edit, except while text is being composed (marked) by an input method: it
/// hears the text once composing ends. A `oneLine` editor keeps no line break: one typed or
/// pasted is dropped before `changed` hears the text.
struct TextStyleEditor: View {
  let role: TextRole
  let text: String
  var oneLine = false
  let changed: (String) -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    // A fixed line box puts the baseline `-descender` above its bottom; this moves it to where
    // `textStyle(role)` puts it. Not `baselineOffset`, which TextKit 2 takes off the line box.
    let baseline = scale.size(role) + scale.emBoxShift(role)
    StyledTextView(role: role, text: text, oneLine: oneLine, changed: changed, scale: scale)
      .offset(y: baseline - scale.lineHeight(role) - scale.font(role).descender)
  }
}

private struct StyledTextView: UIViewRepresentable {
  let role: TextRole
  let text: String
  let oneLine: Bool
  let changed: (String) -> Void
  let scale: TypeScale

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(usingTextLayoutManager: true)
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.adjustsFontForContentSizeCategory = false
    view.delegate = context.coordinator
    view.setContentHuggingPriority(.required, for: .vertical)
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.changed = changed
    context.coordinator.oneLine = oneLine
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil, context.coordinator.scale != scale || view.text != text
    else { return }
    context.coordinator.scale = scale
    let attributes = scale.attributes(role)
    let selection = view.selectedRange
    view.attributedText = NSAttributedString(string: text, attributes: attributes)
    view.typingAttributes = attributes
    let length = (text as NSString).length
    view.selectedRange = NSRange(
      location: min(selection.location, length),
      length: min(selection.length, length - min(selection.location, length)))
    view.invalidateIntrinsicContentSize()
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context)
    -> CGSize?
  {
    guard let width = proposal.width, width.isFinite else { return nil }
    let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    return CGSize(width: width, height: fitted.height)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(changed: changed, oneLine: oneLine)
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var changed: (String) -> Void
    var oneLine: Bool
    /// The scale the text was last set at, so a change of setting restyles it.
    var scale: TypeScale?

    init(changed: @escaping (String) -> Void, oneLine: Bool) {
      self.changed = changed
      self.oneLine = oneLine
    }

    func textViewDidChange(_ view: UITextView) {
      guard view.markedTextRange == nil else { return }
      if oneLine {
        removeLineBreaks(from: view)
      }
      changed(view.text)
    }

    /// Removes every line break from `view`'s text, however it got there, keeping the selection
    /// on the same characters.
    private func removeLineBreaks(from view: UITextView) {
      let text = view.text as NSString
      var breaks: [NSRange] = []
      text.enumerateSubstrings(
        in: NSRange(location: 0, length: text.length), options: .byComposedCharacterSequences
      ) { character, range, _, _ in
        if character?.contains(where: \.isNewline) == true { breaks.append(range) }
      }
      guard !breaks.isEmpty else { return }
      var selection = view.selectedRange
      for range in breaks.reversed() {
        view.textStorage.replaceCharacters(in: range, with: "")
        if range.location < selection.location {
          selection.location -= min(range.length, selection.location - range.location)
        } else if range.location < NSMaxRange(selection) {
          selection.length -= min(range.length, NSMaxRange(selection) - range.location)
        }
      }
      view.selectedRange = selection
    }
  }
}

extension TypeScale {
  /// `role`'s font, line box, and tracking, as `textStyle(role)` sets them, and for the body the
  /// line-breaking rules `Text(body:)` sets.
  func attributes(_ role: TextRole) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight(role)
    paragraph.maximumLineHeight = lineHeight(role)
    paragraph.lineBreakStrategy = .standard
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font(role),
      .foregroundColor: UIColor.label,
      .paragraphStyle: paragraph,
      .tracking: tracking(role),
    ]
    if role == .body {
      attributes[NSAttributedString.Key(kCTLanguageAttributeName as String)] =
        AttributedString.bodyLanguage
    }
    return attributes
  }
}
