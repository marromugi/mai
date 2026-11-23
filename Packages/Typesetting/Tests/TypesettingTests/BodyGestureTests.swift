import CoreGraphics
import Testing
import Typesetting

struct BodyGestureTests {
  private let standard = BodySetting.standard

  @Test(arguments: [
    (CGPoint(x: 100, y: 0), GestureAxis?.some(.horizontal)),
    (CGPoint(x: -100, y: 0), .horizontal),
    (CGPoint(x: 100, y: 69), .horizontal),
    (CGPoint(x: 100, y: 71), nil),
    (CGPoint(x: 100, y: 100), nil),
    (CGPoint(x: 100, y: -142), nil),
    (CGPoint(x: 100, y: 144), .vertical),
    (CGPoint(x: 0, y: -100), .vertical),
    (CGPoint.zero, nil),
  ])
  func axisFollowsTheAngleWithADiagonalDeadBand(_ end: CGPoint, _ axis: GestureAxis?) {
    #expect(GestureAxis(from: .zero, to: end) == axis)
  }

  @Test(arguments: BodyAdjustment.allCases)
  func movingStepsAndStopsAtTheEnds(_ adjustment: BodyAdjustment) {
    let start = standard[adjustment]
    #expect(standard.moving(adjustment, by: 1)[adjustment] == start + adjustment.step)
    #expect(standard.moving(adjustment, by: -2)[adjustment] == start - 2 * adjustment.step)
    #expect(standard.moving(adjustment, by: 1000)[adjustment] == adjustment.range.upperBound)
    #expect(standard.moving(adjustment, by: -1000)[adjustment] == adjustment.range.lowerBound)
  }

  @Test(arguments: BodyAdjustment.allCases)
  func movingLeavesTheOtherValuesAlone(_ adjustment: BodyAdjustment) {
    let moved = standard.moving(adjustment, by: 3)
    for other in BodyAdjustment.allCases where other != adjustment {
      #expect(moved[other] == standard[other], "\(other)")
    }
  }

  @Test(arguments: BodyAdjustment.allCases)
  func aStepTakesItsPointsPerStep(_ adjustment: BodyAdjustment) {
    var run = SteppedAdjustment(adjustment, from: standard)
    let points = adjustment.pointsPerStep
    run.move(to: points - 0.5)
    #expect(run.setting == standard)
    run.move(to: points)
    #expect(run.setting[adjustment] == standard[adjustment] + adjustment.step)
    run.move(to: 2 * points)
    #expect(run.setting[adjustment] == standard[adjustment] + 2 * adjustment.step)
    run.move(to: -points)
    #expect(run.setting[adjustment] == standard[adjustment] - adjustment.step)
    run.move(to: 0)
    #expect(run.setting == standard)
  }

  @Test(arguments: [
    (BodyAdjustment.base, 20 as CGFloat, 17),
    (.lineHeight, 32, 32),
    (.tracking, 10, 10),
  ])
  func eachValueStepsAsThePRSays(_ adjustment: BodyAdjustment, _ points: CGFloat, _ oneUp: Int) {
    var run = SteppedAdjustment(adjustment, from: standard)
    run.move(to: points - 0.1)
    run.move(to: -(points - 0.1))
    #expect(run.setting == standard)
    run.move(to: points)
    #expect(run.setting[adjustment] == oneUp)
  }

  @Test(arguments: BodyAdjustment.allCases)
  func aPartStepCarriesOver(_ adjustment: BodyAdjustment) {
    var run = SteppedAdjustment(adjustment, from: standard)
    let points = adjustment.pointsPerStep
    run.move(to: 1.5 * points)
    run.move(to: 2 * points)
    #expect(run.setting == standard.moving(adjustment, by: 2))
  }

  @Test func aMoveFromOneEndPastTheOtherStepsBackAtOnce() {
    guard let low = BodySetting(base: 16, lineHeight: 28, tracking: -50) else {
      preconditionFailure("The test's body setting is out of range.")
    }
    var run = SteppedAdjustment(.tracking, from: low)
    run.move(to: 300)
    #expect(run.setting.tracking == 200)
    run.move(to: 290)
    #expect(run.setting.tracking == 190)
  }

  @Test func atAnEndMovingBackStepsBackAtOnce() {
    var run = SteppedAdjustment(.lineHeight, from: standard)
    let points = BodyAdjustment.lineHeight.pointsPerStep
    run.move(to: 100 * points)
    #expect(run.setting.lineHeight == BodySetting.lineHeights.upperBound)
    run.move(to: 99 * points)
    #expect(run.setting.lineHeight == BodySetting.lineHeights.upperBound - 4)
  }

  @Test func everyRunStaysInRangeOnStepAndOnItsOwnValue() {
    var random = SplitMix64(seed: 22)
    for adjustment in BodyAdjustment.allCases {
      var run = SteppedAdjustment(adjustment, from: standard)
      for _ in 0..<2000 {
        run.move(to: CGFloat(random.next() % 4001) - 2000)
        let value = run.setting[adjustment]
        #expect(adjustment.range.contains(value))
        #expect(value % adjustment.step == 0)
        for other in BodyAdjustment.allCases where other != adjustment {
          #expect(run.setting[other] == standard[other])
        }
      }
    }
  }

  @Test func aVerticalPinchMovesTheLineHeight() {
    guard var pinch = BodyPinch(CGPoint(x: 200, y: 300), CGPoint(x: 210, y: 400), from: standard)
    else {
      Issue.record("Fingers one above the other start no pinch.")
      return
    }
    #expect(pinch.axis == .vertical)
    pinch.move(CGPoint(x: 200, y: 268), CGPoint(x: 210, y: 400))
    #expect(pinch.setting == standard.moving(.lineHeight, by: 1))
    pinch.move(CGPoint(x: 300, y: 300), CGPoint(x: 0, y: 336))
    #expect(pinch.setting == standard.moving(.lineHeight, by: -2))
  }

  @Test func aVerticalPinchWhoseSecondFingerStartsAboveCountsTheSame() {
    guard var pinch = BodyPinch(CGPoint(x: 210, y: 400), CGPoint(x: 200, y: 300), from: standard)
    else {
      Issue.record("Fingers one above the other start no pinch.")
      return
    }
    pinch.move(CGPoint(x: 210, y: 400), CGPoint(x: 200, y: 268))
    #expect(pinch.setting == standard.moving(.lineHeight, by: 1))
  }

  @Test func aHorizontalPinchMovesTheTracking() {
    guard var pinch = BodyPinch(CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 220), from: standard)
    else {
      Issue.record("Fingers side by side start no pinch.")
      return
    }
    #expect(pinch.axis == .horizontal)
    pinch.move(CGPoint(x: 330, y: 200), CGPoint(x: 100, y: 500))
    #expect(pinch.setting == standard.moving(.tracking, by: 3))
  }

  @Test func fingersThatPassEachOtherKeepLoweringTheValue() {
    guard var pinch = BodyPinch(CGPoint(x: 100, y: 400), CGPoint(x: 100, y: 500), from: standard)
    else {
      Issue.record("Fingers one above the other start no pinch.")
      return
    }
    var seen: [Int] = []
    for y in stride(from: 400.0, through: 600.0, by: 10) {
      pinch.move(CGPoint(x: 100, y: y), CGPoint(x: 100, y: 500))
      seen.append(pinch.setting.lineHeight)
    }
    #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 >= $1 })
    #expect(seen.last == BodySetting.lineHeights.lowerBound)
  }

  @Test(arguments: [CGFloat.nan, .infinity, -.infinity])
  func aMovementThatIsNotFiniteIsNoMovement(_ movement: CGFloat) {
    var run = SteppedAdjustment(.base, from: standard)
    run.move(to: 40)
    run.move(to: movement)
    #expect(run.setting == standard.moving(.base, by: 2))
  }

  @Test(arguments: [CGFloat(1e19), -1e300, .greatestFiniteMagnitude])
  func aMovementTooLargeForIntStopsAtAnEnd(_ movement: CGFloat) {
    var run = SteppedAdjustment(.tracking, from: standard)
    run.move(to: movement)
    let range = BodySetting.trackings
    #expect(run.setting.tracking == (movement > 0 ? range.upperBound : range.lowerBound))
  }

  @Test(arguments: [Int.max, Int.min])
  func movingByAnyCountStopsAtAnEnd(_ steps: Int) {
    let moved = standard.moving(.tracking, by: steps)
    let range = BodySetting.trackings
    #expect(moved.tracking == (steps > 0 ? range.upperBound : range.lowerBound))
  }

  @Test(arguments: BodyAdjustment.allCases)
  func takingOneValueKeepsTheRest(_ adjustment: BodyAdjustment) {
    guard let other = BodySetting(base: 20, lineHeight: 40, tracking: 100) else {
      preconditionFailure("The test's body setting is out of range.")
    }
    let taken = standard.taking(adjustment, from: other)
    for each in BodyAdjustment.allCases {
      #expect(taken[each] == (each == adjustment ? other : standard)[each], "\(each)")
    }
  }

  /// To a value on its step, to one off it (whole steps only, toward the value), and past each end.
  @Test(arguments: [
    (BodyAdjustment.base, 20, 20), (.base, 30, 24), (.base, 0, 12),
    (.lineHeight, 36, 36), (.lineHeight, 35, 32), (.lineHeight, 17, 20), (.lineHeight, 100, 44),
    (.tracking, -50, -50), (.tracking, 15, 10), (.tracking, -15, -10), (.tracking, 999, 200),
    (.base, Int.max, 24), (.lineHeight, Int.min, 16), (.tracking, Int.min, -50),
  ])
  func movingToAValueKeepsTheRest(_ adjustment: BodyAdjustment, _ value: Int, _ expected: Int) {
    let moved = standard.moving(adjustment, to: value)
    for each in BodyAdjustment.allCases {
      #expect(moved[each] == (each == adjustment ? expected : standard[each]), "\(each)")
    }
  }

  /// From the far end, so the distance to `Int.max` or `Int.min` would overflow unclamped.
  @Test func movingToAnyValueFromAnEndStopsAtTheOther() throws {
    let low = try #require(BodySetting(base: 12, lineHeight: 16, tracking: -50))
    let high = try #require(BodySetting(base: 24, lineHeight: 44, tracking: 200))
    for adjustment in BodyAdjustment.allCases {
      #expect(low.moving(adjustment, to: .max)[adjustment] == adjustment.range.upperBound)
      #expect(high.moving(adjustment, to: .min)[adjustment] == adjustment.range.lowerBound)
    }
  }

  @Test func aDiagonalPinchStartsNothing() {
    #expect(BodyPinch(CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 200), from: standard) == nil)
  }

  @Test func aDragUpRaisesTheBaseFromWhereTheFingerTouchedDown() {
    guard var drag = BodyDrag(translation: CGPoint(x: 0, y: -20), from: standard) else {
      Issue.record("A drag up starts no drag.")
      return
    }
    #expect(drag.setting == standard.moving(.base, by: 1))
    drag.move(translation: CGPoint(x: 80, y: 60))
    #expect(drag.setting == standard.moving(.base, by: -3))
  }

  @Test(arguments: [CGPoint(x: 20, y: 0), CGPoint(x: -15, y: 15)])
  func aDragThatStartsSidewaysOrDiagonalStartsNothing(_ translation: CGPoint) {
    #expect(BodyDrag(translation: translation, from: standard) == nil)
  }
}

/// A seeded generator, so a failing run repeats.
private struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
