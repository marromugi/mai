import SwiftUI
internal import Typesetting
import UIKit

/// A writing's title and body as one editable text on the type area, scrolling as the page, with
/// `top` above the text and `bottom` below it, across the page's width; while not `scrolls`, it
/// stays where it is. `bottomMargin` is left below `bottom` at the page's end, and the caret is
/// kept above it. `titleCutOff` hears how much of the title has scrolled above the page's top, from
/// 0 to 1. The first line is the title, set as `textStyle(.heading)` sets it, with 「タイトル」 in
/// the tertiary colour while it is empty; the lines after it are the body, set as `Text(body:)`
/// sets it, `scale.space(.m)` below the title, as the page set them apart. Whatever the edit — a
/// line deleted, a line break typed or taken out — the first line is the title. `changed` hears the
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
struct WritingEditor<Top: View, Bottom: View>: View {
  let writing: WritingText
  var found: FoundMentions?
  var scrolls = true
  var bottomMargin: CGFloat = 0
  var titleCutOff: (CGFloat) -> Void = { _ in }
  let changed: (WritingText) -> Void
  @ViewBuilder let top: Top
  @ViewBuilder let bottom: Bottom
  @State private var asking: TitleRequest?
  @EnvironmentTypeScale private var scale
  @Environment(\.fontFamilies) private var families
  @Environment(\.openURL) private var openURL
  @Environment(\.displayScale) private var displayScale
  /// Handed on to `top` and `bottom`, which a hosting controller of their own holds.
  @Environment(\.self) private var environment

  var body: some View {
    let lines = EditorLines(scale: scale, families: families, pixel: 1 / displayScale)
    WritingTextView(
      writing: writing, found: found, askTitle: { asking = $0 }, changed: changed,
      open: { openURL($0) }, lines: lines, scrolls: scrolls, bottomMargin: bottomMargin,
      titleCutOff: titleCutOff, top: AnyView(top.environment(\.self, environment)),
      bottom: AnyView(bottom.environment(\.self, environment))
    )
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

struct WritingTextView: UIViewControllerRepresentable {
  let writing: WritingText
  let found: FoundMentions?
  let askTitle: (TitleRequest) -> Void
  let changed: (WritingText) -> Void
  let open: (URL) -> Void
  let lines: EditorLines
  let scrolls: Bool
  let bottomMargin: CGFloat
  let titleCutOff: (CGFloat) -> Void
  let top: AnyView
  let bottom: AnyView

  func makeUIViewController(context: Context) -> WritingPageController {
    let page = WritingPageController()
    let view = page.textView
    view.textContainer.lineFragmentPadding = 0
    // The text's own colour, as `TypeScale.attributes` sets it.
    view.tintColor = .label
    view.backgroundColor = .clear
    view.keyboardDismissMode = .interactive
    // A page of any length keeps clear of the screen's edges and bounces, as a short one too.
    view.contentInsetAdjustmentBehavior = .always
    view.alwaysBounceVertical = true
    view.delegate = context.coordinator
    view.pasteDelegate = context.coordinator
    let tap = UITapGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
    tap.delegate = context.coordinator
    view.addGestureRecognizer(tap)
    return page
  }

  func updateUIViewController(_ page: WritingPageController, context: Context) {
    let view = page.textView
    context.coordinator.changed = changed
    context.coordinator.askTitle = askTitle
    view.open = open
    page.show(top: top, bottom: bottom)
    page.titleCutOff = titleCutOff
    page.bottomMargin = bottomMargin
    view.scrolls = scrolls
    // Never while composing: replacing the text ends the input method's composition.
    guard view.markedTextRange == nil else { return }
    restyle(view, context: context)
    if let found, found.body.isSameText(as: view.writing.body), context.coordinator.found != found {
      context.coordinator.found = found
      view.mark(found)
    }
  }

  /// Sets the text and its links again, when they or the type have changed.
  private func restyle(_ view: PlaceholderTextView, context: Context) {
    guard view.lines != lines || view.writing != writing else { return }
    view.restyling = true
    defer { view.restyling = false }
    context.coordinator.found = nil
    view.lines = lines
    // For one line, until the page measures the title on the type area.
    view.titleSpacing = lines.placement.spacing(belowTitleOf: lines.scale.lineHeight(.heading))
    view.titleHeight = lines.scale.lineHeight(.heading)
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
    view.setNeedsLayout()
  }

  /// Text still being composed when the editor goes away is kept, as if composing had ended.
  static func dismantleUIViewController(_ page: WritingPageController, coordinator: Coordinator) {
    let view = page.textView
    guard view.markedTextRange != nil else { return }
    let writing = view.writing
    // After the update that removes the editor, which can't change state itself.
    Task { @MainActor in coordinator.changed(writing) }
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
      view.showTheCaret()
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
    restyling = true
    defer { restyling = false }
    let storage = textStorage
    let whole = NSRange(location: 0, length: storage.length)
    let linked = textLinks.map { NSRange($0.range) }
    var wanted: [NSRange: URL] = [:]
    for mention in found.mentions {
      // Converted in the body they were found in: an index into another string, even one equal
      // to it, may stand for another place.
      let inBody = NSRange(mention.range, in: found.body)
      let range = NSRange(location: bodyStart + inBody.location, length: inBody.length)
      guard NSMaxRange(range) <= storage.length,
        !linked.contains(where: { NSIntersectionRange($0, range).length > 0 })
      else { continue }
      wanted[range] = mention.writing.link
    }
    // Only what differs from what is marked: a change to the text's attributes lays its lines out
    // again, and TextKit places the rest of a long text anew by an estimate.
    var marked: [NSRange: URL] = [:]
    storage.enumerateAttribute(.mention, in: whole) { value, range, _ in
      if let url = value as? URL { marked[range] = url }
    }
    guard marked != wanted else { return }
    storage.beginEditing()
    for (range, url) in marked where wanted[range] != url {
      storage.removeAttribute(.mention, range: range)
      storage.enumerateAttribute(.bodyLink, in: range) { link, part, _ in
        if link == nil { storage.removeAttribute(.underlineStyle, range: part) }
      }
    }
    for (range, url) in wanted where marked[range] != url {
      storage.addAttributes(
        [.mention: url, .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue],
        range: range)
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

/// The writing's page: the text view, scrolling, with `top` above its text and `bottom` below it,
/// each across its width, and the text on the type area between them, set where the page's own
/// `Text`s would set it.
final class WritingPageController: UIViewController {
  let textView = PlaceholderTextView(usingTextLayoutManager: true)
  var titleCutOff: (CGFloat) -> Void = { _ in }
  /// Left below `bottom` at the page's end.
  var bottomMargin: CGFloat = 0 {
    didSet {
      if bottomMargin != oldValue { textView.setNeedsLayout() }
    }
  }
  private let top = UIHostingController(rootView: AnyView(EmptyView()))
  private let bottom = UIHostingController(rootView: AnyView(EmptyView()))
  /// The heights `top` and `bottom` take across `width`, once measured.
  private var measured: (width: CGFloat, top: CGFloat, bottom: CGFloat)?
  private var cutOff: CGFloat?
  /// The text view's height at its last layout.
  private var height: CGFloat = 0

  override func loadView() {
    view = textView
    for host in [top, bottom] {
      // Placed in the page's content, which the page's own insets keep clear of the screen's edges.
      host.safeAreaRegions = []
      host.view.backgroundColor = .clear
      addChild(host)
      textView.addSubview(host.view)
      host.didMove(toParent: self)
    }
    textView.hosted = [top.view, bottom.view]
    textView.laidOut = { [weak self] in self?.place() }
  }

  func show(top: AnyView, bottom: AnyView) {
    self.top.rootView = top
    self.bottom.rootView = bottom
    measure(across: textView.bounds.width)
    textView.setNeedsLayout()
  }

  /// Measures `top` and `bottom` across `width`. Not while the text view lays out: measuring a
  /// hosting controller lays out the views in it, which asks the text view to lay out again.
  private func measure(across width: CGFloat) {
    guard width > 0 else { return }
    let fit = CGSize(width: width, height: .greatestFiniteMagnitude)
    measured = (width, top.sizeThatFits(in: fit).height, bottom.sizeThatFits(in: fit).height)
  }

  override func viewWillLayoutSubviews() {
    super.viewWillLayoutSubviews()
    if measured?.width != textView.bounds.width {
      measure(across: textView.bounds.width)
    }
  }

  /// Sets the text between `top` and `bottom`, and hears how much of the title is cut off.
  private func place() {
    let width = textView.bounds.width
    guard let lines = textView.lines, let measured, measured.width == width else { return }
    let area = lines.scale.typeArea(width: width)
    textView.spaceTheTitle(within: area.lineLength)
    let placement = lines.placement
    // Where the editor's lines start on the page: on the pixel `top` ends on, moved as they are
    // moved to land where their own `Text`s would.
    let start = (measured.top / lines.pixel).rounded() * lines.pixel + placement.viewOffset
    let inset = UIEdgeInsets(
      top: start + placement.titleInset, left: area.margin,
      bottom: measured.bottom - (start - measured.top) - placement.excess,
      right: width - area.margin - area.lineLength)
    if textView.textContainerInset != inset {
      textView.textContainerInset = inset
    }
    if textView.contentInset.bottom != bottomMargin {
      textView.contentInset.bottom = bottomMargin
    }
    if textView.bounds.height < height {
      // Shorter, as under the keyboard.
      textView.showTheCaret()
    }
    height = textView.bounds.height
    top.view.frame = CGRect(x: 0, y: 0, width: width, height: measured.top)
    bottom.view.frame = CGRect(
      x: 0, y: textView.contentSize.height - measured.bottom, width: width,
      height: measured.bottom)
    let shown = textView.contentOffset.y + textView.adjustedContentInset.top
    let height = textView.titleHeight
    let cut = height > 0 ? min(max((shown - measured.top) / height, 0), 1) : 0
    if cut != cutOff {
      cutOff = cut
      titleCutOff(cut)
    }
  }
}

extension PlaceholderTextView: @preconcurrency NSTextStorageDelegate {
  /// Forgets the text as read.
  func textStorage(
    _ storage: NSTextStorage, didProcessEditing edited: NSTextStorage.EditActions,
    range: NSRange, changeInLength delta: Int
  ) {
    read = nil
  }
}

/// A text view that shows `placeholder` over its first line while that line is empty, composed text
/// included. VoiceOver offers each link and mention in it as an action that hands its address to
/// `open`.
final class PlaceholderTextView: UITextView {
  var open: (URL) -> Void = { _ in }

  /// Views placed in the text view over its insets, whose touches are theirs alone.
  var hosted: [UIView] = []
  /// Called after each layout of the text view, as it scrolls too, and as its content's height
  /// changes.
  var laidOut: () -> Void = {}

  override var contentSize: CGSize {
    didSet {
      if contentSize != oldValue { setNeedsLayout() }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let fitted = placeholder.sizeThatFits(
      CGSize(width: textContainer.size.width, height: .greatestFiniteMagnitude))
    placeholder.frame = CGRect(
      x: textContainerInset.left, y: textContainerInset.top, width: textContainer.size.width,
      height: fitted.height)
    laidOut()
  }

  override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
    takes(recognizer, at: recognizer.location(in: self))
      && super.gestureRecognizerShouldBegin(recognizer)
  }

  /// Whether `recognizer` may start at `point`: its pan while it `scrolls`, and its other gestures
  /// nowhere over a hosted view, so a tap there is the view's and doesn't put the caret in.
  func takes(_ recognizer: UIGestureRecognizer, at point: CGPoint) -> Bool {
    if recognizer === panGestureRecognizer { return scrolls }
    return recognizer.view !== self || !hosted.contains { !$0.isHidden && $0.frame.contains(point) }
  }

  /// Set while the editor sets the text's attributes itself: the caret stays where it is, and
  /// TextKit, laying out again, places it by an estimate until it has.
  var restyling = false

  /// Whether a drag scrolls the page. Not `isScrollEnabled`, which scrolls a text view to its top.
  var scrolls = true

  /// Scrolls by as little as keeps the caret's line within what the page shows clear of its
  /// insets, as the fade at its bottom: UIKit keeps it only within the text view's bounds.
  func showTheCaret() {
    guard isFirstResponder, !restyling, let range = selectedTextRange else { return }
    // A caret far from what is laid out is placed by an estimate; laid out there, it moves.
    for _ in 0..<3 {
      let caret = caretRect(for: range.end)
      let shown = bounds.inset(by: adjustedContentInset)
      var y = contentOffset.y
      if caret.maxY > shown.maxY {
        y += caret.maxY - shown.maxY
      } else if caret.minY < shown.minY {
        y -= shown.minY - caret.minY
      }
      let end = contentSize.height + adjustedContentInset.bottom - bounds.height
      y = max(min(y, end), -adjustedContentInset.top)
      guard y != contentOffset.y else { return }
      contentOffset.y = y
      layoutIfNeeded()
    }
  }

  /// The lines the text was last set in; nil until it is first set.
  var lines: EditorLines?
  /// The space below the title, as `spaceTheTitle(within:)` last measured it.
  var titleSpacing: CGFloat = 0
  /// How tall the title's lines are, as `spaceTheTitle(within:)` last measured them.
  var titleHeight: CGFloat = 0

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
    titleHeight = height
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

  /// As tall as the type on the caret's line, from its ascender to its descender, not the line's
  /// whole box.
  override func caretRect(for position: UITextPosition) -> CGRect {
    let caret = super.caretRect(for: position)
    guard let type = typeExtent(atHeightOf: caret) else { return caret }
    return CGRect(
      x: caret.minX, y: type.lowerBound, width: caret.width,
      height: type.upperBound - type.lowerBound)
  }

  /// The highlight as UIKit draws it, with each of the selection's handles where the caret would
  /// be at that end, and as tall. An empty range is UIKit's.
  override func selectionRects(for range: UITextRange) -> [UITextSelectionRect] {
    let rects = super.selectionRects(for: range)
    guard !range.isEmpty else { return rects }
    return rects.map(Highlight.init) + [
      SelectionEnd(at: range.start, isStart: true, of: rects, in: self),
      SelectionEnd(at: range.end, isStart: false, of: rects, in: self),
    ]
  }

  /// From the ascender to the descender of the type on the line laid out at `rect`'s middle, in
  /// the view's coordinates; nil where no line is laid out there. A line with no characters, as
  /// after a last line break, is in the body's type, or the title's in an empty text.
  private func typeExtent(atHeightOf rect: CGRect) -> ClosedRange<CGFloat>? {
    guard let lines else { return nil }
    let inset = textContainerInset
    guard textStorage.length > 0 else {
      return typeExtent(of: titleAttributes, onLineAt: inset.top)
    }
    let point = CGPoint(x: rect.midX - inset.left, y: rect.midY - inset.top)
    guard let fragment = textLayoutManager?.textLayoutFragment(for: point) else { return nil }
    let origin = fragment.layoutFragmentFrame.origin
    let found = fragment.textLineFragments.first { line in
      let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
      return bounds.minY <= point.y && point.y < bounds.maxY
    }
    guard let line = found ?? fragment.textLineFragments.last else { return nil }
    let top = inset.top + origin.y + line.typographicBounds.minY
    guard line.characterRange.length > 0,
      let font = line.attributedString.attribute(
        .font, at: line.characterRange.location, effectiveRange: nil) as? UIFont
    else { return typeExtent(of: lines.body, onLineAt: top) }
    let baseline = top + line.glyphOrigin.y
    return (baseline - font.ascender)...(baseline - font.descender)
  }

  /// From the ascender to the descender of text set in `attributes` on a line whose box starts at
  /// `top`, with its baseline placed as `EditorLines` says.
  private func typeExtent(
    of attributes: [NSAttributedString.Key: Any], onLineAt top: CGFloat
  ) -> ClosedRange<CGFloat>? {
    guard let font = attributes[.font] as? UIFont,
      let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
    else { return nil }
    let baseline = top + paragraph.maximumLineHeight + font.descender
    return (baseline - font.ascender)...(baseline - font.descender)
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

/// A part of a selection's highlight as UIKit laid it out, holding neither of its ends.
private final class Highlight: UITextSelectionRect {
  private let base: UITextSelectionRect

  init(_ base: UITextSelectionRect) {
    self.base = base
  }

  override var rect: CGRect { base.rect }
  override var writingDirection: NSWritingDirection { base.writingDirection }
  override var isVertical: Bool { base.isVertical }
  override var containsStart: Bool { false }
  override var containsEnd: Bool { false }
}

/// One end of a selection, where its handle stands, with no highlight of its own.
private final class SelectionEnd: UITextSelectionRect {
  private let edge: CGRect
  private let direction: NSWritingDirection
  private let isStart: Bool

  /// At `position`, where `view` puts its caret, written in the direction UIKit gives that end
  /// among `rects`.
  init(
    at position: UITextPosition, isStart: Bool, of rects: [UITextSelectionRect], in view: UITextView
  ) {
    let caret = view.caretRect(for: position)
    edge = CGRect(x: caret.midX, y: caret.minY, width: 0, height: caret.height)
    let uikits = rects.first { isStart ? $0.containsStart : $0.containsEnd }
    direction = uikits?.writingDirection ?? .natural
    self.isStart = isStart
  }

  override var rect: CGRect { edge }
  override var writingDirection: NSWritingDirection { direction }
  override var isVertical: Bool { false }
  override var containsStart: Bool { isStart }
  override var containsEnd: Bool { !isStart }
}
