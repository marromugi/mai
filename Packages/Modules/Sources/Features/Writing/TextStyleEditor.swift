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
/// The mentions `found` in the text it holds are drawn as `Text(body:mentions:)` draws them, those
/// on a link left out. A tap on a link or a mention while the editor has no caret hands its address
/// to the environment's `openURL`; with a caret, a tap moves it as on any text. VoiceOver offers
/// each as an action. Where `pastesLinks`, pasting a web address over selected text links it; with nothing selected,
/// a sheet asks for a title, and the title goes in at the caret, linked.
struct TextStyleEditor: View {
  let role: TextRole
  let text: String
  var links: [BodyLink] = []
  var found: FoundMentions?
  var placeholder = ""
  var oneLine = false
  var pastesLinks = false
  let changed: (String, [BodyLink]) -> Void
  @State private var asking: TitleRequest?
  @EnvironmentTypeScale private var scale
  @Environment(\.fontFamilies) private var families
  @Environment(\.openURL) private var openURL

  var body: some View {
    // A fixed line box puts the baseline `-descender` above its bottom; this moves it to where
    // `textStyle(role)` puts it. Not `baselineOffset`, which TextKit 2 takes off the line box.
    let baseline = scale.size(role) + scale.emBoxShift(role, in: families)
    StyledTextView(
      role: role, text: text, links: links, found: found, placeholder: placeholder,
      oneLine: oneLine, askTitle: pastesLinks ? { asking = $0 } : nil, changed: changed,
      open: { openURL($0) }, scale: scale,
      families: families
    )
    .offset(y: baseline - scale.lineHeight(role) - scale.font(role, in: families).descender)
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
  let found: FoundMentions?
  let placeholder: String
  let oneLine: Bool
  let askTitle: ((TitleRequest) -> Void)?
  let changed: (String, [BodyLink]) -> Void
  let open: (URL) -> Void
  let scale: TypeScale
  let families: [FontFamily]

  func makeUIView(context: Context) -> PlaceholderTextView {
    let view = PlaceholderTextView(usingTextLayoutManager: true)
    // The page scrolls; the editor is as tall as its text.
    view.isScrollEnabled = false
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.delegate = context.coordinator
    let tap = UITapGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
    tap.delegate = context.coordinator
    view.addGestureRecognizer(tap)
    return view
  }

  func updateUIView(_ view: PlaceholderTextView, context: Context) {
    context.coordinator.changed = changed
    context.coordinator.askTitle = askTitle
    view.open = open
    view.pasteDelegate = askTitle == nil ? nil : context.coordinator
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil else { return }
    restyle(view, context: context)
    if let found, found.body == view.text, context.coordinator.found != found {
      context.coordinator.found = found
      view.mark(found)
    }
  }

  /// Sets the text and its links again, when they or the type have changed.
  private func restyle(_ view: PlaceholderTextView, context: Context) {
    guard
      context.coordinator.scale != scale || context.coordinator.families != families
        || view.text != text || view.links != links
    else { return }
    context.coordinator.found = nil
    context.coordinator.scale = scale
    context.coordinator.families = families
    let attributes = scale.attributes(role, in: families)
    let selection = view.selectedRange
    let styled = NSMutableAttributedString(string: text, attributes: attributes)
    for link in links {
      styled.addAttributes(.bodyLink(link.url), range: NSRange(link.range))
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

  /// The text view's delegate, the delegate of its tap on links, and, where links are pasted, its
  /// paste delegate: the system hands a paste to it, not the pasteboard to the app.
  final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate,
    UIGestureRecognizerDelegate
  {
    var changed: (String, [BodyLink]) -> Void
    let oneLine: Bool
    /// The mentions last marked in the text, until the text is set again.
    var found: FoundMentions?
    /// The scale and families the text was last set in, so a change of either restyles it.
    var scale: TypeScale?
    var families: [FontFamily]?
    /// Asks for the title of a web address pasted with nothing selected.
    var askTitle: ((TitleRequest) -> Void)?

    init(changed: @escaping (String, [BodyLink]) -> Void, oneLine: Bool) {
      self.changed = changed
      self.oneLine = oneLine
    }

    @objc func tapped(_ tap: UITapGestureRecognizer) {
      guard let view = tap.view as? PlaceholderTextView,
        let url = link(openedAt: tap.location(in: view), in: view)
      else { return }
      view.open(url)
    }

    /// Taken only where a tap opens a link.
    func gestureRecognizerShouldBegin(_ tap: UIGestureRecognizer) -> Bool {
      guard let view = tap.view as? UITextView else { return false }
      return link(openedAt: tap.location(in: view), in: view) != nil
    }

    /// The link or mention a tap at `point` opens: the one drawn there, while `view` has no caret.
    func link(openedAt point: CGPoint, in view: UITextView) -> URL? {
      view.isFirstResponder ? nil : view.link(at: point)
    }

    /// The text view's own taps, which put the caret in, wait for this one to fail.
    func gestureRecognizer(
      _ tap: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
      other.view === tap.view && other is UITapGestureRecognizer
    }

    /// A web address pasted or dropped, and nothing else, goes to `paste(_:into:askingTitle:)`
    /// at `textRange`; other text goes in as text, with the links it was dragged with. Returns the
    /// range the text now covers.
    func textPasteConfigurationSupporting(
      _ supporting: any UITextPasteConfigurationSupporting,
      performPasteOf attributedString: NSAttributedString, to textRange: UITextRange
    ) -> UITextRange {
      guard let view = supporting as? UITextView else { return textRange }
      let start = view.offset(from: view.beginningOfDocument, to: textRange.start)
      if let askTitle, let url = URL(pastedLink: attributedString.string) {
        let length = view.offset(from: textRange.start, to: textRange.end)
        view.selectedRange = NSRange(location: start, length: length)
        paste(url, into: view, askingTitle: askTitle)
        return textRange
      }
      view.replace(textRange, withText: attributedString.string)
      var dragged: [BodyLink] = []
      attributedString.enumerateAttribute(
        .bodyLink, in: NSRange(location: 0, length: attributedString.length)
      ) { value, range, _ in
        guard let url = value as? URL else { return }
        dragged.append(
          BodyLink(range: start + range.location..<start + NSMaxRange(range), url: url))
      }
      for link in dragged {
        view.textStorage.addAttributes(.bodyLink(link.url), range: NSRange(link.range))
      }
      if !dragged.isEmpty {
        changed(view.text, view.links)
      }
      let begin = view.beginningOfDocument
      guard let from = view.position(from: begin, offset: start),
        let to = view.position(from: begin, offset: start + attributedString.length)
      else {
        preconditionFailure("The text just put in is not in the text view.")
      }
      return view.textRange(from: from, to: to) ?? textRange
    }

    /// Links the selection to `url`; with nothing selected, asks for a title and puts it in at the
    /// caret, linked, or the address itself when the title is left empty. Nothing goes in when the
    /// sheet is cancelled.
    func paste(
      _ url: URL, into view: UITextView, askingTitle askTitle: (TitleRequest) -> Void
    ) {
      let selection = view.selectedRange
      guard selection.length == 0 else {
        let linked = NSMutableAttributedString(
          attributedString: view.textStorage.attributedSubstring(from: selection))
        linked.removeAttribute(.mention, range: NSRange(location: 0, length: linked.length))
        linked.addAttributes(.bodyLink(url), range: NSRange(location: 0, length: linked.length))
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
          view.textStorage.addAttributes(
            .bodyLink(url), range: NSRange(location: start, length: (inserted as NSString).length))
          Self.linkTypingOnlyInsideALink(in: view)
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
      // A mention a link now overlaps is left out whole, as the page leaves it out.
      if let found, found.body == view.text {
        view.mark(found)
      }
      Self.linkTypingOnlyInsideALink(in: view)
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
      view.typingAttributes[.mention] = nil
      Self.linkTypingOnlyInsideALink(in: view)
    }

    /// Text typed at the caret, or over the selection, goes on a link only when the characters on
    /// both sides are on that link: text typed at a link's start or end is not linked.
    private static func linkTypingOnlyInsideALink(in view: UITextView) {
      let selection = view.selectedRange
      let storage = view.textStorage
      func link(at location: Int) -> URL? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(.bodyLink, at: location, effectiveRange: nil) as? URL
      }
      if let before = link(at: selection.location - 1),
        before == link(at: selection.location + selection.length)
      {
        // The text view doesn't carry an attribute of the app's own over to typed text.
        view.typingAttributes.merge(.bodyLink(before)) { $1 }
        return
      }
      view.typingAttributes[.bodyLink] = nil
      view.typingAttributes[.underlineStyle] = nil
    }
  }
}

extension NSAttributedString.Key {
  /// Where the editor keeps a body link's address: not `.link`, which a text view opens on a tap
  /// even while it is being edited.
  static let bodyLink = NSAttributedString.Key("MaiBodyLink")
  /// Where the editor keeps the link of a mention of another writing's title.
  static let mention = NSAttributedString.Key("MaiMention")
}

extension [NSAttributedString.Key: Any] {
  /// The attributes of text linked to `url` in the editor: the address, and a solid line in the
  /// text's colour, as `Text(body:links:)` draws it.
  static func bodyLink(_ url: URL) -> Self {
    [.bodyLink: url, .underlineStyle: NSUnderlineStyle.single.rawValue]
  }
}

extension UITextView {
  /// Marks the mentions `found` in the text, as `Text(body:mentions:)` draws them, in place of those
  /// marked before, leaving out any on a link. The text must be the body they were found in.
  func mark(_ found: FoundMentions) {
    let storage = textStorage
    let whole = NSRange(location: 0, length: storage.length)
    storage.beginEditing()
    storage.enumerateAttribute(.mention, in: whole) { value, range, _ in
      guard value != nil else { return }
      storage.removeAttribute(.mention, range: range)
      storage.enumerateAttribute(.bodyLink, in: range) { link, part, _ in
        if link == nil { storage.removeAttribute(.underlineStyle, range: part) }
      }
    }
    let linked = links.map { NSRange($0.range) }
    for mention in found.mentions {
      // Converted in the body they were found in: an index into another string, even one equal
      // to it, may stand for another place.
      let range = NSRange(mention.range, in: found.body)
      guard NSMaxRange(range) <= storage.length,
        !linked.contains(where: { NSIntersectionRange($0, range).length > 0 })
      else { continue }
      storage.addAttributes(
        [
          .mention: mention.writing.link,
          .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
        ], range: range)
    }
    storage.endEditing()
  }

  /// Each link's and mention's text and address, in order.
  var linkedText: [(text: String, url: URL)] {
    var found: [(location: Int, text: String, url: URL)] = []
    let storage = textStorage
    for key in [NSAttributedString.Key.bodyLink, .mention] {
      storage.enumerateAttribute(key, in: NSRange(location: 0, length: storage.length)) {
        value, range, _ in
        guard let url = value as? URL else { return }
        found.append((range.location, storage.attributedSubstring(from: range).string, url))
      }
    }
    return found.sorted { $0.location < $1.location }.map { ($0.text, $0.url) }
  }

  /// The address of the link or mention drawn under `point`, if any.
  func link(at point: CGPoint) -> URL? {
    guard let position = closestPosition(to: point) else { return nil }
    let offset = self.offset(from: beginningOfDocument, to: position)
    let storage = textStorage
    let string = storage.string as NSString
    // The closest position is between two characters; the one under the point is either. Each is
    // measured whole: half of a character stored as two UTF-16 units has no place of its own.
    for index in [offset - 1, offset] where index >= 0 && index < storage.length {
      let character = string.rangeOfComposedCharacterSequence(at: index)
      guard let start = self.position(from: beginningOfDocument, offset: character.location),
        let end = self.position(from: start, offset: character.length),
        let range = textRange(from: start, to: end),
        firstRect(for: range).contains(point)
      else { continue }
      return storage.attribute(.bodyLink, at: index, effectiveRange: nil) as? URL
        ?? storage.attribute(.mention, at: index, effectiveRange: nil) as? URL
    }
    return nil
  }

  /// The text's links, in order, as the body keeps them.
  var links: [BodyLink] {
    var links: [BodyLink] = []
    textStorage.enumerateAttribute(
      .bodyLink, in: NSRange(location: 0, length: textStorage.length)
    ) { value, range, _ in
      guard let url = value as? URL else { return }
      links.append(BodyLink(range: range.location..<range.location + range.length, url: url))
    }
    return links.fitted(to: text)
  }
}

/// A text view that shows `placeholder` over its first line while it holds no text, composed text
/// included. VoiceOver offers each link and mention in it as an action that hands its address to
/// `open`.
final class PlaceholderTextView: UITextView {
  var open: (URL) -> Void = { _ in }

  override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
    get {
      linkedText.map { text, url in
        UIAccessibilityCustomAction(name: "「\(text)」を開く") { [weak self] _ in
          self?.open(url)
          return self != nil
        }
      }
    }
    set {}
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
  func attributes(_ role: TextRole, in families: [FontFamily]) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.minimumLineHeight = lineHeight(role)
    paragraph.maximumLineHeight = lineHeight(role)
    paragraph.lineBreakStrategy = .standard
    var attributes: [NSAttributedString.Key: Any] = [
      .font: font(role, in: families),
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
