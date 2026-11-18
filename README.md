# Mai

自分の言葉だけを書く執筆アプリ。

## 開く

Xcode プロジェクトは `project.yml` から生成する(XcodeGen 2.44 以上)。生成物はコミットしない。

```sh
brew install xcodegen
xcodegen generate
open Mai.xcodeproj
```

コードは `Packages/Modules` のローカルパッケージに置き、`App/` はアプリの入り口だけを持つ。

## スナップショットテスト

見た目のテストは、決まった 1 台のシミュレータで撮った画像と比べる(機種と iOS は `scripts/snapshot-test.swift` に書いてある)。OS が違うと文字の描かれ方が変わるので、CI ではテストを組み立てるだけで走らせない。

```sh
swift scripts/snapshot-test.swift
```

そのシミュレータが無ければ作る。見た目を変えたときは撮り直す。撮り直した回は、撮った分だけテストが失敗と表示される。差分の画像を確かめてからコミットする。

```sh
swift scripts/snapshot-test.swift --record
```
