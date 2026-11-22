/// Vertical space: 8 × 1, 2, 3, 5, 8, 13.
public enum Spacing: CaseIterable, Sendable {
  case xs
  case s
  case m
  case l
  case xl
  case xxl

  public var multiple: Int {
    switch self {
    case .xs: 1
    case .s: 2
    case .m: 3
    case .l: 5
    case .xl: 8
    case .xxl: 13
    }
  }
}
