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

  @Test func plusBought() {
    assertPlanScreen(PlanBought(offer: PlanOffer(plan: .plus, price: "¥700")))
  }

  @Test func plansUnavailable() {
    assertPlanScreen(
      PlansUnavailable(
        reason: "App Store につながりませんでした。ネットワークを確かめて、もう一度お試しください。", retry: {}))
  }
}

/// The plans at their prices in Japan, as the plans screen shows them.
private func assertPlans(
  buying: SyncPlan? = nil,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let offers = zip(SyncPlan.allCases, ["¥150", "¥700", "¥1,600"]).map(PlanOffer.init)
  assertPlanScreen(
    PlanList(offers: offers, buying: buying, buy: { _ in }), colorScheme: colorScheme, size: size,
    testName: testName)
}

/// `content` as the plans screen shows it, pushed onto a navigation stack in a 402 × 874 window.
private func assertPlanScreen(
  _ content: some View,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let page = HostedPage(
    NavigationStack {
      content
        .navigationTitle("同期のプラン")
        .navigationBarTitleDisplayMode(.inline)
    }
    .dynamicTypeSize(size)
    .environment(\.colorScheme, colorScheme))
  assertSnapshot(
    of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
