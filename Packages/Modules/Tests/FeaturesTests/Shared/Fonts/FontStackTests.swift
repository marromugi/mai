import CoreText
import Foundation
import Testing
import Typesetting
import UIKit

@testable import Features

struct FontStackTests {
  static let known = [FontFamily.inter, .notoSansJP]

  @Test func encodesAsTheNamesAlone() throws {
    let stack = FontStack(names: ["Inter", "Noto Sans JP"])
    let json = String(decoding: try JSONEncoder().encode(stack), as: UTF8.self)
    #expect(json == #"{"names":["Inter","Noto Sans JP"]}"#)
    #expect(try JSONDecoder().decode(FontStack.self, from: Data(json.utf8)) == stack)
  }

  @Test func theStandardStackIsTheBundledFamily() {
    #expect(FontStack.standard.families() == [.notoSansJP])
    #expect(FontStack.standard.families().emBoxDescent == 0.12)
  }

  @Test func endsInTheBundledFamily() {
    let stack = FontStack(names: ["Inter"])
    #expect(stack.families(from: Self.known) == [.inter, .notoSansJP])
  }

  @Test func keepsTheBundledFamilyWhereItIsNamed() {
    let stack = FontStack(names: ["Noto Sans JP", "Inter"])
    #expect(stack.families(from: Self.known) == [.notoSansJP, .inter])
  }

  /// A name the app doesn't know, one named twice, and one not available yet are each skipped.
  @Test func skipsUnknownRepeatedAndUnavailableNames() {
    let stack = FontStack(names: ["Nobody Sans", "Inter", "Inter", "Zen Kaku Gothic New"])
    #expect(stack.families(from: Self.known) == [.inter, .notoSansJP])
  }

  @Test func theEmBoxIsTheFirstJapaneseFamilys() {
    let families = FontStack(names: ["Inter"]).families(from: Self.known)
    #expect(families.emBoxDescent == 0.12)
  }

  @Test(arguments: [TextRole.body, .heading])
  func eachCharacterIsSetInTheFirstFamilyThatHasIt(_ role: TextRole) throws {
    let font = TypeScale.standard.font(role, in: [.inter, .notoSansJP])
    let size = TypeScale.standard.size(role)
    let inter = try #require(FontFamily.inter.font(role, size: size))
    let noto = try #require(FontFamily.notoSansJP.font(role, size: size))
    #expect(font.familyName == inter.familyName)
    #expect(usedFamily(in: font, for: "M") == inter.familyName)
    #expect(usedFamily(in: font, for: "書") == noto.familyName)
  }

  /// A variable family's bold is its regular face at `wght` 700, in the stack as well.
  @Test(arguments: [FontFamily.inter, .lora])
  func aVariableFamilysBoldIsItsWeightAxis(_ family: FontFamily) throws {
    BundledFonts.register()
    func weight(_ font: UIFont) -> Double? {
      let variation = CTFontCopyVariation(font) as? [Int: Double]
      return variation?[FontFamily.weightAxis]
    }
    let regular = try #require(family.font(.body, size: 20))
    let bold = try #require(family.font(.heading, size: 20))
    #expect(weight(regular) ?? 400 == 400)
    #expect(weight(bold) == 700)
    let stacked = TypeScale.standard.font(.heading, in: [family, .notoSansJP])
    #expect(weight(stacked) == 700)
    // Wider strokes set the same word wider.
    func width(_ font: UIFont) -> CGFloat {
      NSAttributedString(string: "Morning", attributes: [.font: font]).size().width
    }
    #expect(width(bold) > width(regular))
  }

  private func usedFamily(in font: UIFont, for character: String) -> String {
    let string = character as CFString
    let used = CTFontCreateForString(font, string, CFRange(location: 0, length: 1))
    return CTFontCopyFamilyName(used) as String
  }
}
