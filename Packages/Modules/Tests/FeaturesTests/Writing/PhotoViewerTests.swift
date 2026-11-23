import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import Features

@MainActor
struct PhotoViewerTests {
  /// The viewer pages through every photo, one screen wide each, and opens on the newest, the last.
  @Test func itOpensOnTheNewest() throws {
    let page = HostedPage(PhotoViewer(photos: [.portrait, .landscape, .dusk], close: {}))
    let scrollView = try #require(page.scrollViews.first)
    #expect(scrollView.contentSize.width.rounded() == 402 * 3)
    #expect(scrollView.contentOffset.x.rounded() == 402 * 2)
  }

  /// The newest photo as large as fits, over black, under the close button.
  @Test func theNewestFillsTheScreen() {
    let page = HostedPage(PhotoViewer(photos: [.portrait, .landscape, .dusk], close: {}))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// A landscape photo fits the screen's width.
  @Test func aLandscapePhotoFillsTheWidth() {
    let page = HostedPage(PhotoViewer(photos: [.landscape], close: {}))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  @Test func voiceOverReadsWhichPhoto() {
    #expect(PhotoViewer.label(index: 0, count: 1) == "写真")
    #expect(PhotoViewer.label(index: 1, count: 3) == "写真 2/3")
  }
}
