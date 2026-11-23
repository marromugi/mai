import CryptoKit
import Foundation
import Testing
import UIKit

@testable import Features

struct BundledFontsTests {
  nonisolated static let bundled = FontFamily.known.filter(\.isBundled)

  @Test(arguments: bundled)
  func eachFaceIsAvailable(_ family: FontFamily) throws {
    BundledFonts.register()
    let regular = try #require(family.font(.body, size: 16))
    #expect(regular.fontName == family.regular)
    #expect(family.font(.heading, size: 16) != nil)
  }

  @Test func registeringAgainDoesNotTrap() {
    BundledFonts.register()
    BundledFonts.register()
  }

  /// The files in the bundle are the ones the catalog names, unmodified.
  @Test(arguments: bundled.flatMap(\.files))
  func eachFileIsTheOneTheCatalogNames(_ file: FontFile) throws {
    let data = try Data(contentsOf: BundledFonts.folder.appending(path: file.name))
    #expect(data.count == file.size)
    #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256)
  }

  /// Each bundled family's license names the copyright holder its font names.
  @Test(arguments: bundled)
  func licenseCopyrightMatchesTheFont(_ family: FontFamily) throws {
    BundledFonts.register()
    let font = try #require(family.font(.body, size: 16))
    let fontCopyright = try #require(CTFontCopyName(font, kCTFontCopyrightNameKey) as String?)
    let license = family.license

    #expect(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
    let copyrightLine = String(license.prefix { $0 != "\n" })
    #expect(copyrightLine.hasPrefix("Copyright "))
    #expect(holder(in: copyrightLine) != nil)
    #expect(holder(in: copyrightLine) == holder(in: fontCopyright))
  }

  @Test(arguments: FontFamily.known)
  func everyFamilyHasItsLicense(_ family: FontFamily) {
    #expect(family.license.contains("SIL OPEN FONT LICENSE Version 1.1"))
  }

  /// Who the copyright is held by: what follows the years, up to the URL.
  private func holder(in text: String) -> String? {
    text.firstMatch(of: /\d{4}(?:-\d{4})? (.+?) \(/).map { String($0.output.1) }
  }
}
