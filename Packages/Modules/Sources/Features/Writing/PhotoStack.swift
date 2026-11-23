import SwiftUI
internal import Typesetting

/// Photos taken one after another, oldest first, as prints piled on the page: centred in a column
/// `lineLength` wide, each in a light border with rounded corners and a soft shadow, tilted, the
/// newest on top. Only the newest `PhotoStack.layers.count` are drawn. A tap opens them in a
/// `PhotoViewer`, zooming out of the top print, on the newest.
struct PhotoStack: View {
  let photos: [UIImage]
  let lineLength: CGFloat
  @EnvironmentTypeScale private var scale
  @Namespace private var zoom
  @State private var viewing = false

  var body: some View {
    let shown = Array(photos.suffix(Self.layers.count))
    Button {
      viewing = true
    } label: {
      ZStack {
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, photo in
          let layer = Self.layers[shown.count - 1 - index]
          PhotoPrint(photo: photo, bounds: bounds)
            .rotationEffect(.degrees(layer.tilt))
            .matchedTransitionSource(id: photo.id, in: zoom)
            .offset(x: layer.offset.width * scale.scale, y: layer.offset.height * scale.scale)
        }
      }
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity)
    .padding(.vertical, scale.space(.m))
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits([.isImage, .isButton])
    .accessibilityLabel(Self.label(count: photos.count))
    .fullScreenCover(isPresented: $viewing) {
      PhotoViewer(photos: photos) { viewing = false }
        .navigationTransition(.zoom(sourceID: photos[photos.count - 1].id, in: zoom))
    }
  }

  /// What VoiceOver reads for a stack of `count` photos.
  static func label(count: Int) -> String {
    count == 1 ? "写真" : "写真 \(count)枚"
  }

  /// The box each print fits in, border included: smaller than the text column.
  private var bounds: CGSize {
    CGSize(width: lineLength * 0.6, height: lineLength * 0.75)
  }

  /// Each print's tilt in degrees and its offset at the standard scale, from the top of the pile
  /// down.
  static let layers: [(tilt: Double, offset: CGSize)] = [
    (-2, .zero),
    (4, CGSize(width: 10, height: -6)),
    (-8, CGSize(width: -14, height: 10)),
  ]
}

/// One photo at its own shape, as large as fits in `bounds`, in a light border with rounded
/// corners over a soft shadow.
private struct PhotoPrint: View {
  let photo: UIImage
  let bounds: CGSize
  @EnvironmentTypeScale private var scale

  var body: some View {
    let border = 6 * scale.scale
    let inner = CGSize(width: bounds.width - border * 2, height: bounds.height - border * 2)
    let fit = min(inner.width / photo.size.width, inner.height / photo.size.height)
    Image(uiImage: photo)
      .resizable()
      .frame(width: photo.size.width * fit, height: photo.size.height * fit)
      .clipShape(.rect(cornerRadius: 2 * scale.scale))
      .padding(border)
      .background(
        Color(Self.border), in: .rect(cornerRadius: 4 * scale.scale)
      )
      .shadow(color: .black.opacity(0.25), radius: 6 * scale.scale, y: 3 * scale.scale)
  }

  /// White, dimmed a little in dark mode so it doesn't outshine the page.
  private static let border = UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(white: 0.85, alpha: 1) : .white
  }
}

extension UIImage {
  /// Who this photo is: each photo the camera takes is a new image object, and `UIImage`'s `==`
  /// compares the pixels' source instead.
  var id: ObjectIdentifier { ObjectIdentifier(self) }
}
