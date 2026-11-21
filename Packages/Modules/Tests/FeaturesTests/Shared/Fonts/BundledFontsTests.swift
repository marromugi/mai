import Foundation
import Testing
import UIKit

@testable import Features

struct BundledFontsTests {
  @Test(arguments: ["SourceHanSansJP-Regular", "SourceHanSansJP-Bold"])
  func availableByPostScriptName(_ name: String) {
    BundledFonts.register()
    #expect(UIFont(name: name, size: 16) != nil)
  }

  @Test func registeringAgainDoesNotTrap() {
    BundledFonts.register()
    BundledFonts.register()
  }

  @Test(arguments: BundledFonts.postScriptNames)
  func licenseCopyrightMatchesTheFont(_ name: String) throws {
    BundledFonts.register()
    let font = try #require(UIFont(name: name, size: 16))
    let fontCopyright = try #require(CTFontCopyName(font, kCTFontCopyrightNameKey) as String?)
    let license = try String(
      contentsOf: BundledFonts.folder.appending(path: "LICENSE.txt"), encoding: .utf8)

    #expect(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
    let copyrightLine = String(license.prefix { $0 != "\n" })
    #expect(copyrightLine.hasPrefix("Copyright "))
    #expect(years(in: copyrightLine) == years(in: fontCopyright))
  }

  private func years(in text: String) -> String? {
    text.firstMatch(of: /\d{4}-\d{4}/).map { String($0.output) }
  }
}
