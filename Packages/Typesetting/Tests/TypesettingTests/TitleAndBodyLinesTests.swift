import CoreGraphics
import Testing
import Typesetting

struct TitleAndBodyLinesTests {
  /// (title offset, body offset, title height)
  static let cases: [(CGFloat, CGFloat, CGFloat)] = [
    (2.3, 1.1, 21.6),
    (1.1, 2.3, 21.6),
    // A title line closer than its font, set above where the text view puts it.
    (-3.6, 0.4, 21.6),
    // A title wrapped to two lines.
    (2.3, 1.1, 43.2),
  ]

  /// The body starts on a whole pixel of the text view, and lands at its offset on the page.
  @Test(arguments: cases)
  func theBodyStartsOnAPixelOfTheView(_ title: CGFloat, _ body: CGFloat, _ height: CGFloat) {
    let lines = TitleAndBodyLines(titleOffset: title, bodyOffset: body, gap: 16, pixel: pixel)
    #expect(isWhole(lines.excess))
    #expect(lines.excess >= 0)
    #expect(abs(lines.viewOffset + lines.excess - body) < 1e-9)
    let inView = lines.titleInset + height + lines.spacing(belowTitleOf: height)
    #expect(isWhole(inView))
    // Where a view placed `gap` below the title starts, on the pixel after it, moved by its offset.
    let placed = ((height + 16) / pixel).rounded(.up) * pixel + body
    #expect(abs(lines.viewOffset + inView - placed) < 1e-9)
  }

  /// The title moves by whole pixels in the view, and lands within half a pixel of its offset.
  @Test(arguments: cases)
  func theTitleLandsWithinHalfAPixel(_ title: CGFloat, _ body: CGFloat, _ height: CGFloat) {
    let lines = TitleAndBodyLines(titleOffset: title, bodyOffset: body, gap: 16, pixel: pixel)
    #expect(isWhole(lines.titleInset))
    #expect(lines.titleInset >= 0)
    #expect(abs(lines.viewOffset + lines.titleInset - title) <= pixel / 2 + 1e-9)
  }
}

private let pixel: CGFloat = 1.0 / 3

private func isWhole(_ points: CGFloat) -> Bool {
  abs((points / pixel).rounded() - points / pixel) < 1e-6
}
