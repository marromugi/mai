import CoreGraphics

/// The parts text plays, each set at one step n of the harmonic series base × 8 / n,
/// where the base is `BodySetting.base`, 16 by default.
public enum TextRole: CaseIterable, Sendable {
  case display
  case heading
  case title
  case body
  case meta
  case caption

  public var step: Int {
    switch self {
    case .display: 4
    case .heading: 6
    case .title, .body: 9
    case .meta: 10
    case .caption: 11
    }
  }

  /// The line height as a multiple of the size, before it is rounded up to the line grid.
  /// The body's is only where `BodySetting.standard` takes its line height from.
  public var leading: CGFloat {
    switch self {
    case .display: 1.3
    case .heading: 1.4
    case .title: 1.6
    case .body: 1.75
    case .meta, .caption: 1.4
    }
  }
}
