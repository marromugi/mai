# Cotoma

自分の言葉だけを書く執筆アプリ。

## 開く

Xcode プロジェクトは `project.yml` から生成する(XcodeGen 2.44 以上)。生成物はコミットしない。

```sh
brew install xcodegen
xcodegen generate
open Mai.xcodeproj
```

Xcode から実行したアプリは、同期のプランを App Store ではなく `StoreKit/Mai.storekit` から読み、購入もそこで済ませる(`Mai` スキームの StoreKit Configuration)。

コードは `Packages/Modules` のローカルパッケージに置き、`App/` はアプリの入り口だけを持つ。UIKit と SwiftUI を使わない文字組みの計算(文字の大きさ、行の高さ、余白、版面など)は `Packages/Typesetting` に置き、`Packages/Modules` がそれを使う。文書の暗号化と同期、同期のアカウント(Apple でのサインイン、セッション、自分の鍵)のクライアントは `Packages/Sync` に置き、`Packages/Modules` がそれを使う。同期先のサーバー(Cloudflare Worker)は `Server/` に置く(`Server/README.md`)。読み取りモードの文書を Mac で読む MCP サーバーは `Packages/Agent` に置く(下の「Mac の MCP サーバー」)。

## テスト

`Packages/Typesetting` のテストは Mac で走る。

```sh
swift test --package-path Packages/Typesetting
```

`Packages/Sync` のテストも Mac で走る。名前に `Contract` の付くテスト(文書の同期と、Apple でのサインイン・自分の鍵と、読み取りモード)は手元の Worker が要るので外し、`scripts/server-contract-test.sh` で走らせる(`Server/README.md`)。

```sh
swift test --package-path Packages/Sync --skip Contract
```

キーチェーンのテストと、同期のプランを買うテスト(StoreKit の手元の試験。商品は `StoreKit/Mai.storekit`)はアプリの中でしか走らないので、`Mai` スキームの `MaiTests`(`AppTests/`)に置く。

```sh
xcodebuild test -project Mai.xcodeproj -scheme Mai -only-testing:MaiTests \
  -destination 'platform=iOS Simulator,name=mai-snapshots' -collect-test-diagnostics never
```

Dynamic Type の大きさ、フォント、画面のテストは `Packages/Modules` にあり、スナップショットテストと一緒にシミュレータで走る(次の節)。

`Packages/Agent` のテストも Mac で走る(Secure Enclave は使わず、ソフトウェアの鍵で)。

```sh
swift test --package-path Packages/Agent
```

## Mac の MCP サーバー

`mai-mcp`(`Packages/Agent`、#27)は、iPhone で読み取りモードがオンの間だけ、「AI に読ませない」にしていない文書を読む MCP サーバー。標準入出力で動き、`list_writings`・`read_writing`・`search_writings` の 3 つを出す。どれも読むだけ。Apple シリコンか T2 チップの Mac が要る(鍵を Secure Enclave で作る)。

ソースから作って置き、iPhone と組み、MCP のクライアントに登録する。

```sh
swift build -c release --package-path Packages/Agent
mkdir -p ~/.local/bin && cp Packages/Agent/.build/release/mai-mcp ~/.local/bin/
~/.local/bin/mai-mcp pair
claude mcp add cotoma -- ~/.local/bin/mai-mcp
```

Claude Desktop は `~/Library/Application Support/Claude/claude_desktop_config.json` に `{"mcpServers": {"cotoma": {"command": "/Users/<名前>/.local/bin/mai-mcp"}}}` を書く。

- **組む**: `mai-mcp pair` が Secure Enclave に鍵を作り、ペアリングのコードを QR コードと文字で出す。iPhone の Cotoma で「設定」→「AI に読ませる」→「エージェントを承認…」から読み取るか打ち、承認のあとに出る 1 行(`<Worker の URL>#<トークン>`)を「コピー」して `mai-mcp pair` に貼る。トークンでサーバーを読めたときだけ残す。形は `Server/README.md` の「エージェントの側」。
- **残すもの**: `~/Library/Application Support/mai-mcp/pairing.json`(`MAI_MCP_HOME` で場所を変えられる)の 1 つだけで、この利用者だけが読める。中身は Secure Enclave が返す鍵の形(この Mac の Secure Enclave でしか使えない)、サーバーの URL、その鍵あてに HPKE で封じたトークン。開いた文書は `mai-mcp` のプロセスのメモリにだけ置き、ファイルには書かない。
- **組み直す**: 同じ鍵は二度承認できないので、`mai-mcp pair` はいつも新しい鍵を作る。前のペアリングは、新しいトークンで読めるまで残る。`mai-mcp forget` はペアリングを消す。どちらのときも、iPhone で前のエージェントを取り消す。
- **読む**: どのツールも、まずサーバーの写しの一覧を取り、その中にあるものだけを開く。読み取りモードがオフか終わる時刻を過ぎていれば、何も読めないと答える。iPhone で取り消したエージェントには、組み直すように答える。

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
