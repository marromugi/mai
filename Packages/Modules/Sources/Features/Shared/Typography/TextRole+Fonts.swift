internal import Typesetting

extension TextRole {
  var postScriptName: String {
    switch self {
    case .display, .heading, .title: BundledFonts.bold
    case .body, .meta, .caption: BundledFonts.regular
    }
  }
}
