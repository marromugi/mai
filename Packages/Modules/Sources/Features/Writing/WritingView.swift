import SwiftUI
internal import Typesetting

/// A writing's page: its title, body, and `photos` on the type area, under a back mark, over the
/// bottom row. The row's pencil makes the title and body editable until 「完了」, each change
/// handed to `edit`; its 「組版を調整」 enters the typesetting mode, and a tap or 「閉じる」 leaves
/// it; its camera takes a photo with `camera` and hands it to `photoTaken`. Where one of `others`'
/// titles appears in the body, it links to that writing, and a tap on it calls `open` with it.
struct WritingView: View {
  let writing: Writing
  let others: [Writing]
  let open: (Writing) -> Void
  let edit: (_ change: (inout Writing) -> Void) -> Void
  let photos: [UIImage]
  @Binding var setting: BodySetting
  let camera: Camera
  let photoTaken: (UIImage) -> Void
  @State private var editing = false
  @State private var typesetting = false
  @State private var takingPhoto = false

  var body: some View {
    WritingScreen(
      writing: writing, others: others, open: open, edit: edit, photos: photos,
      setting: $setting, editing: $editing, typesetting: $typesetting,
      takingPhoto: $takingPhoto, camera: camera, photoTaken: photoTaken)
  }
}

/// The writing's page, with its `photos`, being edited or not, in or out of the typesetting mode.
/// While `editing`, the title and body are editable and each change goes to `edit`. As the title scrolls
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
  let photos: [UIImage]
  @Binding var setting: BodySetting
  @Binding var editing: Bool
  @Binding var typesetting: Bool
  @Binding var takingPhoto: Bool
  let camera: Camera
  let photoTaken: (UIImage) -> Void
  @State private var titleCutOff: CGFloat = 0
  /// Found once per body and set of others, not at every update: the scroll updates the screen
  /// each frame. Not found while editing, which shows none and changes the body at each key.
  @State private var mentions: [TitleMention] = []
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        WritingPage(
          writing: writing, mentions: mentions, editing: editing, edit: edit, photos: photos,
          width: proxy.size.width, back: { dismiss() }, titleCutOff: { titleCutOff = $0 })
      }
      .environment(\.openURL, .opening(mentions, with: open))
      .task(id: editing ? nil : MentionSource(body: writing.body, others: others)) {
        guard !editing else { return }
        mentions = writing.body.titleMentions(of: others)
      }
      .scrollDisabled(typesetting)
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
          width: proxy.size.width, cameraAvailable: camera.isAvailable, editing: $editing,
          takePhoto: { takingPhoto = true },
          adjustTypesetting: { withAnimation { typesetting = true } })
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

/// The camera and the pencil, which starts editing, at the bottom leading corner, and the
/// underlined 「組版を調整」 at the trailing one, or 「完了」 alone while `editing`, all on the type
/// area's margins. The camera is dimmed where there is none.
private struct BottomRow: View {
  let width: CGFloat
  let cameraAvailable: Bool
  @Binding var editing: Bool
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
      if !editing {
        Button {
          editing = true
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.text)
        .accessibilityLabel("編集")
      }
      Spacer(minLength: 0)
      Group {
        if editing {
          Button {
            editing = false
          } label: {
            ButtonLabel("完了")
          }
        } else {
          Button(action: adjustTypesetting) {
            ButtonLabel("組版を調整")
          }
        }
      }
      .buttonStyle(.text)
      .underline()
      .padding(.trailing, margin)
    }
    .background(Color(.systemBackground))
  }
}

/// The page laid out across a screen `width` wide: the back mark, then the title, the body with
/// its `mentions` linked, and the photos after its last paragraph, piled as one stack, on the type
/// area. While `editing`, the title and body are editable, set as they are read, the mentions
/// unlinked, and each change goes to `edit`. `titleCutOff` hears how much of the title has
/// scrolled above the scroll view's top, from 0 to 1.
struct WritingPage: View {
  let writing: Writing
  var mentions: [TitleMention] = []
  var editing = false
  var edit: (_ change: (inout Writing) -> Void) -> Void = { _ in }
  let photos: [UIImage]
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
        Group {
          if editing {
            TextStyleEditor(
              role: .heading, text: writing.title, placeholder: "タイトル", oneLine: true
            ) { title in
              edit { $0.title = title }
            }
          } else {
            // An untitled writing keeps its line: an ideographic space is one heading line box tall.
            Text(verbatim: writing.title.isEmpty ? "\u{3000}" : writing.title)
              .textStyle(.heading)
          }
        }
        .onGeometryChange(for: CGFloat.self) {
          let frame = $0.frame(in: .scrollView)
          guard frame.height > 0 else { return 0 }
          return min(max(-frame.minY / frame.height, 0), 1)
        } action: {
          titleCutOff($0)
        }
        .padding(.bottom, scale.space(.m))
        if editing {
          TextStyleEditor(role: .body, text: writing.body) { body in edit { $0.body = body } }
        } else {
          Text(body: writing.body, mentions: mentions)
            .textStyle(.body)
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

/// What a body's mentions are found from.
private struct MentionSource: Equatable {
  let body: String
  let others: [Writing]
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
