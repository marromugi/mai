import SwiftUI
import Testing
import Typesetting

@testable import Features

struct TypeScaleTests {
  @Test(arguments: [
    (TextRole.display, "SourceHanSansJP-Bold"),
    (.heading, "SourceHanSansJP-Bold"),
    (.title, "SourceHanSansJP-Bold"),
    (.body, "SourceHanSansJP-Regular"),
    (.meta, "SourceHanSansJP-Regular"),
    (.caption, "SourceHanSansJP-Regular"),
  ])
  func font(_ role: TextRole, _ postScriptName: String) {
    let font = TypeScale.standard.font(role, in: FontStack.standard.families())
    #expect(font.fontName == postScriptName)
    #expect(font.pointSize == TypeScale.standard.size(role))
  }

  @Test(arguments: [1, 3, 25, 28, 60])
  func typeAreaFitsAWidthOfWholeCharactersExactly(_ columns: Int) {
    for size in [DynamicTypeSize.large, .xxLarge, .accessibility5] {
      let charSize = TypeScale(size, body: .standard).size(.body)
      let area = TypeArea(width: 40 + CGFloat(columns) * charSize, charSize: charSize)
      #expect(area.columns == columns, "\(size)")
      #expect(abs(area.margin - 20) < 0.000_001, "\(size)")
    }
  }

  @Test(arguments: [
    (DynamicTypeSize.xSmall, 1.0),
    (.medium, 1),
    (.large, 1),
    (.xxLarge, 21.0 / 17),
    (.xxxLarge, 23.0 / 17),
    (.accessibility5, 53.0 / 17),
  ])
  func factorFollowsTheSystemBodySize(_ size: DynamicTypeSize, _ factor: CGFloat) {
    #expect(abs(TypeScale(size, body: .standard).factor - factor) < 0.0001)
  }

  @Test(arguments: DynamicTypeSize.allCases)
  func everyLengthScalesByOneFactor(_ size: DynamicTypeSize) throws {
    let scaled = TypeScale(size, body: .standard)
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
    let first = try #require(ratios.first)
    #expect(ratios.allSatisfy { abs($0 - first) < 0.000_001 })
    #expect(abs(scaled.lineHeight(.body) / scaled.size(.body) - 28 / (128.0 / 9)) < 0.000_001)
  }

  @Test func typeAreaIsRecomputedAtTheLargestSize() {
    let area = TypeScale(.accessibility5, body: .standard).typeArea(width: 402)
    #expect(area.columns == 8)
    #expect(abs(area.margin - 23.640) < 0.001)
  }
}
