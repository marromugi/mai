import SnapshotTesting
import SwiftUI
import Testing
import Typesetting
import UIKit

@testable import Features

@MainActor
struct WritingModeTests {
  @Test(arguments: [false, true])
  func scrollingStopsOnlyInTheMode(_ typesetting: Bool) throws {
    let page = HostedPage(screen(typesetting: typesetting))
    let scrollViews = page.scrollViews
    try #require(!scrollViews.isEmpty)
    #expect(scrollViews.allSatisfy { $0.isScrollEnabled != typesetting })
  }

  @Test func aWritingOpensOutOfTheMode() throws {
    let page = HostedPage(
      WritingView(
        writing: Writing(title: "間合いの調整", body: Writing.sampleBody), others: [], open: { _ in },
        edit: { _ in },
        photos: [],
        setting: .constant(.standard), camera: .standIn(taking: nil), photoTaken: { _ in }))
    let scrollView = try #require(page.scrollViews.first)
    #expect(scrollView.isScrollEnabled)
  }

  /// Scrolled to the page's end, entering and leaving the mode leaves the text where it was.
  @Test func theModeKeepsThePageWhereItWas() throws {
    let large = try #require(BodySetting(base: 24, lineHeight: 44, tracking: 200))
    let page = HostedPage(screen(typesetting: false, setting: large))
    let scrollView = try #require(page.scrollViews.first)
    let end =
      scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
      - scrollView.bounds.height
    try #require(end > 0)
    scrollView.setContentOffset(CGPoint(x: 0, y: end), animated: false)
    let before = scrollView.convert(CGPoint.zero, to: nil).y
    page.show(screen(typesetting: true, setting: large))
    page.show(screen(typesetting: false, setting: large))
    #expect(scrollView.convert(CGPoint.zero, to: nil).y == before)
  }

  /// What the page keeps the caret and the text's end within stops above the bottom fade.
  @Test func thePageShowsItsTextAboveTheBottomFade() throws {
    let page = HostedPage(screen(typesetting: false))
    let scrollView = try #require(page.scrollViews.first)
    // The fade lies on the page's bottom edge, at the bottom row's top.
    let above = scrollView.bounds.inset(by: scrollView.safeAreaInsets)
    let shown = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
    #expect(above.maxY - shown.maxY >= EdgeFade.height(TypeScale.standard))
  }

  /// The button that closes the keyboard shows while the keyboard is up, and goes with it.
  @Test func theKeyboardButtonFollowsTheKeyboard() {
    let page = HostedPage(screen(typesetting: false))
    let without = page.image().pngData()
    NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
    page.settle()
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), named: "shown")
    NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
    page.settle()
    #expect(page.image().pngData() == without)
  }

  /// At the top the title is on the page and no header shows; scrolled to the end, the header
  /// stands in for it.
  @Test(arguments: [false, true])
  func theHeaderShowsOnceTheTitleScrollsOff(_ scrolled: Bool) throws {
    let large = try #require(BodySetting(base: 24, lineHeight: 44, tracking: 200))
    let page = HostedPage(screen(typesetting: false, setting: large))
    if scrolled {
      let scrollView = try #require(page.scrollViews.first)
      let end =
        scrollView.contentSize.height + scrollView.adjustedContentInset.bottom
        - scrollView.bounds.height
      try #require(end > 0)
      scrollView.setContentOffset(CGPoint(x: 0, y: end), animated: false)
      page.settle()
    }
    assertSnapshot(
      of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995),
      named: scrolled ? "scrolled" : "top")
  }
}

private func screen(typesetting: Bool, setting: BodySetting = .standard) -> WritingScreen {
  WritingScreen(
    writing: Writing(title: "間合いの調整", body: Writing.sampleBody), others: [], open: { _ in },
    edit: { _ in },
    photos: [],
    setting: .constant(setting),
    typesetting: .constant(typesetting),
    takingPhoto: .constant(false),
    camera: .standIn(taking: nil),
    photoTaken: { _ in })
}
