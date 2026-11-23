import Testing
import UIKit

@testable import Features

struct WritingPhotosTests {
  @Test func aWritingWithNoPhotosReadsAsEmpty() {
    #expect(WritingPhotos()[UUID(sample: 1)].isEmpty)
  }

  @Test func eachWritingKeepsItsOwnPhotosInOrder() {
    let first = Camera.photo(.red)
    let second = Camera.photo(.green)
    let other = Camera.photo(.blue)
    var photos = WritingPhotos()
    photos[UUID(sample: 1)].append(first)
    photos[UUID(sample: 2)].append(other)
    photos[UUID(sample: 1)].append(second)
    #expect(photos[UUID(sample: 1)].count == 2)
    #expect(photos[UUID(sample: 1)].first === first)
    #expect(photos[UUID(sample: 1)].last === second)
    #expect(photos[UUID(sample: 2)].count == 1)
    #expect(photos[UUID(sample: 2)].first === other)
    #expect(photos[UUID(sample: 3)].isEmpty)
  }
}
