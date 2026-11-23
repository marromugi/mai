import SwiftUI
internal import Typesetting
import UIKit

/// `text` as editable text in `role`, set as `textStyle(role)` sets it (and, for the body, as
/// `Text(body:)` breaks it), as tall as its text and never scrolling on its own, with `placeholder`
/// in the tertiary colour while nothing is written or being composed. `changed` hears the whole
/// text after each edit, except while text is being composed (marked) by an input method: it hears
/// the text once composing ends, or when the editor goes away mid-composition. A `oneLine` editor
/// takes no line break: one typed is refused, and those in pasted text are dropped.
struct TextStyleEditor: View {
  let role: TextRole
  let text: String
  var placeholder = ""
  var oneLine = false
  let changed: (String) -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    // A fixed line box puts the baseline `-descender` above its bottom; this moves it to where
    // `textStyle(role)` puts it. Not `baselineOffset`, which TextKit 2 takes off the line box.
    let baseline = scale.size(role) + scale.emBoxShift(role)
    StyledTextView(
      role: role, text: text, placeholder: placeholder, oneLine: oneLine, changed: changed,
      scale: scale
    )
    .offset(y: baseline - scale.lineHeight(role) - scale.font(role).descender)
  }
}

private struct StyledTextView: UIViewRepresentable {
  let role: TextRole
  let text: String
  let placeholder: String
  let oneLine: Bool
  let changed: (String) -> Void
  let scale: TypeScale

  func makeUIView(context: Context) -> PlaceholderTextView {
    let view = PlaceholderTextView(usingTextLayoutManager: true)
    // The page scrolls; the editor is as tall as its text.
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.delegate = context.coordinator
    return view
  }

  func updateUIView(_ view: PlaceholderTextView, context: Context) {
    context.coordinator.changed = changed
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil, context.coordinator.scale != scale || view.text != text
    else { return }
    context.coordinator.scale = scale
    let attributes = scale.attributes(role)
    let selection = view.selectedRange
    view.attributedText = NSAttributedString(string: text, attributes: attributes)
    view.typingAttributes = attributes
    var placeholderAttributes = attributes
    placeholderAttributes[.foregroundColor] = UIColor.tertiaryLabel
    view.placeholder.attributedText = NSAttributedString(
      string: placeholder, attributes: placeholderAttributes)
    view.showPlaceholderIfEmpty()
    let length = (text as NSString).length
    view.selectedRange = NSRange(
      location: min(selection.location, length),
      length: min(selection.length, length - min(selection.location, length)))
  }

  /// Text still being composed when the editor goes away is kept, as if composing had ended.
  static func dismantleUIView(_ view: PlaceholderTextView, coordinator: Coordinator) {
    guard view.markedTextRange != nil else { return }
    let text: String = view.text
    // After the update that removes the editor, which can't change state itself.
    Task { @MainActor in coordinator.changed(text) }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView view: PlaceholderTextView, context: Context
  )
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
    let oneLine: Bool
    /// The scale the text was last set at, so a change of setting restyles it.
    var scale: TypeScale?

    init(changed: @escaping (String) -> Void, oneLine: Bool) {
      self.changed = changed
      self.oneLine = oneLine
    }

    func textView(
      _ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      guard oneLine, text.contains(where: \.isNewline) else { return true }
      let kept = text.filter { !$0.isNewline }
      // Nothing in place of a selection Return was pressed over, which would delete it. Through the
      // text input system, so undo takes it back as one change.
      if !kept.isEmpty {
        view.insertText(kept)
      }
      return false
    }

    func textViewDidChange(_ view: UITextView) {
      (view as? PlaceholderTextView)?.showPlaceholderIfEmpty()
      guard view.markedTextRange == nil else { return }
      changed(view.text)
    }
  }
}

/// A text view that shows `placeholder` over its first line while it holds no text, composed text
/// included.
final class PlaceholderTextView: UITextView {
  private(set) lazy var placeholder: UILabel = {
    let label = UILabel()
    addSubview(label)
    return label
  }()

  override func layoutSubviews() {
    super.layoutSubviews()
    let fitted = placeholder.sizeThatFits(
      CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
    placeholder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fitted.height)
  }

  func showPlaceholderIfEmpty() {
    placeholder.isHidden = !text.isEmpty
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
