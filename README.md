# Mai

自分の言葉だけを書く執筆アプリ。

## 開く

Xcode プロジェクトは `project.yml` から生成する(XcodeGen 2.44 以上)。生成物はコミットしない。

```sh
brew install xcodegen
xcodegen generate
open Mai.xcodeproj
```

コードは `Packages/Modules` のローカルパッケージに置き、`App/` はアプリの入り口だけを持つ。UIKit と SwiftUI を使わない文字組みの計算(文字の大きさ、行の高さ、余白、版面など)は `Packages/Typesetting` に置き、`Packages/Modules` がそれを使う。

## テスト

`Packages/Typesetting` のテストは Mac で走る。

```sh
swift test --package-path Packages/Typesetting
```

Dynamic Type の大きさ、フォント、画面のテストは `Packages/Modules` にあり、スナップショットテストと一緒にシミュレータで走る(次の節)。

## モデル検査

読み取りモードの鍵の写しは TLA+ でモデルにしてある(`Specs/ReadMode`)。TLC で確かめる(Java 11 以上が要る)。

```sh
scripts/model-check.sh
```

## スナップショットテスト

見た目のテストは、決まった 1 台のシミュレータで撮った画像と比べる(機種と iOS は `scripts/snapshot-test.swift` に書いてある)。OS が違うと文字の描かれ方が変わるので、CI ではこのテストを組み立てるだけで走らせない。

```sh
swift scripts/snapshot-test.swift
```

そのシミュレータが無ければ作る。止まっていれば起動し、テストが終わっても起動したままにする(次の回が起動を待たずに済む)。止めるときは `xcrun simctl shutdown mai-snapshots`。画像がまだ無いテストは、その回に撮られて失敗と表示される。撮れた画像を確かめてコミットし、もう一度走らせる。見た目を変えたときは撮り直す。撮り直した回は、撮った分だけテストが失敗と表示される。差分の画像を確かめてからコミットする。

```sh
swift scripts/snapshot-test.swift --record
```

テストが失敗しても、シミュレータの診断(ログやクラッシュレポート。結果が 1 回 50MB ほど増え、失敗した回が数十秒長くなる)は集めない。原因の分からないクラッシュやシミュレータの不調を調べるときだけ `--diagnostics` を付けて集める。

```sh
swift scripts/snapshot-test.swift --diagnostics
```
