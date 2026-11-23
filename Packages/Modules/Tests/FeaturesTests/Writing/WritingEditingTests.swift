import SnapshotTesting
import SwiftUI
import Testing
import Typesetting
import UIKit

@testable import Features

@MainActor
struct WritingEditingTests {
  @Test func theBodyIsEditableOnlyWhileEditing() {
    #expect(bodyEditor(in: HostedPage(screen(editing: false, edits: Edits()))) == nil)
    #expect(bodyEditor(in: HostedPage(screen(editing: true, edits: Edits()))) != nil)
  }

  /// Text typed into the body reaches `edit` as the writing's whole body.
  @Test func typingInTheBodyEditsTheWriting() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let editor = try #require(bodyEditor(in: page))
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.insertText("追記")
    #expect(edits.writing.body == "朝の机\n二行目追記")
  }

  /// A line break typed into the title is refused, so the title on screen is the one saved.
  @Test func aLineBreakTypedIntoTheTitleIsRefused() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let title = try focusedTitle(in: page, holding: "朝")
    title.selectedRange = NSRange(location: 1, length: 0)
    type("\n", into: title)
    type("夕", into: title)
    #expect(title.text == "朝夕")
    #expect(edits.writing.title == "朝夕")
  }

  /// Text with line breaks replacing part of the title keeps its words and drops the breaks.
  @Test func aLineBreakInTextPutIntoTheTitleIsDropped() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let title = try focusedTitle(in: page, holding: "朝")
    title.selectedRange = NSRange(location: 0, length: 1)
    type("夜の\n机", into: title)
    #expect(title.text == "夜の机")
    #expect(edits.writing.title == "夜の机")
  }

  /// Return in the body starts a new paragraph.
  @Test func returnInTheBodyStartsANewLine() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: 3, length: 0)
    type("\n", into: body)
    #expect(edits.writing.body == "朝の机\n\n二行目")
  }

  /// Return over a selection in the title leaves the selected text in place.
  @Test func returnOverASelectionInTheTitleKeepsIt() throws {
    let edits = Edits(writing: Writing(title: "朝昼", body: "本文"))
    let page = HostedPage(screen(editing: true, edits: edits))
    let title = try focusedTitle(in: page, holding: "朝昼")
    title.selectedRange = NSRange(location: 0, length: 2)
    type("\n", into: title)
    #expect(title.text == "朝昼")
    #expect(edits.writing.title == "朝昼")
  }

  /// When the body changes from elsewhere, the editor shows the new text, with the caret kept
  /// inside it.
  @Test func aBodyChangedFromElsewhereKeepsTheCaretInside() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.selectedRange = NSRange(location: (body.text as NSString).length, length: 0)
    edits.writing.body = "朝\n夜"
    page.show(screen(editing: true, edits: edits))
    #expect(body.text == "朝\n夜")
    #expect(body.selectedRange == NSRange(location: 3, length: 0))
  }

  /// A new body setting while editing sets the body again in it.
  @Test func aNewBodySettingRestylesTheBody() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    let setting = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    page.show(screen(editing: true, edits: edits, setting: setting))
    let font = try #require(
      body.attributedText.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
    #expect(font.pointSize == TypeScale(.large, body: setting).size(.body))
  }

  /// Undo after a refused line break takes back what was typed before it, and only that.
  @Test(arguments: [0, 2])
  func undoAfterARefusedLineBreakTakesBackTheTyping(_ caret: Int) throws {
    let edits = Edits(writing: Writing(title: "朝昼", body: "本文"))
    let page = HostedPage(screen(editing: true, edits: edits))
    let title = try focusedTitle(in: page, holding: "朝昼")
    title.selectedRange = NSRange(location: caret, length: 0)
    type("夕", into: title)
    page.settle()
    type("\n", into: title)
    page.settle()
    let undo = try #require(title.undoManager)
    while undo.canUndo {
      undo.undo()
      page.settle()
    }
    #expect(title.text == "朝昼")
    #expect(edits.writing.title == "朝昼")
  }

  /// The placeholder goes as soon as text is being composed into an empty title.
  @Test func composingIntoAnEmptyTitleHidesThePlaceholder() throws {
    let page = HostedPage(
      screen(editing: true, edits: Edits(writing: Writing(title: "", body: "本文"))))
    let title = try focusedTitle(in: page, holding: "")
    let line = title.convert(title.bounds, to: nil)
    // Past the first character, where only the placeholder's later characters would be.
    let pastFirst = CGRect(
      x: line.minX + 40, y: line.minY, width: 160, height: TypeScale.standard.lineHeight(.heading))
    #expect(try darkPixels(in: page.image(), within: pastFirst) > 0)
    title.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
    page.settle()
    #expect(try darkPixels(in: page.image(), within: pastFirst) == 0)
  }

  /// Text still being composed when editing ends is kept.
  @Test func textBeingComposedWhenEditingEndsIsKept() async throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: (body.text as NSString).length, length: 0)
    body.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
    page.show(screen(editing: false, edits: edits))
    try await page.settle { edits.writing.body.hasSuffix("かな") }
    #expect(edits.writing.body == "朝の机\n二行目かな")
  }

  /// While an input method composes text, nothing is edited; the text it settles on is.
  @Test func composedTextEditsTheWritingOnceSettled() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let editor = try #require(bodyEditor(in: page))
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
    #expect(edits.writing.body == "朝の机\n二行目")
    editor.unmarkText()
    #expect(edits.writing.body == "朝の机\n二行目か")
  }

  /// The title and body are drawn where they are when read, so entering the mode moves no text:
  /// the same lines, each within a pixel. SwiftUI and TextKit may round a line whose position
  /// isn't a whole number of pixels to neighbouring pixels; none is further off, and none drifts.
  @Test(arguments: [
    (DynamicTypeSize.large, BodySetting?.some(.standard)), (.accessibility5, .standard),
    // Lines closer than the font's own, and the widest tracking.
    (.large, BodySetting(base: 16, lineHeight: 16, tracking: 200)),
  ])
  func editingMovesNoLinePastAPixel(_ size: DynamicTypeSize, _ setting: BodySetting?) throws {
    let setting = try #require(setting)
    let read = try inkBands(drawn(editing: false, size, setting))
    let edited = try inkBands(drawn(editing: true, size, setting))
    try #require(read.count == edited.count)
    #expect(read.count > 3)
    for (line, (readBand, editedBand)) in zip(read, edited).enumerated() {
      #expect(abs(readBand.lowerBound - editedBand.lowerBound) <= 1, "line \(line)")
      #expect(abs(readBand.upperBound - editedBand.upperBound) <= 1, "line \(line)")
    }
  }

  /// A title written into the body while editing is linked once editing ends, as on a page opened
  /// with it.
  @Test func leavingEditingLinksTitlesInTheEditedBody() async throws {
    let nightDesk = Writing(title: "夜の机に向かう", body: "")
    let edits = Edits(writing: Writing(title: "朝", body: "本文"))
    func page(editing: Bool) -> some View {
      WritingScreen(
        writing: edits.writing, others: [nightDesk], open: { _ in },
        edit: { edits.writing.apply($0) },
        photos: [], setting: .constant(.standard), editing: .constant(editing),
        typesetting: .constant(false), takingPhoto: .constant(false), camera: .standIn(taking: nil),
        photoTaken: { _ in })
    }
    let hosted = HostedPage(page(editing: true))
    edits.writing.body = "本文と夜の机に向かう"
    hosted.show(page(editing: true))
    hosted.show(page(editing: false))
    let opened = HostedPage(page(editing: false))
    try await opened.settle { false }
    try await hosted.settle { false }
    #expect(hosted.image().pngData() == opened.image().pngData())
  }

  /// A web address pasted over selected body text links that text, and the text stays.
  @Test func pastingAWebAddressOverASelectionLinksIt() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.selectedRange = NSRange(location: 0, length: 2)
    try paste("https://example.com/bread", into: body)
    #expect(edits.writing.body == "朝の机\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 0..<2, url: bread)])
    #expect(page.presented == nil)
  }

  /// Text that is not a web address, over a selection or not, is pasted as text: nothing is
  /// linked, and no sheet opens.
  @Test(arguments: [NSRange(location: 0, length: 2), NSRange(location: 3, length: 0)])
  func otherTextIsNotLinked(_ selection: NSRange) throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.selectedRange = selection
    try paste("example.com", into: body)
    page.settle()
    #expect(edits.writing.links.isEmpty)
    #expect(page.presented == nil)
  }

  /// The title holds no links: a web address pasted into it is pasted as text, and no sheet opens.
  @Test(arguments: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 0)])
  func aWebAddressPastedIntoTheTitleIsNotLinked(_ selection: NSRange) throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let title = try focusedTitle(in: page, holding: "朝")
    title.selectedRange = selection
    try paste("https://example.com/bread", into: title)
    page.settle()
    #expect(title.attributedText.attribute(.link, at: 0, effectiveRange: nil) == nil)
    #expect(page.presented == nil)
  }

  /// A web address pasted with nothing selected opens the sheet that asks for its title, and
  /// puts nothing in yet.
  @Test func pastingAWebAddressWithNothingSelectedOpensTheSheet() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.selectedRange = NSRange(location: 3, length: 0)
    try paste("https://example.com/bread", into: body)
    page.settle()
    #expect(page.presented != nil)
    #expect(edits.writing.body == "朝の机\n二行目")
    #expect(edits.writing.links.isEmpty)
  }

  /// The title the sheet gives goes in at the caret where the address was pasted, wherever the
  /// caret went meanwhile, linked to it, and the caret after it; an empty title puts the address
  /// itself in; none puts nothing in.
  @Test(arguments: [
    ("パンの店", "朝の机パンの店\n二行目", [BodyLink(range: 3..<7, url: bread)], 7),
    ("🍞🍞", "朝の机🍞🍞\n二行目", [BodyLink(range: 3..<7, url: bread)], 7),
    (" ", "朝の机https://example.com/bread\n二行目", [BodyLink(range: 3..<28, url: bread)], 28),
  ])
  func theTitleGivenGoesInLinked(
    _ title: String, _ body: String, _ links: [BodyLink], _ caret: Int
  ) throws {
    let asked = try AskedForATitle()
    asked.view.selectedRange = NSRange(location: 0, length: 0)
    asked.answer(title)
    #expect(asked.view.text == body)
    #expect(asked.view.links == links)
    #expect(asked.view.selectedRange == NSRange(location: caret, length: 0))
    #expect(asked.changes.last?.text == body)
    #expect(asked.changes.last?.links == links)
  }

  @Test func noTitleGivenPutsNothingIn() throws {
    let asked = try AskedForATitle()
    asked.answer(nil)
    #expect(asked.view.text == "朝の机\n二行目")
    #expect(asked.view.links.isEmpty)
    #expect(asked.changes.isEmpty)
  }

  /// Text typed right after a title put in inside another link goes on neither link.
  @Test func typingAfterATitlePutInsideALinkIsNotLinked() throws {
    let asked = try AskedForATitle(links: [BodyLink(range: 1..<5, url: flour)])
    asked.answer("パン")
    #expect(
      asked.view.links == [
        BodyLink(range: 1..<3, url: flour), BodyLink(range: 3..<5, url: bread),
        BodyLink(range: 5..<7, url: flour),
      ])
    asked.view.insertText("x")
    #expect(asked.view.text == "朝の机パンx\n二行目")
    #expect(
      asked.view.links == [
        BodyLink(range: 1..<3, url: flour), BodyLink(range: 3..<5, url: bread),
        BodyLink(range: 6..<8, url: flour),
      ])
  }

  /// Undo after linking a selection takes the link off, and only that.
  @Test func undoAfterLinkingASelectionTakesTheLinkOff() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: 3, length: 0)
    type("と", into: body)
    page.settle()
    body.selectedRange = NSRange(location: 0, length: 2)
    try paste("https://example.com/bread", into: body)
    page.settle()
    try #require(body.undoManager).undo()
    page.settle()
    #expect(edits.writing.body == "朝の机と\n二行目")
    #expect(edits.writing.links.isEmpty)
  }

  /// A web address with space around it, or held as a URL rather than text, links the selection.
  @Test func aWebAddressWithSpaceOrHeldAsAURLLinksTheSelection() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.selectedRange = NSRange(location: 0, length: 2)
    try paste("  https://example.com/bread\n", into: body)
    #expect(edits.writing.links == [BodyLink(range: 0..<2, url: bread)])
    body.selectedRange = NSRange(location: 4, length: 3)
    try paste(into: body) { $0.url = flour }
    #expect(
      edits.writing.links == [
        BodyLink(range: 0..<2, url: bread), BodyLink(range: 4..<7, url: flour),
      ])
  }

  /// Links changed from elsewhere while editing are drawn in the editor.
  @Test func linksChangedFromElsewhereAreShown() throws {
    let edits = Edits()
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    edits.writing.links = [BodyLink(range: 0..<2, url: bread)]
    page.show(screen(editing: true, edits: edits))
    #expect(body.links == [BodyLink(range: 0..<2, url: bread)])
  }

  /// Links are kept when text still being composed is kept as editing ends.
  @Test func linksAreKeptWithTextBeingComposedWhenEditingEnds() async throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "朝の机\n二行目", links: [BodyLink(range: 0..<2, url: bread)]))
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: (body.text as NSString).length, length: 0)
    body.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
    page.show(screen(editing: false, edits: edits))
    try await page.settle { edits.writing.body.hasSuffix("かな") }
    #expect(edits.writing.links == [BodyLink(range: 0..<2, url: bread)])
  }

  /// The sheet's title field is focused as it opens, so the title can be typed at once.
  @Test func theSheetsTitleFieldIsFocusedAsItOpens() async throws {
    let page = HostedPage(LinkTitleSheet(url: bread) { _ in })
    try await page.settle { page.textFields.contains { $0.isFirstResponder } }
    #expect(page.textFields.count == 1)
    #expect(page.textFields.first?.isFirstResponder == true)
  }

  /// Text typed at a link's end is not linked; text typed inside it is.
  @Test func typingAtALinksEndLeavesItAndInsideExtendsIt() throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "粉の店へ\n二行目", links: [BodyLink(range: 0..<3, url: flour)]))
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: 3, length: 0)
    type("と", into: body)
    #expect(edits.writing.links == [BodyLink(range: 0..<3, url: flour)])
    body.selectedRange = NSRange(location: 1, length: 0)
    type("と", into: body)
    #expect(edits.writing.body == "粉との店とへ\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 0..<4, url: flour)])
  }

  /// Text typed at a link's start, at the body's start or end, or between two links goes on no
  /// link.
  @Test(arguments: [
    ("粉の店\n二行目", [BodyLink(range: 0..<3, url: flour)], 0, [BodyLink(range: 1..<4, url: flour)]),
    ("朝\n粉の店", [BodyLink(range: 2..<5, url: flour)], 5, [BodyLink(range: 2..<5, url: flour)]),
    (
      "粉パン\n二行目", [BodyLink(range: 0..<1, url: flour), BodyLink(range: 1..<3, url: bread)], 1,
      [BodyLink(range: 0..<1, url: flour), BodyLink(range: 2..<4, url: bread)]
    ),
  ])
  func typingAtALinksEdgeIsNotLinked(
    _ text: String, _ links: [BodyLink], _ caret: Int, _ after: [BodyLink]
  ) throws {
    let edits = Edits(writing: Writing(title: "朝", body: text, links: links))
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: caret, length: 0)
    type("と", into: body)
    #expect(edits.writing.links == after)
  }

  /// A combining mark typed at a link's end joins the link's last character, so the link takes in
  /// the whole character rather than ending inside it.
  @Test func aMarkJoiningALinksLastCharacterStaysInTheLink() throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "cafe\n二行目", links: [BodyLink(range: 0..<4, url: flour)]))
    let page = HostedPage(screen(editing: true, edits: edits))
    let body = try #require(bodyEditor(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: 4, length: 0)
    type("\u{0301}", into: body)
    #expect(edits.writing.body == "cafe\u{0301}\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 0..<5, url: flour)])
  }

  @Test func editingABodyWithALink() {
    assertSnapshot(
      of: screen(editing: true, edits: Edits(writing: linked))
        .frame(width: 402, height: 874)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  @Test func theLinkSheet() {
    assertSnapshot(
      of: LinkTitleSheet(url: bread) { _ in }
        .frame(width: 402, height: 437)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  @Test func editingMode() {
    assertSnapshot(
      of: screen(editing: true, edits: Edits(writing: sampled))
        .frame(width: 402, height: 874)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  /// An empty title keeps its line while being edited, as it does when read.
  @Test func anUntitledWritingKeepsTheTitleLineWhileEdited() throws {
    func height(_ title: String) throws -> CGFloat {
      let page = HostedPage(
        ScrollView {
          WritingPage(
            writing: Writing(title: title, body: "本文"), editing: true, photos: [], width: 402,
            back: {}, titleCutOff: { _ in })
        })
      return try #require(page.scrollViews.first).contentSize.height
    }
    #expect(try height("") == height("朝"))
  }

  @Test func editingAnUntitledWriting() {
    assertSnapshot(
      of: screen(editing: true, edits: Edits(writing: Writing(title: "", body: "本文")))
        .frame(width: 402, height: 874)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }
}

private let sampled = Writing(title: "間合いの調整", body: Writing.sampleBody)

nonisolated private let bread = URL(string: "https://example.com/bread") ?? URL(filePath: "/")
nonisolated private let flour = URL(string: "https://example.com/flour") ?? URL(filePath: "/")

/// The sample page with its first line's 「小さなパン」 linked.
private let linked = Writing(
  title: "間合いの調整", body: Writing.sampleBody, links: [BodyLink(range: 3..<8, url: bread)])

/// Pastes `text` into `view` as the edit menu's Paste does, from a pasteboard of the test's own: a
/// test can't read the general one. What isn't a web address is left to the general one, so it
/// pastes nothing here.
@MainActor
private func paste(_ text: String, into view: UITextView) throws {
  try paste(into: view) { $0.string = text }
}

/// Pastes what `fill` puts on a pasteboard of the test's own into `view`.
@MainActor
private func paste(into view: UITextView, _ fill: (UIPasteboard) -> Void) throws {
  let editor = try #require(view as? PlaceholderTextView)
  let pasteboard = try #require(UIPasteboard(name: .init(UUID().uuidString), create: true))
  defer { UIPasteboard.remove(withName: pasteboard.name) }
  fill(pasteboard)
  editor.pasteboard = pasteboard
  editor.paste(nil)
}

/// A body editor holding 「朝の机\n二行目」 that was pasted a web address with the caret after
/// 「朝の机」: the request the paste made, and the changes the editor has reported since.
@MainActor
private final class AskedForATitle {
  let view = PlaceholderTextView(usingTextLayoutManager: true)
  private(set) var changes: [(text: String, links: [BodyLink])] = []
  private var coordinator: StyledTextView.Coordinator?
  private var asked: TitleRequest?

  init(links: [BodyLink] = []) throws {
    let coordinator = StyledTextView.Coordinator(changed: { _, _ in }, oneLine: false)
    coordinator.changed = { [weak self] in self?.changes.append(($0, $1)) }
    self.coordinator = coordinator
    view.delegate = coordinator
    let text = NSMutableAttributedString(string: "朝の机\n二行目")
    for link in links {
      text.addAttribute(.link, value: link.url, range: NSRange(link.range))
    }
    view.attributedText = text
    view.selectedRange = NSRange(location: 3, length: 0)
    coordinator.paste(bread, into: view) { self.asked = $0 }
    try #require(asked != nil)
  }

  func answer(_ title: String?) {
    asked?.answer(title)
  }
}

/// The sample page at the top of a 402 × 874 window, read or being edited.
@MainActor
private func drawn(editing: Bool, _ size: DynamicTypeSize, _ setting: BodySetting = .standard)
  -> UIImage
{
  HostedPage(
    ScrollView {
      WritingPage(
        writing: sampled, editing: editing, photos: [], width: 402, back: {},
        titleCutOff: { _ in })
    }
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.bodySetting, setting)
    .environment(\.colorScheme, .light)
  ).image()
}

/// `image` in grey, one byte a pixel, top row first.
private func greyPixels(_ image: UIImage) throws -> (pixels: [UInt8], width: Int, height: Int) {
  let cgImage = try #require(image.cgImage)
  let width = cgImage.width
  let height = cgImage.height
  var pixels = [UInt8](repeating: 0, count: width * height)
  let drawn = pixels.withUnsafeMutableBytes { buffer in
    CGContext(
      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.none.rawValue)
  }
  try #require(drawn != nil)
  drawn?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
  return (pixels, width, height)
}

/// How many pixels in `rect` (in points) are darker than the background, the tertiary colour
/// included.
private func darkPixels(in image: UIImage, within rect: CGRect) throws -> Int {
  let (pixels, width, height) = try greyPixels(image)
  let scale = image.scale
  let columns = max(0, Int(rect.minX * scale))..<min(width, Int(rect.maxX * scale))
  let rows = max(0, Int(rect.minY * scale))..<min(height, Int(rect.maxY * scale))
  return rows.reduce(0) { count, row in
    count + columns.count { pixels[row * width + $0] < 230 }
  }
}

/// The runs of pixel rows in `image` that hold any dark pixel, top to bottom.
private func inkBands(_ image: UIImage) throws -> [ClosedRange<Int>] {
  let (pixels, width, height) = try greyPixels(image)
  var bands: [ClosedRange<Int>] = []
  for row in 0..<height
  where pixels[(row * width)..<((row + 1) * width)].contains(where: { $0 < 128 }) {
    if let last = bands.last, last.upperBound == row - 1 {
      bands[bands.count - 1] = last.lowerBound...row
    } else {
      bands.append(row...row)
    }
  }
  return bands
}

/// The writing as the edits handed to the screen leave it.
@MainActor
private final class Edits {
  var writing: Writing

  init(writing: Writing = Writing(title: "朝", body: "朝の机\n二行目")) {
    self.writing = writing
  }
}

private func screen(editing: Bool, edits: Edits, setting: BodySetting = .standard) -> some View {
  WritingScreen(
    writing: edits.writing, others: [], open: { _ in }, edit: { edits.writing.apply($0) },
    photos: [],
    setting: .constant(setting),
    editing: .constant(editing),
    typesetting: .constant(false),
    takingPhoto: .constant(false),
    camera: .standIn(taking: nil),
    photoTaken: { _ in })
}

extension Writing {
  fileprivate mutating func apply(_ change: (inout Writing) -> Void) {
    change(&self)
  }
}

/// The text view holding the title, found by its text, ready for typing as the keyboard types.
@MainActor
private func focusedTitle(in page: HostedPage, holding title: String) throws -> UITextView {
  let view = try #require(page.textViews.first { $0.text == title })
  view.becomeFirstResponder()
  page.settle()
  return view
}

/// Puts `text` in place of `view`'s selection as the keyboard or a paste does: only if its
/// delegate lets it.
@MainActor
private func type(_ text: String, into view: UITextView) {
  if view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: text)
    ?? true
  {
    view.insertText(text)
  }
}

/// The text view holding the body, found by its text.
@MainActor
private func bodyEditor(in page: HostedPage) -> UITextView? {
  page.textViews.first { $0.text.contains("\n") || $0.text == "本文" }
}
