import CoreGraphics

/// The design tokens at one Dynamic Type size, for one body setting.
/// Every length is its value at the default size and the standard body setting times `scale`, so
/// their ratios hold at every size; the exceptions are the body's line height and tracking, which
/// the body setting chooses, and the type area, fitted again to the body's characters.
public struct TypeScale: Equatable, Sendable {
  /// The Dynamic Type factor.
  public let factor: CGFloat
  public let body: BodySetting

  public static let standard = TypeScale(factor: 1)

  static let lineGrid: CGFloat = 4

  public init(factor: CGFloat, body: BodySetting = .standard) {
    precondition(factor > 0, "A type scale factor must be positive, not \(factor).")
    self.factor = factor
    self.body = body
  }

  /// What every length is multiplied by: the Dynamic Type factor times the body setting's base.
  public var scale: CGFloat { factor * body.base / 16 }

  public func size(_ role: TextRole) -> CGFloat {
    Self.standardSize(role) * scale
  }

  /// The body's is the body setting's. Every other role's is size × leading, rounded up to the
  /// line grid at the default size; both are then scaled.
  public func lineHeight(_ role: TextRole) -> CGFloat {
    let standard =
      role == .body
      ? CGFloat(body.lineHeight) : Self.onLineGrid(Self.standardSize(role) * role.leading)
    return standard * scale
  }

  /// The space added after each character of `role`. Only the body is tracked.
  public func tracking(_ role: TextRole) -> CGFloat {
    role == .body ? size(.body) * CGFloat(body.tracking) / 1000 : 0
  }

  static func standardSize(_ role: TextRole) -> CGFloat {
    16 * 8 / CGFloat(role.step)
  }

  static func onLineGrid(_ length: CGFloat) -> CGFloat {
    (length / lineGrid).rounded(.up) * lineGrid
  }

  public func space(_ spacing: Spacing) -> CGFloat {
    8 * CGFloat(spacing.multiple) * scale
  }

  /// The width of `count` characters of `role` mid-line, tracking included.
  public func chars(_ count: CGFloat, of role: TextRole) -> CGFloat {
    (size(role) + tracking(role)) * count
  }

  /// How far a rule reaches past the text column on each side.
  public var ruleOverhang: CGFloat { 4 * scale }

  public func typeArea(width: CGFloat) -> TypeArea {
    TypeArea(width: width, charSize: size(.body), tracking: tracking(.body))
  }
}
