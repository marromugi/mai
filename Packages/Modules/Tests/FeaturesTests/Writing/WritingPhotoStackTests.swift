import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

struct WritingPhotoStackTests {
  @Test func aPhotoAfterTheBody() {
    assertPage([.portrait], .light)
  }

  @Test func aPhotoAfterTheBodyInDarkMode() {
    assertPage([.portrait], .dark)
  }

  /// A landscape photo fits the stack's width, a portrait one its height.
  @Test func aLandscapePhoto() {
    assertPage([.landscape], .light)
  }

  /// Photos taken one after another pile up, the newest (the dusk) on top.
  @Test func photosInARow() {
    assertPage([.portrait, .landscape, .dusk], .light)
  }

  @Test func photosInARowInDarkMode() {
    assertPage([.portrait, .landscape, .dusk], .dark)
  }

  @Test func photosInARowAtTheLargestSize() {
    assertPage([.portrait, .landscape, .dusk], .light, .accessibility5)
  }

  @Test func voiceOverReadsTheCount() {
    #expect(PhotoStack.label(count: 1) == "写真")
    #expect(PhotoStack.label(count: 5) == "写真 5枚")
  }

  /// Under the newest three, older photos are not drawn.
  @Test func theStackDrawsTheNewestThree() throws {
    let older: [UIImage] = [.landscape, .landscape]
    let newest: [UIImage] = [.portrait, .landscape, .dusk]
    let all = try #require(pageImage(older + newest)?.pngData())
    #expect(all == pageImage(newest)?.pngData())
  }

  /// The photos handed to the writing's view reach its page.
  @Test func theViewShowsItsPhotos() throws {
    func contentHeight(_ photos: [UIImage]) throws -> CGFloat {
      let page = HostedPage(
        WritingView(
          writing: Writing(title: "間合いの調整", body: Writing.sampleBody), others: [], open: { _ in },
          photos: photos,
          setting: .constant(.standard), camera: .standIn(taking: nil), photoTaken: { _ in }))
      return try #require(page.scrollViews.first).contentSize.height
    }
    #expect(try contentHeight([.portrait]) > contentHeight([]))
  }
}

extension UIImage {
  /// A new photo 3 wide by 4 tall: a sky over a hill, with a sun at the top leading corner. Each is
  /// its own image, as each photo the camera takes is.
  fileprivate static var portrait: UIImage {
    scene(CGSize(width: 300, height: 400), sky: .systemTeal)
  }

  /// A new photo 3 wide by 4 tall under a dusk sky, told apart from `portrait`.
  fileprivate static var dusk: UIImage {
    scene(CGSize(width: 300, height: 400), sky: .systemIndigo)
  }

  /// A new photo 4 wide by 3 tall, in other colours.
  fileprivate static var landscape: UIImage {
    scene(CGSize(width: 400, height: 300), sky: .systemOrange)
  }

  private static func scene(_ size: CGSize, sky: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      sky.setFill()
      context.fill(CGRect(origin: .zero, size: size))
      UIColor.systemGreen.setFill()
      context.fill(CGRect(x: 0, y: size.height * 0.6, width: size.width, height: size.height * 0.4))
      UIColor.systemYellow.setFill()
      context.cgContext.fillEllipse(
        in: CGRect(x: size.width * 0.1, y: size.height * 0.1, width: 60, height: 60))
    }
  }
}

private func page(
  _ photos: [UIImage], _ colorScheme: ColorScheme, _ size: DynamicTypeSize
) -> some View {
  WritingPage(
    writing: Writing(title: "間合いの調整", body: Writing.sampleBody), photos: photos, width: 402,
    back: {}, titleCutOff: { _ in }
  )
  .fixedSize(horizontal: false, vertical: true)
  .frame(width: 402)
  .background(Color(.systemBackground))
  .dynamicTypeSize(size)
  .environment(\.colorScheme, colorScheme)
}

private func pageImage(_ photos: [UIImage]) -> UIImage? {
  let renderer = ImageRenderer(content: page(photos, .light, .large))
  renderer.scale = 1
  return renderer.uiImage
}

/// The whole page, 402 wide, as tall as its content.
private func assertPage(
  _ photos: [UIImage],
  _ colorScheme: ColorScheme,
  _ size: DynamicTypeSize = .large,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  assertSnapshot(
    of: page(photos, colorScheme, size),
    as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
    fileID: fileID,
    file: file,
    testName: testName,
    line: line,
    column: column)
}
