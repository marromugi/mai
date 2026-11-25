import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

/// The read-mode screens: the settings page off and on, and approving an agent.
struct ReadModeScreenTests {
  /// Off, with an agent approved, one revoked and one no device signed, and a writing excluded.
  @Test func readModeOff() {
    assertReadMode(until: nil)
  }

  /// On until a set time, after the copies were sent.
  @Test func readModeOn() {
    assertReadMode(
      until: noon.addingTimeInterval(3 * 60 * 60),
      sent: "2 件の写しをエージェントあてに置きました。")
  }

  /// With no agent approved yet, read mode can't be turned on.
  @Test func readModeWithNoAgent() {
    assertReadMode(until: nil, agents: [])
  }

  @Test func readModeInDarkMode() {
    assertReadMode(until: nil, colorScheme: .dark)
  }

  @Test func readModeAtTheLargestSize() {
    assertReadMode(until: nil, size: .accessibility5)
  }

  @Test func approvingAnAgent() {
    assertPage(AgentApprovalView(approve: { _ in .failure(ApprovalProblem(message: "")) }))
  }

  /// The line to hand the agent, once approved.
  @Test func handingTheLineToTheAgent() {
    assertPage(
      AgentApprovalView(
        approve: { _ in .failure(ApprovalProblem(message: "")) },
        handoff:
          "https://mai-staging.example.workers.dev#agent.3f2a9c1e-5b7d-4e8f-9a0b-1c2d3e4f5a6b.Qm9vZnN0cmFwX3NlY3JldF9mb3JfdGhlX2FnZW50XzAx"
      ))
  }
}

/// Noon on 2026-11-24 in Tokyo.
private let noon = Date(timeIntervalSince1970: 1_795_489_200)

private let sampleAgents = [
  AgentRow(id: UUID(), code: "7K2M", approved: true, revoked: false),
  AgentRow(id: UUID(), code: "Q9TD", approved: true, revoked: true),
  AgentRow(id: UUID(), code: "H4WX", approved: false, revoked: false),
]

private let sampleWritings = [
  ExcludableWriting(id: UUID(), title: "朝の散歩"),
  ExcludableWriting(id: UUID(), title: "日記 11月"),
  ExcludableWriting(id: UUID(), title: ""),
]

private func assertReadMode(
  until: Date?,
  agents: [AgentRow] = sampleAgents,
  sent: String? = nil,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  assertPage(
    ReadModeForm(
      until: until, agents: agents, writings: sampleWritings, excluded: [sampleWritings[1].id],
      sent: sent, now: noon, turnOn: { _ in }, turnOff: {}, approve: {}, revoke: { _ in },
      setExcluded: { _, _ in }
    )
    .navigationTitle("AI に読ませる")
    .navigationBarTitleDisplayMode(.inline),
    colorScheme: colorScheme, size: size, testName: testName)
}

/// `content` on a navigation stack in a 402 × 874 window, in Japanese, in Tokyo.
private func assertPage(
  _ content: some View,
  colorScheme: ColorScheme = .light,
  size: DynamicTypeSize = .large,
  testName: String = #function
) {
  let page = HostedPage(
    NavigationStack { content }
      .environment(\.locale, Locale(identifier: "ja_JP"))
      .environment(\.timeZone, TimeZone(identifier: "Asia/Tokyo") ?? .gmt)
      .dynamicTypeSize(size)
      .environment(\.colorScheme, colorScheme))
  assertSnapshot(
    of: page.image(), as: .image(precision: 1, perceptualPrecision: 0.995), testName: testName)
}
