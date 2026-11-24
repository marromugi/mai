import Foundation

/// Where writings are kept. Saving a writing replaces the one with its ID.
nonisolated protocol WritingStore: Sendable {
  /// Every writing kept, in no particular order.
  func all() throws -> [Writing]
  func save(_ writing: Writing) throws
}

nonisolated extension WritingStore {
  /// Every writing kept, with `samples` saved first when none are.
  /// Stand-in until writings can be made.
  func all(seedingWhenEmpty samples: [Writing]) throws -> [Writing] {
    let writings = try all()
    guard writings.isEmpty else { return writings }
    for sample in samples {
      try save(sample)
    }
    return samples
  }
}

nonisolated extension WritingStore {
  /// Makes `change` to the writing with `id` in `writings`, updated `now`, and saves it; saves
  /// nothing, and answers false, when the change leaves it as it was. `writings` holds the edit
  /// even when the save throws.
  @discardableResult
  func edit(
    _ id: Writing.ID, in writings: inout [Writing], at now: Date,
    _ change: (inout Writing) -> Void
  ) throws -> Bool {
    guard let edited = writings.edit(id, at: now, change) else { return false }
    try save(edited)
    return true
  }
}

/// Each writing as a JSON file of its own in `directory`, named by its ID.
nonisolated struct FileWritingStore: WritingStore {
  let directory: URL

  /// The store in the app's Application Support directory.
  static let onDevice = FileWritingStore(
    directory: .applicationSupportDirectory.appending(path: "Writings", directoryHint: .isDirectory)
  )

  func all() throws -> [Writing] {
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    } catch CocoaError.fileReadNoSuchFile {
      return []
    }
    return try files.filter { $0.pathExtension == "json" }.map { file in
      let writing: Writing
      do {
        writing = try JSONDecoder().decode(Writing.self, from: Data(contentsOf: file))
      } catch {
        throw UnreadableWriting(file: file, reason: error)
      }
      guard file.lastPathComponent == self.file(for: writing.id).lastPathComponent else {
        throw UnreadableWriting(file: file, reason: MisnamedWriting(id: writing.id))
      }
      return writing
    }
  }

  func save(_ writing: Writing) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(writing).write(to: file(for: writing.id), options: .atomic)
  }

  func file(for id: Writing.ID) -> URL {
    directory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
  }
}

/// A file in the store that doesn't hold a writing.
nonisolated struct UnreadableWriting: LocalizedError {
  let file: URL
  let reason: any Error

  var errorDescription: String? {
    "\(file.lastPathComponent) を文書として読めませんでした。\(reason.localizedDescription)"
  }
}

/// A file holding a writing whose ID is not the file's name, so saving that writing would not
/// replace it.
nonisolated struct MisnamedWriting: LocalizedError {
  let id: Writing.ID

  var errorDescription: String? {
    "中の文書の ID は \(id.uuidString) です。"
  }
}
