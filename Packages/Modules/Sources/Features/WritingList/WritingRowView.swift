import SwiftUI
internal import Typesetting

/// A writing's title, with its count and date on the title's first line at the trailing edge.
/// At accessibility sizes the count and date go under the title, which then takes the whole width,
/// and each on a line of its own when their columns don't fit across.
struct WritingRowView: View {
  let row: WritingRow
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @EnvironmentTypeScale private var scale

  var body: some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 0) {
        title.frame(maxWidth: .infinity, alignment: .leading)
        // The columns are the same width in every row, so every row makes the same choice.
        ViewThatFits(in: .horizontal) {
          MetaColumns(row: row).frame(maxWidth: .infinity, alignment: .trailing)
          VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: row.characterCountLabel)
            Text(verbatim: row.updated)
          }
          .metaStyle()
        }
      }
    } else {
      TitleBesideMetaLayout(
        titleCharSize: scale.size(.title), minimumGap: scale.chars(1, of: .meta)
      ) {
        title
        MetaColumns(row: row)
      }
    }
  }

  /// An untitled writing keeps its line: an ideographic space is one title line box tall.
  private var title: some View {
    Text(verbatim: row.title.isEmpty ? "\u{3000}" : row.title)
      .textStyle(.title)
  }
}

/// The count and the date, each in a column as wide as its widest expected value, so every row's
/// columns line up. A value wider than that reaches out to the leading side without moving them.
struct MetaColumns: View {
  let row: WritingRow
  @EnvironmentTypeScale private var scale

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: scale.chars(1, of: .meta)) {
      column(widest: ["00000文字"], value: row.characterCountLabel)
      column(widest: ["00か月前", "00週間前", "00時間前", "たった今"], value: row.updated)
    }
    .metaStyle()
  }

  private func column(widest: [String], value: String) -> some View {
    ZStack(alignment: .trailing) {
      ForEach(widest, id: \.self) { Text(verbatim: $0).hidden() }
    }
    .overlay(alignment: Alignment(horizontal: .trailing, vertical: .firstTextBaseline)) {
      Text(verbatim: value).fixedSize()
    }
  }
}

extension View {
  fileprivate func metaStyle() -> some View {
    textStyle(.meta)
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
