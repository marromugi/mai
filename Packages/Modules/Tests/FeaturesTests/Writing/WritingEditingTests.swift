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

  /// With a Latin family first, the Latin sets the baseline and Japanese falls back: still no line
  /// moves.
  @Test func editingMovesNoLinePastAPixelWithALatinFamilyFirst() throws {
    let families = [FontFamily.inter, .notoSansJP]
    let read = try inkBands(drawn(editing: false, .large, writing: mixed, families: families))
    let edited = try inkBands(drawn(editing: true, .large, writing: mixed, families: families))
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
private let mixed = Writing(title: "Morning Pages と朝の光", body: Writing.mixedBody)

/// `writing`'s page at the top of a 402 × 874 window, read or being edited.
@MainActor
private func drawn(
  editing: Bool, _ size: DynamicTypeSize, _ setting: BodySetting = .standard,
  writing: Writing = sampled, families: [FontFamily] = FontStack.standard.families()
) -> UIImage {
  HostedPage(
    ScrollView {
      WritingPage(
        writing: writing, editing: editing, photos: [], width: 402, back: {},
        titleCutOff: { _ in })
    }
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.bodySetting, setting)
    .environment(\.fontFamilies, families)
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
