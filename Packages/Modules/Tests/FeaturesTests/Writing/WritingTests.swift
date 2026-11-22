import Testing

@testable import Features

struct WritingTests {
  @Test func sampleTakesTheTitle() {
    #expect(Writing.sample(titled: "朝") == Writing(title: "朝", body: Writing.sampleBody))
  }
}
