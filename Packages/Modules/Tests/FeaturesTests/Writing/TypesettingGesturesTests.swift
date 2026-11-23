import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

@MainActor
struct TypesettingGesturesTests {
  @Test(arguments: [ColorScheme.light, .dark])
  func theSheetNamesEachGestureWithItsIcon(_ colorScheme: ColorScheme) {
    assertSnapshot(
      of: TypesettingGestures()
        .frame(width: 402, height: 420)
        .background(Color(.systemBackground))
        .environment(\.colorScheme, colorScheme),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
      named: colorScheme == .dark ? "dark" : "light")
  }
}
