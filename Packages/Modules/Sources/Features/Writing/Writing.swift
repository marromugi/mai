import Foundation

/// A writing: what the store keeps and its page shows.
nonisolated struct Writing: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  var title: String
  /// Paragraphs separated by line breaks.
  var body: String
  /// Stretches of `body` that link outside the app: whole characters, in order, never overlapping,
  /// as `fitted(to:)` leaves them.
  var links: [BodyLink]
  var updated: Date

  init(
    id: UUID = UUID(), title: String, body: String, links: [BodyLink] = [], updated: Date = .now
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.links = links
    self.updated = updated
  }

  private enum CodingKeys: CodingKey {
    case id, title, body, links, updated
  }

  /// A writing saved before links were kept has none. A link that can't be read is dropped, and
  /// the rest are made to fit the body as `fitted(to:)` does, so the body is read whatever its
  /// links say.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    body = try container.decode(String.self, forKey: .body)
    let saved = (try? container.decodeIfPresent([ReadableLink].self, forKey: .links)) ?? nil
    links = (saved ?? []).compactMap(\.link).fitted(to: body)
    updated = try container.decode(Date.self, forKey: .updated)
  }
}

/// A saved link, or nil where it can't be read as one.
private nonisolated struct ReadableLink: Decodable {
  let link: BodyLink?

  init(from decoder: any Decoder) throws {
    link = try? BodyLink(from: decoder)
  }
}

extension [Writing] {
  /// Makes `change` to the writing with `id`, updated `now`, and returns it. Nil, and nothing
  /// changed, when none has `id` or the change leaves its title, body, and links as they were.
  mutating func edit(_ id: Writing.ID, at now: Date, _ change: (inout Writing) -> Void) -> Writing?
  {
    guard let index = firstIndex(where: { $0.id == id }) else { return nil }
    var edited = self[index]
    change(&edited)
    let before = self[index]
    guard
      edited.title != before.title || edited.body != before.body || edited.links != before.links
    else { return nil }
    edited.updated = now
    self[index] = edited
    return edited
  }
}

extension Writing {
  /// The sample rows as writings, each body `sampleBody` and `sampleMention` repeated to the row's
  /// character count. Stand-in until writings can be made.
  static func samples(now: Date, calendar: Calendar) -> [Writing] {
    let paragraph = sampleBody + "\n" + sampleMention + "\n"
    return WritingRow.samples(now: now, calendar: calendar).map { row in
      let repeated = String(
        repeating: paragraph, count: row.characterCount / paragraph.count + 1)
      return Writing(
        id: row.id, title: row.title, body: String(repeated.prefix(row.characterCount)),
        updated: row.updated)
    }
  }

  /// Names another sample writing's title, so the samples show a title link.
  nonisolated static let sampleMention = "焼いた日の夜のことは「夜の机に向かう」に書いた。"

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
