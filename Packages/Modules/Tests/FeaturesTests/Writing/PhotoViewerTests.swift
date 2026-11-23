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
    let page = HostedPage(viewer(photos, shown: photos[index]))
    let scrollView = try #require(page.scrollViews.first)
    #expect(Int(scrollView.contentSize.width.rounded()) == 402 * 3)
    #expect(Int(scrollView.contentOffset.x.rounded()) == 402 * index)
  }

  /// The newest photo as large as fits, over black, under the close button.
  @Test func theNewestFillsTheScreen() {
    let photos: [UIImage] = [.portrait, .landscape, .dusk]
    let page = HostedPage(viewer(photos, shown: photos[2]))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  /// A landscape photo fits the screen's width.
  @Test func aLandscapePhotoFillsTheWidth() {
    let photo = UIImage.landscape
    let page = HostedPage(viewer([photo], shown: photo))
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995))
  }

  @Test func voiceOverReadsWhichPhoto() {
    #expect(PhotoViewer.label(index: 0, count: 1) == "写真")
    #expect(PhotoViewer.label(index: 1, count: 3) == "写真 2/3")
  }
}

private func viewer(_ photos: [UIImage], shown: UIImage) -> PhotoViewer {
  PhotoViewer(photos: photos, shown: .constant(shown.id), close: {})
}
