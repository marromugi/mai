import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

@MainActor
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
    let all = try #require(endOfPage((older + newest).map(PagePhoto.init)).pngData())
    #expect(all == (try endOfPage(newest.map(PagePhoto.init)).pngData()))
  }

  /// Each print is the photo's thumbnail, not the photo itself.
  @Test func thePrintsAreTheThumbnails() throws {
    let thumbnailOnly = PagePhoto(id: UUID(), thumbnail: .portrait, photo: .landscape)
    let drawn = try #require(endOfPage([thumbnailOnly]).pngData())
    #expect(drawn == (try endOfPage([PagePhoto(.portrait)]).pngData()))
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

/// The end of the page, where the photos are, on a 402 × 874 screen.
@MainActor
private func endOfPage(
  _ photos: [PagePhoto], _ colorScheme: ColorScheme = .light, _ size: DynamicTypeSize = .large
) throws -> UIImage {
  let page = HostedPage(
    WritingPage(
      writing: Writing(title: "間合いの調整", body: Writing.sampleBody), photos: photos, width: 402,
      back: {}, titleCutOff: { _ in }
    )
    .ignoresSafeArea(.container, edges: .top)
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.colorScheme, colorScheme))
  let scroll = try #require(page.scrollViews.first)
  // TextKit sets the text's height from the lines it has laid out: the end moves as it lays out
  // the lines near it.
  for _ in 0..<3 {
    scroll.contentOffset.y = max(
      -scroll.adjustedContentInset.top,
      scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height)
    page.settle()
  }
  return page.image()
}

/// The end of the page, where the photos are, on a 402 × 874 screen.
@MainActor
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
  do {
    assertSnapshot(
      of: try endOfPage(photos.map(PagePhoto.init), colorScheme, size),
      as: .image(precision: 1, perceptualPrecision: 0.995),
      fileID: fileID,
      file: file,
      testName: testName,
      line: line,
      column: column)
  } catch {
    Issue.record(error)
  }
}
