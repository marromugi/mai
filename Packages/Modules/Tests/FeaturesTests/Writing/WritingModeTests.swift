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
        writing: Writing(title: "間合いの調整", body: Writing.sampleBody), setting: .constant(.standard)))
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
}

private func screen(typesetting: Bool, setting: BodySetting = .standard) -> WritingScreen {
  WritingScreen(
    writing: Writing(title: "間合いの調整", body: Writing.sampleBody),
    setting: .constant(setting),
    typesetting: .constant(typesetting))
}

/// A view laid out in a 402 × 874 window.
@MainActor
private final class HostedPage {
  private let controller: UIHostingController<AnyView>
  private let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))

  init(_ view: some View) {
    controller = UIHostingController(rootView: AnyView(view))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    settle()
  }

  /// Replaces the view in place, as a state change would, and lays it out again.
  func show(_ view: some View) {
    controller.rootView = AnyView(view)
    settle()
  }

  /// Lays the view out once the window has given it its safe area.
  private func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    controller.view.layoutIfNeeded()
  }

  var scrollViews: [UIScrollView] {
    var found: [UIScrollView] = []
    var pending: [UIView] = [window]
    while let view = pending.popLast() {
      if let scrollView = view as? UIScrollView { found.append(scrollView) }
      pending.append(contentsOf: view.subviews)
    }
    return found
  }
}
