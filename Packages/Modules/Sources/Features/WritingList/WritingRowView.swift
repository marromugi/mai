import SwiftUI
internal import Typesetting

/// A writing's title, with how long ago it was updated on the title's first line at the trailing
/// edge. At accessibility sizes that goes under the title, which then takes the whole width.
struct WritingRowView: View {
  let row: WritingRow
  let now: Date
  @Environment(\.calendar) private var calendar
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentTypeScale private var scale

  var body: some View {
    let updated = UpdatedColumn(label: row.updatedLabel(now: now, calendar: calendar))
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 0) {
        title.frame(maxWidth: .infinity, alignment: .leading)
        updated.frame(maxWidth: .infinity, alignment: .trailing)
      }
    } else {
      TitleBesideMetaLayout(
        titleCharSize: scale.size(.title), minimumGap: scale.chars(1, of: .meta)
      ) {
        title
        updated
      }
    }
  }

  /// An untitled writing keeps its line: an ideographic space is one title line box tall.
  private var title: some View {
    Text(verbatim: row.title.isEmpty ? "\u{3000}" : row.title)
      .textStyle(.title)
  }
}

/// How long ago a writing was updated, in a column as wide as the widest wording, so every row's
/// column lines up. A label wider than that reaches out to the leading side without moving it.
struct UpdatedColumn: View {
  let label: String

  var body: some View {
    ZStack(alignment: .trailing) {
      ForEach(["00か月前", "00週間前", "00時間前", "たった今"], id: \.self) {
        Text(verbatim: $0).hidden()
      }
    }
    .overlay(alignment: Alignment(horizontal: .trailing, vertical: .firstTextBaseline)) {
      Text(verbatim: label).fixedSize()
    }
    .textStyle(.meta)
    .foregroundStyle(.secondary)
  }
}

/// Lays out two subviews, a title and its meta, on the title's first baseline, with the widths
/// `TitleBesideMeta` gives. The meta sits at the trailing edge at its ideal size.
struct TitleBesideMetaLayout: Layout {
  private let widths: TitleBesideMeta

  init(titleCharSize: CGFloat, minimumGap: CGFloat) {
    widths = TitleBesideMeta(titleCharSize: titleCharSize, minimumGap: minimumGap)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = place(width: proposal.width, subviews: subviews)
    return CGSize(
      width: frames.width,
      height: max(frames.title.maxY, frames.meta.maxY))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let frames = place(width: bounds.width, subviews: subviews)
    let (title, meta) = parts(of: subviews)
    for (subview, frame) in [(title, frames.title), (meta, frames.meta)] {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  /// Without a width, the row is as wide as the whole title on one line beside the meta.
  private func place(width: CGFloat?, subviews: Subviews) -> (
    width: CGFloat, title: CGRect, meta: CGRect
  ) {
    let (title, meta) = parts(of: subviews)
    let metaSize = meta.sizeThatFits(.unspecified)
    let rowWidth =
      width ?? (title.sizeThatFits(.unspecified).width + widths.minimumGap + metaSize.width)
    let titleProposal = ProposedViewSize(
      width: widths.titleWidth(rowWidth: rowWidth, metaWidth: metaSize.width), height: nil)
    let titleSize = title.sizeThatFits(titleProposal)
    let titleBaseline = title.dimensions(in: titleProposal)[.firstTextBaseline]
    let metaBaseline = meta.dimensions(in: .unspecified)[.firstTextBaseline]
    let baseline = max(titleBaseline, metaBaseline)
    return (
      rowWidth,
      CGRect(origin: CGPoint(x: 0, y: baseline - titleBaseline), size: titleSize),
      CGRect(
        origin: CGPoint(x: rowWidth - metaSize.width, y: baseline - metaBaseline), size: metaSize)
    )
  }

  private func parts(of subviews: Subviews) -> (title: LayoutSubview, meta: LayoutSubview) {
    guard subviews.count == 2 else {
      preconditionFailure(
        "TitleBesideMetaLayout lays out a title and its meta, not \(subviews.count) views.")
    }
    return (subviews[0], subviews[1])
  }
}
