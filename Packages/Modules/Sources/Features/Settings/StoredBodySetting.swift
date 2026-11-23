internal import Typesetting

/// The body setting a writing is set in until its own is adjusted, as `@AppStorage` keeps it under
/// `key`: base, line height, and tracking, separated by spaces. A stored value that isn't a valid
/// setting reads as nothing stored.
struct StoredBodySetting: RawRepresentable, Equatable {
  static let key = "defaultBodySetting"
  /// What is read with nothing stored.
  static let standard = StoredBodySetting(.standard)

  let setting: BodySetting

  init(_ setting: BodySetting) {
    self.setting = setting
  }

  init?(rawValue: String) {
    let values = rawValue.split(separator: " ", omittingEmptySubsequences: false).map { Int($0) }
    guard values.count == 3, let base = values[0], let lineHeight = values[1],
      let tracking = values[2],
      let setting = BodySetting(base: base, lineHeight: lineHeight, tracking: tracking)
    else { return nil }
    self.setting = setting
  }

  var rawValue: String { "\(setting.base) \(setting.lineHeight) \(setting.tracking)" }
}
