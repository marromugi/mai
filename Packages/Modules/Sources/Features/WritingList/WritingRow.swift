/// One writing as the list shows it.
public struct WritingRow: Identifiable, Hashable, Sendable {
  public let id: Int
  public let title: String
  public let characterCount: Int
  /// How long ago the writing was updated, already worded: 「1日前」, 「たった今」.
  public let updated: String

  public init(id: Int, title: String, characterCount: Int, updated: String) {
    self.id = id
    self.title = title
    self.characterCount = characterCount
    self.updated = updated
  }

  /// The count without thousands separators: 「1920文字」.
  var characterCountLabel: String { "\(characterCount)文字" }
}

extension WritingRow {
  /// Stand-in writings until there is a store of them.
  public static let samples: [WritingRow] = [
    WritingRow(id: 1, title: "パンを焼く日", characterCount: 1920, updated: "1日前"),
    WritingRow(id: 2, title: "Hello, World!", characterCount: 1920, updated: "1日前"),
    WritingRow(
      id: 3, title: "ものすごく長すぎて入りきらない名前ですよものすごく長すぎて入りきらない名前ですよ",
      characterCount: 1920, updated: "1日前"),
    WritingRow(id: 4, title: "夜の机に向かう", characterCount: 12480, updated: "3週間前"),
    WritingRow(id: 5, title: "書きかけ", characterCount: 8, updated: "たった今"),
    WritingRow(id: 6, title: "去年の手紙", characterCount: 640, updated: "11か月前"),
    WritingRow(id: 7, title: "朝", characterCount: 312, updated: "5分前"),
    WritingRow(
      id: 8, title: "週末に読み返すための、とりとめのない覚え書きをまとめたもの", characterCount: 99999,
      updated: "12時間前"),
    WritingRow(id: 10, title: "読書メモ", characterCount: 2048, updated: "2時間前"),
    WritingRow(
      id: 9, title: "A long English title that keeps going past the edge", characterCount: 12480,
      updated: "11か月前"),
  ]
}
