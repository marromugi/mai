import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

struct WritingListTests {
  @Test func countHasNoThousandsSeparators() {
    let row = WritingRow(id: 0, title: "", characterCount: 12480, updated: "1日前")
    #expect(row.characterCountLabel == "12480文字")
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility5])
  func untitledRowKeepsOneTitleLine(_ size: DynamicTypeSize) {
    let untitled = WritingRow(id: 0, title: "", characterCount: 0, updated: "たった今")
    let titled = WritingRow(id: 0, title: "朝", characterCount: 0, updated: "たった今")
    #expect(height(of: untitled, size: size) == height(of: titled, size: size))
  }

  /// A count past five digits or a missing date leaves the columns, and so the title column, alone.
  @Test(arguments: [
    (DynamicTypeSize.large, "1日前"), (.large, ""), (.xxxLarge, ""), (.accessibility4, "1日前"),
  ])
  func oversizedValuesKeepTheColumns(_ size: DynamicTypeSize, _ updated: String) {
    let title = String(repeating: "あ", count: 15)
    let five = WritingRow(id: 0, title: title, characterCount: 99999, updated: "1日前")
    let seven = WritingRow(id: 0, title: title, characterCount: 1_234_567, updated: updated)
    #expect(height(of: five, size: size) == height(of: seven, size: size))
  }

  @Test(arguments: ["00か月前", "00週間前", "00時間前", "たった今"])
  func metaColumnsHoldTheWidestValues(_ updated: String) {
    let row = WritingRow(id: 0, title: "", characterCount: 99999, updated: updated)
    let values = HStack(spacing: TypeScale.standard.chars(1, of: .meta)) {
      Text(verbatim: "99999文字")
      Text(verbatim: updated)
    }
    .textStyle(.meta)
    #expect(width(of: MetaColumns(row: row)) >= width(of: values))
  }

  /// Offered no width, a row is as wide as its title on one line, the least gap, and the meta.
  /// Measured widths land on device pixels, so they are checked to within half a point.
  @Test func idealRowWidthIsTitleGapAndMeta() {
    let row = WritingRow(id: 0, title: "パンを焼く日", characterCount: 1920, updated: "1日前")
    let title = Text(verbatim: row.title).textStyle(.title)
    let expected =
      width(of: title) + TypeScale.standard.chars(1, of: .meta) + width(of: MetaColumns(row: row))
    #expect(abs(width(of: WritingRowView(row: row)) - expected) < 0.5)
  }

  @Test func rootShowsTheWritingList() {
    assertSnapshot(
      of: RootView().frame(width: 402, height: 874).background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  /// An untitled row, a seven-digit count, and a missing date.
  @Test func rowsWithUnusualValues() {
    assertSnapshot(
      of: WritingListPage(
        rows: [
          WritingRow(id: 1, title: "", characterCount: 0, updated: "たった今"),
          WritingRow(id: 2, title: "百万字の原稿", characterCount: 1_234_567, updated: "1日前"),
          WritingRow(id: 3, title: "日付のない覚え書き", characterCount: 312, updated: ""),
        ],
        width: 402
      )
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 402)
      .background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  @Test func list() {
    assertList(.large, .light)
  }

  @Test func listInDarkMode() {
    assertList(.large, .dark)
  }

  /// The count and date go under the title, still on one line.
  @Test func listAtTheFirstAccessibilitySize() {
    assertList(.accessibility1, .light)
  }

  /// The count and date go under the title, each on a line of its own.
  @Test func listAtTheLargestSize() {
    assertList(.accessibility5, .light)
  }
}

private func height(of row: WritingRow, size: DynamicTypeSize) -> CGFloat {
  let view = WritingRowView(row: row).frame(width: 355.5).dynamicTypeSize(size)
  return UIHostingController(rootView: view)
    .sizeThatFits(in: CGSize(width: 355.5, height: 4000)).height
}

private func width(of view: some View) -> CGFloat {
  UIHostingController(rootView: view.fixedSize())
    .sizeThatFits(in: CGSize(width: 2000, height: 2000)).width
}

/// The sample list on a 402-wide screen, as tall as it needs to be.
private func assertList(
  _ size: DynamicTypeSize,
  _ colorScheme: ColorScheme,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  assertSnapshot(
    of: WritingListPage(rows: WritingRow.samples, width: 402)
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 402)
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
