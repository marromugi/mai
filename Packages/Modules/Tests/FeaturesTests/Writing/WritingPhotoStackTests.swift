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
    let all = try #require(pageImage((older + newest).map(PagePhoto.init))?.pngData())
    #expect(all == pageImage(newest.map(PagePhoto.init))?.pngData())
  }

  /// Each print is the photo's thumbnail, not the photo itself.
  @Test func thePrintsAreTheThumbnails() throws {
    let thumbnailOnly = PagePhoto(id: UUID(), thumbnail: .portrait, photo: .landscape)
    let drawn = try #require(pageImage([thumbnailOnly])?.pngData())
    #expect(drawn == pageImage([PagePhoto(.portrait)])?.pngData())
  }

  /// The photos handed to the writing's view reach its page.
  @Test func theViewShowsItsPhotos() throws {
    func contentHeight(_ photos: [UIImage]) throws -> CGFloat {
      let page = HostedPage(
        WritingView(
          writing: Writing(title: "間合いの調整", body: Writing.sampleBody), others: [], open: { _ in },
          edit: { _ in },
          photos: photos.map(PagePhoto.init),
          setting: .constant(.standard), camera: .standIn(taking: nil), photoTaken: { _ in }))
      return try #require(page.scrollViews.first).contentSize.height
    }
    #expect(try contentHeight([.portrait]) > contentHeight([]))
  }
}

private func page(
  _ photos: [PagePhoto], _ colorScheme: ColorScheme, _ size: DynamicTypeSize
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

private func pageImage(_ photos: [PagePhoto]) -> UIImage? {
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
    of: page(photos.map(PagePhoto.init), colorScheme, size),
    as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
    fileID: fileID,
    file: file,
    testName: testName,
    line: line,
    column: column)
}
