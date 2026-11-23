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

  /// Another writing's title in the body is a link under a dotted line in the text's colour.
  @Test func pageWithATitleLink() {
    assertPage(.large, .light, writing: pageNamingNightDesk, others: [nightDesk])
  }

  @Test func pageWithATitleLinkInDarkMode() {
    assertPage(.large, .dark, writing: pageNamingNightDesk, others: [nightDesk])
  }

  @Test func pageAtTheLargestSize() {
    assertPage(.accessibility5, .light)
  }

  /// On a device with no camera, its button is dimmed.
  @Test func pageWithNoCamera() {
    assertPage(.large, .light, camera: .none)
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

  @Test func typesettingModeAtTheLargestSize() {
    assertPage(.accessibility5, .light, typesetting: true)
  }

  @Test func typesettingModeInDarkMode() {
    assertPage(.large, .dark, typesetting: true)
  }

  @Test func header() {
    assertHeader("夜の机に向かう", .light)
  }

  @Test func headerInDarkMode() {
    assertHeader("夜の机に向かう", .dark)
  }

  /// The chevron and its twin grow with Dynamic Type and leave the title less room; the title
  /// stays at its size at the standard scale.
  @Test func headerAtTheLargestSize() {
    assertHeader("夜の机に向かう", .light, .accessibility5)
  }

  /// A title a step too long is set at the meta's size, still centred.
  @Test func headerWithATitleOneStepDown() {
    assertHeader("週末に読み返すための、とりとめのない覚え", .light)
  }

  /// A title two steps too long is set at the caption's size, still centred.
  @Test func headerWithATitleTwoStepsDown() {
    assertHeader("週末に読み返すための、とりとめのない覚え書きを", .light)
  }

  /// A title too long even at the caption's size ends in an ellipsis, still centred.
  @Test func headerWithALongTitle() {
    assertHeader("ものすごく長すぎて入りきらない名前ですよものすごく長すぎて", .light)
  }

  /// The shrunk page set from the writing's body setting.
  @Test func typesettingModeWithABodySetting() throws {
    let setting = try #require(BodySetting(base: 20, lineHeight: 40, tracking: 50))
    assertPage(.large, .light, body: setting, typesetting: true)
  }
}

/// A writing whose title `pageNamingNightDesk` names.
private let nightDesk = Writing(
  id: UUID(sample: 4), title: "夜の机に向かう", body: "", updated: Date(timeIntervalSince1970: 0))

private let pageNamingNightDesk = Writing(
  title: "間合いの調整", body: Writing.sampleBody + "\n" + Writing.sampleMention)

private func pageHeight(title: String, size: DynamicTypeSize) -> CGFloat {
  let page = WritingPage(
    writing: Writing(title: title, body: "本文"), photos: [], width: 402, back: {},
    titleCutOff: { _ in }
  )
  .dynamicTypeSize(size)
  return UIHostingController(rootView: page)
    .sizeThatFits(in: CGSize(width: 402, height: 8000)).height
}

/// The header over the body it fades, at the top of a 402-wide screen.
private func assertHeader(
  _ title: String,
  _ colorScheme: ColorScheme,
  _ size: DynamicTypeSize = .large,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  let margin = TypeScale.standard.typeArea(width: 402).margin
  assertSnapshot(
    of: ZStack(alignment: .top) {
      Text(body: Writing.sampleBody)
        .textStyle(.body)
        .padding(.horizontal, margin)
      WritingHeader(title: title, width: 402, close: {})
    }
    .frame(width: 402, height: 200, alignment: .top)
    .clipped()
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

/// The page with its bottom row on a 402 × 874 screen, as the mock shows it, or shrunk to a sheet in
/// the typesetting mode.
private func assertPage(
  _ size: DynamicTypeSize,
  _ colorScheme: ColorScheme,
  body: BodySetting = .standard,
  typesetting: Bool = false,
  camera: Camera = .standIn(taking: nil),
  writing: Writing = Writing(title: "間合いの調整", body: Writing.sampleBody),
  others: [Writing] = [],
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  assertSnapshot(
    of: WritingScreen(
      writing: writing, others: others, open: { _ in },
      photos: [], setting: .constant(body),
      typesetting: .constant(typesetting), takingPhoto: .constant(false), camera: camera,
      photoTaken: { _ in }
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
