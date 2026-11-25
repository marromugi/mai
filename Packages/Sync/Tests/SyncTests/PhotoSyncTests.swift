import Foundation
import Sync
import SyncFakes
import Testing

struct PhotoSyncTests {
  private let ownKey = OwnKey.generate()
  private let token = "s1.session.token"
  private let fake: FakeWritingServer

  init() {
    fake = FakeWritingServer(accepting: token)
  }

  private func server(transport: (any HTTPTransport)? = nil) -> WritingServer {
    guard let url = URL(string: "https://fake.test") else {
      preconditionFailure("https://fake.test is a URL")
    }
    return WritingServer(url: url, token: token, transport: transport ?? fake)
  }

  private func photo() -> PlainPhoto {
    PlainPhoto(id: UUID(), photo: Data("写真 \(UUID())".utf8), thumbnail: Data("小".utf8))
  }

  private func writing(pointingAt photos: [UUID], at seconds: Double = 1_000) -> PlainWriting {
    PlainWriting(
      id: UUID(), updated: .init(timeIntervalSince1970: seconds), contents: .pointing(at: photos))
  }

  @Test func aPhotoTravelsWithItsWritingThroughTheFake() async throws {
    try await TwoDevices(server: { server() }, ownKey: ownKey).checkAPhotoTravelsWithItsWriting()
  }

  /// The thumbnail, then the photo, then the writing that points at it, so no device takes in the
  /// writing before the server can give its photo.
  @Test func aPhotoIsSentBeforeTheWritingThatPointsAtIt() async throws {
    let device = try TwoDevices.Device(server: server(), ownKey: ownKey)
    let photo = photo()
    try device.photos.keep(photo)
    let written = writing(pointingAt: [photo.id])
    try device.writings.save(written)

    _ = try await device.synchronizer.sync()

    let puts = await fake.requests.filter { $0.httpMethod == "PUT" }.compactMap(\.url?.path)
    let id = photo.id.uuidString.lowercased()
    #expect(
      puts == [
        "/photos/\(id)/thumbnail", "/photos/\(id)",
        "/writings/\(written.id.uuidString.lowercased())",
      ])
  }

  @Test func aPhotoIsSentOnce() async throws {
    let device = try TwoDevices.Device(server: server(), ownKey: ownKey)
    let photo = photo()
    try device.photos.keep(photo)
    let written = writing(pointingAt: [photo.id])
    try device.writings.save(written)
    _ = try await device.synchronizer.sync()
    var edited = written
    edited.updated += 60
    try device.writings.save(edited)
    try device.writings.save(writing(pointingAt: [photo.id], at: 2_000))

    let again = try await device.synchronizer.sync()

    #expect(again.sent.count == 2)
    #expect(again.photosSent.isEmpty)
    #expect(await fake.requests.filter { $0.url?.path.hasPrefix("/photos") == true }.count == 2)
  }

  /// A photo the device doesn't have holds nothing back; once the device has it, the next sync
  /// sends it, though its writing hasn't changed.
  @Test func aPhotoTheDeviceLacksIsSentOnceItIsThere() async throws {
    let device = try TwoDevices.Device(server: server(), ownKey: ownKey)
    let photo = photo()
    let written = writing(pointingAt: [photo.id])
    try device.writings.save(written)

    let first = try await device.synchronizer.sync()
    #expect(first.sent == [written.id])
    #expect(first.photosSent.isEmpty)

    try device.photos.keep(photo)
    let second = try await device.synchronizer.sync()
    #expect(second.sent.isEmpty)
    #expect(second.photosSent == [photo.id])
    let read = try #require(try await server().readPhoto(photo.id, .photo))
    #expect(try ownKey.open(read) == photo.photo)
  }

  /// A writing whose photo the server can't give yet (404) is taken in without it, and the photo
  /// is taken at a later sync once the server has it.
  @Test func aPhotoNotOnTheServerYetIsTakenAtALaterSync() async throws {
    let devices = try TwoDevices(server: { server() }, ownKey: ownKey)
    let photo = photo()
    let written = writing(pointingAt: [photo.id])
    try devices.first.writings.save(written)
    _ = try await devices.first.synchronizer.sync()

    let early = try await devices.second.synchronizer.sync()
    #expect(early.received == [written.id])
    #expect(early.photosReceived.isEmpty)
    #expect(try devices.second.photos.read(photo.id) == nil)

    try devices.first.photos.keep(photo)
    _ = try await devices.first.synchronizer.sync()
    let later = try await devices.second.synchronizer.sync()
    #expect(later.received.isEmpty)
    #expect(later.photosReceived == [photo.id])
    #expect(try devices.second.photos.read(photo.id) == photo)
  }

  /// A part the server has already (409) counts as sent.
  @Test func aPhotoTheServerHasAlreadyCountsAsSent() async throws {
    let device = try TwoDevices.Device(server: server(), ownKey: ownKey)
    let photo = photo()
    let sealed = try ownKey.seal(photo)
    _ = try await server().send(sealed.thumbnail)
    _ = try await server().send(sealed.photo)
    try device.photos.keep(photo)
    let written = writing(pointingAt: [photo.id])
    try device.writings.save(written)

    let report = try await device.synchronizer.sync()

    #expect(report.sent == [written.id])
    #expect(report.photosSent == [photo.id])
  }

  /// A plan's photo limits (429) are the account's: the sync stops, and the writing isn't sent.
  @Test(arguments: [PlanLimit.photos, .photoStorage])
  func aPhotoRefusedForAPlansLimitStopsTheSync(_ limit: PlanLimit) async throws {
    let device = try TwoDevices.Device(
      server: server(transport: RefusingPhotos(fake, status: 429, limit: limit)), ownKey: ownKey)
    let photo = photo()
    try device.photos.keep(photo)
    try device.writings.save(writing(pointingAt: [photo.id]))

    await #expect {
      try await device.synchronizer.sync()
    } throws: { error in
      guard case .limitReached(limit?) = error as? ServerError else { return false }
      return true
    }
    #expect(try await server().list().isEmpty)
  }

  /// A lapsed plan refuses the photo (402): its writing isn't sent, and the sync goes on taking in
  /// the server's writings.
  @Test func aLapsedPlansRefusedPhotoHoldsBackItsWritingAlone() async throws {
    let devices = try TwoDevices(server: { server() }, ownKey: ownKey)
    let theirs = writing(pointingAt: [], at: 2_000)
    try devices.second.writings.save(theirs)
    _ = try await devices.second.synchronizer.sync()
    let lapsed = try TwoDevices.Device(
      server: server(transport: RefusingPhotos(fake, status: 402, limit: nil)), ownKey: ownKey)
    let photo = photo()
    try lapsed.photos.keep(photo)
    let mine = writing(pointingAt: [photo.id])
    try lapsed.writings.save(mine)

    await #expect {
      try await lapsed.synchronizer.sync()
    } throws: { error in
      guard let error = error as? SyncFailures,
        case .refused(status: 402, _) = error.failures[mine.id] as? ServerError
      else { return false }
      return error.failures.count == 1 && error.report.received == [theirs.id]
    }
    #expect(try await server().list().map(\.id) == [theirs.id])
  }

  /// Starting over with a new own key removes the server's photos, so a sync with that key sends
  /// each photo again, sealed with it.
  @Test func aNewOwnKeySendsThePhotosAgain() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "mai-sync-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let writings = MemoryWritingStore()
    let photos = MemoryPhotoStore()
    let photo = photo()
    try photos.keep(photo)
    try writings.save(writing(pointingAt: [photo.id]))
    let synchronizer = { (key: OwnKey) in
      Synchronizer(
        writings: writings, photos: photos, stateFile: directory.appending(path: "state.json"),
        server: server(), ownKey: key)
    }
    #expect(try await synchronizer(ownKey).sync().photosSent == [photo.id])
    #expect(try await synchronizer(ownKey).sync().photosSent.isEmpty)

    #expect(try await synchronizer(OwnKey.generate()).sync().photosSent == [photo.id])
  }

  /// A photo on the server this own key can't open fails its writing alone. (The first device
  /// has the photo, so its send finds the server's there already.)
  @Test func aPhotoSealedWithAnotherKeyFailsItsWritingAlone() async throws {
    let devices = try TwoDevices(server: { server() }, ownKey: ownKey)
    let photo = photo()
    let sealed = try OwnKey.generate().seal(photo)
    _ = try await server().send(sealed.thumbnail)
    _ = try await server().send(sealed.photo)
    try devices.first.photos.keep(photo)
    let written = writing(pointingAt: [photo.id])
    let other = writing(pointingAt: [], at: 2_000)
    try devices.first.writings.save(written)
    try devices.first.writings.save(other)
    _ = try await devices.first.synchronizer.sync()

    await #expect {
      try await devices.second.synchronizer.sync()
    } throws: { error in
      guard let error = error as? SyncFailures else { return false }
      return (error.failures[written.id] as? PhotoOpeningError)?.id == photo.id
        && error.report.received == [written.id, other.id]
    }
    #expect(try devices.second.photos.read(photo.id) == nil)
  }
}

/// Refuses every photo sent with `status`, naming `limit` as the Worker does in a 429.
private struct RefusingPhotos: HTTPTransport {
  let next: any HTTPTransport
  let status: Int
  let limit: PlanLimit?

  init(_ next: any HTTPTransport, status: Int, limit: PlanLimit?) {
    self.next = next
    self.status = status
    self.limit = limit
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard request.httpMethod == "PUT", let url = request.url, url.path.hasPrefix("/photos/"),
      let response = HTTPURLResponse(
        url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])
    else { return try await next.send(request) }
    let body =
      limit.map { #"{"error":"refused","limit":"\#($0.rawValue)"}"# } ?? #"{"error":"refused"}"#
    return (Data(body.utf8), response)
  }
}
