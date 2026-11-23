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

/// Two stored writings for opening one of them.
private let twoWritings = [
  Writing(title: "別の文書", body: "別の本文。", updated: now),
  Writing(title: "保存した文書", body: "保存した本文。\n二段落目。", updated: now),
]

private func movedFromNow(_ offset: DateComponents) -> Date {
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
    (DateComponents(year: -1, month: -3), "1年前"),
    (DateComponents(year: -12), "12年前"),
  ])
  func updatedIsWordedInTheLargestWholeUnit(_ offset: DateComponents, _ expected: String) {
    let row = WritingRow(
      id: UUID(sample: 0), title: "", characterCount: 0, updated: movedFromNow(offset))
    #expect(row.updatedLabel(now: now, calendar: calendar) == expected)
  }

  /// New York falls back on 2025-11-02: 24 to 25 hours before noon that day is still a day.
  @Test(arguments: [24.0, 24.5, 24.99])
  func aDayAcrossTheFallBackIsOneDay(_ hours: Double) throws {
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let noon = try #require(
      newYork.date(from: DateComponents(year: 2025, month: 11, day: 2, hour: 12)))
    let row = WritingRow(
      id: UUID(sample: 0), title: "", characterCount: 0,
      updated: noon.addingTimeInterval(-hours * 3600))
    #expect(row.updatedLabel(now: noon, calendar: newYork) == "1日前")
  }

  @Test func rowsAreNewestFirstAndTiesInIDOrder() {
    let rows = [
      WritingRow(
        id: UUID(sample: 1), title: "", characterCount: 0,
        updated: movedFromNow(DateComponents(day: -2))),
      WritingRow(id: UUID(sample: 3), title: "", characterCount: 0, updated: now),
      WritingRow(
        id: UUID(sample: 4), title: "", characterCount: 0,
        updated: movedFromNow(DateComponents(day: -1))),
      WritingRow(id: UUID(sample: 2), title: "", characterCount: 0, updated: now),
    ]
    #expect(rows.sorted(.newestFirst).map(\.id) == [2, 3, 4, 1].map(UUID.init(sample:)))
  }

  @Test func rowsAreMostCharactersFirstAndTiesNewestFirstThenInIDOrder() {
    let rows = [
      WritingRow(id: UUID(sample: 1), title: "", characterCount: 10, updated: now),
      WritingRow(
        id: UUID(sample: 5), title: "", characterCount: 300,
        updated: movedFromNow(DateComponents(day: -2))),
      WritingRow(
        id: UUID(sample: 6), title: "", characterCount: 300,
        updated: movedFromNow(DateComponents(day: -1))),
      WritingRow(id: UUID(sample: 3), title: "", characterCount: 0, updated: now),
      WritingRow(
        id: UUID(sample: 2), title: "", characterCount: 300,
        updated: movedFromNow(DateComponents(day: -2))),
      WritingRow(
        id: UUID(sample: 4), title: "", characterCount: 99999,
        updated: movedFromNow(DateComponents(year: -1))),
    ]
    #expect(
      rows.sorted(.mostCharactersFirst).map(\.id) == [4, 6, 2, 5, 1, 3].map(UUID.init(sample:)))
  }

  /// The chosen order is remembered by these names; changing one forgets what was chosen.
  @Test func ordersAreRememberedByTheirNames() {
    #expect(WritingListOrder.allCases.map(\.rawValue) == ["updated", "characterCount"])
  }

  @Test(arguments: [DynamicTypeSize.large, .accessibility5])
  func untitledRowKeepsOneTitleLine(_ size: DynamicTypeSize) {
    let untitled = WritingRow(id: UUID(sample: 0), title: "", characterCount: 0, updated: now)
    let titled = WritingRow(id: UUID(sample: 0), title: "朝", characterCount: 0, updated: now)
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
      id: UUID(sample: 0), title: "パンを焼く日", characterCount: 1920,
      updated: movedFromNow(DateComponents(day: -1)))
    let title = Text(verbatim: row.title).textStyle(.title)
    let expected =
      width(of: title) + TypeScale.standard.chars(1, of: .meta)
      + width(of: UpdatedColumn(label: "1日前"))
    let rowWidth = width(of: WritingRowView(row: row, now: now).environment(\.calendar, calendar))
    #expect(abs(rowWidth - expected) < 0.5)
  }

  /// With nothing remembered, newest first.
  @Test func rootShowsTheWritingList() {
    assertRoot(remembering: [:])
  }

  @Test func rootShowsTheRememberedOrder() {
    assertRoot(remembering: ["writingListOrder": "characterCount"])
  }

  /// The page opened on a stored writing shows its stored title and body, not another's. Opening
  /// each of the two in turn means whichever the store lists first, one test opens the other.
  @Test func rootOpensAStoredWriting() {
    assertRoot(remembering: [:], writings: twoWritings, opening: [twoWritings[1].id])
  }

  @Test func rootOpensTheOtherStoredWriting() {
    assertRoot(remembering: [:], writings: twoWritings, opening: [twoWritings[0].id])
  }

  /// A stored writing never adjusted, set in the default remembered as base 20, line height 36,
  /// tracking 50.
  @Test func rootOpensAWritingInTheRememberedDefault() {
    assertRoot(
      remembering: [StoredBodySetting.key: "20 36 50"], writings: [twoWritings[1]],
      opening: [twoWritings[1].id])
  }

  /// The rows are the stored writings, not the samples.
  @Test func rootShowsTheStoredWritings() {
    assertRoot(
      remembering: [:],
      writings: [
        Writing(title: "保存した文書", body: "本文", updated: .now),
        Writing(title: "もうひとつ", body: "", updated: .now),
      ])
  }

  /// An untitled row, a row updated after `now`, and one updated long enough ago that its label is
  /// wider than the column, given oldest first.
  @Test func rowsWithUnusualValues() {
    assertSnapshot(
      of: WritingListPage(
        rows: [
          WritingRow(
            id: UUID(sample: 1), title: "古い覚え書き", characterCount: 312,
            updated: movedFromNow(DateComponents(year: -1234))),
          WritingRow(id: UUID(sample: 2), title: "", characterCount: 0, updated: now),
          WritingRow(
            id: UUID(sample: 3), title: "時計より先の原稿", characterCount: 1_234_567,
            updated: movedFromNow(DateComponents(hour: 3))),
        ],
        now: now,
        order: .constant(.newestFirst),
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

  @Test func listByCharacterCount() {
    assertList(.large, .light, .mostCharactersFirst)
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

/// The app's first screen, reading what is remembered from a store holding only `remembered`,
/// and writings from a store holding only `writings` (seeded with the samples when there are none).
private func assertRoot(
  remembering remembered: [String: String],
  writings: [Writing] = [],
  opening path: [Writing.ID] = [],
  testName: String = #function
) {
  let suite = "WritingListTests.\(testName)"
  guard let store = UserDefaults(suiteName: suite) else {
    preconditionFailure("The defaults suite \(suite) can't be opened.")
  }
  store.removePersistentDomain(forName: suite)
  for (key, value) in remembered {
    store.set(value, forKey: key)
  }
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "WritingListTests-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  let writingStore = FileWritingStore(directory: directory)
  for writing in writings {
    do {
      try writingStore.save(writing)
    } catch {
      preconditionFailure("A writing can't be saved to \(directory): \(error)")
    }
  }
  assertSnapshot(
    of: RootView(store: writingStore, path: path).defaultAppStorage(store)
      .frame(width: 402, height: 874).background(Color(.systemBackground)),
    as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
    testName: testName)
}

/// The sample list on a 402-wide screen, as tall as it needs to be.
private func assertList(
  _ size: DynamicTypeSize,
  _ colorScheme: ColorScheme,
  _ order: WritingListOrder = .newestFirst,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  assertSnapshot(
    of: WritingListPage(
      rows: WritingRow.samples(now: now, calendar: calendar), now: now, order: .constant(order),
      width: 402
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
