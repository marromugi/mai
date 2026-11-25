import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import Features

@MainActor
struct PhotoViewerTests {
  /// The viewer pages through every photo, one screen wide each, and opens on the one it is given.
  @Test(arguments: [0, 1, 2])
  func itOpensOnTheGivenPhoto(_ index: Int) throws {
    let photos: [UIImage] = [.portrait, .landscape, .dusk]
    let page = HostedPage(viewer(photos, shown: index))
    let scrollView = try #require(page.scrollViews.first)
    #expect(Int(scrollView.contentSize.width.rounded()) == 402 * 3)
    #expect(Int(scrollView.contentOffset.x.rounded()) == 402 * index)
  }

  /// The newest photo as large as fits, over black, under the close button.
  @Test func theNewestFillsTheScreen() {
    let photos: [UIImage] = [.portrait, .landscape, .dusk]
    let page = HostedPage(viewer(photos, shown: 2))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// A landscape photo fits the screen's width.
  @Test func aLandscapePhotoFillsTheWidth() {
    let photo = UIImage.landscape
    let page = HostedPage(viewer([photo], shown: 0))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// A swipe stops on a page, not part way between two.
  @Test func itPages() throws {
    let photos: [UIImage] = [.portrait, .dusk]
    let page = HostedPage(viewer(photos, shown: 1))
    #expect(try #require(page.scrollViews.first).isPagingEnabled)
  }

  /// A photo taller than the screen's shape fits the screen's height.
  @Test func aTallPhotoFillsTheHeight() {
    let photo = UIImage.tall
    let page = HostedPage(viewer([photo], shown: 0))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  @Test func voiceOverReadsWhichPhoto() {
    #expect(PhotoViewer.label(index: 0, count: 1) == "写真")
    #expect(PhotoViewer.label(index: 1, count: 3) == "写真 2/3")
  }
}

/// The viewer of `images`, on the one at `shown`.
private func viewer(_ images: [UIImage], shown: Int) -> PhotoViewer {
  let photos = images.map(PagePhoto.init)
  return PhotoViewer(photos: photos, shown: .constant(photos[shown].id), close: {})
}
