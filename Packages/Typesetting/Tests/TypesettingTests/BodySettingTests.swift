import CoreGraphics
import Testing
import Typesetting

struct BodySettingTests {
  @Test func standardKeepsTheTokensAsTheyWere() {
    let standard = BodySetting.standard
    #expect((standard.base, standard.lineHeight, standard.tracking) == (16, 28, 0))
  }

  @Test(arguments: [
    (12, 16, -50),
    (24, 44, 200),
    (16, 28, 0),
  ])
  func acceptsValuesInRangeAndOnStep(_ base: Int, _ lineHeight: Int, _ tracking: Int) {
    #expect(BodySetting(base: base, lineHeight: lineHeight, tracking: tracking) != nil)
  }

  @Test(arguments: [
    (11, 28, 0),
    (25, 28, 0),
    (16, 12, 0),
    (16, 48, 0),
    (16, 30, 0),
    (16, 28, -60),
    (16, 28, 210),
    (16, 28, 15),
  ])
  func rejectsValuesOutOfRangeOrOffStep(_ base: Int, _ lineHeight: Int, _ tracking: Int) {
    #expect(BodySetting(base: base, lineHeight: lineHeight, tracking: tracking) == nil)
  }

  private func scale(base: Int = 16, lineHeight: Int = 28, tracking: Int = 0) -> TypeScale {
    guard let body = BodySetting(base: base, lineHeight: lineHeight, tracking: tracking) else {
      preconditionFailure("The test's body setting is out of range.")
    }
    return TypeScale(factor: 1, body: body)
  }

  @Test(arguments: [12, 20, 24])
  func baseScalesEveryLengthTogether(_ base: Int) {
    let scaled = scale(base: base)
    let standard = TypeScale.standard
    let ratio = CGFloat(base) / 16
    var ratios: [CGFloat] = [scaled.ruleOverhang / standard.ruleOverhang]
    for role in TextRole.allCases {
      ratios.append(scaled.size(role) / standard.size(role))
      ratios.append(scaled.lineHeight(role) / standard.lineHeight(role))
    }
    for spacing in Spacing.allCases {
      ratios.append(scaled.space(spacing) / standard.space(spacing))
    }
    #expect(ratios.allSatisfy { abs($0 - ratio) < 0.000_001 })
  }

  @Test func baseMultipliesTheDynamicTypeFactor() {
    guard let body = BodySetting(base: 20, lineHeight: 28, tracking: 0) else {
      preconditionFailure("The test's body setting is out of range.")
    }
    let size = TypeScale(factor: 1.5, body: body).size(.body)
    #expect(abs(size - TypeScale.standard.size(.body) * 1.5 * 20 / 16) < 0.000_001)
  }

  @Test func lineHeightSetsTheBodyAlone() {
    let scaled = scale(lineHeight: 40)
    #expect(scaled.lineHeight(.body) == 40)
    for role in TextRole.allCases where role != .body {
      #expect(scaled.lineHeight(role) == TypeScale.standard.lineHeight(role), "\(role)")
    }
  }

  @Test func trackingSetsTheBodyAlone() {
    let scaled = scale(base: 20, tracking: 100)
    #expect(abs(scaled.tracking(.body) - scaled.size(.body) / 10) < 0.000_001)
    for role in TextRole.allCases where role != .body {
      #expect(scaled.tracking(role) == 0, "\(role)")
      #expect(scaled.chars(1, of: role) == scaled.size(role), "\(role)")
    }
  }

  @Test(arguments: [-50, 0, 100, 200])
  func typeAreaCountsTrackedCharacters(_ tracking: Int) {
    let scaled = scale(tracking: tracking)
    let size = scaled.size(.body)
    let trackingWidth = size * CGFloat(tracking) / 1000
    for columns in [1, 21, 25] {
      let line = CGFloat(columns) * (size + trackingWidth) - max(trackingWidth, 0)
      let area = scaled.typeArea(width: 40 + line)
      #expect(area.columns == columns, "\(tracking) \(columns)")
      #expect(abs(area.margin - 20) < 0.000_001, "\(tracking) \(columns)")
    }
  }

  @Test func typeAreaStopsATrackingThatLeavesNoWidth() async {
    await #expect(processExitsWith: .failure) {
      _ = TypeArea(width: 390, charSize: 14, tracking: -20)
    }
  }
}
