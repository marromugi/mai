import CoreText
import Foundation

/// Source Han Sans JP, shipped unmodified with its license in `Resources/Fonts`.
public enum BundledFonts {
  nonisolated static let postScriptNames = ["SourceHanSansJP-Regular", "SourceHanSansJP-Bold"]

  static var folder: URL {
    guard let url = Bundle.module.url(forResource: "Fonts", withExtension: nil) else {
      fatalError("The Fonts folder is missing from the Features bundle.")
    }
    return url
  }

  /// Makes the bundled fonts usable by their PostScript names in this process.
  /// Registers them on the first call only.
  public static func register() {
    _ = registration
  }

  private static let registration: Void = {
    for name in postScriptNames {
      let url = folder.appending(path: "\(name).otf")
      var error: Unmanaged<CFError>?
      if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
        let reason = error.map { String(describing: $0.takeRetainedValue()) } ?? "no error given"
        fatalError("Could not register \(url.lastPathComponent): \(reason)")
      }
    }
  }()
}
