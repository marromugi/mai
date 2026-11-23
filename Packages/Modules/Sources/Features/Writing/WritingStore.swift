import Foundation

/// Where writings are kept. Saving a writing replaces the one with its ID.
protocol WritingStore {
  /// Every writing kept, in no particular order.
  func all() throws -> [Writing]
  func save(_ writing: Writing) throws
}

extension WritingStore {
  /// Every writing kept, with `samples` saved first when none are.
  /// Stand-in until writings can be written (#29).
  func all(seedingWhenEmpty samples: [Writing]) throws -> [Writing] {
    let writings = try all()
    guard writings.isEmpty else { return writings }
    for sample in samples {
      try save(sample)
    }
    return samples
  }
}

/// Each writing as a JSON file of its own in `directory`, named by its ID.
struct FileWritingStore: WritingStore {
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
      do {
        return try JSONDecoder().decode(Writing.self, from: Data(contentsOf: file))
      } catch {
        throw UnreadableWriting(file: file, reason: error)
      }
    }
  }

  func save(_ writing: Writing) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    try encoder.encode(writing).write(to: file(for: writing.id), options: .atomic)
  }

  func file(for id: Writing.ID) -> URL {
    directory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
  }
}

/// A file in the store that doesn't hold a writing.
struct UnreadableWriting: LocalizedError {
  let file: URL
  let reason: any Error

  var errorDescription: String? {
    "\(file.lastPathComponent) を文書として読めませんでした。\(reason.localizedDescription)"
  }
}
