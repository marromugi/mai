import CoreText
import Foundation
import Testing
import Typesetting
import UIKit

@testable import Features

struct FontStackTests {
  /// A Latin family with no Japanese, from the fonts iOS ships.
  static let helvetica = FontFamily(
    name: "Helvetica", regular: "Helvetica", bold: "Helvetica-Bold", emBoxDescent: nil)
  static let known = [helvetica, FontFamily.notoSansJP]

  @Test func encodesAsTheNamesAlone() throws {
    let stack = FontStack(names: ["Inter", "Noto Sans JP"])
    let json = String(decoding: try JSONEncoder().encode(stack), as: UTF8.self)
    #expect(json == #"{"names":["Inter","Noto Sans JP"]}"#)
    #expect(try JSONDecoder().decode(FontStack.self, from: Data(json.utf8)) == stack)
  }

  @Test func theStandardStackIsTheBundledFamily() {
    #expect(FontStack.standard.families() == [.notoSansJP])
    #expect(FontStack.standard.emBoxDescent() == 0.12)
  }

  @Test func endsInTheBundledFamily() {
    let stack = FontStack(names: ["Helvetica"])
    #expect(stack.families(from: Self.known) == [Self.helvetica, .notoSansJP])
  }

  @Test func keepsTheBundledFamilyWhereItIsNamed() {
    let stack = FontStack(names: ["Noto Sans JP", "Helvetica"])
    #expect(stack.families(from: Self.known) == [.notoSansJP, Self.helvetica])
  }

  @Test func skipsUnknownAndRepeatedNames() {
    let stack = FontStack(names: ["Nobody Sans", "Helvetica", "Helvetica"])
    #expect(stack.families(from: Self.known) == [Self.helvetica, .notoSansJP])
  }

  @Test func theEmBoxIsTheFirstJapaneseFamilys() {
    let stack = FontStack(names: ["Helvetica"])
    #expect(stack.emBoxDescent(from: Self.known) == 0.12)
  }

  @Test(arguments: [TextRole.body, .heading])
  func eachCharacterIsSetInTheFirstFamilyThatHasIt(_ role: TextRole) throws {
    let font = TypeScale.standard.font(role, in: [Self.helvetica, .notoSansJP])
    #expect(font.fontName == Self.helvetica.postScriptName(role))
    func fontName(for character: String) -> String {
      let string = character as CFString
      let used = CTFontCreateForString(font, string, CFRange(location: 0, length: 1))
      return CTFontCopyPostScriptName(used) as String
    }
    #expect(fontName(for: "M") == Self.helvetica.postScriptName(role))
    #expect(fontName(for: "書") == FontFamily.notoSansJP.postScriptName(role))
  }
}
