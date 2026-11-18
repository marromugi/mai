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

見た目のテストは、この Mac の iPhone 17 Pro(iOS 27.2)のシミュレータで撮った画像と比べる。OS が違うと文字の描かれ方が変わるので、CI ではテストを組み立てるだけで走らせない。

```sh
./scripts/snapshot-test.sh
```

シミュレータ `mai-snapshots` が無ければ作る。見た目を変えたときは撮り直して、差分の画像を確かめてからコミットする。

```sh
SNAPSHOT_TESTING_RECORD=all ./scripts/snapshot-test.sh
```
