import SnapshotTesting
import SwiftUI
import Testing
import Typesetting
import UIKit

@testable import Features

@MainActor
struct WritingEditingTests {
  /// A page just opened can be typed into: the title and body are one editor, the title on its
  /// first line.
  @Test func theTitleAndBodyAreOneEditorAsThePageOpens() throws {
    let page = HostedPage(screen(edits: Edits()))
    #expect(page.textViews.count == 1)
    let editor = try #require(editorView(in: page))
    #expect(editor.text == "朝\n朝の机\n二行目")
    #expect(editor.isEditable)
  }

  /// Text typed into the body reaches `edit` as the writing's whole body.
  @Test func typingInTheBodyEditsTheWriting() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try #require(editorView(in: page))
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.insertText("追記")
    #expect(edits.writing.body == "朝の机\n二行目追記")
    #expect(edits.writing.title == "朝")
  }

  /// Return at the title's end goes on into the body, in the body's type, with no tap between.
  @Test func returnAtTheTitlesEndStartsTheBody() throws {
    let edits = Edits(writing: Writing(title: "", body: ""))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    type("朝", into: editor)
    type("\n", into: editor)
    type("本文", into: editor)
    #expect(edits.writing.title == "朝")
    #expect(edits.writing.body == "本文")
    #expect(try role(at: 0, in: editor) == .heading)
    #expect(try role(at: 2, in: editor) == .body)
  }

  /// Return inside the title takes the rest of the title down into the body, set as the body.
  @Test func returnInsideTheTitleTakesTheRestIntoTheBody() throws {
    let edits = Edits(writing: Writing(title: "朝昼", body: "本文"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 1, length: 0)
    type("\n", into: editor)
    #expect(edits.writing.title == "朝")
    #expect(edits.writing.body == "昼\n本文")
    #expect(try role(at: 2, in: editor) == .body)
  }

  /// Deleting the line break after the title joins the body's first line to the title, set as
  /// the title, and the next line becomes the body's first.
  @Test func deletingTheTitlesLineBreakJoinsTheNextLineToIt() throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文\n二行目"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 2, length: 0)
    editor.deleteBackward()
    page.settle()
    #expect(edits.writing.title == "朝本文")
    #expect(edits.writing.body == "二行目")
    #expect(try role(at: 1, in: editor) == .heading)
    #expect(try role(at: 3, in: editor) == .heading)
    #expect(try role(at: 4, in: editor) == .body)
  }

  /// Deleting the whole first line makes the next line the title.
  @Test func deletingTheTitlesLineMakesTheNextLineTheTitle() throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文\n二行目"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 0, length: 2)
    editor.deleteBackward()
    #expect(edits.writing.title == "本文")
    #expect(edits.writing.body == "二行目")
    #expect(try role(at: 0, in: editor) == .heading)
    #expect(try role(at: 3, in: editor) == .body)
  }

  /// Text with line breaks put into the title runs on into the body from its first break.
  @Test func linesPutIntoTheTitleRunOnIntoTheBody() throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 0, length: 1)
    type("夜の\n机", into: editor)
    #expect(edits.writing.title == "夜の")
    #expect(edits.writing.body == "机\n本文")
    #expect(try role(at: 3, in: editor) == .body)
  }

  /// A body link pulled up into the title is no longer a link: the title holds none.
  @Test func aLinkPulledIntoTheTitleIsDropped() throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "小さなパン\n二行目", links: [BodyLink(range: 0..<5, url: bread)]))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 2, length: 0)
    editor.deleteBackward()
    #expect(edits.writing.title == "朝小さなパン")
    #expect(edits.writing.links.isEmpty)
    #expect(editor.linkedText.isEmpty)
    #expect(editor.attributedText.attribute(.underlineStyle, at: 2, effectiveRange: nil) == nil)
  }

  /// Another kind of line break typed into the title starts the body there, as Return does.
  @Test(arguments: ["\r", "\r\n", "\u{2028}", "\u{2029}"])
  func otherLineBreaksTypedIntoTheTitleStartTheBody(_ lineBreak: String) throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 1, length: 0)
    type("夜" + lineBreak + "机", into: editor)
    #expect(editor.text == "朝夜\n机\n本文")
    #expect(edits.writing.title == "朝夜")
    #expect(edits.writing.body == "机\n本文")
    #expect(try role(at: 3, in: editor) == .body)
    editor.undoManager?.undo()
    #expect(edits.writing.title == "朝")
  }

  /// Another kind of line break pasted or dropped into the title starts the body there, and the
  /// links that came with the text keep their characters.
  @Test(arguments: ["\r", "\r\n", "\u{2028}"])
  func otherLineBreaksPastedIntoTheTitleStartTheBody(_ lineBreak: String) throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    let dragged = NSMutableAttributedString(string: "夜" + lineBreak + "粉の店")
    let shop = ("夜" + lineBreak + "粉" as NSString).length
    dragged.addAttributes(.bodyLink(flour), range: NSRange(location: shop, length: 2))
    _ = try pasted(dragged, into: editor, at: NSRange(location: 1, length: 0))
    #expect(edits.writing.title == "朝夜")
    #expect(edits.writing.body == "粉の店\n本文")
    #expect(edits.writing.links == [BodyLink(range: 1..<3, url: flour)])
  }

  /// A title that came with a line break from elsewhere is shown as one line, the break as a space,
  /// and is set once, not at every update.
  @Test func aTitleHoldingALineBreakIsOneLine() throws {
    let edits = Edits(writing: Writing(title: "朝\n昼", body: "本文"))
    let page = HostedPage(screen(edits: edits))
    let editor = try #require(editorView(in: page))
    #expect(editor.text == "朝 昼\n本文")
    let marker = NSAttributedString.Key("TestMarker")
    editor.textStorage.addAttribute(marker, value: true, range: NSRange(location: 0, length: 1))
    page.show(screen(edits: edits))
    #expect(editor.textStorage.attribute(marker, at: 0, effectiveRange: nil) as? Bool == true)
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.insertText("。")
    #expect(edits.writing.title == "朝 昼")
    #expect(edits.writing.body == "本文。")
  }

  /// Text typed goes in in the type of the line the caret is on: the title's at a title-only
  /// writing's end and at the title's end, the body's at the body's start.
  @Test func typingGoesInInTheTypeOfTheCaretsLine() throws {
    let alone = HostedPage(screen(edits: Edits(writing: Writing(title: "朝", body: ""))))
    let titleOnly = try focusedEditor(in: alone)
    titleOnly.selectedRange = NSRange(location: 1, length: 0)
    #expect(try typedRole(in: titleOnly) == .heading)
    let page = HostedPage(screen(edits: Edits()))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 1, length: 0)
    #expect(try typedRole(in: editor) == .heading)
    editor.selectedRange = inBody(0)
    #expect(try typedRole(in: editor) == .body)
  }

  /// Text dragged with a link into the title goes in without it: the title holds none.
  @Test func textDraggedWithALinkIntoTheTitleLosesIt() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    let dragged = NSMutableAttributedString(string: "粉の店")
    dragged.addAttributes(.bodyLink(flour), range: NSRange(location: 0, length: 3))
    _ = try pasted(dragged, into: editor, at: NSRange(location: 1, length: 0))
    #expect(edits.writing.title == "朝粉の店")
    #expect(edits.writing.links.isEmpty)
    #expect(editor.linkedText.isEmpty)
    #expect(editor.attributedText.attribute(.underlineStyle, at: 1, effectiveRange: nil) == nil)
  }

  /// A title that wraps with no body after it has the space below it measured for its lines.
  @Test func aWrappedTitleWithNoBodyIsSpacedForItsLines() throws {
    let title = String(repeating: "間合いの調整", count: 4)
    let edits = Edits(writing: Writing(title: title, body: ""))
    let page = HostedPage(screen(edits: edits))
    let editor = try #require(editorView(in: page))
    let lines = try #require(editor.lines)
    #expect(editor.text == title)
    let measured = editor.titleSpacing
    #expect(measured > 0)
    editor.titleSpacing = 0
    editor.spaceTheTitle(within: editor.bounds.width)
    let paragraph = try #require(
      editor.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        as? NSParagraphStyle)
    #expect(paragraph.paragraphSpacing == measured)
    #expect(lines.scale.lineHeight(.heading) * 2 <= editor.bounds.height)
  }

  /// The header bar fades in as the title's line scrolls above the page's top: half of the line
  /// off is half faded in, and a line wholly off shows it whole.
  @Test func theHeaderFadesInAsTheTitleScrollsOff() throws {
    let cutOff = CutOff()
    let page = HostedPage(
      ScrollView {
        WritingPage(
          writing: sampled, photos: [], width: 402, back: {}, titleCutOff: { cutOff.last = $0 })
      })
    let editor = try #require(editorView(in: page))
    let scroll = try #require(page.scrollViews.first { !($0 is UITextView) })
    let lines = try #require(editor.lines)
    let lineHeight = lines.scale.lineHeight(.heading)
    // Where the title's line starts, from the page's top below the safe area.
    let top =
      editor.convert(CGPoint.zero, to: scroll).y - lines.placement.viewOffset
      - scroll.adjustedContentInset.top
    #expect(cutOff.last ?? 0 == 0)
    scroll.contentOffset.y = top + lineHeight / 2
    page.settle()
    #expect(abs((cutOff.last ?? 0) - 0.5) < 0.05)
    scroll.contentOffset.y = top + lineHeight * 3
    page.settle()
    #expect(cutOff.last == 1)
  }

  /// What measures the title for the header bar is not drawn: on an untitled page only the
  /// placeholder is, in the tertiary colour.
  @Test func theTitleMeasuredForTheHeaderIsNotDrawn() throws {
    let page = HostedPage(
      screen(edits: Edits(writing: Writing(title: "", body: "本文")))
        .background(Color(.systemBackground))
        .environment(\.colorScheme, .light))
    let editor = try #require(editorView(in: page))
    let lines = try #require(editor.lines)
    let titleLine = editor.convert(
      CGRect(
        x: 0, y: editor.textContainerInset.top, width: editor.bounds.width,
        height: lines.scale.lineHeight(.heading)), to: nil)
    #expect(try inkPixels(in: page.image(), within: titleLine) == 0)
    #expect(try darkPixels(in: page.image(), within: titleLine) > 0)
  }

  /// Return in the body starts a new paragraph.
  @Test func returnInTheBodyStartsANewLine() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = inBody(3)
    type("\n", into: editor)
    #expect(edits.writing.body == "朝の机\n\n二行目")
  }

  /// When the body changes from elsewhere, the editor shows the new text, with the caret kept
  /// inside it.
  @Test func aBodyChangedFromElsewhereKeepsTheCaretInside() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try #require(editorView(in: page))
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    edits.writing.body = "朝\n夜"
    page.show(screen(edits: edits))
    #expect(editor.text == "朝\n朝\n夜")
    #expect(editor.selectedRange == NSRange(location: 5, length: 0))
  }

  /// A writing with no body is its title alone; a line break typed after it stays, starting the
  /// body.
  @Test func aLineBreakAfterTheTitleStaysWhileTheBodyIsEmpty() throws {
    let edits = Edits(writing: Writing(title: "朝", body: ""))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    #expect(editor.text == "朝")
    editor.selectedRange = NSRange(location: 1, length: 0)
    type("\n", into: editor)
    page.show(screen(edits: edits))
    #expect(editor.text == "朝\n")
    #expect(editor.selectedRange == NSRange(location: 2, length: 0))
  }

  /// A new body setting while editing sets the body again in it.
  @Test func aNewBodySettingRestylesTheBody() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try #require(editorView(in: page))
    let setting = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    page.show(screen(edits: edits, setting: setting))
    let font = try #require(
      editor.attributedText.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
    #expect(font.pointSize == TypeScale(.large, body: setting).size(.body))
  }

  /// A new stack while editing sets the title and body again in it.
  @Test func aNewStackRestylesTheText() throws {
    let edits = Edits(writing: Writing(title: "Morning", body: "Pages"))
    let page = HostedPage(
      screen(edits: edits).environment(\.fontFamilies, [.notoSansJP]))
    let editor = try #require(editorView(in: page))
    page.show(
      screen(edits: edits).environment(\.fontFamilies, [.inter, .notoSansJP]))
    #expect(editorView(in: page) === editor)
    for location in [0, 8] {
      let font = try #require(
        editor.attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
      #expect(font.familyName == "Inter")
    }
  }

  /// Undo takes back a line break typed in the title, and the title is set as the title again.
  @Test func undoTakesBackALineBreakTypedInTheTitle() throws {
    let edits = Edits(writing: Writing(title: "朝昼", body: "本文"))
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 1, length: 0)
    type("\n", into: editor)
    page.settle()
    let undo = try #require(editor.undoManager)
    while undo.canUndo {
      undo.undo()
      page.settle()
    }
    #expect(edits.writing.title == "朝昼")
    #expect(edits.writing.body == "本文")
    #expect(try role(at: 1, in: editor) == .heading)
  }

  /// The placeholder goes as soon as text is being composed into an empty title.
  @Test func composingIntoAnEmptyTitleHidesThePlaceholder() throws {
    let page = HostedPage(
      screen(edits: Edits(writing: Writing(title: "", body: "本文"))))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: 0, length: 0)
    let line = editor.placeholder.convert(editor.placeholder.bounds, to: nil)
    // Past the first character, where only the placeholder's later characters would be.
    let pastFirst = CGRect(x: line.minX + 40, y: line.minY, width: 160, height: line.height)
    #expect(try darkPixels(in: page.image(), within: pastFirst) > 0)
    editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
    page.settle()
    #expect(try darkPixels(in: page.image(), within: pastFirst) == 0)
  }

  /// Text still being composed when the page closes is kept.
  @Test func textBeingComposedWhenThePageClosesIsKept() async throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
    page.show(Color.clear)
    try await page.settle { edits.writing.body.hasSuffix("かな") }
    #expect(edits.writing.body == "朝の机\n二行目かな")
  }

  /// While an input method composes text, nothing is edited; the text it settles on is.
  @Test func composedTextEditsTheWritingOnceSettled() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try #require(editorView(in: page))
    editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
    editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
    #expect(edits.writing.body == "朝の机\n二行目")
    editor.unmarkText()
    #expect(edits.writing.body == "朝の机\n二行目か")
  }

  /// The editor draws the title and body where `textStyle` sets them as text: the same lines, each
  /// within a pixel. SwiftUI and TextKit may round a line whose position
  /// isn't a whole number of pixels to neighbouring pixels; none is further off, and none drifts.
  @Test(arguments: [
    (DynamicTypeSize.large, BodySetting?.some(.standard)), (.accessibility5, .standard),
    // Lines closer than the font's own, and the widest tracking.
    (.large, BodySetting(base: 16, lineHeight: 16, tracking: 200)),
  ])
  func theEditorsSetLinesAsTextDoes(_ size: DynamicTypeSize, _ setting: BodySetting?) throws {
    let setting = try #require(setting)
    let read = try inkBands(drawn(editors: false, size, setting))
    let edited = try inkBands(drawn(editors: true, size, setting))
    try #require(read.count == edited.count)
    #expect(read.count > 3)
    for (line, (readBand, editedBand)) in zip(read, edited).enumerated() {
      #expect(abs(readBand.lowerBound - editedBand.lowerBound) <= 1, "line \(line)")
      #expect(abs(readBand.upperBound - editedBand.upperBound) <= 1, "line \(line)")
    }
  }

  /// With a Latin family first, the Latin sets the baseline and Japanese falls back: still no line
  /// moves.
  @Test func theEditorsSetLinesAsTextDoesWithALatinFamilyFirst() throws {
    let families = [FontFamily.inter, .notoSansJP]
    let read = try inkBands(drawn(editors: false, .large, writing: mixed, families: families))
    let edited = try inkBands(drawn(editors: true, .large, writing: mixed, families: families))
    try #require(read.count == edited.count)
    #expect(read.count > 3)
    for (line, (readBand, editedBand)) in zip(read, edited).enumerated() {
      #expect(abs(readBand.lowerBound - editedBand.lowerBound) <= 1, "line \(line)")
      #expect(abs(readBand.upperBound - editedBand.upperBound) <= 1, "line \(line)")
    }
  }

  /// A title typed into the body is linked once the typing rests, as on a page opened with it.
  @Test func aTitleTypedIntoTheBodyIsLinkedOnceTypingRests() async throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文と"))
    let hosted = HostedPage(mentioning(edits))
    let body = try #require(editorView(in: hosted))
    body.selectedRange = inBody(3)
    type("夜の机に向かう", into: body)
    hosted.show(mentioning(edits))
    #expect(body.linkedText.isEmpty)
    try await hosted.settle(within: mentionsFound) { !body.linkedText.isEmpty }
    #expect(body.linkedText.map(\.text) == ["夜の机に向かう"])
    let opened = HostedPage(mentioning(edits))
    try await opened.settle { false }
    #expect(hosted.image().pngData() == opened.image().pngData())
  }

  /// Text typed right after a mention is not part of it, and a mention typed into stops being one.
  @Test func typingAtAndIntoAMention() async throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文と夜の机に向かう"))
    let page = HostedPage(mentioning(edits))
    let body = try #require(editorView(in: page))
    try await page.settle(within: mentionsFound) { !body.linkedText.isEmpty }
    body.becomeFirstResponder()
    body.selectedRange = inBody(10)
    type("。", into: body)
    #expect(body.textStorage.attribute(.mention, at: 12, effectiveRange: nil) == nil)
    #expect(body.textStorage.attribute(.underlineStyle, at: 12, effectiveRange: nil) == nil)
    body.selectedRange = inBody(5)
    type("い", into: body)
    page.show(mentioning(edits))
    try await page.settle(within: mentionsFound) { body.linkedText.isEmpty }
    #expect(body.linkedText.isEmpty)
    #expect(body.textStorage.attribute(.underlineStyle, at: 6, effectiveRange: nil) == nil)
  }

  /// A mention and a link are found under a point on their text, and nothing past a line's end.
  @Test func aLinkOrMentionIsFoundUnderAPointOnIt() async throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "小さなパンと\n夜の机に向かう", links: [BodyLink(range: 0..<5, url: bread)]))
    let page = HostedPage(mentioning(edits))
    let body = try #require(editorView(in: page))
    try await page.settle(within: mentionsFound) { body.linkedText.count == 2 }
    #expect(body.link(at: centre(of: 3, in: body)) == bread)
    #expect(body.link(at: centre(of: 7, in: body)) == nil)
    #expect(body.link(at: centre(of: 11, in: body)) == nightDesk.link)
    #expect(body.link(at: centre(of: 0, in: body)) == nil)
    let pastTheEnd = centre(of: 7, in: body).applying(.init(translationX: 120, y: 0))
    #expect(body.link(at: pastTheEnd) == nil)
  }

  /// VoiceOver offers each link and mention as an action; on a mention it opens its writing.
  @Test func voiceOverOpensAMention() async throws {
    var opened: [Writing] = []
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "小さなパンと夜の机に向かう", links: [BodyLink(range: 0..<5, url: bread)]))
    let page = HostedPage(mentioning(edits, open: { opened.append($0) }))
    let body = try #require(editorView(in: page))
    try await page.settle(within: mentionsFound) { body.linkedText.count == 2 }
    let actions = try #require(body.accessibilityCustomActions)
    #expect(actions.map(\.name) == ["「小さなパン」を開く", "「夜の机に向かう」を開く"])
    _ = actions[1].actionHandler?(actions[1])
    #expect(opened.map(\.id) == [nightDesk.id])
  }

  /// VoiceOver's action on a link hands its address to the environment's `openURL`.
  @Test func voiceOverOpensALink() throws {
    var handedOn: [URL] = []
    let page = HostedPage(
      WritingEditor(
        writing: WritingText(
          title: "朝", body: "小さなパン", links: [BodyLink(range: 0..<5, url: bread)])
      ) { _ in }
      .environment(
        \.openURL,
        OpenURLAction {
          handedOn.append($0)
          return .handled
        }))
    let editor = try #require(page.textViews.first)
    let action = try #require(editor.accessibilityCustomActions?.first)
    _ = action.actionHandler?(action)
    #expect(handedOn == [bread])
  }

  /// A tap on a link or mention opens it while the editor has no caret; with a caret anywhere in
  /// it, the text view's own taps take it, and they wait for this one to fail first.
  @Test func aTapOpensALinkOnlyWhileTheEditorHasNoCaret() async throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "小さなパンと夜の机に向かう", links: [BodyLink(range: 0..<5, url: bread)]))
    let page = HostedPage(mentioning(edits))
    let body = try #require(editorView(in: page))
    try await page.settle(within: mentionsFound) { body.linkedText.count == 2 }
    let tap = try #require(
      body.gestureRecognizers?.first { $0.delegate is WritingTextView.Coordinator })
    let coordinator = try #require(tap.delegate as? WritingTextView.Coordinator)
    #expect(coordinator.link(openedAt: centre(of: 3, in: body), in: body) == bread)
    #expect(coordinator.link(openedAt: centre(of: 10, in: body), in: body) == nightDesk.link)
    #expect(coordinator.link(openedAt: centre(of: 7, in: body), in: body) == nil)
    let others = (body.gestureRecognizers ?? []).filter { $0 !== tap }
    #expect(others.contains { coordinator.gestureRecognizer(tap, shouldBeRequiredToFailBy: $0) })
    #expect(
      !others.contains {
        !($0 is UITapGestureRecognizer)
          && coordinator.gestureRecognizer(tap, shouldBeRequiredToFailBy: $0)
      })
    body.becomeFirstResponder()
    page.settle()
    #expect(coordinator.link(openedAt: centre(of: 3, in: body), in: body) == nil)
    #expect(coordinator.link(openedAt: centre(of: 10, in: body), in: body) == nil)
  }

  /// A link on a character stored as more than one UTF-16 unit is found under any part of it.
  @Test(arguments: ["🍞", "🇯🇵", "か\u{3099}"])
  func aLinkOnACharacterOfManyUnitsIsFoundUnderAnyPartOfIt(character: String) throws {
    let length = (character as NSString).length
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "前\(character)後", links: [BodyLink(range: 1..<1 + length, url: bread)]))
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    let rect = try rect(of: NSRange(location: 3, length: length), in: body)
    for fraction in [0.25, 0.75] {
      let point = CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
      #expect(body.link(at: point) == bread, "at \(fraction)")
    }
  }

  /// A web address pasted over part of a mention leaves the whole mention out, as a page opened
  /// with that link does.
  @Test func pastingAWebAddressOverPartOfAMentionLeavesTheMentionOut() async throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文と夜の机に向かう"))
    let page = HostedPage(mentioning(edits))
    let body = try #require(editorView(in: page))
    try await page.settle(within: mentionsFound) { !body.linkedText.isEmpty }
    body.selectedRange = inBody(3, 2)
    try paste("https://example.com/bread", into: body)
    page.show(mentioning(edits))
    page.settle()
    #expect(body.linkedText.map(\.text) == ["夜の"])
    #expect(body.textStorage.attribute(.mention, at: 9, effectiveRange: nil) == nil)
    #expect(body.textStorage.attribute(.underlineStyle, at: 9, effectiveRange: nil) == nil)
    let opened = HostedPage(mentioning(edits))
    let openedBody = try #require(editorView(in: opened))
    try await opened.settle { false }
    #expect(openedBody.linkedText.map(\.text) == body.linkedText.map(\.text))
  }

  /// A change of the body's setting keeps its mentions, and marks none found in text since changed.
  @Test func aSettingChangeKeepsMentionsFoundInTheText() async throws {
    let edits = Edits(writing: Writing(title: "朝", body: "本文と夜の机に向かう"))
    let page = HostedPage(mentioning(edits))
    let body = try #require(editorView(in: page))
    try await page.settle(within: mentionsFound) { !body.linkedText.isEmpty }
    let larger = try #require(BodySetting(base: 20, lineHeight: 36, tracking: -50))
    page.show(mentioning(edits, setting: larger))
    try await page.settle(within: mentionsFound) { !body.linkedText.isEmpty }
    #expect(body.linkedText.map(\.text) == ["夜の机に向かう"])
    body.becomeFirstResponder()
    body.selectedRange = inBody(5)
    type("い", into: body)
    page.show(mentioning(edits))
    #expect(body.linkedText.isEmpty)
  }

  /// A web address pasted over selected body text links that text, and the text stays.
  @Test func pastingAWebAddressOverASelectionLinksIt() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.selectedRange = inBody(0, 2)
    try paste("https://example.com/bread", into: body)
    #expect(edits.writing.body == "朝の机\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 0..<2, url: bread)])
    #expect(page.presented == nil)
  }

  /// Text that is not a web address, over a selection or not, is pasted as text: nothing is
  /// linked, and no sheet opens.
  @Test(arguments: [
    (inBody(0, 2), "example.com机\n二行目"),
    (inBody(3), "朝の机example.com\n二行目"),
  ])
  func otherTextIsNotLinked(_ selection: NSRange, _ pasted: String) throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.selectedRange = selection
    try paste("example.com", into: body)
    page.settle()
    #expect(edits.writing.body == pasted)
    #expect(edits.writing.links.isEmpty)
    #expect(page.presented == nil)
  }

  /// The title holds no links: a web address pasted into it is pasted as text, and no sheet opens.
  @Test(arguments: [
    (NSRange(location: 0, length: 1), "https://example.com/bread"),
    (NSRange(location: 1, length: 0), "朝https://example.com/bread"),
  ])
  func aWebAddressPastedIntoTheTitleIsNotLinked(_ selection: NSRange, _ title: String) throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let editor = try focusedEditor(in: page)
    editor.selectedRange = selection
    try paste("https://example.com/bread", into: editor)
    page.settle()
    #expect(page.presented == nil)
    #expect(edits.writing.title == title)
    #expect(edits.writing.body == "朝の机\n二行目")
    #expect(edits.writing.links.isEmpty)
  }

  /// A web address pasted with nothing selected opens the sheet that asks for its title, and
  /// puts nothing in yet.
  @Test func pastingAWebAddressWithNothingSelectedOpensTheSheet() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.selectedRange = inBody(3)
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
    #expect(asked.view.writing.body == body)
    #expect(asked.view.writing.links == links)
    #expect(asked.view.selectedRange == inBody(caret))
    #expect(asked.changes.last?.body == body)
    #expect(asked.changes.last?.links == links)
  }

  @Test func noTitleGivenPutsNothingIn() throws {
    let asked = try AskedForATitle()
    asked.answer(nil)
    #expect(asked.view.writing.body == "朝の机\n二行目")
    #expect(asked.view.writing.links.isEmpty)
    #expect(asked.changes.isEmpty)
  }

  /// Text typed right after a title put in inside another link goes on neither link.
  @Test func typingAfterATitlePutInsideALinkIsNotLinked() throws {
    let asked = try AskedForATitle(links: [BodyLink(range: 1..<5, url: flour)])
    asked.answer("パン")
    #expect(
      asked.view.writing.links == [
        BodyLink(range: 1..<3, url: flour), BodyLink(range: 3..<5, url: bread),
        BodyLink(range: 5..<7, url: flour),
      ])
    asked.view.insertText("x")
    #expect(asked.view.writing.body == "朝の机パンx\n二行目")
    #expect(
      asked.view.writing.links == [
        BodyLink(range: 1..<3, url: flour), BodyLink(range: 3..<5, url: bread),
        BodyLink(range: 6..<8, url: flour),
      ])
  }

  /// Undo after linking a selection takes the link off, and only that.
  @Test func undoAfterLinkingASelectionTakesTheLinkOff() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = inBody(3)
    type("と", into: body)
    page.settle()
    body.selectedRange = inBody(0, 2)
    try paste("https://example.com/bread", into: body)
    page.settle()
    try #require(body.undoManager).undo()
    page.settle()
    #expect(edits.writing.body == "朝の机と\n二行目")
    #expect(edits.writing.links.isEmpty)
  }

  /// Text typed over a selection goes on a link only when both sides of the selection are on it:
  /// typed over a link's end or all of it, it is neither linked nor drawn as a link.
  @Test(arguments: [
    (inBody(2, 2), [BodyLink(range: 0..<2, url: flour)], 4),
    (inBody(0, 3), [], 2),
  ])
  func typingOverALinksEdgeIsNotLinked(_ selection: NSRange, _ after: [BodyLink], _ typed: Int)
    throws
  {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "粉の店へ\n二行目", links: [BodyLink(range: 0..<3, url: flour)]))
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = selection
    type("と", into: body)
    #expect(edits.writing.links == after)
    #expect(body.attributedText.attribute(.underlineStyle, at: typed, effectiveRange: nil) == nil)
  }

  /// Text typed over a selection just linked replaces the link.
  @Test func typingOverASelectionJustLinkedIsNotLinked() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = inBody(0, 2)
    try paste("https://example.com/bread", into: body)
    type("夜", into: body)
    #expect(edits.writing.body == "夜机\n二行目")
    #expect(edits.writing.links.isEmpty)
    #expect(body.attributedText.attribute(.underlineStyle, at: 2, effectiveRange: nil) == nil)
  }

  /// A paste or drop lands where the system says, which need not be the selection; it hands back
  /// the range the text now covers.
  @Test func aPasteLandsWhereTheSystemSays() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.selectedRange = inBody(5)
    let linked = try pasted("https://example.com/bread", into: body, at: inBody(0, 2))
    #expect(linked == inBody(0, 2))
    #expect(edits.writing.links == [BodyLink(range: 0..<2, url: bread)])
    let text = try pasted("夕方", into: body, at: inBody(3))
    #expect(text == inBody(3, 2))
    #expect(edits.writing.body == "朝の机夕方\n二行目")
  }

  /// Text dragged with its links within the body keeps them where it lands.
  @Test func textDraggedWithALinkKeepsIt() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    let dragged = NSMutableAttributedString(string: "粉の店")
    dragged.addAttributes(.bodyLink(flour), range: NSRange(location: 1, length: 2))
    _ = try pasted(dragged, into: body, at: inBody(3))
    #expect(edits.writing.body == "朝の机粉の店\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 4..<6, url: flour)])
  }

  /// A web address with space around it links the selection.
  @Test func aWebAddressWithSpaceAroundItLinksTheSelection() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.selectedRange = inBody(0, 2)
    try paste("  https://example.com/bread\n", into: body)
    #expect(edits.writing.body == "朝の机\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 0..<2, url: bread)])
  }

  /// A link is drawn under a line but is no link the text view itself opens on a tap, which would
  /// open it while typing.
  @Test func aLinkWhileEditingIsNotOpenedOnATap() throws {
    let edits = Edits(writing: linked)
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    #expect(body.writing.links == [BodyLink(range: 3..<8, url: bread)])
    var opened = 0
    body.attributedText.enumerateAttribute(
      .link, in: NSRange(location: 0, length: body.attributedText.length)
    ) { value, _, _ in if value != nil { opened += 1 } }
    #expect(opened == 0)
  }

  /// Links changed from elsewhere while editing are drawn in the editor.
  @Test func linksChangedFromElsewhereAreShown() throws {
    let edits = Edits()
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    edits.writing.links = [BodyLink(range: 0..<2, url: bread)]
    page.show(screen(edits: edits))
    #expect(body.writing.links == [BodyLink(range: 0..<2, url: bread)])
  }

  /// Links are kept when text still being composed is kept as the page closes.
  @Test func linksAreKeptWithTextBeingComposedWhenThePageCloses() async throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "朝の机\n二行目", links: [BodyLink(range: 0..<2, url: bread)]))
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = NSRange(location: (body.text as NSString).length, length: 0)
    body.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0))
    page.show(Color.clear)
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
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = inBody(3)
    type("と", into: body)
    #expect(edits.writing.links == [BodyLink(range: 0..<3, url: flour)])
    body.selectedRange = inBody(1)
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
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = inBody(caret)
    type("と", into: body)
    #expect(edits.writing.links == after)
    #expect(
      body.attributedText.attribute(.underlineStyle, at: caret + 2, effectiveRange: nil) == nil)
  }

  /// A combining mark typed at a link's end joins the link's last character, so the link takes in
  /// the whole character rather than ending inside it.
  @Test func aMarkJoiningALinksLastCharacterStaysInTheLink() throws {
    let edits = Edits(
      writing: Writing(
        title: "朝", body: "cafe\n二行目", links: [BodyLink(range: 0..<4, url: flour)]))
    let page = HostedPage(screen(edits: edits))
    let body = try #require(editorView(in: page))
    body.becomeFirstResponder()
    page.settle()
    body.selectedRange = inBody(4)
    type("\u{0301}", into: body)
    #expect(edits.writing.body == "cafe\u{0301}\n二行目")
    #expect(edits.writing.links == [BodyLink(range: 0..<5, url: flour)])
  }

  @Test func theLinkSheet() {
    assertSnapshot(
      of: LinkTitleSheet(url: bread) { _ in }
        .frame(width: 402, height: 437)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  /// An untitled writing shows the title's placeholder on the title's line.
  @Test func anUntitledWriting() {
    assertSnapshot(
      of: screen(edits: Edits(writing: Writing(title: "", body: "本文")))
        .frame(width: 402, height: 874)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }
}

private let sampled = Writing(title: "間合いの調整", body: Writing.sampleBody)
private let mixed = Writing(title: "Morning Pages と朝の光", body: Writing.mixedBody)

nonisolated private let bread = URL(string: "https://example.com/bread") ?? URL(filePath: "/")
nonisolated private let flour = URL(string: "https://example.com/flour") ?? URL(filePath: "/")

/// The sample page with its first line's 「小さなパン」 linked.
private let linked = Writing(
  title: "間合いの調整", body: Writing.sampleBody, links: [BodyLink(range: 3..<8, url: bread)])

/// Hands `text` to `view`'s paste delegate for `range`, as the system does for a paste or a drop,
/// and returns the range the delegate says the text now covers.
@MainActor
private func pasted(_ text: String, into view: UITextView, at range: NSRange) throws -> NSRange {
  try pasted(NSAttributedString(string: text), into: view, at: range)
}

@MainActor
private func pasted(_ text: NSAttributedString, into view: UITextView, at range: NSRange) throws
  -> NSRange
{
  let begin = view.beginningOfDocument
  let from = try #require(view.position(from: begin, offset: range.location))
  let to = try #require(view.position(from: begin, offset: NSMaxRange(range)))
  let target = try #require(view.textRange(from: from, to: to))
  let delegate = try #require(view.pasteDelegate)
  let covered = try #require(
    delegate.textPasteConfigurationSupporting?(view, performPasteOf: text, to: target))
  return NSRange(
    location: view.offset(from: begin, to: covered.start),
    length: view.offset(from: covered.start, to: covered.end))
}

/// Pastes `text` into `view` as the system's paste does once it has what was copied: through the
/// view's paste delegate, or straight in where it has none.
@MainActor
private func paste(_ text: String, into view: UITextView) throws {
  let range = try #require(view.selectedTextRange)
  guard let delegate = view.pasteDelegate else {
    view.replace(range, withText: text)
    return
  }
  _ = delegate.textPasteConfigurationSupporting?(
    view, performPasteOf: NSAttributedString(string: text), to: range)
}

/// An editor holding the title 「朝」 and the body 「朝の机\n二行目」 that was pasted a web address
/// with the caret after 「朝の机」: the request the paste made, and the changes the editor has
/// reported since.
@MainActor
private final class AskedForATitle {
  let view = PlaceholderTextView(usingTextLayoutManager: true)
  private(set) var changes: [WritingText] = []
  private var coordinator: WritingTextView.Coordinator?
  private var asked: TitleRequest?

  init(links: [BodyLink] = []) throws {
    let coordinator = WritingTextView.Coordinator(changed: { _ in }, askTitle: { _ in })
    coordinator.changed = { [weak self] in self?.changes.append($0) }
    self.coordinator = coordinator
    view.delegate = coordinator
    view.lines = EditorLines(
      scale: .standard, families: FontStack.standard.families(), pixel: 1.0 / 3)
    let writing = WritingText(title: "朝", body: "朝の机\n二行目", links: links)
    let text = NSMutableAttributedString(string: writing.text)
    for link in writing.textLinks {
      text.addAttributes(.bodyLink(link.url), range: NSRange(link.range))
    }
    view.attributedText = text
    view.selectedRange = inBody(3)
    coordinator.paste(bread, into: view) { self.asked = $0 }
    try #require(asked != nil)
  }

  func answer(_ title: String?) {
    asked?.answer(title)
  }
}

/// `writing`'s title and body at the top of a 402 × 874 window, in the editor or as text set by
/// `textStyle`.
@MainActor
private func drawn(
  editors: Bool, _ size: DynamicTypeSize, _ setting: BodySetting = .standard,
  writing: Writing = sampled, families: [FontFamily] = FontStack.standard.families()
) -> UIImage {
  HostedPage(
    ScrollView {
      TitleAndBody(writing: writing, editors: editors)
    }
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.bodySetting, setting)
    .environment(\.fontFamilies, families)
    .environment(\.colorScheme, .light)
  ).image()
}

/// A writing's title and body on the type area of a 402-wide screen, as the page sets them.
private struct TitleAndBody: View {
  let writing: Writing
  let editors: Bool
  @EnvironmentTypeScale private var scale

  var body: some View {
    let area = scale.typeArea(width: 402)
    // Apart by the page's own space, so the title's line and the body's first are not one band.
    VStack(alignment: .leading, spacing: scale.space(.m)) {
      if editors {
        WritingEditor(
          writing: WritingText(title: writing.title, body: writing.body, links: [])
        ) { _ in }
      } else {
        Text(verbatim: writing.title).textStyle(.heading)
        Text(body: writing.body).textStyle(.body)
      }
      // A line after them, where what follows on the page starts.
      Rectangle().fill(.black).frame(height: 1)
    }
    .frame(width: area.lineLength, alignment: .leading)
    .padding(.horizontal, area.margin)
    // Where the page's back mark leaves them, so their lines fall on the same pixels.
    .padding(.top, max(17 * scale.scale, TextButtonStyle.minimumSide) + scale.space(.l))
  }
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

private func screen(edits: Edits, setting: BodySetting = .standard) -> some View {
  WritingScreen(
    writing: edits.writing, others: [], open: { _ in }, edit: { edits.writing.apply($0) },
    photos: [],
    setting: .constant(setting),
    typesetting: .constant(false),
    takingPhoto: .constant(false),
    camera: .standIn(taking: nil),
    photoTaken: { _ in })
}

/// How long the mention tests wait for mentions to be found: the main actor they are found on is
/// shared with the snapshot tests running beside them, which can hold it for tens of seconds.
private let mentionsFound: TimeInterval = 60

/// A writing whose title the bodies in the mention tests name.
private let nightDesk = Writing(
  id: UUID(sample: 4), title: "夜の机に向かう", body: "", updated: Date(timeIntervalSince1970: 0))

/// The edited writing's page, with `nightDesk` among the others.
private func mentioning(
  _ edits: Edits, setting: BodySetting = .standard, open: @escaping (Writing) -> Void = { _ in }
) -> some View {
  WritingScreen(
    writing: edits.writing, others: [nightDesk], open: open, edit: { edits.writing.apply($0) },
    photos: [], setting: .constant(setting), typesetting: .constant(false),
    takingPhoto: .constant(false), camera: .standIn(taking: nil), photoTaken: { _ in })
}

/// Where `range` of `view`'s text is drawn, in its own coordinates.
@MainActor
private func rect(of range: NSRange, in view: UITextView) throws -> CGRect {
  let start = try #require(view.position(from: view.beginningOfDocument, offset: range.location))
  let end = try #require(view.position(from: start, offset: range.length))
  return view.firstRect(for: try #require(view.textRange(from: start, to: end)))
}

/// The centre of the character at `offset` in `view`, in its own coordinates.
@MainActor
private func centre(of offset: Int, in view: UITextView) -> CGPoint {
  guard let start = view.position(from: view.beginningOfDocument, offset: offset),
    let end = view.position(from: start, offset: 1),
    let range = view.textRange(from: start, to: end)
  else { preconditionFailure("No character at \(offset).") }
  let rect = view.firstRect(for: range)
  return CGPoint(x: rect.midX, y: rect.midY)
}

extension Writing {
  fileprivate mutating func apply(_ change: (inout Writing) -> Void) {
    change(&self)
  }
}

/// The page's editor, ready for typing as the keyboard types.
@MainActor
private func focusedEditor(in page: HostedPage) throws -> PlaceholderTextView {
  let view = try #require(editorView(in: page))
  view.becomeFirstResponder()
  page.settle()
  return view
}

/// The place `location` UTF-16 units into the body, `length` long, in the editor of a writing
/// titled 「朝」.
nonisolated private func inBody(_ location: Int, _ length: Int = 0) -> NSRange {
  NSRange(location: 2 + location, length: length)
}

/// Whether the character at `location` in `view` is drawn as the title or the body, by its font's
/// size.
@MainActor
private func role(at location: Int, in view: UITextView) throws -> TextRole {
  let font = try #require(
    view.attributedText.attribute(.font, at: location, effectiveRange: nil) as? UIFont)
  return try role(ofSize: font.pointSize)
}

private func role(ofSize size: CGFloat) throws -> TextRole {
  let scale = TypeScale.standard
  switch size {
  case scale.size(.heading): return .heading
  case scale.size(.body): return .body
  default: throw Unexpected.size(size)
  }
}

private enum Unexpected: Error {
  case size(CGFloat)
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

/// Whether text typed at `view`'s caret goes in as the title or the body, by its font's size.
@MainActor
private func typedRole(in view: UITextView) throws -> TextRole {
  let font = try #require(view.typingAttributes[.font] as? UIFont)
  return try role(ofSize: font.pointSize)
}

/// What `titleCutOff` heard last.
@MainActor
private final class CutOff {
  var last: CGFloat?
}

/// How many pixels in `rect` (in points) are drawn in ink, the text's own colour: darker than the
/// tertiary colour.
private func inkPixels(in image: UIImage, within rect: CGRect) throws -> Int {
  let (pixels, width, height) = try greyPixels(image)
  let scale = image.scale
  let columns = max(0, Int(rect.minX * scale))..<min(width, Int(rect.maxX * scale))
  let rows = max(0, Int(rect.minY * scale))..<min(height, Int(rect.maxY * scale))
  return rows.reduce(0) { count, row in
    count + columns.count { pixels[row * width + $0] < 128 }
  }
}

/// The page's one editor.
@MainActor
private func editorView(in page: HostedPage) -> PlaceholderTextView? {
  page.textViews.first as? PlaceholderTextView
}

@MainActor
struct EditorViewTests {
  /// On a body many screens long, the text view is a window tall and sits over the part of the
  /// page shown, wherever the page is scrolled to.
  @Test func theTextViewCoversThePartOfAPageShown() throws {
    let page = HostedPage(screen(edits: Edits(writing: long)))
    let editor = try #require(editorView(in: page))
    let container = try #require(editor.editor)
    let scroll = try #require(page.scrollViews.first { !($0 is UITextView) })
    let window = try #require(editor.window)
    #expect(container.bounds.height > window.bounds.height * 3)
    for y in [0, container.bounds.height / 2, scroll.contentSize.height - scroll.bounds.height] {
      scroll.contentOffset.y = y
      page.settle()
      #expect(editor.bounds.height == window.bounds.height)
      let shown = editor.convert(editor.bounds, to: nil)
      let screen = window.bounds.intersection(container.convert(container.bounds, to: nil))
      #expect(shown.contains(screen.insetBy(dx: 1, dy: 1)))
    }
  }

  /// The text view's own scroll to a place out of sight, as to keep the caret in sight, scrolls
  /// the page to it: the text view doesn't scroll on its own.
  @Test func aScrollToTheCaretScrollsThePage() throws {
    let page = HostedPage(screen(edits: Edits(writing: long)))
    let editor = try focusedEditor(in: page)
    let scroll = try #require(page.scrollViews.first { !($0 is UITextView) })
    let window = try #require(editor.window)
    scroll.contentOffset.y = 0
    page.settle()
    editor.selectedRange = NSRange(location: (editor.text as NSString).length / 2, length: 0)
    editor.scrollRangeToVisible(editor.selectedRange)
    page.settle()
    #expect(scroll.contentOffset.y > 0)
    let caret = try #require(editor.selectedTextRange)
    let shown = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: nil)
    #expect(shown.contains(editor.convert(editor.caretRect(for: caret.start), to: nil)))
  }
}

extension EditorViewTests {
  /// A line break typed on the last line shown, above the bottom row, moves the page by no more
  /// than to keep the caret in sight; the same for each line typed after it.
  @Test func aLineBreakOnTheLastLineShownKeepsThePageInPlace() throws {
    let page = HostedPage(screen(edits: Edits(writing: long)))
    let editor = try focusedEditor(in: page)
    let lineHeight = try #require(editor.lines).scale.lineHeight(.body)
    let scroll = try #require(page.scrollViews.first { !($0 is UITextView) })
    scroll.contentOffset.y = 2_000
    page.settle()
    let shown = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: nil)
    // The caret at the start of the last whole line shown.
    let point = editor.convert(CGPoint(x: 1, y: shown.maxY - 40), from: nil)
    let position = try #require(editor.closestPosition(to: point))
    editor.selectedTextRange = editor.textRange(from: position, to: position)
    page.settle()
    for _ in 0..<3 {
      let before = scroll.contentOffset.y
      type("\n", into: editor)
      page.settle()
      // A line or a few, to bring the new line out from under the bottom row; never a jump.
      #expect(abs(scroll.contentOffset.y - before) <= lineHeight * 4)
      let caret = try #require(editor.selectedTextRange)
      #expect(shown.contains(editor.convert(editor.caretRect(for: caret.start), to: nil)))
    }
  }

  /// The arrow keys move the caret to the end of a long writing, and the page follows it there.
  @Test func movingTheCaretToTheEndScrollsThePageThere() throws {
    let page = HostedPage(screen(edits: Edits(writing: long)))
    let editor = try focusedEditor(in: page)
    let scroll = try #require(page.scrollViews.first { !($0 is UITextView) })
    scroll.contentOffset.y = 0
    page.settle()
    editor.selectedTextRange = editor.textRange(
      from: editor.endOfDocument, to: editor.endOfDocument)
    page.settle()
    let shown = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: nil)
    let caret = try #require(editor.selectedTextRange)
    #expect(shown.contains(editor.convert(editor.caretRect(for: caret.start), to: nil)))
  }
}

@MainActor
struct EditorHeightTests {
  /// Wherever the page is scrolled on a body of 100,000 characters, text is drawn on screen, and
  /// at the page's end, the body's last line is.
  @Test func textIsShownAllTheWayToTheEnd() async throws {
    let page = HostedPage(
      screen(edits: Edits(writing: Writing(title: "朝", body: hundredThousand))))
    let editor = try #require(editorView(in: page))
    let scroll = try #require(page.scrollViews.first { !($0 is UITextView) })
    func bottom() -> CGFloat {
      scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
    }
    for part in [0.25, 0.5, 0.75] {
      scroll.contentOffset.y = bottom() * part
      page.settle()
      // A point on the text a third of the way down the screen falls on a line drawn there.
      let point = editor.convert(
        CGPoint(x: 60, y: scroll.bounds.height / 3), from: scroll.superview)
      let position = try #require(editor.closestPosition(to: point))
      #expect(abs(editor.caretRect(for: position).midY - point.y) < 40, "at \(part)")
    }
    // Scrolled to the end, as often as TextKit's height for the text changes on the way.
    let shown = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: nil)
    func lastLineShown() -> Bool {
      shown.contains(editor.convert(editor.caretRect(for: editor.endOfDocument), to: nil))
    }
    // Scrolled to the end as the editor's height follows TextKit's, which changes as TextKit
    // lays out the lines it had estimated.
    // As long as a full run's snapshot suites can hold the main actor.
    try await page.settle(within: 60) {
      scroll.contentOffset.y = bottom()
      page.settle()
      return lastLineShown()
    }
    #expect(lastLineShown())
  }
}

private let hundredThousand: String = {
  let paragraph = Writing.sampleBody + "\n" + Writing.sampleMention + "\n"
  return String(String(repeating: paragraph, count: 100_000 / paragraph.count + 1).prefix(100_000))
}()

/// A writing whose body is many screens long.
private let long = Writing(
  title: "朝", body: Array(repeating: Writing.sampleBody, count: 12).joined(separator: "\n"))
