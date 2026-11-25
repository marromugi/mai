import SwiftUI
internal import Typesetting

/// A writing's page: its title, body, and `photos` on the type area, under a back mark, over the
/// bottom row. The title and body are always editable, each change handed to `edit`. The row's
/// 「組版を調整」 enters the typesetting mode, and a tap or 「閉じる」 leaves it; its camera takes a
/// photo with `camera` and hands it to `photoTaken`. Where one of `others`' titles appears in the
/// body, it links to that writing, and a tap on it calls `open` with it. The body's own links open
/// their pages, and a web address pasted into it becomes one.
struct WritingView: View {
  let writing: Writing
  let others: [Writing]
  let open: (Writing) -> Void
  let edit: (_ change: (inout Writing) -> Void) -> Void
  let photos: [PagePhoto]
  @Binding var setting: BodySetting
  let camera: Camera
  let photoTaken: (UIImage) -> Void
  @State private var typesetting = false
  @State private var takingPhoto = false

  var body: some View {
    WritingScreen(
      writing: writing, others: others, open: open, edit: edit, photos: photos,
      setting: $setting, typesetting: $typesetting,
      takingPhoto: $takingPhoto, camera: camera, photoTaken: photoTaken)
  }
}

/// The writing's page, with its `photos`, in or out of the typesetting mode. The title and body are
/// editable and each change goes to `edit`. As the title scrolls
/// off the top, the header fades in to stand in for it. In the mode the page stops scrolling and lifts off the desk
/// above the typesetting bar, the typesetting gestures over it step `setting`, and a tap or the
/// bar's 「閉じる」 leaves the mode. The bottom row's camera sets `takingPhoto`, which covers the
/// page with `camera`'s screen until it takes a photo or is cancelled. A tap on a mention of one of
/// `others` in the body calls `open` with it.
struct WritingScreen: View {
  let writing: Writing
  let others: [Writing]
  let open: (Writing) -> Void
  let edit: (_ change: (inout Writing) -> Void) -> Void
  let photos: [PagePhoto]
  @Binding var setting: BodySetting
  @Binding var typesetting: Bool
  @Binding var takingPhoto: Bool
  let camera: Camera
  let photoTaken: (UIImage) -> Void
  @State private var titleCutOff: CGFloat = 0
  /// Found once per body and set of others, not at every update: the scroll updates the screen
  /// each frame. While the body changes, found once it rests for `FoundMentions.rest`.
  @State private var found: FoundMentions?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        WritingPage(
          writing: writing, found: found, edit: edit, photos: photos,
          width: proxy.size.width, back: { dismiss() }, titleCutOff: { titleCutOff = $0 })
      }
      .environment(\.openURL, .opening(found?.mentions ?? [], with: open))
      .task(id: MentionSource(body: writing.body, others: others)) {
        if found != nil {
          do {
            try await Task.sleep(for: FoundMentions.rest)
          } catch {
            return
          }
        }
        found = FoundMentions(body: writing.body, mentions: writing.body.titleMentions(of: others))
      }
      .scrollDisabled(typesetting)
      .scrollDismissesKeyboard(.interactively)
      .modifier(BottomEdgeFade(shown: !typesetting))
      .clipShape(pageShape)
      .background {
        pageShape
          .fill(
            Color(.systemBackground)
              .shadow(.inner(color: .black.opacity(typesetting ? 0.2 : 0), radius: 10)))
      }
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
      .accessibilityHidden(typesetting)
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
      .safeAreaInset(edge: .bottom, spacing: 0) {
        // Hidden, not removed: the row sets the inset's height in and out of the mode, so the
        // scroll offset isn't clamped. The bar lies over it.
        let row = BottomRow(
          width: proxy.size.width, cameraAvailable: camera.isAvailable,
          takePhoto: { takingPhoto = true },
          adjustTypesetting: {
            UIApplication.shared.sendAction(
              #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            withAnimation { typesetting = true }
          })
        Group {
          if typesetting {
            row.hidden()
          } else {
            row
          }
        }
        .overlay {
          if typesetting {
            TypesettingBar(
              width: proxy.size.width,
              close: { withAnimation { typesetting = false } })
          }
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

  /// The page's outline: in the typesetting mode its bottom lifts off the desk with rounded corners,
  /// so the paper's edge shows; out of it, the page fills the screen.
  private var pageShape: PageShape {
    typesetting ? PageShape(cornerRadius: 32, lift: 12) : PageShape(cornerRadius: 0, lift: 0)
  }
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

/// The page laid out across a screen `width` wide: the back mark, then the title, the body with
/// the mentions `found` in it linked, and the photos after its last paragraph, piled as one stack,
/// on the type area. The title and body are one editor, and each change goes to `edit`.
/// `titleCutOff` hears how much of the title has scrolled above the scroll view's top, from 0 to 1.
struct WritingPage: View {
  let writing: Writing
  var found: FoundMentions?
  var edit: (_ change: (inout Writing) -> Void) -> Void = { _ in }
  let photos: [PagePhoto]
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
        let text = WritingText(title: writing.title, body: writing.body, links: writing.links)
        WritingEditor(writing: text, found: found) { text in
          edit {
            $0.title = text.title
            $0.body = text.body
            $0.links = text.links
          }
        }
        .background(alignment: .topLeading) {
          // The title's lines as the editor sets them, to measure how far they have scrolled off.
          Text(verbatim: text.title.isEmpty ? "タイトル" : text.title)
            .textStyle(.heading)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) {
              let frame = $0.frame(in: .scrollView)
              guard frame.height > 0 else { return 0 }
              return min(max(-frame.minY / frame.height, 0), 1)
            } action: {
              titleCutOff($0)
            }
        }
        if !photos.isEmpty {
          PhotoStack(photos: photos, lineLength: area.lineLength)
        }
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
  @Environment(\.fontFamilies) private var families

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
      EdgeFade(edge: .top)
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
      .font(Font(scale.font(.title, in: families).withSize(size)))
      .lineLimit(1)
      .accessibilityAddTraits(.isHeader)
  }
}

/// The page's background fading out away from `edge`, for the body to pass under at that edge of
/// the screen. It takes no touches.
struct EdgeFade: View {
  let edge: VerticalEdge
  @EnvironmentTypeScale private var scale

  var body: some View {
    LinearGradient(
      colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
      startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top
    )
    .frame(height: Self.height(scale))
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  static func height(_ scale: TypeScale) -> CGFloat {
    scale.space(.l)
  }
}

/// An `EdgeFade` over the scroll view's bottom edge while `shown`, with a content margin as tall
/// either way, so the end of the content and the caret stop above it and the scroll offset holds.
private struct BottomEdgeFade: ViewModifier {
  let shown: Bool
  @EnvironmentTypeScale private var scale

  func body(content: Content) -> some View {
    content
      .contentMargins(.bottom, EdgeFade.height(scale), for: .scrollContent)
      .overlay(alignment: .bottom) {
        if shown {
          EdgeFade(edge: .bottom)
        }
      }
  }
}

/// The mentions of other writings' titles found in `body`.
nonisolated struct FoundMentions: Equatable, Sendable {
  let body: String
  let mentions: [TitleMention]

  static func == (lhs: FoundMentions, rhs: FoundMentions) -> Bool {
    lhs.body.isSameText(as: rhs.body) && lhs.mentions == rhs.mentions
  }

  /// How long the body rests unchanged before its mentions are found again.
  static let rest = Duration.milliseconds(400)
}

/// What a body's mentions are found from.
private struct MentionSource: Equatable {
  let body: String
  let others: [Writing]

  static func == (lhs: MentionSource, rhs: MentionSource) -> Bool {
    lhs.body.isSameText(as: rhs.body) && lhs.others == rhs.others
  }
}

extension OpenURLAction {
  /// Calls `open` with the writing a link among `mentions` names, and hands any other link to the
  /// system.
  static func opening(_ mentions: [TitleMention], with open: @escaping (Writing) -> Void)
    -> OpenURLAction
  {
    OpenURLAction { url in
      guard let writing = mentions.writing(linkedBy: url) else { return .systemAction }
      open(writing)
      return .handled
    }
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
      writing: Writing(title: "間合いの調整", body: Writing.sampleBody), others: [],
      open: { _ in }, edit: { _ in }, photos: [],
      setting: $setting, camera: .device, photoTaken: { _ in })
  }
}
