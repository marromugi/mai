import SwiftUI

/// A writing's `photos`, oldest first, each as large as fits the screen over black, one to a page,
/// paged sideways. `shown` is the photo on screen, by its `UIImage.id`; the close button calls
/// `close`.
struct PhotoViewer: View {
  let photos: [UIImage]
  @Binding var shown: ObjectIdentifier?
  let close: () -> Void

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 0) {
        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
          Image(uiImage: photo)
            .resizable()
            .scaledToFit()
            .containerRelativeFrame(.horizontal)
            .accessibilityLabel(Self.label(index: index, count: photos.count))
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollIndicators(.hidden)
    .scrollPosition(id: $shown)
    .overlay(alignment: .topTrailing) {
      Button(action: close) {
        Image(systemName: "xmark")
      }
      .buttonStyle(.text)
      .accessibilityLabel("閉じる")
      .padding(.trailing, 8)
    }
    .background(.black)
    .environment(\.colorScheme, .dark)
  }

  /// What VoiceOver reads for the photo at `index` of `count`.
  static func label(index: Int, count: Int) -> String {
    count == 1 ? "写真" : "写真 \(index + 1)/\(count)"
  }
}
