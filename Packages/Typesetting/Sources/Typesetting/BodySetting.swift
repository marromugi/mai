import CoreGraphics

/// How the writer sets the body text of one document, or of every document not yet set.
/// `base` moves every role's size together; `lineHeight` and `tracking` apply to the body alone.
public struct BodySetting: Hashable, Sendable {
  /// The `16` of the size series 16 × 8 / n, in half points.
  public static let baseHalfPoints: ClosedRange<Int> = 24...48
  /// The body line height at the default size and base 16, in points on the line grid.
  public static let lineHeights: ClosedRange<Int> = 16...44
  public static let lineHeightStep = Int(TypeScale.lineGrid)
  /// In thousandths of an em.
  public static let trackings: ClosedRange<Int> = -50...200
  public static let trackingStep = 10

  public static let standard = BodySetting(
    validBaseHalfPoints: 32,
    lineHeight: Int(TypeScale.onLineGrid(TypeScale.standardSize(.body) * TextRole.body.leading)),
    tracking: 0)

  public let baseHalfPoints: Int
  public let lineHeight: Int
  public let tracking: Int

  /// In points.
  public var base: CGFloat { CGFloat(baseHalfPoints) / 2 }

  /// `base` is in points. Nil when a value is outside its range or off its step.
  public init?(base: CGFloat, lineHeight: Int, tracking: Int) {
    let halfPoints = base * 2
    guard
      (CGFloat(Self.baseHalfPoints.lowerBound)...CGFloat(Self.baseHalfPoints.upperBound))
        .contains(halfPoints),
      halfPoints == halfPoints.rounded()
    else { return nil }
    self.init(baseHalfPoints: Int(halfPoints), lineHeight: lineHeight, tracking: tracking)
  }

  /// Nil when a value is outside its range or off its step.
  init?(baseHalfPoints: Int, lineHeight: Int, tracking: Int) {
    guard Self.baseHalfPoints.contains(baseHalfPoints),
      Self.lineHeights.contains(lineHeight), lineHeight % Self.lineHeightStep == 0,
      Self.trackings.contains(tracking), tracking % Self.trackingStep == 0
    else { return nil }
    self.init(validBaseHalfPoints: baseHalfPoints, lineHeight: lineHeight, tracking: tracking)
  }

  private init(validBaseHalfPoints baseHalfPoints: Int, lineHeight: Int, tracking: Int) {
    self.baseHalfPoints = baseHalfPoints
    self.lineHeight = lineHeight
    self.tracking = tracking
  }
}
