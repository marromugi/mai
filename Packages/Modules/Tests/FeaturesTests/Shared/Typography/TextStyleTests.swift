import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

struct TextStyleTests {
  @Test(arguments: [
    (TextRole.display, 44.0),
    (.heading, 32),
    (.title, 24),
    (.body, 28),
    (.meta, 20),
    (.caption, 20),
  ])
  func everyLineBoxIsTheLineHeight(_ role: TextRole, _ lineHeight: CGFloat) {
    #expect(abs(height(of: Text("あ").textStyle(role)) - lineHeight) < 0.01)
    #expect(abs(height(of: Text("あ\nHg\n永").textStyle(role)) - 3 * lineHeight) < 0.01)
  }

  /// Scaled line boxes land on device pixels, so they are checked to within half a point.
  @Test(arguments: [
    (TextRole.display, 44.0),
    (.heading, 32),
    (.title, 24),
    (.body, 28),
    (.meta, 20),
    (.caption, 20),
  ])
  func lineBoxesScaleWithDynamicType(_ role: TextRole, _ lineHeight: CGFloat) {
    let one = Text("あ").textStyle(role).dynamicTypeSize(.accessibility5)
    let three = Text("あ\nHg\n永").textStyle(role).dynamicTypeSize(.accessibility5)
    #expect(abs(height(of: one) - lineHeight * 53 / 17) < 0.5)
    #expect(abs(height(of: three) - 3 * lineHeight * 53 / 17) < 0.5)
  }

  @Test(arguments: TextRole.allCases)
  func emBoxSitsInTheMiddleOfTheLineBox(_ role: TextRole) throws {
    let ink = try #require(inkRows(of: Text("■").textStyle(role)))
    let below = TypeScale.standard.lineHeight(role) - ink.bottom
    #expect(abs(ink.top - below) <= 0.5, "\(ink.top) above, \(below) below")
  }

  @Test func baselinesAlignAcrossRoles() throws {
    for role in TextRole.allCases where role != .body {
      let row = HStack(alignment: .firstTextBaseline, spacing: 0) {
        Text("H").textStyle(.body)
        Text("H").textStyle(role).foregroundStyle(.red)
      }
      let body = try #require(inkRows(of: row, red: false))
      let other = try #require(inkRows(of: row, red: true))
      #expect(abs(body.bottom - other.bottom) <= 0.5, "\(role): \(body) \(other)")
    }
  }

  @Test func lastBaselinesAlignAcrossRoles() throws {
    for role in TextRole.allCases where role != .body {
      let row = HStack(alignment: .lastTextBaseline, spacing: 0) {
        Text("H\nH\nH").textStyle(.body)
        Text("H").textStyle(role).foregroundStyle(.red)
      }
      let body = try #require(inkRows(of: row, red: false))
      let other = try #require(inkRows(of: row, red: true))
      #expect(abs(body.bottom - other.bottom) <= 0.5, "\(role): \(body) \(other)")
    }
  }

  /// Three lines of body characters fill three lines exactly, and one more character takes a fourth.
  @Test(arguments: [(16, -50), (16, 0), (16, 100), (16, 200), (20, 200), (12, -50)])
  func trackedBodyBreaksWhereTheTypeAreaSays(_ base: Int, _ tracking: Int) throws {
    let body = try #require(BodySetting(base: base, lineHeight: 28, tracking: tracking))
    let scale = TypeScale(factor: 1, body: body)
    let area = scale.typeArea(width: 402)
    func lines(_ count: Int) -> CGFloat {
      let text = Text(body: String(repeating: "あ", count: count))
        .textStyle(.body)
        .frame(width: area.lineLength, alignment: .leading)
        .environment(\.bodySetting, body)
      return height(of: text) / scale.lineHeight(.body)
    }
    #expect(abs(lines(area.columns * 3) - 3) < 0.01, "\(area.columns) columns")
    #expect(abs(lines(area.columns * 3 + 1) - 4) < 0.01, "\(area.columns) columns")
  }

  /// Each line is full: n - 1 あ and ネ, then `first` and n - 1 あ. Where `first` can't start a line,
  /// ネ goes down with it and the text takes a third line.
  @Test(arguments: [(16, 0), (18, 100), (12, -50), (24, 200)])
  func bodyLinesNeverStartWithWhatKinsokuForbids(_ base: Int, _ tracking: Int) throws {
    let body = try #require(BodySetting(base: base, lineHeight: 28, tracking: tracking))
    let scale = TypeScale(factor: 1, body: body)
    let n = scale.typeArea(width: 402).columns
    let a = { String(repeating: "あ", count: $0) }
    func lines(_ string: String) -> CGFloat {
      let text = Text(body: string)
        .textStyle(.body)
        .frame(width: scale.typeArea(width: 402).lineLength, alignment: .leading)
        .environment(\.bodySetting, body)
      return height(of: text) / scale.lineHeight(.body)
    }
    #expect(abs(lines(a(n - 1) + "ネあ" + a(n - 1)) - 2) < 0.01, "\(n) columns")
    for first in ["ー", "ッ", "ょ", "ァ", "ゝ", "。", "、", "）", "」", "・", "々", "！", "？"] {
      #expect(abs(lines(a(n - 1) + "ネ" + first + a(n - 1)) - 3) < 0.01, "「\(first)」 starts a line")
    }
    // Brackets set half wide would fit n + 1 characters on one line.
    #expect(abs(lines("（" + a(n - 1) + "）") - 2) < 0.01, "brackets lose their full width")
  }

  @Test func bodySettingSetsTheBodyLineHeightAndTrackingAlone() throws {
    let body = try #require(BodySetting(base: 16, lineHeight: 40, tracking: 200))
    func width(_ role: TextRole, _ setting: BodySetting) -> CGFloat {
      UIHostingController(
        rootView: Text("ああああ").textStyle(role).environment(\.bodySetting, setting).fixedSize()
      ).sizeThatFits(in: CGSize(width: 2000, height: 2000)).width
    }
    #expect(
      abs(height(of: Text("あ").textStyle(.body).environment(\.bodySetting, body)) - 40) < 0.01)
    #expect(width(.body, body) > width(.body, .standard) + 3 * 2.8)
    for role in TextRole.allCases where role != .body {
      let text = Text("あ").textStyle(role)
      #expect(
        abs(height(of: text.environment(\.bodySetting, body)) - height(of: text)) < 0.01,
        "\(role)")
      #expect(abs(width(role, body) - width(role, .standard)) < 0.01, "\(role)")
    }
  }

  @Test func specimen() {
    assertSnapshot(of: specimenView, as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  @Test func specimenAtTheLargestSize() {
    assertSnapshot(
      of: specimenView.dynamicTypeSize(.accessibility5),
      as: .image(precision: 1, perceptualPrecision: 0.995))
  }
}

/// Each role set over two line boxes, shaded in turn, across the type area of a 402-wide screen.
private var specimenView: some View {
  SpecimenPage().frame(width: 402).fixedSize().background(Color(.systemBackground))
}

private struct SpecimenPage: View {
  @EnvironmentTypeScale private var scale

  var body: some View {
    let area = scale.typeArea(width: 402)
    VStack(alignment: .leading, spacing: scale.space(.s)) {
      ForEach(TextRole.allCases, id: \.self) { role in
        let sample = "永い調和の\(role)と、次の行に送られる組み見本の文。かなと漢字に English と 1920 を混ぜる。"
        (role == .body ? Text(body: sample) : Text(sample))
          .textStyle(role)
          .frame(width: area.lineLength, alignment: .leading)
          .background(alignment: .top) {
            VStack(spacing: 0) {
              Color.blue.opacity(0.12).frame(height: scale.lineHeight(role))
              Color.blue.opacity(0.04).frame(height: scale.lineHeight(role))
            }
          }
      }
    }
    .padding(.horizontal, area.margin)
    .padding(.vertical, scale.space(.m))
  }
}

private func height(of view: some View) -> CGFloat {
  UIHostingController(rootView: view.fixedSize())
    .sizeThatFits(in: CGSize(width: 2000, height: 2000)).height
}

/// The first and last rows, in points, that hold black ink (or red ink when `red`).
/// Pixels left transparent past the view's edge are not ink.
private func inkRows(of view: some View, red: Bool = false) -> (top: CGFloat, bottom: CGFloat)? {
  let renderer = ImageRenderer(content: view.fixedSize().background(Color.white))
  let scale = 4
  renderer.scale = CGFloat(scale)
  guard let image = renderer.cgImage else { return nil }
  let width = image.width
  let height = image.height
  var pixels = [UInt8](repeating: 0, count: width * height * 4)
  let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
    guard
      let context = CGContext(
        data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return true
  }
  guard drawn else { return nil }
  func isInk(_ x: Int, _ y: Int) -> Bool {
    let i = (y * width + x) * 4
    let (r, g, alpha) = (pixels[i], pixels[i + 1], pixels[i + 3])
    guard alpha > 200 else { return false }
    return red ? r > 160 && g < 100 : r < 100 && g < 100
  }
  let rows = (0..<height).filter { y in (0..<width).contains { isInk($0, y) } }
  guard let first = rows.first, let last = rows.last else { return nil }
  return (CGFloat(first) / CGFloat(scale), CGFloat(last + 1) / CGFloat(scale))
}
