import Foundation

/// The font stack text is set in, as `@AppStorage` keeps it under `key`: the stack's JSON,
/// `{"names":[…]}`. A stored value that isn't that reads as nothing stored.
struct StoredFontStack: RawRepresentable, Equatable {
  static let key = "fontStack"
  /// What is read with nothing stored.
  static let standard = StoredFontStack(.standard)

  let stack: FontStack

  init(_ stack: FontStack) {
    self.stack = stack
  }

  init?(rawValue: String) {
    guard let stack = try? JSONDecoder().decode(FontStack.self, from: Data(rawValue.utf8)) else {
      return nil
    }
    self.stack = stack
  }

  var rawValue: String {
    do {
      return String(decoding: try JSONEncoder().encode(stack), as: UTF8.self)
    } catch {
      preconditionFailure("A list of strings always encodes as JSON: \(error)")
    }
  }
}
