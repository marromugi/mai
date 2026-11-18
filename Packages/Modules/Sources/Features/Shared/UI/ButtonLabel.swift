import SwiftUI

/// The content of a button: a title with an optional icon on either side.
/// The button style decides its font and colour.
struct ButtonLabel: View {
  private let title: LocalizedStringKey
  private let leadingIcon: Image?
  private let trailingIcon: Image?
  @ScaledMetric(relativeTo: .subheadline) private var spacing = 6

  init(_ title: LocalizedStringKey, leadingIcon: Image? = nil, trailingIcon: Image? = nil) {
    self.title = title
    self.leadingIcon = leadingIcon
    self.trailingIcon = trailingIcon
  }

  var body: some View {
    HStack(spacing: spacing) {
      if let leadingIcon {
        ButtonIcon(image: leadingIcon)
      }
      Text(title)
      if let trailingIcon {
        ButtonIcon(image: trailingIcon)
      }
    }
  }
}

private struct ButtonIcon: View {
  let image: Image

  var body: some View {
    image
      .fontWeight(.semibold)
      .imageScale(.small)
      .accessibilityHidden(true)
  }
}

#Preview("Icons") {
  VStack(alignment: .leading) {
    ButtonLabel("BACK", leadingIcon: Image(systemName: "chevron.left"))
    ButtonLabel("NEXT", trailingIcon: Image(systemName: "chevron.right"))
    ButtonLabel("写真", leadingIcon: Image(systemName: "camera"))
  }
}
