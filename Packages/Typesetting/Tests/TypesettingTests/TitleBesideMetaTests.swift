import CoreGraphics
import Testing
import Typesetting

struct TitleBesideMetaTests {
  @Test(arguments: [
    // (row width, meta width, title columns)
    (355.5, 126.0, 15),
    (341.3, 126.0, 14),
    // A room of exactly 10 title characters after the meta and the gap: 126 + 12.8 + 142.22.
    (281.02, 126.0, 10),
    // About 10.7 characters of room round down to 10.
    (291.0, 126.0, 10),
    // No room at all still leaves one character.
    (100.0, 126.0, 1),
  ])
  func titleColumnIsAWholeNumberOfTitleCharacters(
    _ rowWidth: CGFloat, _ metaWidth: CGFloat, _ columns: Int
  ) {
    let row = TitleBesideMeta(titleCharSize: 14.222, minimumGap: 12.8)
    let width = row.titleWidth(rowWidth: rowWidth, metaWidth: metaWidth)
    #expect(abs(width - 14.222 * CGFloat(columns)) < 0.001)
  }
}
