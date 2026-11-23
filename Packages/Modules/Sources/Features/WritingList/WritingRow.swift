import Foundation

/// One writing in the list.
public struct WritingRow: Identifiable, Hashable, Sendable {
  public let id: UUID
  public let title: String
  public let characterCount: Int
  public let updated: Date

  public init(id: UUID, title: String, characterCount: Int, updated: Date) {
    self.id = id
    self.title = title
    self.characterCount = characterCount
    self.updated = updated
  }

  /// How long before `now` the writing was updated, in the largest whole unit: 「1日前」, 「3週間前」.
  /// Under a minute, or after `now`, is 「たった今」.
  func updatedLabel(now: Date, calendar: Calendar) -> String {
    guard updated < now else { return "たった今" }
    let elapsed = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute], from: updated, to: now)
    let years = elapsed.year ?? 0
    let months = elapsed.month ?? 0
    // Across a fall-back the calendar can give 0 days and 24 hours.
    let days = (elapsed.day ?? 0) + (elapsed.hour ?? 0) / 24
    let hours = elapsed.hour ?? 0
    let minutes = elapsed.minute ?? 0
    if years > 0 { return "\(years)年前" }
    if months > 0 { return "\(months)か月前" }
    if days >= 7 { return "\(days / 7)週間前" }
    if days > 0 { return "\(days)日前" }
    if hours > 0 { return "\(hours)時間前" }
    if minutes > 0 { return "\(minutes)分前" }
    return "たった今"
  }
}

extension WritingRow {
  /// The row for `writing`, counting every character of its body.
  init(_ writing: Writing) {
    self.init(
      id: writing.id, title: writing.title, characterCount: writing.body.count,
      updated: writing.updated)
  }
}

extension [WritingRow] {
  /// The most recently updated first; rows updated at the same moment in `id` order.
  func newestFirst() -> [WritingRow] {
    sorted { ($0.updated, $1.id) > ($1.updated, $0.id) }
  }
}

extension WritingRow {
  /// Stand-in rows, updated at times counted back from `now`.
  public static func samples(now: Date, calendar: Calendar) -> [WritingRow] {
    func ago(_ value: Int, _ unit: Calendar.Component) -> Date {
      guard let date = calendar.date(byAdding: unit, value: -value, to: now) else {
        preconditionFailure("\(value) \(unit) before \(now) is out of the calendar's range.")
      }
      return date
    }
    return [
      WritingRow(
        id: UUID(sample: 1), title: "パンを焼く日", characterCount: 1920, updated: ago(24, .hour)),
      WritingRow(
        id: UUID(sample: 2), title: "Hello, World!", characterCount: 1920, updated: ago(25, .hour)),
      WritingRow(
        id: UUID(sample: 3), title: "ものすごく長すぎて入りきらない名前ですよものすごく長すぎて入りきらない名前ですよ",
        characterCount: 1920, updated: ago(26, .hour)),
      WritingRow(
        id: UUID(sample: 4), title: "夜の机に向かう", characterCount: 12480, updated: ago(21, .day)),
      WritingRow(
        id: UUID(sample: 5), title: "書きかけ", characterCount: 8, updated: now),
      WritingRow(
        id: UUID(sample: 6), title: "去年の手紙", characterCount: 640, updated: ago(11, .month)),
      WritingRow(
        id: UUID(sample: 7), title: "朝", characterCount: 312, updated: ago(5, .minute)),
      WritingRow(
        id: UUID(sample: 8), title: "週末に読み返すための、とりとめのない覚え書きをまとめたもの", characterCount: 99999,
        updated: ago(12, .hour)),
      WritingRow(
        id: UUID(sample: 10), title: "読書メモ", characterCount: 2048, updated: ago(2, .hour)),
      WritingRow(
        id: UUID(sample: 9), title: "A long English title that keeps going past the edge",
        characterCount: 12480,
        updated: ago(345, .day)),
    ]
  }
}

extension UUID {
  /// A fixed ID for sample `number`, so samples keep their IDs across launches and devices.
  init(sample number: Int) {
    guard let uuid = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))
    else { preconditionFailure("\(number) doesn't fit in a sample ID.") }
    self = uuid
  }
}
