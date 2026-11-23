import Foundation

/// A writing as it is kept on the device.
nonisolated struct Writing: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  var title: String
  /// Paragraphs separated by line breaks.
  var body: String
  var updated: Date

  init(id: UUID = UUID(), title: String, body: String, updated: Date = .now) {
    self.id = id
    self.title = title
    self.body = body
    self.updated = updated
  }
}

extension Writing {
  /// The sample rows as writings, each body `sampleBody` repeated to the row's character count.
  /// Stand-in for the writings the developer will write (#29).
  static func samples(now: Date, calendar: Calendar) -> [Writing] {
    let paragraph = sampleBody + "\n"
    return WritingRow.samples(now: now, calendar: calendar).map { row in
      let repeated = String(
        repeating: paragraph, count: row.characterCount / paragraph.count + 1)
      return Writing(
        id: row.id, title: row.title, body: String(repeated.prefix(row.characterCount)),
        updated: row.updated)
    }
  }

  nonisolated static let sampleBody = """
    週末に小さなパンを焼いてみたい。
    最初の週は3月2日に粉を買い（ライ麦はまだない）、台所の棚を片づけて生地をこねる場所をつくった。
    目標は丸い田舎パン。フランスの村で焼かれてきたパン・ド・カンパーニュ
    （仏：pain de campagne, 2026年3月2日-2026年4月26日の記録）を手本にして、毎週ひとつ焼く。
    水の量を少しずつ変えることで、焼き上がりの違いを確かめる。
    最初はバター・ロール（小型パン）・食パンの順に試すつもりだったが、オーブンが小さかった。
    そこでカンパーニュ・ミニ（直径12センチ）として焼くことにした。呼び名はミニ。
    FLOUR, WATER+SALT（基本）。
    """
}
