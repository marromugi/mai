import SwiftUI
internal import Typesetting

/// A writing's page: its title and body on the type area, under a back mark, over the bottom row.
/// The row's 「組版を調整」 enters the typesetting mode, and a tap leaves it; its camera takes a
/// photo with `camera` and hands it to `photoTaken`.
struct WritingView: View {
  let writing: Writing
  @Binding var setting: BodySetting
  let camera: Camera
  let photoTaken: (UIImage) -> Void
  @State private var typesetting = false
  @State private var takingPhoto = false

  var body: some View {
    WritingScreen(
      writing: writing, setting: $setting, typesetting: $typesetting, takingPhoto: $takingPhoto,
      camera: camera, photoTaken: photoTaken)
  }
}

/// The writing's page in or out of the typesetting mode. As the title scrolls off the top, the
/// header fades in to stand in for it. In the mode the page shrinks to a sheet on the desk and stops
/// scrolling, the typesetting gestures over it step `setting`, and a tap leaves the mode. The bottom
/// row's camera sets `takingPhoto`, which covers the page with `camera`'s screen until it takes a
/// photo or is cancelled.
struct WritingScreen: View {
  let writing: Writing
  @Binding var setting: BodySetting
  @Binding var typesetting: Bool
  @Binding var takingPhoto: Bool
  let camera: Camera
  let photoTaken: (UIImage) -> Void
  @State private var titleCutOff: CGFloat = 0
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        WritingPage(
          writing: writing, width: proxy.size.width, back: { dismiss() },
          titleCutOff: { titleCutOff = $0 })
      }
      .scrollDisabled(typesetting)
      .overlay(alignment: .top) {
        // Faded by the scroll, not animated: an animation running as the mode starts moves the
        // page.
        if titleCutOff > 0 {
          WritingHeader(title: writing.title, width: proxy.size.width, close: { dismiss() })
            .opacity(titleCutOff)
            // Taken in only once whole, so a faint bar neither closes the page nor holds a drag.
            .allowsHitTesting(titleCutOff == 1)
            .accessibilityHidden(titleCutOff < 1)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        // Hidden, not removed: the inset keeps its height so the scroll offset isn't clamped.
        let row = BottomRow(
          width: proxy.size.width, cameraAvailable: camera.isAvailable,
          takePhoto: { takingPhoto = true },
          adjustTypesetting: { withAnimation { typesetting = true } })
        if typesetting {
          row.hidden()
        } else {
          row
        }
      }
      .accessibilityHidden(typesetting)
      .background {
        Rectangle()
          .fill(Color(.systemBackground))
          .shadow(color: .black.opacity(typesetting ? 0.15 : 0), radius: 12)
          .ignoresSafeArea()
      }
      .scaleEffect(typesetting ? Self.sheetScale : 1)
      .overlay {
        if typesetting {
          Color.clear
            .contentShape(.rect)
            .bodySettingGestures($setting)
            .onTapGesture {
              withAnimation { typesetting = false }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("組版の調整を終える")
            // Gone at once on leaving, so a touch right after the tap scrolls the page.
            .transition(.identity)
        }
      }
    }
    .background(Color(.secondarySystemBackground), ignoresSafeAreaEdges: .all)
    .fullScreenCover(isPresented: $takingPhoto) {
      camera.screen(
        { photo in
          takingPhoto = false
          photoTaken(photo)
        },
        { takingPhoto = false })
    }
    .environment(\.bodySetting, setting)
    .toolbar(.hidden, for: .navigationBar)
  }

  /// How large the page is in the typesetting mode, so the paper's edges show.
  static let sheetScale: CGFloat = 0.85
}

/// The camera at the bottom leading corner and the underlined 「組版を調整」 at the trailing one,
/// both on the type area's margins. The camera is dimmed where there is none.
private struct BottomRow: View {
  let width: CGFloat
  let cameraAvailable: Bool
  let takePhoto: () -> Void
  let adjustTypesetting: () -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    let margin = scale.typeArea(width: width).margin
    HStack(spacing: 0) {
      Button(action: takePhoto) {
        Image(systemName: "camera")
      }
      .buttonStyle(.text)
      .disabled(!cameraAvailable)
      .accessibilityLabel("写真を撮る")
      // Its 44-point tap area centred on the margin line, as the header's chevron is, unless that
      // would push it past the screen's edge.
      .padding(.leading, max(0, margin - TextButtonStyle.minimumSide / 2))
      Spacer(minLength: 0)
      Button(action: adjustTypesetting) {
        ButtonLabel("組版を調整")
      }
      .buttonStyle(.text)
      .underline()
      .padding(.trailing, margin)
    }
    .background(Color(.systemBackground))
  }
}

/// The page laid out across a screen `width` wide: the back mark, then the title and body on the
/// type area. `titleCutOff` hears how much of the title has scrolled above the scroll view's top,
/// from 0 to 1.
struct WritingPage: View {
  let writing: Writing
  let width: CGFloat
  let back: () -> Void
  let titleCutOff: (CGFloat) -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    let area = scale.typeArea(width: width)
    VStack(alignment: .leading, spacing: 0) {
      let markWidth = 15 * scale.scale
      Button(action: back) {
        BackMark()
          .stroke(.tertiary, style: StrokeStyle(lineWidth: 2.5 * scale.scale, lineCap: .round))
          .padding(1.25 * scale.scale)
          .frame(width: markWidth, height: 17 * scale.scale)
      }
      .buttonStyle(.text)
      .accessibilityLabel("戻る")
      // Centred on the margin line, unless that would push it past the screen's edge.
      .padding(.leading, max(0, area.margin - max(markWidth, TextButtonStyle.minimumSide) / 2))
      .padding(.bottom, scale.space(.l))
      VStack(alignment: .leading, spacing: 0) {
        // An untitled writing keeps its line: an ideographic space is one heading line box tall.
        Text(verbatim: writing.title.isEmpty ? "\u{3000}" : writing.title)
          .textStyle(.heading)
          .onGeometryChange(for: CGFloat.self) {
            let frame = $0.frame(in: .scrollView)
            guard frame.height > 0 else { return 0 }
            return min(max(-frame.minY / frame.height, 0), 1)
          } action: {
            titleCutOff($0)
          }
          .padding(.bottom, scale.space(.m))
        Text(body: writing.body)
          .textStyle(.body)
      }
      .frame(width: area.lineLength, alignment: .leading)
      .padding(.horizontal, area.margin)
      .padding(.bottom, scale.space(.xl))
    }
  }
}

/// The bar at the top once the title scrolls off: a close chevron on the margin and the title
/// centred on one line, stepped down the size series to fit, over a fade the body passes under. The
/// title grows with neither Dynamic Type nor the body setting past its size at the standard scale.
struct WritingHeader: View {
  let title: String
  let width: CGFloat
  let close: () -> Void
  @EnvironmentTypeScale private var scale

  var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        // The title's own size, then the series' next steps down to the caption's: the first at
        // which the whole title fits, or the last, cut short at its end.
        centred(at: .title)
        centred(at: .meta)
        centred(at: .caption)
      }
      // The chevron centred on the margin line, as the page's back mark is, unless that would push
      // it past the screen's edge.
      .padding(
        .horizontal,
        max(0, scale.typeArea(width: width).margin - TextButtonStyle.minimumSide / 2)
      )
      .background(Color(.systemBackground), ignoresSafeAreaEdges: .top)
      LinearGradient(
        colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
        startPoint: .top, endPoint: .bottom
      )
      .frame(height: scale.space(.l))
      .allowsHitTesting(false)
    }
  }

  /// The close button, the title at `step`'s size, and the button's hidden twin, which gives the
  /// trailing side the same space and keeps the title centred.
  private func centred(at step: TextRole) -> some View {
    HStack(spacing: scale.space(.s)) {
      closeButton
      titleText(at: step).frame(maxWidth: .infinity)
      closeButton.hidden()
    }
  }

  private var closeButton: some View {
    Button(action: close) {
      Image(systemName: "chevron.left")
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.text)
    .accessibilityLabel("閉じる")
  }

  /// The title on one line in the title's bold, at `step`'s size.
  private func titleText(at step: TextRole) -> some View {
    let size = min(scale.size(step), TypeScale.standard.size(step))
    return Text(verbatim: title)
      .font(Font(scale.font(.title).withSize(size)))
      .lineLimit(1)
      .accessibilityAddTraits(.isHeader)
  }
}

/// A short stroke across, met at its trailing end by one that leans down to the trailing side.
private struct BackMark: Shape {
  nonisolated func path(in rect: CGRect) -> Path {
    Path { path in
      let across = rect.minY + rect.height * 0.35
      let corner = rect.minX + rect.width * 0.6
      path.move(to: CGPoint(x: rect.minX, y: across))
      path.addLine(to: CGPoint(x: corner, y: across))
      path.move(to: CGPoint(x: corner, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    }
  }
}

#Preview {
  @Previewable @State var setting = BodySetting.standard
  NavigationStack {
    WritingView(
      writing: Writing(title: "間合いの調整", body: Writing.sampleBody), setting: $setting,
      camera: .device, photoTaken: { _ in })
  }
}
