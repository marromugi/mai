import SwiftUI

/// The bar under the page in the typesetting mode: 「組版の調整」 and a round question mark that
/// shows the gestures on the leading margin, and the underlined 「閉じる」 on the trailing one.
struct TypesettingBar: View {
  let width: CGFloat
  let showGestures: () -> Void
  let close: () -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    let margin = scale.typeArea(width: width).margin
    HStack(spacing: 0) {
      Text("組版の調整")
        .font(.subheadline.weight(.semibold))
        .tracking(0.6)
        .accessibilityAddTraits(.isHeader)
      Button(action: showGestures) {
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
  }
}

/// The sheet that says how each typesetting gesture changes the body, with its icon.
struct TypesettingGestures: View {
  var body: some View {
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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .presentationDetents([.medium])
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

/// The page's outline in the typesetting mode: its sides and bottom, with the bottom corners
/// rounded by `cornerRadius`. The top runs a whole height above the frame, so the page also covers
/// the status bar.
struct PageShape: Shape {
  var cornerRadius: CGFloat

  var animatableData: CGFloat {
    get { cornerRadius }
    set { cornerRadius = newValue }
  }

  nonisolated func path(in rect: CGRect) -> Path {
    let page = CGRect(
      x: rect.minX, y: rect.minY - rect.height, width: rect.width, height: rect.height * 2)
    return UnevenRoundedRectangle(
      bottomLeadingRadius: cornerRadius, bottomTrailingRadius: cornerRadius, style: .continuous
    ).path(in: page)
  }
}

#Preview("Bar") {
  TypesettingBar(width: 402, showGestures: {}, close: {})
    .background(Color(.secondarySystemBackground))
}

#Preview("Gestures") {
  Text("").sheet(isPresented: .constant(true)) {
    TypesettingGestures()
  }
}
