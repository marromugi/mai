import SwiftUI

/// The bar under the page in the typesetting mode: 「組版の調整」 and a round question mark that
/// opens the gestures sheet on the leading margin, and the underlined 「閉じる」 on the trailing one.
struct TypesettingBar: View {
  let width: CGFloat
  let close: () -> Void
  @State private var showingGestures = false
  @EnvironmentTypeScale private var scale

  var body: some View {
    let margin = scale.typeArea(width: width).margin
    HStack(spacing: 0) {
      Text("組版の調整")
        .font(.subheadline.weight(.semibold))
        .tracking(0.6)
        // One line at every size, shrunk where it would otherwise be cut: the bar keeps the
        // bottom row's height.
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .accessibilityAddTraits(.isHeader)
      Button {
        showingGestures = true
      } label: {
        Image(systemName: "questionmark.circle.fill")
          .font(.title2)
      }
      .buttonStyle(.text)
      .accessibilityLabel("組版のジェスチャー")
      Spacer(minLength: 0)
      Button(action: close) {
        ButtonLabel("閉じる")
      }
      .buttonStyle(.text)
      .underline()
    }
    .padding(.horizontal, margin)
    .sheet(isPresented: $showingGestures) {
      TypesettingGestures()
    }
  }
}

/// The sheet that says how each typesetting gesture changes the body, with its icon. It scrolls,
/// and opens to the full height, where large text makes it longer than half the screen.
struct TypesettingGestures: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("組版のジェスチャー")
          .font(.headline)
          .accessibilityAddTraits(.isHeader)
        GestureRow(
          icon: "gesture-drag-base", name: "上下にドラッグ",
          effect: "文字の大きさを変えます。上で大きく、下で小さくなります。")
        GestureRow(
          icon: "gesture-pinch-line-height", name: "縦にピンチ",
          effect: "行間を変えます。広げると開き、つまむと詰まります。")
        GestureRow(
          icon: "gesture-pinch-tracking", name: "横にピンチ",
          effect: "字間を変えます。広げると開き、つまむと詰まります。")
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

private struct GestureRow: View {
  let icon: String
  let name: LocalizedStringKey
  let effect: LocalizedStringKey

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(icon, bundle: .module)
        .foregroundStyle(.primary)
        .frame(width: 44, height: 44)
        .background(Color(.secondarySystemBackground), in: .circle)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(name)
          .font(.subheadline.weight(.semibold))
        Text(effect)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// The page's outline in the typesetting mode: its sides and bottom, the bottom `lift` above the
/// frame's and its corners rounded by `cornerRadius`. The top runs a whole height above the frame,
/// so the page also covers the status bar.
struct PageShape: Shape {
  var cornerRadius: CGFloat
  var lift: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(cornerRadius, lift) }
    set { (cornerRadius, lift) = (newValue.first, newValue.second) }
  }

  nonisolated func path(in rect: CGRect) -> Path {
    let page = CGRect(
      x: rect.minX, y: rect.minY - rect.height, width: rect.width, height: rect.height * 2 - lift)
    return UnevenRoundedRectangle(
      bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius, style: .continuous
    ).path(in: page)
  }
}

#Preview("Bar") {
  TypesettingBar(width: 402, close: {})
    .background(Color(.secondarySystemBackground))
}

#Preview("Gestures") {
  Text("").sheet(isPresented: .constant(true)) {
    TypesettingGestures()
  }
}
