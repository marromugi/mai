# サーバー

暗号化した文書と写真だけを置き、端末どうしの同期に使う Cloudflare Worker(#25)。データは Turso の 1 つのデータベースに、写真は R2 に置き、アカウントのデータはどの表でもアカウント ID の列で分ける(#22 の設計、#43)。表は `schema.sql`、Turso に触るのは `src/store.ts` だけで、1 リクエストを 1 つの `batch()`(1 往復・1 トランザクション)にする(写真を送るときだけは、取り置きのあとに書き終わりを別に書く。下の「写真」)。サーバーが分かるのは、文書ごとの ID・更新時刻・大きさと、写真ごとの ID・大きさと、アカウントごとの Apple の利用者・Apple の refresh トークン(封じたもの)・自分の鍵の確かめの値と、App Store の購読(取引の ID・商品・期限・環境)だけ。保存どうしを見分けるリビジョンは暗号化した文書の SHA-256 で、暗号文から誰でも出せるもの。

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

| 経路                            | 内容                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /challenges`              | 201 と `{"challenge"}`。5 分使える。アプリはその SHA-256(小文字の 16 進)を Sign in with Apple の nonce にする                                                                                                                                                                                                                                                                                                                                                        |
| `POST /account`                 | `{"account", "challenge", "identityToken", "authorizationCode", "transaction"}`。`account` はアプリが作った UUID で、購入の `appAccountToken` と同じもの。`transaction` はそのアカウントのために買った購読の StoreKit 2 の取引(`Transaction.jwsRepresentation`)。201 と `{"token"}`(セッションのトークン)。その Apple の利用者かその ID のアカウントがもうあれば 409 で、アカウントもセッションも作らない(サインインは `POST /sessions`)。取引の断り方は下の「購読」 |
| `POST /sessions`                | `{"challenge", "identityToken"}`。200 と `{"account", "token"}`。その Apple の利用者のアカウントがなければ 404                                                                                                                                                                                                                                                                                                                                                       |
| `POST /app-store/notifications` | Apple が送る App Store Server Notifications V2 の `{"signedPayload"}`。下の「購読」                                                                                                                                                                                                                                                                                                                                                                                  |

ID トークンは `src/apple-sign-in.ts` で、Apple の鍵の署名・`iss`・`aud`(`APPLE_CLIENT_ID`)・`exp` と、nonce がチャレンジの SHA-256 であることを確かめる。チャレンジは `CHALLENGE_KEY` の HMAC で、サーバーは出すときには何も書かず、使ったものを期限の 1 時間あとまで `used_challenges` に置く。使ったもの、このサーバーが出していないもの、期限の切れたもの(Apple を待つ間に切れたものも)、ID トークンが別のチャレンジに作られたものは 401。チャレンジは通ればその場で使ったことになり、409 や 404 で終わっても使い直せない。

`POST /account` は認可コードを Apple の `/auth/token` で refresh トークンに替え(`src/apple-tokens.ts`)、`REFRESH_TOKEN_KEY` の AES-256-GCM でアカウント ID を付けて封じて `accounts.apple_refresh_token` に置く(`src/refresh-tokens.ts`)。封じる前の値はどこにも置かない。Apple がコードを断るか(`invalid_grant`)、コードが別の利用者のものなら 401、Apple が答えなければ 502。Apple がそれ以外の 4xx を返したら Worker の要求か `APPLE_` の秘密の誤りなので 500。取引は Apple に引き換えを頼む前に確かめ、プランは取引の商品で決める。

### セッションのある経路

どれも `Authorization: Bearer <セッションのトークン>` が要る。トークンは `s1.<セッション ID>.<秘密>`(秘密は 32 バイトの base64url)で、サーバーは秘密(base64url の文字列)の SHA-256 だけを `sessions` に置く。知らないトークン、形の違うトークン、最後に使ってから 180 日たったセッションは、経路や中身を見る前に 401。Apple に届かない手元の試験では、テストは `Store.makeAccount` で、手元で動かすときは `scripts/new-session.sh` で、Apple の利用者のいないアカウントとセッションを作る。

| 経路                         | 内容                                                                                                                                                                                                                                      |
| ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `DELETE /session`            | サインアウト。このセッションを終えて 204                                                                                                                                                                                                  |
| `GET /account`               | 200 と `{"plan", "paidUntil", "lapsed", "usage", "ownKeyCheck"}`。期限の切れたアカウントも読める。表の下に                                                                                                                                |
| `PUT /account/subscription`  | アプリが起動のたびに、今の購読の取引と更新の情報を `{"transaction", "renewalInfo"}`(どちらも `jwsRepresentation`)で送り直す。200 と `{"plan", "paidUntil"}`(送り直したあとのプランと、いつまで払われているか)。下の「購読」               |
| `PUT /account/own-key-check` | 自分の鍵から作った確かめの値(32 バイト)を `application/octet-stream` で。アカウントにまだなければ置いて 204、同じ値なら 204、別の値なら 409(2 つ目の自分の鍵は作らせない)。長さが違えば 400、型が違えば 415                               |
| `GET /writings`              | `{"writings": [{"id", "revision", "updated", "size"}]}`                                                                                                                                                                                   |
| `GET /writings/<ID>`         | 暗号化した文書(`application/octet-stream`)。リビジョンは `Mai-Revision` に。無ければ 404                                                                                                                                                  |
| `PUT /writings/<ID>`         | 暗号化した文書を `application/octet-stream` で送り、最後に読んだリビジョンを `Mai-Base-Revision` に(新しい文書は `none`)。合えば 200 と新しいリビジョン、合わなければ 409 と今のリビジョン(無ければ null)。形が違えば 400、型が違えば 415 |

文書の ID はアカウントごとに分かれ、ほかのアカウントの文書は読めず、書けず、一覧にも出ない。

`PUT /writings/<ID>` は `Specs/ReadMode` のモデルの `Save` のうち文書そのものを置く部分にあたる。モデルには断られる保存がないので、#26 は受けられた保存にだけ写しを送る。`GET /writings/<ID>` は文書を取るもので、モデルは文書の中身を扱わない。モデルの `Sync` が取り込む設定は #26 が足す。

`GET /account` はセッションのアカウントのことを答える。`plan` はプラン、`paidUntil` はいつまで払われているか(1970 年からのミリ秒)、`lapsed` はそれを過ぎたか。`usage` は `writingsBytes`・`writings`・`photosBytes`・`requests`・`lists`・`saves`・`photos` それぞれの `{"used", "limit"}` で、`limit` はプランの上限、`requests`・`lists`・`saves`・`photos` の `used` はその日(UTC)の、この要求の前までの数。`ownKeyCheck` は自分の鍵の確かめの値(小文字の 16 進)で、まだなければ null。端末はこれで自分の鍵を決める(#22 の設計の 3 節)。

- 端末に自分の鍵があるとき: その鍵から作った値と同じならそのまま使う。null なら `PUT /account/own-key-check` でその値を置く。違えばその鍵は使わず、リカバリーキーを求める。
- 端末に自分の鍵がないとき: null なら鍵を作って、その値を置く。null でなければ鍵を作らず、リカバリーキーを求める。
- 置こうとして 409 なら、別の端末が先に鍵を作っている。作った鍵は使わず、リカバリーキーを求める。

### 写真

写真は文書とは別に、写真とサムネイルの 2 つに分けて R2(バインディング `PHOTOS`)に置く(#28)。どちらもアプリが写真ごとの鍵で封じたもので、サーバーは中を見ない。文書は写真をその ID で指す。 どれも上の「セッションのある経路」と同じくセッションが要り、なければ 401。

| 経路                                | 内容                                                                                                                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PUT /photos/<ID>`                  | 封じた写真を `application/octet-stream` で、`Content-Length` をつけて送る。1 バイトから 50,000,000 バイトまで。201。その写真がもうあるか、別の要求が今送っていれば 409 で、何も変えない |
| `PUT /photos/<ID>/thumbnail`        | 封じたサムネイルを同じように。1,000,000 バイトまで。写真より先に送ってもよい                                                                                                            |
| `GET /photos/<ID>`、`.../thumbnail` | 置いたものをそのまま(`application/octet-stream`)。無ければ 404                                                                                                                          |

型が違えば 415、`Content-Length` がなければ 411、0 バイトなら 400、大きすぎれば 413。写真の ID はアカウントごとに分かれ、ほかのアカウントの写真は読めない。同じ ID を別のアカウントが使っても混ざらない。消す経路はまだない。

送るときは、まず `Content-Length` の分をプランの写真の容量から取っておき(`photos` 表に `state` が `reserved` の行を入れる。トリガーが `accounts.photos_bytes` に足し、超えれば 429)、それから R2 にちょうどその長さだけ書く。書けたら `stored` にして 201。長さが合わないか R2 が失敗したら、行を `releasing` にし、R2 に書いたものを消してから行を消して取っておいた分を戻し、要求は 500 で終わる。R2 で消せなければ行は `releasing` のまま残り、Cron がやり直す。取っておいてから 1 時間たっても `stored` にならない行(Worker が途中で止まったときなど)は、Cron が同じように `releasing` にして戻す。`reserved` の行だけが `stored` か `releasing` になるので、戻している途中の写真が `stored` になることも、`stored` の写真が戻されることもない。書き終わる前に戻されていたら、書いたものを消して 408 を返す。送り直せばよい。送る途中で端末の接続が切れても、Worker は R2 への書き込みと戻しを最後まで続ける(`ctx.waitUntil`)。Worker 自体が止まったときは、Cron が戻すまで(1 時間と少し)同じ写真を送ると 409 になる。

R2 のキーは `<アカウント ID>/<写真 ID>/<photo か thumbnail>/<送るごとの ID>`。送るごとの ID は送り直しのたびに新しく、2 つの要求が同じキーに書くことはない。アカウントのものは `<アカウント ID>/` で始まるので、アカウント削除(#22 の S5)はこの前置きで消す。

### 購読

アカウントは App Store の自動更新の購読で払われる。購読は `subscriptions` に `originalTransactionId` ごとに 1 行で置き、App Store が署名したもののうち、一番新しい請求の期間(取引の `expiresDate`)についての一番新しいもの(署名した時刻 `signedDate` で比べる)を写す。前の期間の取引(過ぎた期間の返金の通知など)は今の期間を変えない。アカウントのプラン(`accounts.tier`)は一番長く払われている購読の商品のプラン(同じなら大きいプラン)、`accounts.paid_until` はその購読が払われている時刻。購読が払われている時刻は、期限(`expiresDate`)、請求のやり直しの猶予(`gracePeriodExpiresDate`)の終わりのうち遅い方で、返金・取り消しのあとは取り消された時刻(`revocationDate`)。

購読のことはどれも、App Store が署名した取引と更新の情報から読む。通知の種類は見ない。更新(`DID_RENEW`)は新しい期限の取引を、期限切れ(`EXPIRED`・`GRACE_PERIOD_EXPIRED`・猶予のない `DID_FAIL_TO_RENEW`)は過ぎた期限の取引を、猶予(`DID_FAIL_TO_RENEW` の `GRACE_PERIOD`)は猶予の終わりの入った更新の情報を、返金と取り消し(`REFUND`・`REVOKE`)は `revocationDate` の入った取引を、すぐ変わる上のプランへの変更(`DID_CHANGE_RENEWAL_PREF` の `UPGRADE`)は新しい商品の取引を持ってくる。下のプランへの変更(`DOWNGRADE`)は次の更新で新しい商品の取引が来るまで、今のプランのまま。

- **アカウントを作るとき**(`POST /account`): 取引が `src/app-store.ts` で通り(下の「Apple の署名」)、`appAccountToken` がそのアカウント ID で、まだ払われていて(期限切れや返金・取り消しでなく)、`APP_STORE_ENVIRONMENTS` の環境のもので、どれかのプランの商品であること。署名・形・別のアプリ・自動更新の購読でないものは 400、`appAccountToken` が別のアカウントか無いもの、その購読がもう別のアカウントのものなら 409、払われていなければ 402、受けない環境なら 403。
- **送り直し**(`PUT /account/subscription`): 同じように確かめ、更新の情報は同じ `originalTransactionId` の取引のものに限る(別の購読のものは 400)。期限が過ぎたものや取り消されたものも受け、その通りに写す。`appAccountToken` が呼んだアカウントでないか、その購読が別のアカウントのものなら 409。期限の切れたアカウントからも送れる。今のものより古いか同じ時刻のもの、前の期間のものなら何も変えずに 200(アプリが同じ取引を送り直したときも)。
- **通知**(`POST /app-store/notifications`): 署名と環境を同じように確かめ、通らなければ 400、受けない環境なら 403。取引のない通知(`TEST` など)、自動更新の購読でない取引、まだ置いていない購読で `appAccountToken` のアカウントがないものは、何もせず 200。まだ置いていない購読でアカウントがあれば、そのアカウントのものとして置く。今のものより古いか同じ時刻のもの、前の期間のものは何も変えない。Apple は 200 を返すまで送り直す。

`accounts.paid_until` を過ぎたアカウントは期限切れで、文書と写真を読めるが書けない。文書の保存(`PUT /writings/<ID>`)、写真とサムネイル(`PUT /photos/<ID>`、`.../thumbnail`)、自分の鍵の確かめの値(`PUT /account/own-key-check`)は 402 で、何も書かず、数えもしない。一覧・読み出し、アカウントを読むこと(`GET /account`)、購読を戻すための送り直しはそのまま使える。`paid_until` が期限の切れた時刻で、それから 90 日で消すのは #22 の S6。

`APP_STORE_ENVIRONMENTS` は受ける購入の環境で、`Production`・`Sandbox`、または両方をカンマで。`wrangler.jsonc` の値は `Production` で、本番の Worker は Sandbox(TestFlight と Sandbox のテスト用アカウント)の購入を受けない。Sandbox のビルドは、`APP_STORE_ENVIRONMENTS` を `Sandbox` にした別の Worker と別のデータベースに向ける。App Review の購入も Sandbox なので、本番が Sandbox も受けるかは #54 で聞いている。Xcode の StoreKit の試験(`environment: "Xcode"`)の取引は Apple の鍵で署名されていないので、どの Worker も受けない。

### プランの上限

アカウントはプラン(`plans` 表の `basic`・`plus`・`pro`)に入っている。上限に届いた要求は 429 で、何も書かず、数えもしない。

- 1 日(UTC)のリクエスト数、そのうちの一覧(`GET /writings`)と保存(`PUT`、409 になったものも数える)と写真(`PUT /photos/<ID>`。サムネイルは数えない。409 になったものと、取っておいたあと失敗したものも数える)の数。`usage` 表で数える。
- 文書の合計の大きさと本数。`writings` のトリガーが `accounts` に足し、超えた保存は batch ごと戻る。大きさの減る保存は断らない。
- 写真とサムネイルの合計の大きさ(上の「写真」)。

| プラン | 写真の容量 | 写真 / 日 |
| ------ | ---------- | --------- |
| basic  | 5 GB       | 100       |
| plus   | 50 GB      | 300       |
| pro    | 200 GB     | 300       |

上限の値は #22 の設計の案で、プランと値段の答え(#22 の質問)で変わりうる。変えるときは `plans` の行を書き換える。

### 期限の掃除

Cron(毎分)が、最後に使ってから 180 日たったセッションと、前の日までの `usage` と、期限から 1 時間たった `used_challenges` を消す(`Store.sweep`)。1 時間たっても書き終わらない写真の取り置きを、R2 のものと一緒に 1 回 1,000 件まで戻す(`sweepUploads`)。#26 の写しと読み取りモードの期限もここに足す。

## Apple の署名

ID トークンは上のサインインの経路が、署名つき取引・更新の情報・通知は上の購読の経路(`src/subscriptions.ts`)が呼ぶ。どれも WebCrypto だけで確かめ、通れば読み出した値を、通らなければ理由を返す。

- `src/apple-sign-in.ts`: Sign in with Apple の ID トークン。Apple の JWKS(RS256)で署名、`iss`、`aud`(バンドル ID)、`exp`、渡された `nonce`。JWKS は Cache に 1 日置き、知らない鍵 ID が来たら取り直す(前の取得から 5 分たっていれば、1 回だけ)。
- `src/app-store.ts`: StoreKit 2 の署名つき取引・更新の情報と、App Store Server Notifications V2 の `signedPayload`(中の取引と更新の情報も)。ES256 の署名と、`x5c` の葉・中間が `src/apple-root.ts` の Apple Root CA - G3 までつながること。ルートは引数で渡し、`x5c` の中のルートは使わない。バンドル ID は `APPLE_CLIENT_ID`。期限・取り消し・環境・`appAccountToken` は見ず、購入として受けるかは `src/subscriptions.ts` が決める。Xcode の StoreKit の試験で作った取引は Apple の鍵で署名されていないので、どれも通らない。

テストは自分で作った認証局と鍵で作ったものを確かめる(購読の経路のテストは、その認証局を G3 の代わりに `signInOf` に渡す)。本物で確かめているのは、G3 と、それが署名した中間の WWDR G6 だけ。

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
- Cloudflare: R2 のバケット `mai-photos` 1 つ(`wrangler r2 bucket create mai-photos`、Worker のバインディング `PHOTOS`)、Worker `mai-server` 1 つ(`workers.dev` の URL つき)、その毎分の Cron Trigger、変数 `APP_STORE_ENVIRONMENTS`(`Production`)、秘密 `TURSO_URL`・`TURSO_TOKEN`・`CHALLENGE_KEY`・`REFRESH_TOKEN_KEY`・`APPLE_CLIENT_ID`・`APPLE_TEAM_ID`・`APPLE_SIGN_IN_KEY_ID`・`APPLE_SIGN_IN_KEY`

その前に開発者が Apple Developer でしておくこと:

- App ID `com.marromugi.mai` で Sign in with Apple を有効にする
- Sign in with Apple の鍵(.p8)を 1 つ作り、その鍵 ID と、チーム ID を控える。.p8 は一度しか落とせない

App Store Connect でしておくこと:

- 購読のグループを 1 つ作り、その中に自動更新の購読を 3 つ、次の商品 ID で作る。商品 ID は `schema.sql` の `plans.product_id` と同じもので、あとから変えられない。値段は #22 の答え。

  | プラン | 商品 ID                           | 期間   | 値段(日本) |
  | ------ | --------------------------------- | ------ | ---------- |
  | Basic  | `com.marromugi.mai.basic.monthly` | 1 か月 | ¥150       |
  | Plus   | `com.marromugi.mai.plus.monthly`  | 1 か月 | ¥700       |
  | Pro    | `com.marromugi.mai.pro.monthly`   | 1 か月 | ¥1,600     |

- 請求のやり直しの猶予(Billing Grace Period)を入れるなら、その間も書き込める
- App Store Server Notifications を Version 2 にし、本番の URL を `https://<Worker の URL>/app-store/notifications` にする。Sandbox の URL は、Sandbox を受ける Worker があればその URL に

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
pnpm exec wrangler r2 bucket create mai-photos
secrets="$(mktemp)"
printf 'TURSO_URL=%s\nTURSO_TOKEN=%s\n' "$(turso db show mai --url)" "$(turso db tokens create mai)" > "$secrets"
printf 'CHALLENGE_KEY=%s\nREFRESH_TOKEN_KEY=%s\n' "$(openssl rand -base64 32)" "$(openssl rand -base64 32)" >> "$secrets"
printf 'APPLE_CLIENT_ID=com.marromugi.mai\nAPPLE_TEAM_ID=%s\nAPPLE_SIGN_IN_KEY_ID=%s\nAPPLE_SIGN_IN_KEY=%s\n' \
  "$team_id" "$key_id" "$(grep -v -- ----- "$p8" | tr -d '\n')" >> "$secrets"
pnpm exec wrangler deploy --secrets-file "$secrets"
rm "$secrets"
```
