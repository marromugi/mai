import SwiftUI
import UIKit

/// A view laid out in a 402 × 874 window.
@MainActor
final class HostedPage {
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
  func settle() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    controller.view.layoutIfNeeded()
  }

  /// Waits until `done` holds, or until three seconds have passed. Waiting, unlike `settle()`, lets
  /// the main actor run the tasks queued on it.
  func settle(until done: () -> Bool) async throws {
    let deadline = Date(timeIntervalSinceNow: 3)
    while !done(), Date() < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  /// The window as it is drawn now.
  func image() -> UIImage {
    UIGraphicsImageRenderer(bounds: window.bounds).image { context in
      window.layer.render(in: context.cgContext)
    }
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
