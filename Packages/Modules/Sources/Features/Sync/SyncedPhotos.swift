import Foundation
internal import Sync

/// The photos in `store` as the sync sees them: each photo's JPEG and its thumbnail's, as kept.
nonisolated struct SyncedPhotos: PlainPhotoStore {
  let store: PhotoStore

  func read(_ id: UUID) async throws -> PlainPhoto? {
    let files: (photo: Data, thumbnail: Data)?
    do {
      files = try await store.files(of: id)
    } catch {
      throw UnreadablePhoto(id: id, reason: error)
    }
    return files.map { PlainPhoto(id: id, photo: $0.photo, thumbnail: $0.thumbnail) }
  }

  func keep(_ photo: PlainPhoto) async throws {
    do {
      try store.write(photo: photo.photo, thumbnail: photo.thumbnail, as: photo.id)
    } catch  where (error.reason as? CocoaError)?.code == .fileWriteFileExists {
      // Kept already.
    } catch {
      throw UnkeptReceivedPhoto(id: photo.id, reason: error.reason)
    }
  }
}

/// A photo on the device that couldn't be read for the sync, as while the device is locked. Its
/// writing waits for the next sync; the others still sync.
nonisolated struct UnreadablePhoto: LocalizedError, OneWritingFailure {
  let id: UUID
  let reason: any Error

  var errorDescription: String? {
    "端末の写真が読めず、同期できない文書があります。端末のロックを解いて、もう一度同期してください。"
  }
}

/// A photo from the server that couldn't be kept on the device. The next sync takes it again; the
/// other writings still sync.
nonisolated struct UnkeptReceivedPhoto: LocalizedError, OneWritingFailure {
  let id: UUID
  let reason: any Error

  var errorDescription: String? {
    "同期で届いた写真を端末に残せませんでした。端末の空き容量を確かめて、もう一度同期してください。"
  }
}
