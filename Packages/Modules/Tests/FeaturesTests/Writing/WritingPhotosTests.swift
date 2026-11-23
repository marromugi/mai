import Testing
import UIKit

@testable import Features

struct WritingPhotosTests {
  @Test func aWritingWithNoPhotosReadsAsEmpty() {
    #expect(WritingPhotos()[1].isEmpty)
  }

  @Test func eachWritingKeepsItsOwnPhotosInOrder() {
    let first = Camera.photo(.red)
    let second = Camera.photo(.green)
    let other = Camera.photo(.blue)
    var photos = WritingPhotos()
    photos[1].append(first)
    photos[2].append(other)
    photos[1].append(second)
    #expect(photos[1].count == 2)
    #expect(photos[1].first === first)
    #expect(photos[1].last === second)
    #expect(photos[2].count == 1)
    #expect(photos[2].first === other)
    #expect(photos[3].isEmpty)
  }
}
