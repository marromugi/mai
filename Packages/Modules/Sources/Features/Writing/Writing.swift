/// A writing as its page shows it.
struct Writing: Equatable {
  let title: String
  /// Paragraphs separated by line breaks.
  let body: String
}

extension Writing {
  /// Stand-in until there is a store of writings: `title` over one sample body, which ends naming
  /// another sample writing's title.
  static func sample(titled title: String) -> Writing {
    Writing(title: title, body: sampleBody + "\n" + sampleMention)
  }

  static let sampleMention = "焼いた日の夜のことは「夜の机に向かう」に書いた。"

  static let sampleBody = """
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
