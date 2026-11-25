import CoreGraphics

/// Where one text view moves a title line and the body lines `gap` below it, so each lands where
/// its own `Text` would. Each line goes `titleOffset` or `bodyOffset` below where the text view
/// would put it, and the text view sets lines on whole pixels of itself: so the body starts on one
/// there and the view is moved by the rest of the body's offset, `viewOffset`; the title is moved
/// down from there by `titleInset`, within a pixel of its offset.
public struct TitleAndBodyLines: Equatable, Sendable {
  public let titleOffset: CGFloat
  public let bodyOffset: CGFloat
  public let gap: CGFloat
  /// A pixel's size, in points.
  public let pixel: CGFloat

  public init(titleOffset: CGFloat, bodyOffset: CGFloat, gap: CGFloat, pixel: CGFloat) {
    self.titleOffset = titleOffset
    self.bodyOffset = bodyOffset
    self.gap = gap
    self.pixel = pixel
  }

  /// At or above both offsets, and a whole number of pixels above the body's.
  public var viewOffset: CGFloat {
    let higher = min(titleOffset, bodyOffset)
    return bodyOffset - ((bodyOffset - higher) / pixel).rounded(.up) * pixel
  }

  public var titleInset: CGFloat {
    ((titleOffset - viewOffset) / pixel).rounded() * pixel
  }

  /// How much taller than the title's and the body's lines `gap` apart the text view is: the
  /// body's move down.
  public var excess: CGFloat {
    bodyOffset - viewOffset
  }

  /// The space below a title `height` tall that sets the body's lines where they fall `gap` below
  /// the title's, on the pixel a view placed there starts on.
  public func spacing(belowTitleOf height: CGFloat) -> CGFloat {
    let apart = ((height + gap) / pixel).rounded(.up) * pixel
    return apart - height + excess - titleInset
  }
}
