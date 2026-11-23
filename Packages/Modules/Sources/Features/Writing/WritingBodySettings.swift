internal import Typesetting

/// Each writing's body setting, kept while the app runs. A writing never set reads as the default
/// it is read with.
struct WritingBodySettings {
  private var settings: [Writing.ID: BodySetting] = [:]

  subscript(id: Writing.ID, default defaultSetting: BodySetting) -> BodySetting {
    get { settings[id, default: defaultSetting] }
    set { settings[id] = newValue }
  }
}
