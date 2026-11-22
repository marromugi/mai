/// How the writer sets the body text of one document.
/// `base` moves every role's size together; `lineHeight` and `tracking` apply to the body alone.
public struct BodySetting: Equatable, Sendable {
  /// The `16` of the size series 16 × 8 / n.
  public static let bases: ClosedRange<Int> = 12...24
  /// The body line height at the default size and base 16, in points on the line grid.
  public static let lineHeights: ClosedRange<Int> = 16...44
  public static let lineHeightStep = Int(TypeScale.lineGrid)
  /// In thousandths of an em.
  public static let trackings: ClosedRange<Int> = -50...200
  public static let trackingStep = 10

  public static let standard = BodySetting(
    validBase: 16,
    lineHeight: Int(TypeScale.onLineGrid(TypeScale.standardSize(.body) * TextRole.body.leading)),
    tracking: 0)

  public let base: Int
  public let lineHeight: Int
  public let tracking: Int

  /// Nil when a value is outside its range or off its step.
  public init?(base: Int, lineHeight: Int, tracking: Int) {
    guard Self.bases.contains(base),
      Self.lineHeights.contains(lineHeight), lineHeight % Self.lineHeightStep == 0,
      Self.trackings.contains(tracking), tracking % Self.trackingStep == 0
    else { return nil }
    self.init(validBase: base, lineHeight: lineHeight, tracking: tracking)
  }

  private init(validBase base: Int, lineHeight: Int, tracking: Int) {
    self.base = base
    self.lineHeight = lineHeight
    self.tracking = tracking
  }
}
