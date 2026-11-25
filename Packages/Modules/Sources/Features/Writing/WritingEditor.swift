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
    .offset(y: lines.placement.viewOffset)
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
/// TextKit 2 takes off the line box. `placement` sets the lines on the text view's pixels.
struct EditorLines: Equatable {
  let scale: TypeScale
  let families: [FontFamily]
  /// A pixel's size, in points.
  let pixel: CGFloat

  func offset(_ role: TextRole) -> CGFloat {
    let baseline = scale.size(role) + scale.emBoxShift(role, in: families)
    return baseline - scale.lineHeight(role) - scale.font(role, in: families).descender
  }

  var placement: TitleAndBodyLines {
    TitleAndBodyLines(
      titleOffset: offset(.heading), bodyOffset: offset(.body), gap: scale.space(.m),
      pixel: pixel)
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

  func makeUIView(context: Context) -> EditorView {
    let editor = EditorView()
    let view = editor.textView
    view.textContainer.lineFragmentPadding = 0
    view.delegate = context.coordinator
    view.pasteDelegate = context.coordinator
    let tap = UITapGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
    tap.delegate = context.coordinator
    view.addGestureRecognizer(tap)
    return editor
  }

  func updateUIView(_ editor: EditorView, context: Context) {
    let view = editor.textView
    context.coordinator.changed = changed
    context.coordinator.askTitle = askTitle
    view.open = open
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil else { return }
    restyle(editor, context: context)
    if let found, found.body.isSameText(as: view.writing.body), context.coordinator.found != found {
      context.coordinator.found = found
      view.mark(found)
    }
  }

  /// Sets the text and its links again, when they or the type have changed.
  private func restyle(_ editor: EditorView, context: Context) {
    let view = editor.textView
    guard view.lines != lines || view.writing != writing else { return }
    context.coordinator.found = nil
    view.lines = lines
    // For one line, until `sizeThatFits` measures the title at the editor's width.
    view.titleSpacing = lines.placement.spacing(belowTitleOf: lines.scale.lineHeight(.heading))
    view.textContainerInset = UIEdgeInsets(
      top: lines.placement.titleInset, left: 0, bottom: 0, right: 0)
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
    editor.paragraphs = nil
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
  static func dismantleUIView(_ editor: EditorView, coordinator: Coordinator) {
    let view = editor.textView
    guard view.markedTextRange != nil else { return }
    let writing = view.writing
    // After the update that removes the editor, which can't change state itself.
    Task { @MainActor in coordinator.changed(writing) }
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView editor: EditorView, context: Context
  )
    -> CGSize?
  {
    guard let width = proposal.width, width.isFinite else { return nil }
    let view = editor.textView
    view.spaceTheTitle(within: width)
    // As tall as the title's and the body's lines apart, so what follows on the page stays put.
    return CGSize(width: width, height: editor.textHeight(within: width) - lines.placement.excess)
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
      let attributedString = attributedString.withLineBreaks
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
      if let found, found.body.isSameText(as: view.writing.body) {
        view.mark(found)
      }
      Self.typeInTheLinesRole(in: view)
      changed(view.writing)
    }

    /// Text with another kind of line break goes in with `"\n"` in its place, through the text
    /// input system, so undo takes it back as typed.
    func textView(
      _ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
    ) -> Bool {
      let lineBreaks = text.withLineBreaks
      guard lineBreaks != text, let view = view as? PlaceholderTextView else { return true }
      let begin = view.beginningOfDocument
      guard let from = view.position(from: begin, offset: range.location),
        let to = view.position(from: from, offset: range.length),
        let replaced = view.textRange(from: from, to: to)
      else { return false }
      view.replace(replaced, withText: lineBreaks)
      return false
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

extension NSAttributedString {
  /// With each line break as `"\n"`, as `String.withLineBreaks` has it, keeping the attributes.
  var withLineBreaks: NSAttributedString {
    let copy = NSMutableAttributedString(attributedString: self)
    let others = string.indices.filter { string[$0].isNewline && string[$0] != "\n" }
    // From the end, so each range still points at its character.
    for index in others.reversed() {
      let character = index..<string.index(after: index)
      copy.replaceCharacters(in: NSRange(character, in: string), with: "\n")
    }
    return copy
  }
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
    // Underlines alone: no line's height changes.
    let editor = self.editor
    editor?.heightsKept = true
    defer { editor?.heightsKept = false }
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

/// The editor's view, as tall as its text. The text view in it is a window tall, kept over the part
/// of the editor the enclosing scroll view shows and scrolled to show that part, so TextKit lays
/// out and draws no more of the text than is on screen.
final class EditorView: UIView {
  let textView = PlaceholderTextView(usingTextLayoutManager: true)
  /// What moves over the part shown, the text view in it: a text view moved itself resizes its
  /// text container, and TextKit sets every line again.
  private let mover = UIView()
  private weak var scrollView: UIScrollView?
  private var scrolled: NSKeyValueObservation?
  private var resized: NSKeyValueObservation?
  /// Set while the text view is moved over the part shown; any other scroll of it goes to the page.
  private(set) var moving = false
  /// Each paragraph's height, once the whole text has been laid out since it was set at this
  /// width; an edit forgets the paragraphs it touches, and they alone are laid out again. TextKit
  /// keeps the layout of no more than the lines shown, so the text's height is summed here.
  var paragraphs: ParagraphHeights?
  /// Set while an edit changes attributes that leave every line's height as it was.
  var heightsKept = false
  /// How many times the whole text has been laid out.
  private(set) var wholeLayouts = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    // The page's scroll view takes the drags, and its own scrolling stays with the page's.
    textView.panGestureRecognizer.isEnabled = false
    textView.scrollsToTop = false
    textView.showsVerticalScrollIndicator = false
    textView.showsHorizontalScrollIndicator = false
    textView.contentInsetAdjustmentBehavior = .never
    textView.bounces = false
    textView.textStorage.delegate = textView
    // Lines closer than their glyphs draw past the text view, as `Text` draws them past its frame.
    textView.clipsToBounds = false
    // It reaches past the editor, over what follows on the page.
    textView.backgroundColor = .clear
    mover.addSubview(textView)
    addSubview(mover)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    preconditionFailure("The editor is made in code.")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    var ancestor = superview
    while let view = ancestor, !(view is UIScrollView) {
      ancestor = view.superview
    }
    scrollView = ancestor as? UIScrollView
    scrolled = scrollView?.observe(\.contentOffset) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.setNeedsLayout() }
    }
    resized = scrollView?.observe(\.bounds) { [weak self] _, _ in
      MainActor.assumeIsolated { self?.setNeedsLayout() }
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Always the window's height, and the width the text was measured at, which can be a part of a
    // pixel wider than the editor: a text view resized resizes its text container too.
    let width = textView.frame.width > 0 ? textView.frame.width : bounds.width
    let size = CGSize(width: width, height: window?.bounds.height ?? bounds.height)
    var top: CGFloat = 0
    // What the page shows of the text view: the rest is inset, so the text view keeps the caret
    // within it, clear of the bottom row and the keyboard. An inset leaves the container as it is.
    var hidden = UIEdgeInsets.zero
    if let scrollView {
      // Placed over all the page draws, under the bars too; caret kept within what they leave.
      let drawn = convert(scrollView.bounds, from: scrollView)
      let clear = convert(
        scrollView.bounds.inset(by: scrollView.adjustedContentInset), from: scrollView)
      top = min(max(drawn.minY, 0), max(bounds.height - size.height, 0))
      hidden.top = min(max(clear.minY - top, 0), size.height)
      hidden.bottom = min(max(top + size.height - clear.maxY, 0), size.height - hidden.top)
    }
    moving = true
    mover.frame = CGRect(origin: CGPoint(x: 0, y: top), size: size)
    if textView.frame.size != size {
      textView.frame = CGRect(origin: .zero, size: size)
    }
    if textView.contentSize.height < bounds.height {
      textView.contentSize = textView.contentSize
    }
    if textView.contentInset != hidden {
      textView.contentInset = hidden
    }
    textView.contentOffset = CGPoint(x: 0, y: top)
    moving = false
  }

  /// Taken in only within the editor: the text view reaches past it when the text is shorter than
  /// the window.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.contains(point)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    self.point(inside: point, with: event) ? super.hitTest(point, with: event) : nil
  }

  /// How tall the text is set `width` wide, its insets included. Measured at the text container's
  /// own size, so TextKit keeps the layout of the lines an edit hasn't changed: asked for another
  /// size, as `sizeThatFits(_:)` asks, it sets every line again.
  func textHeight(within width: CGFloat) -> CGFloat {
    if textView.frame.width != width {
      moving = true
      textView.frame.size.width = width
      mover.frame.size.width = width
      moving = false
      paragraphs = nil
    }
    let inset = textView.textContainerInset
    return measured() + inset.top + inset.bottom
  }

  /// The text's height: each paragraph laid out once, then those an edit touched.
  private func measured() -> CGFloat {
    guard let layout = textView.textLayoutManager,
      let content = layout.textContentManager as? NSTextContentStorage
    else {
      preconditionFailure("The editor's text view is made with TextKit 2.")
    }
    let document = layout.documentRange
    func offset(_ location: any NSTextLocation) -> Int {
      content.offset(from: document.location, to: location)
    }
    guard var paragraphs else {
      wholeLayouts += 1
      var starts: [Int] = []
      var heights: [CGFloat] = []
      layout.enumerateTextLayoutFragments(
        from: document.location, options: [.ensuresLayout, .ensuresExtraLineFragment]
      ) { fragment in
        starts.append(offset(fragment.rangeInElement.location))
        heights.append(fragment.layoutFragmentFrame.height)
        return true
      }
      guard starts.first == 0 else { return layout.usageBoundsForTextContainer.maxY }
      let length = textView.textStorage.length
      paragraphs = ParagraphHeights(starts: starts, heights: heights, length: length)
      return heights.reduce(0, +)
    }
    for run in paragraphs.unmeasured {
      guard let start = content.location(document.location, offsetBy: run.lowerBound) else {
        continue
      }
      layout.enumerateTextLayoutFragments(
        from: start, options: [.ensuresLayout, .ensuresExtraLineFragment]
      ) { fragment in
        let at = offset(fragment.rangeInElement.location)
        guard at <= run.upperBound else { return false }
        paragraphs.measured(fragment.layoutFragmentFrame.height, startingAt: at)
        return true
      }
    }
    self.paragraphs = paragraphs
    guard let total = paragraphs.total else {
      // A paragraph TextKit didn't lay out where it was kept: lay them all out again.
      self.paragraphs = nil
      return measured()
    }
    return total
  }

  /// Scrolls the page by `offset`, as far as it scrolls: what the text view would have scrolled
  /// itself. Not animated: the page's scroll view drops an animated scroll asked of it here.
  func scroll(by offset: CGFloat) {
    guard let scrollView, offset != 0 else { return }
    let inset = scrollView.adjustedContentInset
    let top = -inset.top
    let bottom = max(top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
    let y = min(max(scrollView.contentOffset.y + offset, top), bottom)
    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
  }

  /// Scrolls the page so `rect` of the text view is in sight, within what the page shows of it.
  func scroll(toShow rect: CGRect) {
    guard let scrollView else { return }
    scrollView.scrollRectToVisible(textView.convert(rect, to: scrollView), animated: false)
  }
}

extension EditorView {
  /// Forgets the heights of the paragraphs an edit of `storage` touches.
  func edited(
    _ storage: NSTextStorage, _ edited: NSTextStorage.EditActions, range: NSRange, delta: Int
  ) {
    guard var paragraphs, edited.contains(.editedCharacters) || !heightsKept else { return }
    let string = storage.string as NSString
    paragraphs.replace(range.location..<NSMaxRange(range) - delta, with: range.length) { span in
      var lineBreaks: [Int] = []
      var searched = NSRange(span)
      while true {
        let found = string.range(of: "\n", range: searched)
        guard found.location != NSNotFound else { return lineBreaks }
        lineBreaks.append(found.location)
        searched = NSRange(
          location: found.location + 1, length: NSMaxRange(searched) - found.location - 1)
      }
    }
    self.paragraphs = paragraphs
  }
}

extension PlaceholderTextView: @preconcurrency NSTextStorageDelegate {
  /// Forgets the text as read, and tells the editor it is in.
  func textStorage(
    _ storage: NSTextStorage, didProcessEditing edited: NSTextStorage.EditActions,
    range: NSRange, changeInLength delta: Int
  ) {
    read = nil
    editor?.edited(storage, edited, range: range, delta: delta)
  }
}

/// A text view that shows `placeholder` over its first line while that line is empty, composed text
/// included. VoiceOver offers each link and mention in it as an action that hands its address to
/// `open`.
final class PlaceholderTextView: UITextView {
  var open: (URL) -> Void = { _ in }

  /// The editor it is in, if any. Looked up, not kept: UIKit scrolls the text view before its own
  /// properties are set.
  var editor: EditorView? {
    superview?.superview as? EditorView
  }

  /// At least as tall as the editor: TextKit's own height is an estimate, and a text view held
  /// shorter than the place it is scrolled to pulls itself back.
  override var contentSize: CGSize {
    get { super.contentSize }
    set {
      super.contentSize = CGSize(
        width: newValue.width, height: max(newValue.height, editor?.bounds.height ?? 0))
    }
  }

  // A scroll the text view makes itself, as to keep the caret in sight, scrolls the page.
  override var contentOffset: CGPoint {
    get { super.contentOffset }
    set {
      guard let editor = self.editor, !editor.moving else {
        super.contentOffset = newValue
        return
      }
      editor.scroll(by: newValue.y - super.contentOffset.y)
    }
  }

  override func setContentOffset(_ offset: CGPoint, animated: Bool) {
    guard let editor = self.editor, !editor.moving else {
      super.setContentOffset(offset, animated: animated)
      return
    }
    editor.scroll(by: offset.y - contentOffset.y)
  }

  override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
    guard let editor, !editor.moving else {
      super.scrollRectToVisible(rect, animated: animated)
      return
    }
    editor.scroll(toShow: rect)
  }
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
    let spacing = lines.placement.spacing(belowTitleOf: height)
    guard spacing != titleSpacing else { return }
    titleSpacing = spacing
    let end = min(bodyStart, textStorage.length)
    textStorage.addAttribute(
      .paragraphStyle, value: titleAttributes[.paragraphStyle] ?? NSParagraphStyle(),
      range: NSRange(location: 0, length: end))
    WritingTextView.Coordinator.typeInTheLinesRole(in: self)
  }

  /// The title, body, and links the text holds, read once per edit.
  var writing: WritingText {
    if textStorage.delegate !== self {
      textStorage.delegate = self
    }
    if let read { return read }
    let writing = WritingText(text: text, links: textLinks)
    read = writing
    return writing
  }

  /// The text's title, body, and links as last read, until the text storage is next edited.
  fileprivate var read: WritingText?

  /// Where the body starts: after the first line break, or past the end when there is none.
  var bodyStart: Int {
    let string = text as NSString
    let lineBreak = WritingText.firstLineBreak(in: string)
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
