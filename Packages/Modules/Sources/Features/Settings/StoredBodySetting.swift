import CoreGraphics
internal import Typesetting

/// The body setting a writing is set in until its own is adjusted, as `@AppStorage` keeps it under
/// `key`: base in points ("16" or "16.5"), line height, and tracking, separated by spaces. A stored
/// value that isn't a valid setting, or isn't written that way, reads as nothing stored.
struct StoredBodySetting: RawRepresentable, Equatable {
  static let key = "defaultBodySetting"
  /// What is read with nothing stored.
  static let standard = StoredBodySetting(.standard)

  let setting: BodySetting

  init(_ setting: BodySetting) {
    self.setting = setting
  }

  init?(rawValue: String) {
    let fields = rawValue.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 3, let base = Double(fields[0]), let lineHeight = Int(fields[1]),
      let tracking = Int(fields[2]),
      let setting = BodySetting(base: CGFloat(base), lineHeight: lineHeight, tracking: tracking),
      Self.text(base: setting) == fields[0]
    else { return nil }
    self.setting = setting
  }

  var rawValue: String { "\(Self.text(base: setting)) \(setting.lineHeight) \(setting.tracking)" }

  private static func text(base setting: BodySetting) -> String {
    let halfPoints = setting.baseHalfPoints
    return halfPoints.isMultiple(of: 2) ? "\(halfPoints / 2)" : "\(halfPoints / 2).5"
  }
}
