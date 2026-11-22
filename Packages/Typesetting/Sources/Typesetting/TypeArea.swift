import CoreGraphics

/// The type area: as many body characters as fit across the width with at least `minimumMargin`
/// on each side, and the rest split into the two side margins.
/// A line of n characters is n × (`charSize` + `tracking`) long, less `trailing`: as TextKit 2
/// sets `.tracking`, the last character's tracking is trailing whitespace when it is positive.
public struct TypeArea: Equatable, Sendable {
  public static let minimumMargin: CGFloat = 20

  public let width: CGFloat
  public let charSize: CGFloat
  public let tracking: CGFloat
  /// At least one, even when one character and the two minimum margins don't fit.
  public let columns: Int

  public init(width: CGFloat, charSize: CGFloat, tracking: CGFloat = 0) {
    precondition(charSize > 0, "A type area needs a positive character size, not \(charSize).")
    precondition(
      charSize + tracking > 0, "Tracking \(tracking) leaves a character of \(charSize) no width.")
    self.width = width
    self.charSize = charSize
    self.tracking = tracking
    // The slack keeps a width that fits n characters exactly from rounding down to n - 1.
    let fit = (width - Self.minimumMargin * 2 + max(tracking, 0)) / (charSize + tracking) + 1e-9
    columns = max(1, Int(fit.rounded(.down)))
  }

  /// The last character's tracking, when it hangs outside the line.
  public var trailing: CGFloat { max(tracking, 0) }
  public var lineLength: CGFloat { (charSize + tracking) * CGFloat(columns) - trailing }
  public var margin: CGFloat { (width - lineLength) / 2 }
}
