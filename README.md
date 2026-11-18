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
