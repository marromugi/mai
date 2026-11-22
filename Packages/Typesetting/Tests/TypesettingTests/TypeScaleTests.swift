import CoreGraphics
import Testing
import Typesetting

struct TypeScaleTests {
  @Test(arguments: [
    (TextRole.display, 32.0),
    (.heading, 21.333),
    (.title, 14.222),
    (.body, 14.222),
    (.meta, 12.8),
    (.caption, 11.636),
  ])
  func size(_ role: TextRole, _ expected: CGFloat) {
    #expect(abs(TypeScale.standard.size(role) - expected) < 0.001)
  }

  @Test(arguments: [
    (TextRole.display, 44.0),
    (.heading, 32),
    (.title, 24),
    (.body, 28),
    (.meta, 20),
    (.caption, 20),
  ])
  func lineHeight(_ role: TextRole, _ expected: CGFloat) {
    #expect(TypeScale.standard.lineHeight(role) == expected)
  }

  @Test func spacing() {
    #expect(Spacing.allCases.map(TypeScale.standard.space) == [8, 16, 24, 40, 64, 104])
  }

  @Test func charsAreTheSizeOfTheTextBeside() {
    #expect(TypeScale.standard.chars(1, of: .meta) == 12.8)
    #expect(abs(TypeScale.standard.chars(2, of: .title) - 28.444) < 0.001)
  }

  @Test func ruleOverhang() {
    #expect(TypeScale.standard.ruleOverhang == 4)
  }

  @Test(arguments: [
    (390.0, 24, 24.333),
    (402, 25, 23.222),
    (440, 28, 20.889),
  ])
  func typeArea(_ width: CGFloat, _ columns: Int, _ margin: CGFloat) {
    let area = TypeScale.standard.typeArea(width: width)
    #expect(area.columns == columns)
    #expect(abs(area.margin - margin) < 0.001)
  }

  /// The factors at the default size, at xxLarge, and at the largest accessibility size.
  @Test(arguments: [1, 3, 25, 28, 60])
  func typeAreaFitsAWidthOfWholeCharactersExactly(_ columns: Int) {
    for factor in [1, 21.0 / 17, 53.0 / 17] {
      let charSize = TypeScale(factor: factor).size(.body)
      let area = TypeArea(width: 40 + CGFloat(columns) * charSize, charSize: charSize)
      #expect(area.columns == columns, "\(factor)")
      #expect(abs(area.margin - 20) < 0.000_001, "\(factor)")
    }
  }

  @Test func typeAreaKeepsOneColumnWhenNothingFits() {
    #expect(TypeArea(width: 0, charSize: 14).columns == 1)
  }

  @Test(arguments: [1, 21.0 / 17, 23.0 / 17, 53.0 / 17])
  func everyLengthScalesByOneFactor(_ factor: CGFloat) {
    let scaled = TypeScale(factor: factor)
    let standard = TypeScale.standard
    var ratios: [CGFloat] = [scaled.ruleOverhang / standard.ruleOverhang]
    for role in TextRole.allCases {
      ratios.append(scaled.size(role) / standard.size(role))
      ratios.append(scaled.lineHeight(role) / standard.lineHeight(role))
      ratios.append(scaled.chars(1, of: role) / standard.chars(1, of: role))
    }
    for spacing in Spacing.allCases {
      ratios.append(scaled.space(spacing) / standard.space(spacing))
    }
    #expect(ratios.allSatisfy { abs($0 - factor) < 0.000_001 })
    #expect(abs(scaled.lineHeight(.body) / scaled.size(.body) - 28 / (128.0 / 9)) < 0.000_001)
  }

  @Test func typeAreaIsRecomputedAtTheLargestSize() {
    let area = TypeScale(factor: 53.0 / 17).typeArea(width: 402)
    #expect(area.columns == 8)
    #expect(abs(area.margin - 23.640) < 0.001)
  }
}
