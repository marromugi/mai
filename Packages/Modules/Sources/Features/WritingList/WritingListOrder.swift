/// The orders the writing list can be sorted in. The raw value is what the chosen order is
/// remembered as.
enum WritingListOrder: String, CaseIterable, Identifiable {
  case newestFirst = "updated"
  case mostCharactersFirst = "characterCount"

  var id: Self { self }

  var title: String {
    switch self {
    case .newestFirst: "更新日時の新しい順"
    case .mostCharactersFirst: "文字数の多い順"
    }
  }
}

extension [WritingRow] {
  func sorted(_ order: WritingListOrder) -> [WritingRow] {
    switch order {
    case .newestFirst: newestFirst()
    case .mostCharactersFirst: mostCharactersFirst()
    }
  }

  /// The longest first; rows of the same length newest first, then in `id` order.
  func mostCharactersFirst() -> [WritingRow] {
    sorted { ($0.characterCount, $0.updated, $1.id) > ($1.characterCount, $1.updated, $0.id) }
  }
}
