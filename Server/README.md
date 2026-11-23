# サーバー

暗号化した文書を置き、端末どうしの同期に使う Cloudflare Worker(#25)。アプリが取る書体のファイルも R2 から配る(#48、下の「書体」)。データは Turso の 1 つのデータベースに置き、アカウントのデータはどの表でもアカウント ID の列で分ける(#22 の設計、#43)。表は `schema.sql`、Turso に触るのは `src/store.ts` だけで、1 リクエストを 1 つの `batch()`(1 往復・1 トランザクション)にする。サーバーが分かるのは、文書ごとの ID・更新時刻・大きさと、アカウントごとの Apple の利用者・Apple の refresh トークン(封じたもの)・自分の鍵の確かめの値だけ。保存どうしを見分けるリビジョンは暗号化した文書の SHA-256 で、暗号文から誰でも出せるもの。書体の取得では、アカウントと結びつかない形で、どのファイルを取ったかとリクエストの IP が分かる。

## 暗号化した文書の形

アプリ(`Packages/Sync` の `OwnKey.seal`)が作り、サーバーはこの形でない書き込みを断る。

| 位置 | 長さ   | 中身                                                                              |
| ---- | ------ | --------------------------------------------------------------------------------- |
| 0    | 4      | `6d 61 69 01`(`mai` と形の版 1)                                                   |
| 4    | 16     | 文書の ID(UUID のバイト列)                                                        |
| 20   | 8      | 更新時刻。1970 年からのミリ秒、符号なしのビッグエンディアン。1 から 2^53 − 1 まで |
| 28   | 60     | 文書の鍵を自分の鍵で封じたもの。nonce 12・暗号文 32・タグ 16                      |
| 88   | 28 + n | 本文を文書の鍵で封じたもの。nonce 12・暗号文 n・タグ 16                           |

どちらも AES-256-GCM で、先頭の 28 バイトを認証付きデータにする。文書の鍵は保存のたびに作り直す。全体は 116 バイトから 1,900,000 バイトまで。

`test/fixtures/sealed-writing.json` はアプリが封じた文書で、両方のテストがこの形で読む。

## 経路

### アカウントとサインイン

アカウントは、有料の同期プランに入るときにアプリが作る(#22)。どれもセッションは要らず、JSON(`Content-Type: application/json`)を送る。

| 経路               | 内容                                                                                                                                                                                                                                                                                                               |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `POST /challenges` | 201 と `{"challenge"}`。5 分使える。アプリはその SHA-256(小文字の 16 進)を Sign in with Apple の nonce にする                                                                                                                                                                                                      |
| `POST /account`    | `{"account", "challenge", "identityToken", "authorizationCode"}`。`account` はアプリが作った UUID で、購入の `appAccountToken` と同じもの。201 と `{"token"}`(セッションのトークン)。その Apple の利用者かその ID のアカウントがもうあれば 409 で、アカウントもセッションも作らない(サインインは `POST /sessions`) |
| `POST /sessions`   | `{"challenge", "identityToken"}`。200 と `{"account", "token"}`。その Apple の利用者のアカウントがなければ 404                                                                                                                                                                                                     |

ID トークンは `src/apple-sign-in.ts` で、Apple の鍵の署名・`iss`・`aud`(`APPLE_CLIENT_ID`)・`exp` と、nonce がチャレンジの SHA-256 であることを確かめる。チャレンジは `CHALLENGE_KEY` の HMAC で、サーバーは出すときには何も書かず、使ったものを期限の 1 時間あとまで `used_challenges` に置く。使ったもの、このサーバーが出していないもの、期限の切れたもの(Apple を待つ間に切れたものも)、ID トークンが別のチャレンジに作られたものは 401。チャレンジは通ればその場で使ったことになり、409 や 404 で終わっても使い直せない。

`POST /account` は認可コードを Apple の `/auth/token` で refresh トークンに替え(`src/apple-tokens.ts`)、`REFRESH_TOKEN_KEY` の AES-256-GCM でアカウント ID を付けて封じて `accounts.apple_refresh_token` に置く(`src/refresh-tokens.ts`)。封じる前の値はどこにも置かない。Apple がコードを断るか(`invalid_grant`)、コードが別の利用者のものなら 401、Apple が答えなければ 502。Apple がそれ以外の 4xx を返したら Worker の要求か `APPLE_` の秘密の誤りなので 500。購入を確かめてプランを決めるのは #22 の S4 で、それまではどのアカウントも `basic` で作る。

### セッションのある経路

どれも `Authorization: Bearer <セッションのトークン>` が要る。トークンは `s1.<セッション ID>.<秘密>`(秘密は 32 バイトの base64url)で、サーバーは秘密(base64url の文字列)の SHA-256 だけを `sessions` に置く。知らないトークン、形の違うトークン、最後に使ってから 180 日たったセッションは、経路や中身を見る前に 401。Apple に届かない手元の試験では、テストは `Store.makeAccount` で、手元で動かすときは `scripts/new-session.sh` で、Apple の利用者のいないアカウントとセッションを作る。

| 経路                         | 内容                                                                                                                                                                                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DELETE /session`            | サインアウト。このセッションを終えて 204                                                                                                                                                                                                  |
| `PUT /account/own-key-check` | 自分の鍵から作った確かめの値(32 バイト)を `application/octet-stream` で。アカウントにまだなければ置いて 204、同じ値なら 204、別の値なら 409(2 つ目の自分の鍵は作らせない)。長さが違えば 400、型が違えば 415                               |
| `GET /writings`              | `{"writings": [{"id", "revision", "updated", "size"}]}`                                                                                                                                                                                   |
| `GET /writings/<ID>`         | 暗号化した文書(`application/octet-stream`)。リビジョンは `Mai-Revision` に。無ければ 404                                                                                                                                                  |
| `PUT /writings/<ID>`         | 暗号化した文書を `application/octet-stream` で送り、最後に読んだリビジョンを `Mai-Base-Revision` に(新しい文書は `none`)。合えば 200 と新しいリビジョン、合わなければ 409 と今のリビジョン(無ければ null)。形が違えば 400、型が違えば 415 |

文書の ID はアカウントごとに分かれ、ほかのアカウントの文書は読めず、書けず、一覧にも出ない。

`PUT` は `Specs/ReadMode` のモデルの `Save` のうち文書そのものを置く部分にあたる。モデルには断られる保存がないので、#26 は受けられた保存にだけ写しを送る。`GET` は文書を取るもので、モデルは文書の中身を扱わない。モデルの `Sync` が取り込む設定は #26 が足す。

### プランの上限

アカウントはプラン(`plans` 表の `basic`・`plus`・`pro`)に入っている。上限に届いた要求は 429 で、何も書かず、数えもしない。

- 1 日(UTC)のリクエスト数、そのうちの一覧(`GET /writings`)と保存(`PUT`、409 になったものも数える)の数。`usage` 表で数える。
- 文書の合計の大きさと本数。`writings` のトリガーが `accounts` に足し、超えた保存は batch ごと戻る。大きさの減る保存は断らない。

上限の値は #22 の設計の案で、プランと値段の答え(#22 の質問)で変わりうる。変えるときは `plans` の行を書き換える。

### 書体

| 経路                | 内容                                                                                                                                                               |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GET /fonts/<file>` | R2 のバケット(binding `FONTS`)の `fonts/<file>` を返す。セッションは要らない。`Cache-Control: public, max-age=31536000, immutable`。無い名前は 404、GET 以外は 405 |

アプリは和文の書体をここから取り、`FontFamily.known` の SHA-256 と合うものだけを端末に置く(#48)。置くファイルは `fonts.json` に、google/fonts のコミットと SHA-256 と一緒に並べてある。アプリの一覧と `fonts.json` が同じファイルを指すことは `ServerFontsTests` が確かめる。書体のライセンスはアプリが持っているので、バケットには置かない。

`scripts/upload-fonts.sh` が google/fonts から取り、SHA-256 を確かめてからバケットに置く。手元では `wrangler dev` と同じ `--persist-to` を渡す。

```sh
scripts/upload-fonts.sh --local --persist-to /private/tmp/mai-wrangler
pnpm exec wrangler dev --persist-to /private/tmp/mai-wrangler --var TURSO_URL:http://127.0.0.1:8080 --var TURSO_TOKEN:
```

デバッグビルドのアプリは `http://localhost:8787` から取る。ほかのポートは環境変数 `MAI_SERVER_URL` で渡す。リリースビルドはまだサーバーを持たず、和文の書体は一覧に出ない。

### 期限の掃除

Cron(毎分)が、最後に使ってから 180 日たったセッションと、前の日までの `usage` と、期限から 1 時間たった `used_challenges` を消す(`Store.sweep`)。#26 の写しと読み取りモードの期限もここに足す。

## Apple の署名

ID トークンは上のサインインの経路が呼ぶ。署名つき取引と通知はまだ呼ばない(#22 の S4 が呼ぶ)。どれも WebCrypto だけで確かめ、通れば読み出した値を、通らなければ理由を返す。

- `src/apple-sign-in.ts`: Sign in with Apple の ID トークン。Apple の JWKS(RS256)で署名、`iss`、`aud`(バンドル ID)、`exp`、渡された `nonce`。JWKS は Cache に 1 日置き、知らない鍵 ID が来たら取り直す(前の取得から 5 分たっていれば、1 回だけ)。
- `src/app-store.ts`: StoreKit 2 の署名つき取引・更新の情報と、App Store Server Notifications V2 の `signedPayload`(中の取引と更新の情報も)。ES256 の署名と、`x5c` の葉・中間が `src/apple-root.ts` の Apple Root CA - G3 までつながること。ルートは引数で渡し、`x5c` の中のルートは使わない。通っても、期限(`expiresDate`)・取り消し(`revocationDate`)・環境(`environment`)・`appAccountToken` がどのアカウントかは確かめていない。購入として受けるかは呼ぶ側(S4)が決める。Xcode の StoreKit の試験で作った取引は Apple の鍵で署名されていないので、どれも通らない。

テストは自分で作った認証局と鍵で作ったものを確かめる。本物で確かめているのは、G3 と、それが署名した中間の WWDR G6 だけ。

## 手元で動かす

テストは手元の libSQL サーバー `sqld`(`turso dev` が中で動かすもの)を空のデータベースで立て、`schema.sql` を入れてから走る。ログインは要らない。

```sh
brew install tursodatabase/tap/turso libsql/sqld/sqld
pnpm install
pnpm test          # Worker のテスト(Miniflare の上で動き、sqld につなぐ)
pnpm typecheck
pnpm lint          # oxlint
pnpm fmt:check     # oxfmt
```

手元で Worker を動かすときは、データベースのファイルに表とセッションを作ってから `turso dev` で出す。`new-session.sh` がトークンを出す。サインインの経路は Apple に届かないと使えないので、手元では動かさず、テストが偽物の Apple で確かめる(秘密は `TURSO_` のほかは渡さない。`POST /challenges` などは 500)。

```sh
sqlite3 /private/tmp/mai.db < schema.sql
scripts/new-session.sh /private/tmp/mai.db        # 2 つ目の引数でプランを選べる(既定は basic)
turso dev --db-file /private/tmp/mai.db --port 8080
pnpm exec wrangler dev --var TURSO_URL:http://127.0.0.1:8080 --var TURSO_TOKEN:
```

アプリの同期の部品(`Packages/Sync`)を、`turso dev` と `wrangler dev` の Worker に通して確かめる。

```sh
scripts/server-contract-test.sh
```

## デプロイ

まだしていない。するときは、次のものが作られる。

- Turso: データベース `mai` 1 つ(`schema.sql` の表とトリガー、`plans` の 3 行)と、それに書ける認証トークン 1 つ
- Cloudflare: R2 のバケット `mai-fonts` 1 つと、そこに置く書体のファイル 6 つ(合わせて 28.8 MB)
- Cloudflare: Worker `mai-server` 1 つ(`workers.dev` の URL つき)、その毎分の Cron Trigger、秘密 `TURSO_URL`・`TURSO_TOKEN`・`CHALLENGE_KEY`・`REFRESH_TOKEN_KEY`・`APPLE_CLIENT_ID`・`APPLE_TEAM_ID`・`APPLE_SIGN_IN_KEY_ID`・`APPLE_SIGN_IN_KEY`

その前に開発者が Apple Developer でしておくこと:

- App ID `com.marromugi.mai` で Sign in with Apple を有効にする
- Sign in with Apple の鍵(.p8)を 1 つ作り、その鍵 ID と、チーム ID を控える。.p8 は一度しか落とせない

秘密のうち:

- `APPLE_CLIENT_ID` はアプリのバンドル ID `com.marromugi.mai`(ID トークンの `aud` と、`/auth/token` の `client_id`)
- `APPLE_TEAM_ID`・`APPLE_SIGN_IN_KEY_ID` は上で控えたもの、`APPLE_SIGN_IN_KEY` は .p8 の中身(`-----BEGIN PRIVATE KEY-----` の行ごとでも、間の base64 だけでもよい)
- `CHALLENGE_KEY` と `REFRESH_TOKEN_KEY` はそれぞれ 32 バイトの乱数の base64。`REFRESH_TOKEN_KEY` を変えると、置いてある refresh トークンが開けなくなり、削除のときに Apple で取り消せなくなる

Turso と Cloudflare にログインして、`Server/` で次を実行する。最初のデプロイは、`secrets.required` の秘密をデプロイと一緒に渡す(`--secrets-file`)。

```sh
team_id=...   # チーム ID
key_id=...    # Sign in with Apple の鍵 ID
p8=...        # その .p8 のパス
turso db create mai
turso db shell mai < schema.sql
secrets="$(mktemp)"
printf 'TURSO_URL=%s\nTURSO_TOKEN=%s\n' "$(turso db show mai --url)" "$(turso db tokens create mai)" > "$secrets"
printf 'CHALLENGE_KEY=%s\nREFRESH_TOKEN_KEY=%s\n' "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" >> "$secrets"
printf 'APPLE_CLIENT_ID=com.marromugi.mai\nAPPLE_TEAM_ID=%s\nAPPLE_SIGN_IN_KEY_ID=%s\nAPPLE_SIGN_IN_KEY=%s\n' \
  "$team_id" "$key_id" "$(grep -v -- ----- "$p8" | tr -d '\n')" >> "$secrets"
pnpm exec wrangler r2 bucket create mai-fonts
scripts/upload-fonts.sh --remote
pnpm exec wrangler deploy --secrets-file "$secrets"
rm "$secrets"
```

デプロイしたら、アプリの `MaiApp.server` のリリースビルドの値を Worker の URL にする。
