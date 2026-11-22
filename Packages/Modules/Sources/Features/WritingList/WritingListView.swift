import SwiftUI
internal import Typesetting

/// The writings, in the order given, under the page heading 「執筆」.
public struct WritingListView: View {
  private let rows: [WritingRow]
  private let open: (WritingRow) -> Void

  /// `open` is called with the row tapped.
  public init(rows: [WritingRow], open: @escaping (WritingRow) -> Void) {
    self.rows = rows
    self.open = open
  }

  public var body: some View {
    GeometryReader { proxy in
      ScrollView {
        WritingListPage(rows: rows, width: proxy.size.width, open: open)
      }
    }
  }
}

/// The list laid out across a screen `width` wide: text on the type area's margins, rules past them.
struct WritingListPage: View {
  let rows: [WritingRow]
  let width: CGFloat
  var open: (WritingRow) -> Void = { _ in }
  @EnvironmentTypeScale private var scale

  var body: some View {
    let area = scale.typeArea(width: width)
    VStack(alignment: .leading, spacing: 0) {
      Text("執筆")
        .textStyle(.heading)
        .padding(.bottom, scale.space(.m))
      ForEach(rows) { row in
        Button {
          open(row)
        } label: {
          WritingRowView(row: row)
            .padding(.vertical, scale.space(.s))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        DottedRule()
          .padding(.horizontal, -scale.ruleOverhang)
      }
    }
    .frame(width: area.lineLength, alignment: .leading)
    .padding(.horizontal, area.margin)
    .padding(.top, scale.space(.xl))
  }
}

private struct DottedRule: View {
  var body: some View {
    Line()
      .stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
      .frame(height: 1)
  }

  private struct Line: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
      Path { path in
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      }
    }
  }
}

#Preview {
  WritingListView(rows: WritingRow.samples) { _ in }
}
