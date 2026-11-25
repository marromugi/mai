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
  /// The IDs of its photos, oldest first, none twice, shown after the body. A writing synced from
  /// another device may point at a photo this device's `PhotoStore` doesn't have.
  var photos: [UUID]
  var updated: Date

  init(
    id: UUID = UUID(), title: String, body: String, links: [BodyLink] = [], photos: [UUID] = [],
    updated: Date = .now
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.links = links
    self.photos = photos
    self.updated = updated
  }

  /// Texts compared by their bytes, as `String.isSameText(as:)` compares them.
  static func == (lhs: Writing, rhs: Writing) -> Bool {
    lhs.id == rhs.id && lhs.updated == rhs.updated && lhs.photos == rhs.photos
      && lhs.links == rhs.links && lhs.title.isSameText(as: rhs.title)
      && lhs.body.isSameText(as: rhs.body)
  }

  private enum CodingKeys: CodingKey {
    case id, title, body, links, photos, updated
  }

  /// A writing saved before links or photos were kept has none. A link that can't be read is
  /// dropped, and the rest are made to fit the body as `fitted(to:)` does, so the body is read
  /// whatever its links say. Photos are read as `photoIDs(forKey:)` reads them.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    body = try container.decode(String.self, forKey: .body)
    let saved = (try? container.decodeIfPresent([ReadableLink].self, forKey: .links)) ?? nil
    links = (saved ?? []).compactMap(\.link).fitted(to: body)
    photos = container.photoIDs(forKey: .photos)
    updated = try container.decode(Date.self, forKey: .updated)
  }
}

/// A saved link, or nil where it can't be read as one.
nonisolated struct ReadableLink: Decodable {
  let link: BodyLink?

  init(from decoder: any Decoder) throws {
    link = try? BodyLink(from: decoder)
  }
}

nonisolated extension KeyedDecodingContainer {
  /// The photo IDs under `key`, each once, in their first place. An ID that can't be read is
  /// dropped, and a value that isn't a list reads as none, so the writing is read whatever its
  /// photos say.
  func photoIDs(forKey key: Key) -> [UUID] {
    let saved = (try? decodeIfPresent([ReadablePhotoID].self, forKey: key)) ?? nil
    var seen = Set<UUID>()
    return (saved ?? []).compactMap(\.id).filter { seen.insert($0).inserted }
  }
}

/// A saved photo ID, or nil where it can't be read as one.
nonisolated struct ReadablePhotoID: Decodable {
  let id: UUID?

  init(from decoder: any Decoder) throws {
    id = try? UUID(from: decoder)
  }
}

nonisolated extension [Writing] {
  /// Makes `change` to the writing with `id`, updated `now`, and returns it. Nil, and nothing
  /// changed, when none has `id` or the change leaves its title, body, links, and photos as they
  /// were.
  mutating func edit(_ id: Writing.ID, at now: Date, _ change: (inout Writing) -> Void) -> Writing?
  {
    guard let index = firstIndex(where: { $0.id == id }) else { return nil }
    var edited = self[index]
    change(&edited)
    let before = self[index]
    guard
      !edited.title.isSameText(as: before.title) || !edited.body.isSameText(as: before.body)
        || edited.links != before.links || edited.photos != before.photos
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

nonisolated extension String {
  /// Whether `other` holds the same bytes: a text unchanged by an edit. A memory compare, where
  /// `==` works out canonical equivalence character by character, which a long body pays for on
  /// every keystroke.
  func isSameText(as other: String) -> Bool {
    guard utf8.count == other.utf8.count else { return false }
    let compared = utf8.withContiguousStorageIfAvailable { bytes in
      other.utf8.withContiguousStorageIfAvailable { otherBytes in
        bytes.count == 0 || memcmp(bytes.baseAddress, otherBytes.baseAddress, bytes.count) == 0
      }
    }
    return (compared ?? nil) ?? utf8.elementsEqual(other.utf8)
  }

  /// This text with its bytes in one piece, as `isSameText(as:)` compares them quickest.
  var contiguous: String {
    var text = self
    text.makeContiguousUTF8()
    return text
  }
}
