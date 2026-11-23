import SwiftUI
internal import Typesetting
import UIKit

/// `text` as editable text in `role`, set as `textStyle(role)` sets it (and, for the body, as
/// `Text(body:)` breaks it), as tall as its text and never scrolling on its own, with `placeholder`
/// in the tertiary colour while nothing is written or being composed. `changed` hears the whole
/// text after each edit, except while text is being composed (marked) by an input method: it hears
/// the text once composing ends, or when the editor goes away mid-composition. A `oneLine` editor
/// takes no line break: one typed is refused, and those in pasted text are dropped.
///
/// `links` are drawn as `Text(body:links:)` draws them, and `changed` hears them with the text.
/// Where `pastesLinks`, pasting a web address over selected text links it; with nothing selected,
/// a sheet asks for a title, and the title goes in at the caret, linked.
struct TextStyleEditor: View {
  let role: TextRole
  let text: String
  var links: [BodyLink] = []
  var placeholder = ""
  var oneLine = false
  var pastesLinks = false
  let changed: (String, [BodyLink]) -> Void
  @State private var asking: TitleRequest?
  @EnvironmentTypeScale private var scale

  var body: some View {
    // A fixed line box puts the baseline `-descender` above its bottom; this moves it to where
    // `textStyle(role)` puts it. Not `baselineOffset`, which TextKit 2 takes off the line box.
    let baseline = scale.size(role) + scale.emBoxShift(role)
    StyledTextView(
      role: role, text: text, links: links, placeholder: placeholder, oneLine: oneLine,
      askTitle: pastesLinks ? { asking = $0 } : nil, changed: changed, scale: scale
    )
    .offset(y: baseline - scale.lineHeight(role) - scale.font(role).descender)
    .sheet(item: $asking) { request in
      LinkTitleSheet(url: request.url) { title in
        asking = nil
        request.answer(title)
      }
    }
  }
}

/// A pasted web address waiting for the title it goes in under; `answer` hears the title, or nil
/// when none is given.
struct TitleRequest: Identifiable {
  let id = UUID()
  let url: URL
  let answer: (String?) -> Void
}

struct StyledTextView: UIViewRepresentable {
  let role: TextRole
  let text: String
  let links: [BodyLink]
  let placeholder: String
  let oneLine: Bool
  let askTitle: ((TitleRequest) -> Void)?
  let changed: (String, [BodyLink]) -> Void
  let scale: TypeScale

  func makeUIView(context: Context) -> PlaceholderTextView {
    let view = PlaceholderTextView(usingTextLayoutManager: true)
    // The page scrolls; the editor is as tall as its text.
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.delegate = context.coordinator
    view.linkTextAttributes = [
      .foregroundColor: UIColor.label, .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    return view
  }

  func updateUIView(_ view: PlaceholderTextView, context: Context) {
    context.coordinator.changed = changed
    view.pasteLink =
      askTitle.map { askTitle in
        { [weak view, coordinator = context.coordinator] url in
          guard let view else { return }
          coordinator.paste(url, into: view, askingTitle: askTitle)
        }
      }
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil,
      context.coordinator.scale != scale || view.text != text || view.links != links
    else { return }
    context.coordinator.scale = scale
    let attributes = scale.attributes(role)
    let selection = view.selectedRange
    let styled = NSMutableAttributedString(string: text, attributes: attributes)
    for link in links {
      styled.addAttribute(.link, value: link.url, range: NSRange(link.range))
    }
    view.attributedText = styled
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
    let links = view.links
    // After the update that removes the editor, which can't change state itself.
    Task { @MainActor in coordinator.changed(text, links) }
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
    var changed: (String, [BodyLink]) -> Void
    let oneLine: Bool
    /// The scale the text was last set at, so a change of setting restyles it.
    var scale: TypeScale?

    init(changed: @escaping (String, [BodyLink]) -> Void, oneLine: Bool) {
      self.changed = changed
      self.oneLine = oneLine
    }

    /// Links the selection to `url`; with nothing selected, asks for a title and puts it in at the
    /// caret, linked, or the address itself when the title is left empty. Nothing goes in when the
    /// sheet is cancelled.
    func paste(
      _ url: URL, into view: PlaceholderTextView, askingTitle askTitle: (TitleRequest) -> Void
    ) {
      let selection = view.selectedRange
      guard selection.length == 0 else {
        let linked = NSMutableAttributedString(
          attributedString: view.textStorage.attributedSubstring(from: selection))
        linked.addAttribute(.link, value: url, range: NSRange(location: 0, length: linked.length))
        restyle(selection, in: view, as: linked)
        return
      }
      askTitle(
        TitleRequest(url: url) { [weak self, weak view] title in
          guard let self, let view, let title else { return }
          let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
          let inserted = trimmed.isEmpty ? url.absoluteString : trimmed
          let length = (view.text as NSString).length
          view.becomeFirstResponder()
          view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
          let start = view.selectedRange.location
          // Through the text input system, so undo takes the title back out.
          view.insertText(inserted)
          view.textStorage.addAttribute(
            .link, value: url,
            range: NSRange(location: start, length: (inserted as NSString).length))
          Self.unlinkTypingAtALinksEdge(in: view)
          changed(view.text, view.links)
        })
    }

    /// Gives `range` of `view`'s text the attributes `styled` has, as one change undo takes back.
    private func restyle(_ range: NSRange, in view: UITextView, as styled: NSAttributedString) {
      let before = view.textStorage.attributedSubstring(from: range)
      view.textStorage.replaceCharacters(in: range, with: styled)
      view.undoManager?.registerUndo(withTarget: view) { [weak self] view in
        self?.restyle(range, in: view, as: before)
      }
      Self.unlinkTypingAtALinksEdge(in: view)
      changed(view.text, view.links)
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
      changed(view.text, view.links)
    }

    func textViewDidChangeSelection(_ view: UITextView) {
      Self.unlinkTypingAtALinksEdge(in: view)
    }

    /// Text typed at the caret goes on a link only when the characters on both sides of the caret
    /// are on that link: text typed at a link's start or end is not linked.
    private static func unlinkTypingAtALinksEdge(in view: UITextView) {
      let caret = view.selectedRange
      let storage = view.textStorage
      guard caret.length == 0 else { return }
      func link(at location: Int) -> URL? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(.link, at: location, effectiveRange: nil) as? URL
      }
      let before = link(at: caret.location - 1)
      guard before == nil || before != link(at: caret.location) else { return }
      view.typingAttributes[.link] = nil
    }
  }
}

extension UITextView {
  /// The text's links, in order, as the body keeps them.
  var links: [BodyLink] {
    var links: [BodyLink] = []
    textStorage.enumerateAttribute(
      .link, in: NSRange(location: 0, length: textStorage.length)
    ) { value, range, _ in
      guard let url = value as? URL else { return }
      links.append(BodyLink(range: range.location..<range.location + range.length, url: url))
    }
    return links.fitted(to: text)
  }
}

/// A text view that shows `placeholder` over its first line while it holds no text, composed text
/// included. Where `pasteLink` is set, a paste of a web address goes to it instead of in as text.
final class PlaceholderTextView: UITextView {
  var pasteLink: ((URL) -> Void)?
  /// Where a web address is looked for; anything else is pasted from the general pasteboard.
  var pasteboard = UIPasteboard.general

  override func paste(_ sender: Any?) {
    // Read only here, where the person asked to paste, so the system doesn't ask them first.
    guard let pasteLink,
      let url = (pasteboard.url?.absoluteString ?? pasteboard.string).flatMap(
        URL.init(pastedLink:))
    else {
      super.paste(sender)
      return
    }
    pasteLink(url)
  }

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
