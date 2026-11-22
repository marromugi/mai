import CoreGraphics

/// The widths in a row that sets a title beside its meta, on the title's first line.
/// The title column is a whole number of `titleCharSize` wide, with at least `minimumGap` before
/// the meta; what is left goes into the gap.
public struct TitleBesideMeta: Equatable, Sendable {
  public let titleCharSize: CGFloat
  public let minimumGap: CGFloat

  public init(titleCharSize: CGFloat, minimumGap: CGFloat) {
    self.titleCharSize = titleCharSize
    self.minimumGap = minimumGap
  }

  /// At least one character, even when the meta leaves no room.
  public func titleWidth(rowWidth: CGFloat, metaWidth: CGFloat) -> CGFloat {
    // The slack keeps a room of exactly n characters from rounding down to n - 1.
    let fit = (rowWidth - metaWidth - minimumGap) / titleCharSize + 1e-9
    return max(1, fit.rounded(.down)) * titleCharSize
  }
}
