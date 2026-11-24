import CoreText
import Foundation

/// The families shipped unmodified in `Resources/Fonts`, their licenses in `Resources/Fonts/Licenses`.
public enum BundledFonts {
  static var folder: URL {
    guard let url = Bundle.module.url(forResource: "Fonts", withExtension: nil) else {
      fatalError("The Fonts folder is missing from the Features bundle.")
    }
    return url
  }

  /// Makes the bundled families usable by their PostScript names in this process.
  /// Registers them on the first call only.
  public static func register() {
    _ = registration
  }

  private static let registration: Void = {
    for file in FontFamily.known.filter(\.isBundled).flatMap(\.files) {
      let url = folder.appending(path: file.name)
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "no error given"
        fatalError("Could not register \(url.lastPathComponent): \(reason)")
      }
    }
  }()
}
