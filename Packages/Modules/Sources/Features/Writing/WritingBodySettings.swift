internal import Typesetting

/// Each writing's body setting, kept while the app runs. A writing never set reads as standard.
struct WritingBodySettings {
  private var settings: [WritingRow.ID: BodySetting] = [:]

  subscript(id: WritingRow.ID) -> BodySetting {
    get { settings[id, default: .standard] }
    set { settings[id] = newValue }
  }
}
