import SwiftUI
internal import Typesetting
import UIKit

/// A writing's title and body as one editable text, as tall as its text and never scrolling on its
/// own. The first line is the title, set as `textStyle(.heading)` sets it, with 「タイトル」 in the
/// tertiary colour while it is empty; the lines after it are the body, set as `Text(body:)` sets
/// it, `scale.space(.m)` below the title, as the page set them apart. Whatever the edit — a line
/// deleted, a line break typed or taken out — the first line is the title. `changed` hears the
/// title, body and links after each edit, except while text is being composed (marked) by an input
/// method: it hears them once composing ends, or when the editor goes away mid-composition.
///
/// The body's links are drawn as `Text(body:links:)` draws them; the title takes none. The mentions
/// `found` in the body are drawn as `Text(body:mentions:)` draws them, those on a link left out. A
/// tap on a link or a mention while the editor has no caret hands its address to the environment's
/// `openURL`; with a caret, a tap moves it as on any text. VoiceOver offers each as an action.
/// Pasting a web address over selected body text links it; with nothing selected in the body, a
/// sheet asks for a title, and the title goes in at the caret, linked. In the title a web address
/// goes in as text.
struct WritingEditor: View {
  let writing: WritingText
  var found: FoundMentions?
  let changed: (WritingText) -> Void
  @State private var asking: TitleRequest?
  @EnvironmentTypeScale private var scale
  @Environment(\.fontFamilies) private var families
  @Environment(\.openURL) private var openURL
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    let lines = EditorLines(scale: scale, families: families, pixel: 1 / displayScale)
    WritingTextView(
      writing: writing, found: found, askTitle: { asking = $0 }, changed: changed,
      open: { openURL($0) }, lines: lines
    )
    .offset(y: lines.viewOffset)
    .sheet(item: $asking) { request in
      LinkTitleSheet(url: request.url) { title in
        asking = nil
        request.answer(title)
      }
    }
  }
}

/// Where the editor's lines go: a fixed line box puts the baseline `-descender` above its bottom,
/// and `offset(_:)` moves it to where `textStyle(role)` puts it. Not `baselineOffset`, which
/// TextKit 2 takes off the line box. TextKit sets lines on whole pixels of the text view, so the
/// body starts on one there and the view is moved by the rest of the body's offset, `viewOffset`;
/// the title is moved down from there by `titleInset`, within a pixel of where it goes.
struct EditorLines: Equatable {
  let scale: TypeScale
  let families: [FontFamily]
  /// A pixel's size, in points.
  let pixel: CGFloat

  func offset(_ role: TextRole) -> CGFloat {
    let baseline = scale.size(role) + scale.emBoxShift(role, in: families)
    return baseline - scale.lineHeight(role) - scale.font(role, in: families).descender
  }

  var viewOffset: CGFloat {
    let higher = min(offset(.heading), offset(.body))
    return offset(.body) - ((offset(.body) - higher) / pixel).rounded(.up) * pixel
  }

  var titleInset: CGFloat {
    ((offset(.heading) - viewOffset) / pixel).rounded() * pixel
  }

  /// How much taller than the title's and the body's lines `scale.space(.m)` apart the text view
  /// is: the body's move down.
  var excess: CGFloat {
    offset(.body) - viewOffset
  }

  /// The title paragraph's attributes, with `spacing` below it.
  func title(spacing: CGFloat) -> [NSAttributedString.Key: Any] {
    var attributes = scale.attributes(.heading, in: families)
    attributes[.lineRole] = LineRole.title.rawValue
    if let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle,
      let spaced = paragraph.mutableCopy() as? NSMutableParagraphStyle
    {
      spaced.paragraphSpacing = spacing
      attributes[.paragraphStyle] = spaced
    }
    return attributes
  }

  /// The space below a title `height` tall that sets the body's lines where they fall
  /// `scale.space(.m)` below the title's, on the pixel a view placed there starts on.
  func spacing(belowTitleOf height: CGFloat) -> CGFloat {
    let apart = ((height + scale.space(.m)) / pixel).rounded(.up) * pixel
    return apart - height + offset(.body) - viewOffset - titleInset
  }

  var body: [NSAttributedString.Key: Any] {
    var attributes = scale.attributes(.body, in: families)
    attributes[.lineRole] = LineRole.body.rawValue
    return attributes
  }
}

/// Which of the editor's lines a character is set as, kept on it as `.lineRole`.
enum LineRole: String {
  case title
  case body
}

/// A pasted web address waiting for the title it goes in under; `answer` hears the title, or nil
/// when none is given.
struct TitleRequest: Identifiable {
  let id = UUID()
  let url: URL
  let answer: (String?) -> Void
}

struct WritingTextView: UIViewRepresentable {
  let writing: WritingText
  let found: FoundMentions?
  let askTitle: (TitleRequest) -> Void
  let changed: (WritingText) -> Void
  let open: (URL) -> Void
  let lines: EditorLines

  func makeUIView(context: Context) -> PlaceholderTextView {
    let view = PlaceholderTextView(usingTextLayoutManager: true)
    // The page scrolls; the editor is as tall as its text.
    view.isScrollEnabled = false
    view.textContainer.lineFragmentPadding = 0
    view.delegate = context.coordinator
    view.pasteDelegate = context.coordinator
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
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil else { return }
    restyle(view, context: context)
    if let found, found.body == view.writing.body, context.coordinator.found != found {
      context.coordinator.found = found
      view.mark(found)
    }
  }

  /// Sets the text and its links again, when they or the type have changed.
  private func restyle(_ view: PlaceholderTextView, context: Context) {
    guard context.coordinator.lines != lines || view.writing != writing else { return }
    context.coordinator.found = nil
    context.coordinator.lines = lines
    view.lines = lines
    view.titleSpacing = lines.spacing(belowTitleOf: lines.scale.lineHeight(.heading))
    view.textContainerInset = UIEdgeInsets(top: lines.titleInset, left: 0, bottom: 0, right: 0)
    let selection = view.selectedRange
    let text = writing.text
    let styled = NSMutableAttributedString(string: text)
    let bodyStart = min(writing.bodyStart, styled.length)
    styled.setAttributes(view.titleAttributes, range: NSRange(location: 0, length: bodyStart))
    styled.setAttributes(
      lines.body, range: NSRange(location: bodyStart, length: styled.length - bodyStart))
    for link in writing.textLinks {
      styled.addAttributes(.bodyLink(link.url), range: NSRange(link.range))
    }
    view.attributedText = styled
    var placeholderAttributes = lines.title(spacing: 0)
    placeholderAttributes[.foregroundColor] = UIColor.tertiaryLabel
    view.placeholder.attributedText = NSAttributedString(
      string: "タイトル", attributes: placeholderAttributes)
    view.showPlaceholderIfUntitled()
    let length = styled.length
    view.selectedRange = NSRange(
      location: min(selection.location, length),
      length: min(selection.length, length - min(selection.location, length)))
    Coordinator.typeInTheLinesRole(in: view)
  }

  /// Text still being composed when the editor goes away is kept, as if composing had ended.
  static func dismantleUIView(_ view: PlaceholderTextView, coordinator: Coordinator) {
    guard view.markedTextRange != nil else { return }
    let writing = view.writing
    // After the update that removes the editor, which can't change state itself.
    Task { @MainActor in coordinator.changed(writing) }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView view: PlaceholderTextView, context: Context
  )
    -> CGSize?
  {
    guard let width = proposal.width, width.isFinite else { return nil }
    view.spaceTheTitle(within: width)
    let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    // As tall as the title's and the body's lines apart, so what follows on the page stays put.
    return CGSize(width: width, height: fitted.height - lines.excess)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(changed: changed, askTitle: askTitle)
  }

  /// The text view's delegate, its paste delegate (the system hands a paste to it, not the
  /// pasteboard to the app), and the delegate of its tap on links.
  final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate,
    UIGestureRecognizerDelegate
  {
    var changed: (WritingText) -> Void
    /// Asks for the title of a web address pasted into the body with nothing selected.
    var askTitle: (TitleRequest) -> Void
    /// The mentions last marked in the text, until the text is set again.
    var found: FoundMentions?
    /// The lines the text was last set in, so a change of the type restyles it.
    var lines: EditorLines?

    init(changed: @escaping (WritingText) -> Void, askTitle: @escaping (TitleRequest) -> Void) {
      self.changed = changed
      self.askTitle = askTitle
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

    /// A web address pasted or dropped into the body, and nothing else, goes to
    /// `paste(_:into:askingTitle:)` at `textRange`; other text, and anything put in the title, goes
    /// in as text, with the links it was dragged with that land in the body. Returns the range the
    /// text now covers.
    func textPasteConfigurationSupporting(
      _ supporting: any UITextPasteConfigurationSupporting,
      performPasteOf attributedString: NSAttributedString, to textRange: UITextRange
    ) -> UITextRange {
      guard let view = supporting as? PlaceholderTextView else { return textRange }
      let start = view.offset(from: view.beginningOfDocument, to: textRange.start)
      if start >= view.bodyStart, let url = URL(pastedLink: attributedString.string) {
        let length = view.offset(from: textRange.start, to: textRange.end)
        view.selectedRange = NSRange(location: start, length: length)
        paste(url, into: view, askingTitle: askTitle)
        return textRange
      }
      view.replace(textRange, withText: attributedString.string)
      attributedString.enumerateAttribute(
        .bodyLink, in: NSRange(location: 0, length: attributedString.length)
      ) { value, range, _ in
        guard let url = value as? URL else { return }
        view.textStorage.addAttributes(
          .bodyLink(url), range: NSRange(location: start + range.location, length: range.length))
      }
      Self.keepTheLinesRoles(in: view)
      changed(view.writing)
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
      _ url: URL, into view: PlaceholderTextView, askingTitle askTitle: (TitleRequest) -> Void
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
          Self.typeInTheLinesRole(in: view)
          changed(view.writing)
        })
    }

    /// Gives `range` of `view`'s text the attributes `styled` has, as one change undo takes back.
    private func restyle(
      _ range: NSRange, in view: PlaceholderTextView, as styled: NSAttributedString
    ) {
      let before = view.textStorage.attributedSubstring(from: range)
      view.textStorage.replaceCharacters(in: range, with: styled)
      view.undoManager?.registerUndo(withTarget: view) { [weak self] view in
        self?.restyle(range, in: view, as: before)
      }
      // A mention a link now overlaps is left out whole, as the page leaves it out.
      if let found, found.body == view.writing.body {
        view.mark(found)
      }
      Self.typeInTheLinesRole(in: view)
      changed(view.writing)
    }

    func textViewDidChange(_ view: UITextView) {
      guard let view = view as? PlaceholderTextView else { return }
      view.showPlaceholderIfUntitled()
      guard view.markedTextRange == nil else { return }
      Self.keepTheLinesRoles(in: view)
      changed(view.writing)
    }

    func textViewDidChangeSelection(_ view: UITextView) {
      guard let view = view as? PlaceholderTextView else { return }
      Self.typeInTheLinesRole(in: view)
    }

    /// Sets the first line as the title and the rest as the body, where an edit has carried one's
    /// type onto the other: a line break typed in the title, or the one after it taken out. The
    /// title loses any link that has come into it. Told by `.lineRole`: the text storage gives a
    /// paragraph joined to another the other's paragraph style, but keeps the fonts.
    static func keepTheLinesRoles(in view: PlaceholderTextView) {
      guard let lines = view.lines else { return }
      let storage = view.textStorage
      let bodyStart = min(view.bodyStart, storage.length)
      let title = NSRange(location: 0, length: bodyStart)
      let body = NSRange(location: bodyStart, length: storage.length - bodyStart)
      storage.beginEditing()
      for (range, attributes) in [(title, view.titleAttributes), (body, lines.body)] {
        storage.enumerateAttribute(.lineRole, in: range) { value, run, _ in
          guard value as? String != attributes[.lineRole] as? String else { return }
          storage.addAttributes(attributes, range: run)
        }
      }
      storage.enumerateAttribute(.bodyLink, in: title) { value, run, _ in
        guard value != nil else { return }
        storage.removeAttribute(.bodyLink, range: run)
        storage.removeAttribute(.underlineStyle, range: run)
      }
      storage.endEditing()
      typeInTheLinesRole(in: view)
    }

    /// Text typed goes in in the type of the line it is typed on. In the body, it goes on a link
    /// only when the characters on both sides of the caret, or of the selection, are on that link:
    /// text typed at a link's start or end is not linked.
    static func typeInTheLinesRole(in view: PlaceholderTextView) {
      guard let lines = view.lines else { return }
      let selection = view.selectedRange
      guard selection.location >= view.bodyStart else {
        view.typingAttributes = view.titleAttributes
        return
      }
      var attributes = lines.body
      let storage = view.textStorage
      func link(at location: Int) -> URL? {
        guard location >= 0, location < storage.length else { return nil }
        return storage.attribute(.bodyLink, at: location, effectiveRange: nil) as? URL
      }
      if let before = link(at: selection.location - 1),
        before == link(at: selection.location + selection.length)
      {
        // The text view doesn't carry an attribute of the app's own over to typed text.
        attributes.merge(.bodyLink(before)) { $1 }
      }
      view.typingAttributes = attributes
    }
  }
}

extension NSAttributedString.Key {
  /// Where the editor keeps a body link's address: not `.link`, which a text view opens on a tap
  /// even while it is being edited.
  static let bodyLink = NSAttributedString.Key("MaiBodyLink")
  /// Where the editor keeps the link of a mention of another writing's title.
  static let mention = NSAttributedString.Key("MaiMention")
  /// Where the editor keeps which line a character is set as, a `LineRole`'s raw value.
  static let lineRole = NSAttributedString.Key("MaiLineRole")
}

extension [NSAttributedString.Key: Any] {
  /// The attributes of text linked to `url` in the editor: the address, and a solid line in the
  /// text's colour, as `Text(body:links:)` draws it.
  static func bodyLink(_ url: URL) -> Self {
    [.bodyLink: url, .underlineStyle: NSUnderlineStyle.single.rawValue]
  }
}

extension PlaceholderTextView {
  /// Marks the mentions `found` in the body, as `Text(body:mentions:)` draws them, in place of those
  /// marked before, leaving out any on a link. The body must be the one they were found in.
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
    let linked = textLinks.map { NSRange($0.range) }
    for mention in found.mentions {
      // Converted in the body they were found in: an index into another string, even one equal
      // to it, may stand for another place.
      let inBody = NSRange(mention.range, in: found.body)
      let range = NSRange(location: bodyStart + inBody.location, length: inBody.length)
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
}

extension UITextView {
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

  /// The text's links, in order, in the text's UTF-16 offsets.
  var textLinks: [BodyLink] {
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

/// A text view that shows `placeholder` over its first line while that line is empty, composed text
/// included. VoiceOver offers each link and mention in it as an action that hands its address to
/// `open`.
final class PlaceholderTextView: UITextView {
  var open: (URL) -> Void = { _ in }
  /// The lines the text was last set in; nil until it is first set.
  var lines: EditorLines?
  /// The space below the title, as `spaceTheTitle(within:)` last measured it.
  var titleSpacing: CGFloat = 0

  var titleAttributes: [NSAttributedString.Key: Any] {
    lines?.title(spacing: titleSpacing) ?? [:]
  }

  /// Sets the space below the title for the title's lines `width` wide, when they have changed:
  /// the body follows the title's last line, wherever it wraps.
  func spaceTheTitle(within width: CGFloat) {
    guard let lines, markedTextRange == nil else { return }
    let title = writing.title.isEmpty ? " " : writing.title
    let height = NSAttributedString(string: title, attributes: lines.title(spacing: 0))
      .boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: .usesLineFragmentOrigin, context: nil
      ).height
    let spacing = lines.spacing(belowTitleOf: height)
    guard spacing != titleSpacing else { return }
    titleSpacing = spacing
    let end = min(bodyStart, textStorage.length)
    textStorage.addAttribute(
      .paragraphStyle, value: titleAttributes[.paragraphStyle] ?? NSParagraphStyle(),
      range: NSRange(location: 0, length: end))
    WritingTextView.Coordinator.typeInTheLinesRole(in: self)
  }

  /// The title, body, and links the text holds.
  var writing: WritingText {
    WritingText(text: text, links: textLinks)
  }

  /// Where the body starts: after the first line break, or past the end when there is none.
  var bodyStart: Int {
    let string = text as NSString
    let lineBreak = string.range(of: "\n")
    return lineBreak.location == NSNotFound ? string.length + 1 : NSMaxRange(lineBreak)
  }

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
    placeholder.frame = CGRect(
      x: 0, y: textContainerInset.top, width: bounds.width, height: fitted.height)
  }

  /// Shows 「タイトル」 while the first line is empty, composed text included.
  func showPlaceholderIfUntitled() {
    placeholder.isHidden = !(text.isEmpty || text.hasPrefix("\n"))
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
