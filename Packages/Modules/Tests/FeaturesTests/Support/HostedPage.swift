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

  /// The first view controller of type `T` among those the view holds.
  func child<T: UIViewController>(_ type: T.Type) -> T? {
    var pending: [UIViewController] = [controller]
    while let next = pending.popLast() {
      if let found = next as? T { return found }
      pending.append(contentsOf: next.children)
    }
    return nil
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

  var textViews: [UITextView] {
    views(UITextView.self)
  }

  /// The text fields in the window, a sheet's included.
  var textFields: [UITextField] {
    views(UITextField.self)
  }

  /// The view controller presented over the view, such as a sheet, if any.
  var presented: UIViewController? {
    controller.presentedViewController
  }

  private func views<T: UIView>(_ type: T.Type) -> [T] {
    var found: [T] = []
    var pending: [UIView] = [window]
    while let view = pending.popLast() {
      if let match = view as? T { found.append(match) }
      pending.append(contentsOf: view.subviews)
    }
    return found
  }
}
