import SwiftUI
import UIKit

/// The colors the app is shown in. The raw value is what the chosen theme is remembered as under
/// `key`; anything else stored reads as `.system`.
enum ColorTheme: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let key = "colorTheme"

  var id: Self { self }

  var title: String {
    switch self {
    case .system: "システムに合わせる"
    case .light: "ライト"
    case .dark: "ダーク"
    }
  }

  /// Unspecified follows the device's own setting.
  var userInterfaceStyle: UIUserInterfaceStyle {
    switch self {
    case .system: .unspecified
    case .light: .light
    case .dark: .dark
    }
  }
}

extension View {
  /// Shows the whole window this view is in, every sheet presented in it included, in `theme`.
  func colorTheme(_ theme: ColorTheme) -> some View {
    background(WindowStyle(style: theme.userInterfaceStyle))
  }
}

/// Sets the override of the window it is in, which every sheet follows, back to unspecified
/// included; `preferredColorScheme` going back to nil leaves an open sheet as it was (#41).
private struct WindowStyle: UIViewRepresentable {
  let style: UIUserInterfaceStyle

  func makeUIView(context: Context) -> StylingView {
    StylingView()
  }

  func updateUIView(_ view: StylingView, context: Context) {
    view.style = style
  }

  final class StylingView: UIView {
    var style = UIUserInterfaceStyle.unspecified {
      didSet { window?.overrideUserInterfaceStyle = style }
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      window?.overrideUserInterfaceStyle = style
    }
  }
}
