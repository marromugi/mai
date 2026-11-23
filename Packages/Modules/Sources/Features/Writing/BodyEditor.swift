import SwiftUI
internal import Typesetting
import UIKit

/// The body as editable text, set as `Text(body:)` with `textStyle(.body)` sets it, as tall as its
/// text and never scrolling on its own. `changed` hears the whole text after each edit, except
/// while text is being composed (marked) by an input method: it hears the text once composing
/// ends.
struct BodyEditor: View {
  let text: String
  let changed: (String) -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    // A fixed line box puts the baseline `-descender` above its bottom; this moves it to where
    // `textStyle(.body)` puts it. Not `baselineOffset`, which TextKit 2 takes off the line box.
    let font = scale.font(.body)
    let baseline = scale.size(.body) + scale.emBoxShift(.body)
    BodyTextView(text: text, changed: changed, scale: scale)
      .offset(y: baseline - scale.lineHeight(.body) - font.descender)
  }
}

private struct BodyTextView: UIViewRepresentable {
  let text: String
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
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil, context.coordinator.scale != scale || view.text != text
    else { return }
    context.coordinator.scale = scale
    let attributes = scale.bodyAttributes
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
    Coordinator(changed: changed)
  }

  final class Coordinator: NSObject, UITextViewDelegate {
    var changed: (String) -> Void
    /// The scale the text was last set at, so a change of setting restyles it.
    var scale: TypeScale?

    init(changed: @escaping (String) -> Void) {
      self.changed = changed
    }

    func textViewDidChange(_ view: UITextView) {
      guard view.markedTextRange == nil else { return }
      changed(view.text)
    }
  }
}

extension TypeScale {
  /// The body's font, line box, tracking, and line-breaking rules, as `textStyle(.body)` and
  /// `Text(body:)` set them.
  var bodyAttributes: [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight(.body)
    paragraph.maximumLineHeight = lineHeight(.body)
    paragraph.lineBreakStrategy = .standard
    return [
      .font: font(.body),
      .foregroundColor: UIColor.label,
      .paragraphStyle: paragraph,
      .tracking: tracking(.body),
      NSAttributedString.Key(kCTLanguageAttributeName as String): AttributedString.bodyLanguage,
    ]
  }
}
