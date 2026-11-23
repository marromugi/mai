import SwiftUI
internal import Typesetting

/// The writings under the page heading 「執筆」, in the order last chosen, newest first until one is.
public struct WritingListView: View {
  private let rows: [WritingRow]
  private let now: Date
  private let open: (WritingRow) -> Void
  @AppStorage("writingListOrder") private var order = WritingListOrder.newestFirst

  /// Each row says how long before `now` it was updated. `open` is called with the row tapped.
  public init(rows: [WritingRow], now: Date, open: @escaping (WritingRow) -> Void) {
    self.rows = rows
    self.now = now
    self.open = open
  }

  public var body: some View {
    GeometryReader { proxy in
      ScrollView {
        WritingListPage(
          rows: rows, now: now, order: $order, width: proxy.size.width, open: open)
      }
    }
  }
}

/// The list laid out across a screen `width` wide: text on the type area's margins, rules past them.
/// The control that chooses `order` sits under the heading.
struct WritingListPage: View {
  let rows: [WritingRow]
  let now: Date
  @Binding var order: WritingListOrder
  let width: CGFloat
  var open: (WritingRow) -> Void = { _ in }
  @EnvironmentTypeScale private var scale

  var body: some View {
    let area = scale.typeArea(width: width)
    VStack(alignment: .leading, spacing: 0) {
      Text("執筆")
        .textStyle(.heading)
        .padding(.bottom, scale.space(.s))
      OrderMenu(order: $order)
      ForEach(rows.sorted(order)) { row in
        Button {
          open(row)
        } label: {
          WritingRowView(row: row, now: now)
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

/// The chosen order, opening a menu of every order with the chosen one checked.
private struct OrderMenu: View {
  @Binding var order: WritingListOrder

  var body: some View {
    Menu {
      Picker("並べ替え", selection: $order) {
        ForEach(WritingListOrder.allCases) { Text(verbatim: $0.title) }
      }
    } label: {
      ButtonLabel(
        LocalizedStringKey(order.title),
        trailingIcon: Image(systemName: "chevron.up.chevron.down"))
    }
    .menuStyle(.button)
    .buttonStyle(.text)
    .accessibilityLabel("並べ替え")
    .accessibilityValue(order.title)
  }
}

/// A dotted rule, a step fainter in dark mode, where light on black stands out more.
private struct DottedRule: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Line()
      .stroke(
        colorScheme == .dark ? HierarchicalShapeStyle.quaternary : .tertiary,
        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
      )
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
  WritingListView(rows: WritingRow.samples(now: .now, calendar: .current), now: .now) { _ in }
}
