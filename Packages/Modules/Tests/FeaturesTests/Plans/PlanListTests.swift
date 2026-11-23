import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

struct PlanListTests {
  @Test func plans() {
    assertPlans()
  }

  /// Every button dimmed, and Plus's showing it is under way.
  @Test func plansWhileBuyingPlus() {
    assertPlans(buying: .plus)
  }

  @Test func plansInDarkMode() {
    assertPlans(colorScheme: .dark)
  }

  @Test func plansAtTheLargestSize() {
    assertPlans(size: .accessibility5)
  }
}

/// The plans at their prices in Japan, pushed onto a navigation stack in a 402 × 874 window.
private func assertPlans(
  buying: SyncPlan? = nil,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let offers = zip(SyncPlan.allCases, ["¥150", "¥700", "¥1,600"]).map(PlanOffer.init)
  let page = HostedPage(
    NavigationStack {
      PlanList(offers: offers, buying: buying, buy: { _ in })
        .navigationTitle("同期のプラン")
        .navigationBarTitleDisplayMode(.inline)
    }
    .dynamicTypeSize(size)
    .environment(\.colorScheme, colorScheme))
  assertSnapshot(
    of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
