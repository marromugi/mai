import CoreGraphics

/// One value of a body setting that a typesetting gesture or a settings stepper moves.
public enum BodyAdjustment: CaseIterable, Sendable {
  case base, lineHeight, tracking

  public var range: ClosedRange<Int> {
    switch self {
    case .base: BodySetting.bases
    case .lineHeight: BodySetting.lineHeights
    case .tracking: BodySetting.trackings
    }
  }

  public var step: Int {
    switch self {
    case .base: 1
    case .lineHeight: BodySetting.lineHeightStep
    case .tracking: BodySetting.trackingStep
    }
  }

  /// How many steps the range holds from end to end.
  public var steps: Int { (range.upperBound - range.lowerBound) / step }

  /// How far the fingers move, in points, for one step.
  public var pointsPerStep: CGFloat {
    switch self {
    case .base: 20
    case .lineHeight: 32
    case .tracking: 10
    }
  }
}

extension BodySetting {
  public subscript(adjustment: BodyAdjustment) -> Int {
    switch adjustment {
    case .base: base
    case .lineHeight: lineHeight
    case .tracking: tracking
    }
  }

  /// This setting with `other`'s value for `adjustment`, and its own for the rest.
  public func taking(_ adjustment: BodyAdjustment, from other: BodySetting) -> BodySetting {
    moving(adjustment, by: (other[adjustment] - self[adjustment]) / adjustment.step)
  }

  /// Moved by `steps` of the adjustment's step, stopping at the ends of its range.
  public func moving(_ adjustment: BodyAdjustment, by steps: Int) -> BodySetting {
    let range = adjustment.range
    let span = adjustment.steps
    let value = min(
      max(self[adjustment] + min(max(steps, -span), span) * adjustment.step, range.lowerBound),
      range.upperBound)
    let moved =
      switch adjustment {
      case .base: BodySetting(base: value, lineHeight: lineHeight, tracking: tracking)
      case .lineHeight: BodySetting(base: base, lineHeight: value, tracking: tracking)
      case .tracking: BodySetting(base: base, lineHeight: lineHeight, tracking: value)
      }
    guard let moved else {
      preconditionFailure("\(adjustment) \(value) is off its step: the range's ends are on it.")
    }
    return moved
  }
}

/// The axis a pair of points lies along, measured by the angle from the horizontal.
public enum GestureAxis: Sendable {
  case horizontal, vertical

  /// Angles from the horizontal, in degrees, that lie along neither axis.
  public static let diagonal: ClosedRange<CGFloat> = 35...55

  /// Nil when the points are the same or lie within `diagonal`.
  public init?(from start: CGPoint, to end: CGPoint) {
    let dx = abs(end.x - start.x)
    let dy = abs(end.y - start.y)
    guard dx > 0 || dy > 0 else { return nil }
    let degrees = atan2(dy, dx) * 180 / .pi
    if degrees < Self.diagonal.lowerBound {
      self = .horizontal
    } else if degrees > Self.diagonal.upperBound {
      self = .vertical
    } else {
      return nil
    }
  }

  func length(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
    switch self {
    case .horizontal: x
    case .vertical: y
    }
  }
}

/// One gesture's run of steps on one value: the finger movement since the gesture started picks
/// the steps, and at an end of the range the count starts again from where the finger is, so
/// moving back steps back at once.
public struct SteppedAdjustment: Equatable, Sendable {
  public let adjustment: BodyAdjustment
  public private(set) var setting: BodySetting
  /// The movement at which `setting` was reached.
  private var anchor: CGFloat = 0

  public init(_ adjustment: BodyAdjustment, from setting: BodySetting) {
    self.adjustment = adjustment
    self.setting = setting
  }

  /// `movement` is in points from where the gesture started; a positive one raises the value.
  /// A movement that is not finite is no movement.
  public mutating func move(to movement: CGFloat) {
    guard movement.isFinite else { return }
    // A count past the range's own steps reaches its end either way, so it is cut there before
    // it can overflow `Int`.
    let span = CGFloat(adjustment.steps)
    let exact = ((movement - anchor) / adjustment.pointsPerStep).rounded(.towardZero)
    let steps = Int(min(max(exact, -span - 1), span + 1))
    guard steps != 0 else { return }
    let moved = setting.moving(adjustment, by: steps)
    let taken = (moved[adjustment] - setting[adjustment]) / adjustment.step
    anchor = taken == steps ? anchor + CGFloat(steps) * adjustment.pointsPerStep : movement
    setting = moved
  }
}

/// A two-finger pinch: fingers that start one above the other move the line height, side by
/// side the tracking. Spreading them apart along that axis raises the value. The spread keeps
/// the sign it starts with, so fingers that pass each other keep lowering the value.
public struct BodyPinch: Equatable, Sendable {
  public let axis: GestureAxis
  /// 1 or -1: which way along the axis the second finger starts from the first.
  private let direction: CGFloat
  private let startSpread: CGFloat
  public private(set) var adjustment: SteppedAdjustment

  /// `first` and `second` are the same two fingers in every call. Nil when they start diagonal
  /// to each other, or at the same point.
  public init?(_ first: CGPoint, _ second: CGPoint, from setting: BodySetting) {
    guard let axis = GestureAxis(from: first, to: second) else { return nil }
    self.axis = axis
    direction = axis.length(second.x - first.x, second.y - first.y) < 0 ? -1 : 1
    startSpread = axis.length(abs(second.x - first.x), abs(second.y - first.y))
    adjustment = SteppedAdjustment(axis == .vertical ? .lineHeight : .tracking, from: setting)
  }

  public var setting: BodySetting { adjustment.setting }

  public mutating func move(_ first: CGPoint, _ second: CGPoint) {
    let spread = axis.length(second.x - first.x, second.y - first.y) * direction
    adjustment.move(to: spread - startSpread)
  }
}

/// A one-finger drag up or down that moves the base. Dragging up raises it.
public struct BodyDrag: Equatable, Sendable {
  public private(set) var adjustment: SteppedAdjustment

  /// `translation` is how far the finger has moved since it touched down, when the drag is
  /// recognized. Nil when that movement is not vertical.
  public init?(translation: CGPoint, from setting: BodySetting) {
    guard GestureAxis(from: .zero, to: translation) == .vertical else { return nil }
    adjustment = SteppedAdjustment(.base, from: setting)
    move(translation: translation)
  }

  public var setting: BodySetting { adjustment.setting }

  public mutating func move(translation: CGPoint) {
    adjustment.move(to: -translation.y)
  }
}
