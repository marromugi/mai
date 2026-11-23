import SwiftUI

/// A writing's `photos`, oldest first, each as large as fits the screen over black, one to a page.
/// It opens on the newest, pages sideways to the older ones, and its close button calls `close`.
struct PhotoViewer: View {
  let photos: [UIImage]
  let close: () -> Void

  var body: some View {
    ScrollView(.horizontal) {
      LazyHStack(spacing: 0) {
        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
          Image(uiImage: photo)
            .resizable()
            .scaledToFit()
            .containerRelativeFrame([.horizontal, .vertical])
            .accessibilityLabel(Self.label(index: index, count: photos.count))
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollIndicators(.hidden)
    .defaultScrollAnchor(.trailing, for: .initialOffset)
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
