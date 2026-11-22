import SnapshotTesting
import SwiftUI
import Testing

@testable import Features

struct TextButtonStyleTests {
  @Test func titleOnly() {
    assertLooks(textButton(ButtonLabel("EXPORT")))
  }

  @Test func shortTitleKeepsMinimumWidth() {
    assertLooks(textButton(ButtonLabel("OK")))
  }

  @Test func leadingIcon() {
    assertLooks(textButton(ButtonLabel("BACK", leadingIcon: Image(systemName: "chevron.left"))))
  }

  @Test func trailingIcon() {
    assertLooks(textButton(ButtonLabel("NEXT", trailingIcon: Image(systemName: "chevron.right"))))
  }

  @Test func iconsOnBothSides() {
    assertLooks(
      textButton(
        ButtonLabel(
          "SHARE",
          leadingIcon: Image(systemName: "square.and.arrow.up"),
          trailingIcon: Image(systemName: "chevron.down"))))
  }

  @Test func japaneseTitle() {
    assertLooks(textButton(ButtonLabel("写真", leadingIcon: Image(systemName: "camera"))))
  }

  @Test func disabled() {
    assertLooks(textButton(ButtonLabel("EXPORT")).disabled(true))
  }

  @Test func darkAppearance() {
    assertLooks(
      textButton(ButtonLabel("BACK", leadingIcon: Image(systemName: "chevron.left"))),
      colorScheme: .dark)
  }

  @Test func largestText() {
    assertLooks(
      textButton(ButtonLabel("BACK", leadingIcon: Image(systemName: "chevron.left")))
        .dynamicTypeSize(.accessibility5))
  }
}

private func textButton(_ label: ButtonLabel) -> some View {
  Button {
  } label: {
    label
  }
  .buttonStyle(.text)
}

private func assertLooks(
  _ view: some View,
  colorScheme: ColorScheme = .light,
  fileID: StaticString = #fileID,
  file: StaticString = #filePath,
  testName: String = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  assertSnapshot(
    of: view.fixedSize().padding(16).background(Color(.systemBackground))
      .environment(\.colorScheme, colorScheme),
    as: .image(precision: 1, perceptualPrecision: 0.995, layout: .sizeThatFits),
    fileID: fileID,
    file: file,
    testName: testName,
    line: line,
    column: column)
}
