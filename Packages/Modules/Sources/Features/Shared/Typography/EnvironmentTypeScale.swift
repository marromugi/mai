import SwiftUI
internal import Typesetting

extension EnvironmentValues {
  /// How the text in this subtree is set: its base sizes every role, and its line height and
  /// tracking set the body. Set by a writing's own pages and by the settings' sample line.
  @Entry var bodySetting: BodySetting = .standard
}

/// The type scale for the environment's Dynamic Type size and body setting.
@propertyWrapper
struct EnvironmentTypeScale: DynamicProperty {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.bodySetting) private var bodySetting

  var wrappedValue: TypeScale { TypeScale(dynamicTypeSize, body: bodySetting) }
}
