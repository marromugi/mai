import SwiftUI

/// A button drawn as its label alone, in the text colour, with no background or border.
struct TextButtonStyle: ButtonStyle {
  /// The least width and height of a button, so it stays easy to tap.
  static let minimumSide: CGFloat = 44
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.medium))
      .tracking(0.6)
      .foregroundStyle(.primary)
      .frame(minWidth: Self.minimumSide, minHeight: Self.minimumSide)
      .contentShape(.rect)
      .opacity(isEnabled ? (configuration.isPressed ? 0.4 : 1) : 0.3)
  }
}

extension ButtonStyle where Self == TextButtonStyle {
  static var text: TextButtonStyle { TextButtonStyle() }
}

#Preview("Text button") {
  VStack(alignment: .leading) {
    Button {
    } label: {
      ButtonLabel("BACK", leadingIcon: Image(systemName: "chevron.left"))
    }
    Button {
    } label: {
      ButtonLabel("EXPORT")
    }
    Button {
    } label: {
      ButtonLabel("NEXT", trailingIcon: Image(systemName: "chevron.right"))
    }
    Button {
    } label: {
      ButtonLabel("整える")
    }
    .disabled(true)
  }
  .buttonStyle(.text)
}
