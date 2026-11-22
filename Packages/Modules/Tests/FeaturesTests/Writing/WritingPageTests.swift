import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

struct WritingPageTests {
  @Test func page() {
    assertPage(.large, .light)
  }

  @Test func pageInDarkMode() {
    assertPage(.large, .dark)
  }

  @Test func pageAtTheLargestSize() {
    assertPage(.accessibility5, .light)
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility5])
  func untitledPageKeepsTheTitleLine(_ size: DynamicTypeSize) {
    #expect(pageHeight(title: "", size: size) == pageHeight(title: "朝", size: size))
  }

  /// A larger base, a looser line height, and wider tracking from the environment.
  @Test func pageWithABodySetting() throws {
    let setting = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    assertPage(.large, .light, body: setting)
  }

  @Test func typesettingMode() {
    assertPage(.large, .light, typesetting: true)
  }

  @Test func typesettingModeInDarkMode() {
    assertPage(.large, .dark, typesetting: true)
  }

  /// The shrunk page set from the writing's body setting.
  @Test func typesettingModeWithABodySetting() throws {
    let setting = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    assertPage(.large, .light, body: setting, typesetting: true)
  }
}

private func pageHeight(title: String, size: DynamicTypeSize) -> CGFloat {
  let page = WritingPage(writing: Writing(title: title, body: "本文"), width: 402, back: {})
    .dynamicTypeSize(size)
  return UIHostingController(rootView: page)
    .sizeThatFits(in: CGSize(width: 402, height: 8000)).height
}

/// The page with its button on a 402 × 874 screen, as the mock shows it, or shrunk to a sheet in
/// the typesetting mode.
private func assertPage(
  _ size: DynamicTypeSize,
  _ colorScheme: ColorScheme,
  body: BodySetting = .standard,
  typesetting: Bool = false,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  assertSnapshot(
    of: WritingScreen(
      writing: Writing(title: "間合いの調整", body: Writing.sampleBody), setting: .constant(body),
      typesetting: .constant(typesetting)
    )
    .frame(width: 402, height: 874)
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.colorScheme, colorScheme),
    as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
    fileID: fileID,
    file: file,
    testName: testName,
    line: line,
    column: column)
}
