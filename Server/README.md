# サーバー

暗号化した文書だけを置き、端末どうしの同期に使う Cloudflare Worker(#25)。文書は 1 つの Durable Object(SQLite)に置く。サーバーが分かるのは、文書ごとの ID・更新時刻・大きさだけ。保存どうしを見分けるリビジョンは暗号化した文書の SHA-256 で、暗号文から誰でも出せるもの。

## 暗号化した文書の形

アプリ(`Packages/Sync` の `OwnKey.seal`)が作り、サーバーはこの形でない書き込みを断る。

| 位置 | 長さ   | 中身                                                                              |
| ---- | ------ | --------------------------------------------------------------------------------- |
| 0    | 4      | `6d 61 69 01`(`mai` と形の版 1)                                                   |
| 4    | 16     | 文書の ID(UUID のバイト列)                                                        |
| 20   | 8      | 更新時刻。1970 年からのミリ秒、符号なしのビッグエンディアン。1 から 2^53 − 1 まで |
| 28   | 60     | 文書の鍵を自分の鍵で封じたもの。nonce 12・暗号文 32・タグ 16                      |
| 88   | 28 + n | 本文を文書の鍵で封じたもの。nonce 12・暗号文 n・タグ 16                           |

どちらも AES-256-GCM で、先頭の 28 バイトを認証付きデータにする。文書の鍵は保存のたびに作り直す。全体は 116 バイトから 1,900,000 バイトまで(Durable Object の 1 行の上限 8 MB より十分小さくしてある)。

`test/fixtures/sealed-writing.json` はアプリが封じた文書で、両方のテストがこの形で読む。

## 経路

どれも `Authorization: Bearer <token>` が要る。token の SHA-256 が秘密の値 `ACCESS_TOKEN_SHA256` と合わなければ 401。アプリは自分の鍵から token を作る(`OwnKey.accessToken`)。

| 経路                 | 内容                                                                                                                                                                                                                                      |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /writings`      | `{"writings": [{"id", "revision", "updated", "size"}]}`                                                                                                                                                                                   |
| `GET /writings/<ID>` | 暗号化した文書(`application/octet-stream`)。リビジョンは `Mai-Revision` に。無ければ 404                                                                                                                                                  |
| `PUT /writings/<ID>` | 暗号化した文書を `application/octet-stream` で送り、最後に読んだリビジョンを `Mai-Base-Revision` に(新しい文書は `none`)。合えば 200 と新しいリビジョン、合わなければ 409 と今のリビジョン(無ければ null)。形が違えば 400、型が違えば 415 |

`PUT` は `Specs/ReadMode` のモデルの `Save` のうち文書そのものを置く部分にあたる。モデルには断られる保存がないので、#26 は受けられた保存にだけ写しを送る。`GET` は文書を取るもので、モデルは文書の中身を扱わない。モデルの `Sync` が取り込む設定は #26 が足す。

## 手元で動かす

```sh
pnpm install
pnpm test          # Worker のテスト(Miniflare の上で動く)
pnpm typecheck
pnpm lint          # oxlint
pnpm fmt:check     # oxfmt
```

アプリの同期の部品(`Packages/Sync`)を `wrangler dev` の Worker に通して確かめる。

```sh
scripts/server-contract-test.sh
```

## デプロイ

まだしていない。するときは、Cloudflare にログインして次を実行する(Worker と Durable Object が作られる)。

```sh
pnpm exec wrangler deploy
printf '%s' "<アプリの「設定」→「同期」の「サーバーに置く値」>" | pnpm exec wrangler secret put ACCESS_TOKEN_SHA256
```

「サーバーに置く値」は、自分の鍵から作った token の SHA-256(`OwnKey.accessTokenSHA256`)。最初の端末で「新しい鍵を作る」と出る。そのあと、同じ画面のサーバーの URL にデプロイした Worker の URL を入れる。
