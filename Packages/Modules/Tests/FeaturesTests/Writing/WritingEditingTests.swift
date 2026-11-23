import SnapshotTesting
import SwiftUI
import Testing
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

  /// The title and body are drawn where they are when read, so entering the mode moves no text.
  @Test func editingMovesNoText() throws {
    let read = try #require(drawn(editing: false, .large).pngData())
    let edited = try #require(drawn(editing: true, .large).pngData())
    #expect(read == edited)
  }

  /// Where the line height is not a whole number of pixels, SwiftUI and TextKit may round a line
  /// to neighbouring pixels; no line is further off than that, and none drifts.
  @Test func editingMovesNoLinePastAPixelAtTheLargestSize() throws {
    let read = try inkBands(drawn(editing: false, .accessibility5))
    let edited = try inkBands(drawn(editing: true, .accessibility5))
    try #require(read.count == edited.count)
    #expect(read.count > 3)
    for (line, (readBand, editedBand)) in zip(read, edited).enumerated() {
      #expect(abs(readBand.lowerBound - editedBand.lowerBound) <= 1, "line \(line)")
      #expect(abs(readBand.upperBound - editedBand.upperBound) <= 1, "line \(line)")
    }
  }

  @Test func editingMode() {
    assertSnapshot(
      of: screen(editing: true, edits: Edits(writing: sampled))
        .frame(width: 402, height: 874)
        .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
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

/// The sample page at the top of a 402 × 874 window, read or being edited.
@MainActor
private func drawn(editing: Bool, _ size: DynamicTypeSize) -> UIImage {
  HostedPage(
    ScrollView {
      WritingPage(
        writing: sampled, editing: editing, photos: [], width: 402, back: {},
        titleCutOff: { _ in })
    }
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.colorScheme, .light)
  ).image()
}

/// The runs of pixel rows in `image` that hold any dark pixel, top to bottom.
private func inkBands(_ image: UIImage) throws -> [ClosedRange<Int>] {
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

private func screen(editing: Bool, edits: Edits) -> some View {
  WritingScreen(
    writing: edits.writing, others: [], open: { _ in }, edit: { edits.writing.apply($0) },
    photos: [],
    setting: .constant(.standard),
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

/// The text view holding the body, found by its text.
@MainActor
private func bodyEditor(in page: HostedPage) -> UITextView? {
  page.textViews.first { $0.text.contains("\n") || $0.text == "本文" }
}
