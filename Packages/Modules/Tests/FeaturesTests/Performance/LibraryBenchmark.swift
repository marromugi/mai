import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Features

/// The main thread's time, in milliseconds of its own CPU time, for the app's work on a heavy
/// library: dozens of writings, one of 100,000 characters (#116). Run with `scripts/benchmark.sh`,
/// which builds `-O` as the Beta build is; skipped in other runs. Each line printed is
/// `benchmark <case>: <median> ms (<each run>)`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BENCHMARK"] == "1"), .serialized)
struct LibraryBenchmark {
  @Test func readingTheLibrary() throws {
    try withHeavyLibrary { store, _ in
      try report("reading the library", runs: 5) {
        let library = WritingLibrary(store: store)
        library.load(seedingWhenEmpty: [])
        guard case .success(let writings) = library.writings, writings.count == Self.count else {
          throw Unread()
        }
      }
    }
  }

  @Test func launchingToTheList() throws {
    try withHeavyLibrary { store, photos in
      try report("launching to the list", runs: 3) {
        let page = HostedPage(root(store, photos, path: []))
        settle(page, for: 1)
        guard page.scrollViews.contains(where: { $0.contentSize.height > 2000 }) else {
          throw Unread()
        }
      }
    }
  }

  @Test func openingTheLongWriting() throws {
    try withHeavyLibrary { store, photos in
      let writings = try store.all()
      let long = try #require(writings.first { $0.id == Self.longID })
      try report("opening the long writing", runs: 3) {
        let page = HostedPage(
          NavigationStack {
            WritingView(
              writing: long, others: others(than: long.id, in: writings), open: { _ in },
              edit: { _ in }, photos: [], setting: .constant(.standard),
              camera: .standIn(taking: nil), photoTaken: { _ in })
          })
        settle(page, for: 2)
        guard longEditor(in: page) != nil else { throw Unread() }
      }
    }
  }

  @Test func typingIntoTheLongWriting() throws {
    try withHeavyLibrary { store, photos in
      let page = HostedPage(root(store, photos, path: [Self.longID]))
      settle(page, for: 3)
      let editor = try #require(longEditor(in: page))
      editor.becomeFirstResponder()
      settle(page, for: 0.5)
      editor.selectedRange = NSRange(location: (editor.text as NSString).length / 2, length: 0)
      settle(page, for: 0.5)
      try report("typing a character into the long writing", runs: 9) {
        // Under `FoundMentions.rest`, so the mentions aren't found again between keystrokes.
        type("あ", into: editor)
        settle(page, for: 0.3)
      }
      try report("the long writing after typing rests", runs: 3) {
        type("あ", into: editor)
        settle(page, for: 3)
      }
      #expect(editor.text.contains("ああ"))
      editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
      settle(page, for: 0.5)
      try report("typing a character at the end of the long writing", runs: 9) {
        type("い", into: editor)
        settle(page, for: 0.3)
      }
      #expect(editor.text.hasSuffix("いいい"))
    }
  }

  @Test func findingMentionsInTheLongWriting() throws {
    try withHeavyLibrary { store, _ in
      let writings = try store.all()
      let long = try #require(writings.first { $0.id == Self.longID })
      let rest = others(than: long.id, in: writings)
      try report("finding mentions in the long writing", runs: 3) {
        guard !long.body.titleMentions(of: rest).isEmpty else { throw Unread() }
      }
    }
  }

  static let count = 48
  static let longID = UUID(sample: 116)

  /// `count` writings saved in a fresh store: one of 100,000 characters, one titled as the bodies'
  /// mention names, and the rest of 2,000, each body its own string as a read library's are.
  private func withHeavyLibrary(_ test: (FileWritingStore, PhotoStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "LibraryBenchmark-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileWritingStore(directory: directory.appending(path: "Writings"))
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for number in 0..<Self.count {
      let (id, title, length) =
        switch number {
        case 0: (Self.longID, "週末に読み返すための覚え書き", 100_000)
        case 1: (UUID(), "夜の机に向かう", 2_000)
        default: (UUID(), "覚え書き その\(number)", 2_000)
        }
      try store.save(
        Writing(
          id: id, title: title, body: body(length: length),
          updated: start.addingTimeInterval(TimeInterval(-number * 3600))))
    }
    try test(store, PhotoStore(directory: directory.appending(path: "Photos")))
  }

  private func root(_ store: FileWritingStore, _ photos: PhotoStore, path: [Writing.ID])
    -> some View
  {
    RootView(store: store, photoStore: photos, path: path)
      .defaultAppStorage(UserDefaults(suiteName: "LibraryBenchmark") ?? .standard)
  }
}

/// A body `length` characters long, the samples' paragraphs repeated.
private func body(length: Int) -> String {
  let paragraph = Writing.sampleBody + "\n" + Writing.sampleMention + "\n"
  return String(
    String(repeating: paragraph, count: length / paragraph.count + 1).prefix(length))
}

/// Runs `work` `runs` times and prints the median of the main thread's CPU time over each run.
@MainActor
private func report(_ name: String, runs: Int, _ work: () throws -> Void) throws {
  var times: [Double] = []
  for _ in 0..<runs {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    try work()
    times.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1_000_000)
  }
  let median = times.sorted()[times.count / 2]
  let each = times.map { String(format: "%.1f", $0) }.joined(separator: ", ")
  print(String(format: "benchmark %@: %.1f ms (%@)", name, median, each))
}

/// Lets the main run loop run for `seconds`, its queued tasks included, then lays the page out.
@MainActor
private func settle(_ page: HostedPage, for seconds: TimeInterval) {
  RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
  page.settle()
}

/// Types `text` at the caret as the keyboard does.
@MainActor
private func type(_ text: String, into view: UITextView) {
  if view.delegate?.textView?(view, shouldChangeTextIn: view.selectedRange, replacementText: text)
    ?? true
  {
    view.insertText(text)
  }
}

@MainActor
private func longEditor(in page: HostedPage) -> PlaceholderTextView? {
  page.textViews.compactMap { $0 as? PlaceholderTextView }.first {
    ($0.text as NSString).length > 50_000
  }
}

private struct Unread: Error {}

/// Every writing in `writings` but the one with `id`.
private func others(than id: Writing.ID, in writings: [Writing]) -> [Writing] {
  var others: [Writing] = []
  for writing in writings where writing.id != id {
    others.append(writing)
  }
  return others
}
