import SnapshotTesting
import SwiftUI
import Testing
import Typesetting

@testable import Features

/// A fixed calendar and time, so the wording doesn't move with the machine's clock or time zone.
private let calendar: Calendar = {
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "ja_JP")
  guard let tokyo = TimeZone(identifier: "Asia/Tokyo") else {
    preconditionFailure("The time zone Asia/Tokyo is missing.")
  }
  calendar.timeZone = tokyo
  return calendar
}()

private let now: Date = {
  guard
    let date = calendar.date(
      from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))
  else { preconditionFailure("2026-11-23 12:00 is out of the calendar's range.") }
  return date
}()

private func before(now offset: DateComponents) -> Date {
  guard let date = calendar.date(byAdding: offset, to: now) else {
    preconditionFailure("\(offset) from \(now) is out of the calendar's range.")
  }
  return date
}

struct WritingListTests {
  @Test(arguments: [
    (DateComponents(second: 0), "たった今"),
    (DateComponents(second: -59), "たった今"),
    (DateComponents(second: 1), "たった今"),
    (DateComponents(hour: 3), "たった今"),
    (DateComponents(minute: -1), "1分前"),
    (DateComponents(minute: -59, second: -59), "59分前"),
    (DateComponents(hour: -1), "1時間前"),
    (DateComponents(hour: -23, minute: -59), "23時間前"),
    (DateComponents(day: -1), "1日前"),
    (DateComponents(day: -6, hour: -23), "6日前"),
    (DateComponents(day: -7), "1週間前"),
    (DateComponents(day: -13), "1週間前"),
    (DateComponents(day: -14), "2週間前"),
    (DateComponents(month: -1, minute: 1), "4週間前"),
    (DateComponents(month: -1), "1か月前"),
    (DateComponents(month: -11), "11か月前"),
    (DateComponents(year: -1, minute: 1), "11か月前"),
    (DateComponents(year: -1), "1年前"),
    (DateComponents(year: -12), "12年前"),
  ])
  func updatedIsWordedInTheLargestWholeUnit(_ offset: DateComponents, _ expected: String) {
    let row = WritingRow(id: 0, title: "", characterCount: 0, updated: before(now: offset))
    #expect(row.updatedLabel(now: now, calendar: calendar) == expected)
  }

  @Test func rowsAreNewestFirstAndTiesInIDOrder() {
    let rows = [
      WritingRow(
        id: 1, title: "", characterCount: 0, updated: before(now: DateComponents(day: -2))),
      WritingRow(id: 3, title: "", characterCount: 0, updated: now),
      WritingRow(
        id: 4, title: "", characterCount: 0, updated: before(now: DateComponents(day: -1))),
      WritingRow(id: 2, title: "", characterCount: 0, updated: now),
    ]
    #expect(rows.newestFirst().map(\.id) == [2, 3, 4, 1])
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility5])
  func untitledRowKeepsOneTitleLine(_ size: DynamicTypeSize) {
    let untitled = WritingRow(id: 0, title: "", characterCount: 0, updated: now)
    let titled = WritingRow(id: 0, title: "朝", characterCount: 0, updated: now)
    #expect(height(of: untitled, size: size) == height(of: titled, size: size))
  }

  @Test(arguments: ["たった今", "59分前", "23時間前", "6日前", "4週間前", "11か月前", "99年前"])
  func updatedColumnHoldsTheWidestLabels(_ label: String) {
    let text = Text(verbatim: label).textStyle(.meta)
    #expect(width(of: UpdatedColumn(label: label)) >= width(of: text))
  }

  /// A label past the widest wording reaches out to the leading side and leaves the column alone.
  @Test func widerLabelKeepsTheColumnWidth() {
    #expect(width(of: UpdatedColumn(label: "1234567年前")) == width(of: UpdatedColumn(label: "1日前")))
  }

  /// Offered no width, a row is as wide as its title on one line, the least gap, and the date.
  /// Measured widths land on device pixels, so they are checked to within half a point.
  @Test func idealRowWidthIsTitleGapAndDate() {
    let row = WritingRow(
      id: 0, title: "パンを焼く日", characterCount: 1920, updated: before(now: DateComponents(day: -1)))
    let title = Text(verbatim: row.title).textStyle(.title)
    let expected =
      width(of: title) + TypeScale.standard.chars(1, of: .meta)
      + width(of: UpdatedColumn(label: "1日前"))
    let rowWidth = width(of: WritingRowView(row: row, now: now).environment(\.calendar, calendar))
    #expect(abs(rowWidth - expected) < 0.5)
  }

  @Test func rootShowsTheWritingList() {
    assertSnapshot(
      of: RootView().frame(width: 402, height: 874).background(Color(.systemBackground)),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  /// An untitled row, a row updated after `now`, and one updated years ago, given oldest first.
  @Test func rowsWithUnusualValues() {
    assertSnapshot(
      of: WritingListPage(
        rows: [
          WritingRow(
            id: 1, title: "古い覚え書き", characterCount: 312,
            updated: before(now: DateComponents(year: -12))),
          WritingRow(id: 2, title: "", characterCount: 0, updated: now),
          WritingRow(
            id: 3, title: "時計より先の原稿", characterCount: 1_234_567,
            updated: before(now: DateComponents(hour: 3))),
        ],
        now: now,
        width: 402
      )
      .fixedSize(horizontal: false, vertical: true)
      .frame(width: 402)
      .background(Color(.systemBackground))
      .environment(\.calendar, calendar),
      as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits))
  }

  @Test func list() {
    assertList(.large, .light)
  }

  @Test func listInDarkMode() {
    assertList(.large, .dark)
  }

  /// The date goes under the title.
  @Test func listAtTheFirstAccessibilitySize() {
    assertList(.accessibility1, .light)
  }

  @Test func listAtTheLargestSize() {
    assertList(.accessibility5, .light)
  }
}

private func height(of row: WritingRow, size: DynamicTypeSize) -> CGFloat {
  let view = WritingRowView(row: row, now: now).frame(width: 355.5).dynamicTypeSize(size)
    .environment(\.calendar, calendar)
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
    of: WritingListPage(
      rows: WritingRow.samples(now: now, calendar: calendar), now: now, width: 402
    )
    .fixedSize(horizontal: false, vertical: true)
    .frame(width: 402)
    .background(Color(.systemBackground))
    .dynamicTypeSize(size)
    .environment(\.colorScheme, colorScheme)
    .environment(\.calendar, calendar),
    as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
    fileID: fileID,
    file: file,
    testName: testName,
    line: line,
    column: column)
}
