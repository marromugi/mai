import Foundation
import Testing

@testable import Features

struct StoredFontStackTests {
  @Test func storesTheStacksJSON() {
    let stored = StoredFontStack(FontStack(names: ["Inter", "Zen Kaku Gothic New"]))
    #expect(stored.rawValue == #"{"names":["Inter","Zen Kaku Gothic New"]}"#)
    #expect(StoredFontStack(rawValue: stored.rawValue) == stored)
  }

  @Test(arguments: ["", "Inter", #"{"names":"Inter"}"#, #"["Inter"]"#])
  func anythingElseReadsAsNothingStored(_ raw: String) {
    #expect(StoredFontStack(rawValue: raw) == nil)
  }
}
