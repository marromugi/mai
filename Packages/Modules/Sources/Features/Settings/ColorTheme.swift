import SwiftUI

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

  /// Nil follows the device's own setting.
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
