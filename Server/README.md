# サーバー

暗号化した文書と写真を置き、端末どうしの同期に使う Cloudflare Worker(#25)。アプリが取る書体のファイルも R2 から配る(#48、下の「書体」)。データは Turso の 1 つのデータベースに、写真は R2 に置き、アカウントのデータはどの表でもアカウント ID の列で分ける(#22 の設計、#43)。表は `schema.sql`、Turso に触るのは `src/store.ts` だけで、1 リクエストを 1 つの `batch()`(1 往復・1 トランザクション)にする(写真を送るときだけは、取り置きのあとに書き終わりを別に書く。下の「写真」)。サーバーが分かるのは、文書ごとの ID・更新時刻・大きさと、写真ごとの ID・大きさと、アカウントごとの Apple の利用者・Apple の refresh トークン(封じたもの)・自分の鍵の確かめの値と、App Store の購読(取引の ID・商品・期限・環境)と、読み取りモード(エージェントの公開鍵と端末の署名、モードの終わる時刻、除外した文書の ID、エージェントあてに包んだ文書の鍵)だけ。保存どうしを見分けるリビジョンは暗号化した文書の SHA-256 で、暗号文から誰でも出せるもの。書体の取得では、アカウントと結びつかない形で、どのファイルを取ったかとリクエストの IP が分かる。

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
| `GET /account`               | 200 と `{"plan", "paidUntil", "lapsed", "deletesAt", "usage", "ownKeyCheck"}`。期限の切れたアカウントも読める。表の下に                                                                                                                   |
| `PUT /account/subscription`  | アプリが起動のたびに、今の購読の取引と更新の情報を `{"transaction", "renewalInfo"}`(どちらも `jwsRepresentation`)で送り直す。200 と `{"plan", "paidUntil"}`(送り直したあとのプランと、いつまで払われているか)。下の「購読」               |
| `PUT /account/own-key-check` | 自分の鍵から作った確かめの値(32 バイト)を `application/octet-stream` で。アカウントにまだなければ置いて 204、同じ値なら 204、別の値なら 409(2 つ目の自分の鍵は作らせない)。長さが違えば 400、型が違えば 415                               |
| `DELETE /account`            | アカウントを消す。Apple の refresh トークンを取り消し、R2 とすべての表からそのアカウントのものを消して 204。期限の切れたアカウントも、その日のリクエストを使い切ったアカウントも消せる。下の「アカウントの削除」                          |
| `GET /writings`              | `{"writings": [{"id", "revision", "updated", "size"}]}`                                                                                                                                                                                   |
| `GET /writings/<ID>`         | 暗号化した文書(`application/octet-stream`)。リビジョンは `Mai-Revision` に。無ければ 404                                                                                                                                                  |
| `PUT /writings/<ID>`         | 暗号化した文書を `application/octet-stream` で送り、最後に読んだリビジョンを `Mai-Base-Revision` に(新しい文書は `none`)。合えば 200 と新しいリビジョン、合わなければ 409 と今のリビジョン(無ければ null)。形が違えば 400、型が違えば 415 |

文書の ID はアカウントごとに分かれ、ほかのアカウントの文書は読めず、書けず、一覧にも出ない。

`PUT /writings/<ID>` は `Specs/ReadMode` のモデルの `Save` のうち文書そのものを置く部分にあたり、受けた保存はその文書の前の版の写しを消す(下の「読み取りモード」)。モデルには断られる保存がないので、端末は受けられた保存にだけ写しを送る。`GET /writings/<ID>` は文書を取るもので、モデルは文書の中身を扱わない。

`GET /account` はセッションのアカウントのことを答える。`plan` はプラン、`paidUntil` はいつまで払われているか(1970 年からのミリ秒)、`lapsed` はそれを過ぎたか。`deletesAt` は期限の切れたアカウントが消える時刻(`paidUntil` の 90 日あと、1970 年からのミリ秒)で、期限が切れていなければ null(下の「期限切れのあとの削除」)。`usage` は `writingsBytes`・`writings`・`photosBytes`・`requests`・`lists`・`saves`・`photos` それぞれの `{"used", "limit"}` で、`limit` はプランの上限、`requests`・`lists`・`saves`・`photos` の `used` はその日(UTC)の、この要求の前までの数。`ownKeyCheck` は自分の鍵の確かめの値(小文字の 16 進)で、まだなければ null。端末はこれで自分の鍵を決める(#22 の設計の 3 節)。

- 端末に自分の鍵があるとき: その鍵から作った値と同じならそのまま使う。null なら `PUT /account/own-key-check` でその値を置く。違えばその鍵は使わず、リカバリーキーを求める。
- 端末に自分の鍵がないとき: null なら鍵を作って、その値を置く。null でなければ鍵を作らず、リカバリーキーを求める。
- 置こうとして 409 なら、別の端末が先に鍵を作っている。作った鍵は使わず、リカバリーキーを求める。

### アカウントの削除

`DELETE /account`(`src/account-deletion.ts`)は次の順に進む。

1. `accounts.apple_refresh_token` を開き、Apple の `/auth/revoke` で取り消す。Apple は前に取り消したトークンにも 200 を返す。Apple が答えなければ 502、それ以外の 4xx は Worker の要求か `APPLE_` の秘密の誤りなので 500。
2. R2 の `<アカウント ID>/` の下を全部消す。
3. `accounts` と、`account_id` を持つ表(`src/store.ts` の `accountTables`)のそのアカウントの行を 1 つの batch で消す。セッションも全部なくなり、どの端末のトークンも 401 になる。
4. 2 と 3 の間に送り終えた写真のために、R2 の `<アカウント ID>/` の下で `photos` に行のないものをもう一度消す(要求のあとも続ける)。行のあるものは、同じ ID で作り直したアカウント(同じ購入の `appAccountToken`)の写真なので残す。3 のあとに R2 に書き終えた写真は、行がないので `stored` にならず、その要求が自分で消す。

行を消すまではセッションが使えるので、途中で失敗したら同じ要求をやり直せばよい。1 で失敗すれば何も消えていない。2 で失敗すれば R2 の一部が消え、行は全部残る。3 で失敗すれば R2 は空で、行は全部残る。2 か 3 で失敗したあと、やり直すまでの間、そのアカウントの写真を読むと 500 になる。3 が通れば 204 で、やり直しは 401。

Apple の購読は削除では止まらない。解約の案内はアプリの削除の画面(#22 の A5)が出す。端末の文書は端末に残る。手元で動かす Worker は Apple に届かないので、この経路は手元では 500 になる。

### 写真

写真は文書とは別に、写真とサムネイルの 2 つに分けて R2(バインディング `PHOTOS`)に置く(#28)。どちらもアプリが写真ごとの鍵で封じたもので、サーバーは中を見ない。文書は写真をその ID で指す。 どれも上の「セッションのある経路」と同じくセッションが要り、なければ 401。

| 経路                                | 内容                                                                                                                                                                                    |
| ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PUT /photos/<ID>`                  | 封じた写真を `application/octet-stream` で、`Content-Length` をつけて送る。1 バイトから 50,000,000 バイトまで。201。その写真がもうあるか、別の要求が今送っていれば 409 で、何も変えない |
| `PUT /photos/<ID>/thumbnail`        | 封じたサムネイルを同じように。1,000,000 バイトまで。写真より先に送ってもよい                                                                                                            |
| `GET /photos/<ID>`、`.../thumbnail` | 置いたものをそのまま(`application/octet-stream`)。無ければ 404                                                                                                                          |

型が違えば 415、`Content-Length` がなければ 411、0 バイトなら 400、大きすぎれば 413。写真の ID はアカウントごとに分かれ、ほかのアカウントの写真は読めない。同じ ID を別のアカウントが使っても混ざらない。消す経路はまだない。

送るときは、まず `Content-Length` の分をプランの写真の容量から取っておき(`photos` 表に `state` が `reserved` の行を入れる。トリガーが `accounts.photos_bytes` に足し、超えれば 429)、それから R2 にちょうどその長さだけ書く。書けたら `stored` にして 201。長さが合わないか R2 が失敗したら、行を `releasing` にし、R2 に書いたものを消してから行を消して取っておいた分を戻し、要求は 500 で終わる。R2 で消せなければ行は `releasing` のまま残り、Cron がやり直す。取っておいてから 1 時間たっても `stored` にならない行(Worker が途中で止まったときなど)は、Cron が同じように `releasing` にして戻す。`reserved` の行だけが `stored` か `releasing` になるので、戻している途中の写真が `stored` になることも、`stored` の写真が戻されることもない。書き終わる前に戻されていたら、書いたものを消して 408 を返す。送り直せばよい。送る途中で端末の接続が切れても、Worker は R2 への書き込みと戻しを最後まで続ける(`ctx.waitUntil`)。Worker 自体が止まったときは、Cron が戻すまで(1 時間と少し)同じ写真を送ると 409 になる。

R2 のキーは `<アカウント ID>/<写真 ID>/<photo か thumbnail>/<送るごとの ID>`。送るごとの ID は送り直しのたびに新しく、2 つの要求が同じキーに書くことはない。アカウントのものは `<アカウント ID>/` で始まるので、アカウントの削除はこの前置きで消す(上の「アカウントの削除」)。

### 読み取りモード

AI のエージェント(Mac の MCP サーバーなど)に、期間を決めて文書を読ませる(#26、#22 の設計の 7 節、モデルは `Specs/ReadMode`)。端末が文書の鍵をエージェントの公開鍵に包んで「写し」としてサーバーに置き、エージェントは自分のトークンで暗号化した文書と写しを取ってくる。サーバーは包んだ鍵も文書も開けない。

端末の経路は上の「セッションのある経路」と同じくセッションが要る。鍵・署名・包んだ鍵は JSON の中で小文字の 16 進。

| 経路                      | 内容                                                                                                                                                                                                                                                                                                                                                                       |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /agents`            | 端末が承認したエージェントを `{"publicKey", "signature"}`(どちらも 1〜1,024 バイト)で置く。201 と `{"agent", "token"}`。`token` は `agent.<エージェント ID>.<秘密>`(秘密は 32 バイトの base64url)で、サーバーは秘密の SHA-256 だけを置く。取り消していないエージェントがもう 10 あるか、同じ公開鍵のエージェントを前に取り消していれば 409(取り消した鍵は二度と承認しない) |
| `GET /agents`             | `{"agents": [{"id", "publicKey", "signature", "revoked"}]}`。取り消したものも `revoked: true` で残る。端末は包む前に署名を確かめ、取り消したものには包まない                                                                                                                                                                                                               |
| `DELETE /agents/<ID>`     | 取り消す。そのエージェントあての写しも消し、トークンはそれから 401。204、そのアカウントのエージェントでなければ 404                                                                                                                                                                                                                                                        |
| `GET /read-mode`          | `{"until"}`。オフか終わる時刻を過ぎていれば null                                                                                                                                                                                                                                                                                                                           |
| `PUT /read-mode`          | `{"until"}`(1970 年からのミリ秒)でオンにする。200 と `{"until"}`。サーバーの時計で過ぎていれば 400。オンの間に別の期間でオンにし直すこともでき、前の期間の写しは消える(モデルにはない操作)                                                                                                                                                                                 |
| `DELETE /read-mode`       | オフにし、写しを全部消して 204                                                                                                                                                                                                                                                                                                                                             |
| `GET /exclusions`         | `{"exclusions": [<文書 ID>]}`                                                                                                                                                                                                                                                                                                                                              |
| `PUT /exclusions/<ID>`    | その文書を除外し(「AI に読ませない」)、写しを消して 204。文書がまだサーバーになくてもよい                                                                                                                                                                                                                                                                                  |
| `DELETE /exclusions/<ID>` | 除外を外して 204。写しは端末が次に送る                                                                                                                                                                                                                                                                                                                                     |
| `POST /copies`            | `{"expires", "copies": [{"writing", "agent", "revision", "wrapped"}]}` で写しを 1〜100 送る。`expires` は端末が見ているモードの終わる時刻、`wrapped` はその版の文書の鍵を包んだもの(1〜1,024 バイト)。200 と `{"copies": [{"writing", "agent", "refused"}]}`(送った順)。同じ文書とエージェントの写しは置き換える                                                           |

`POST /copies` はそれぞれの写しを、その時点で次がそろうときだけ置く(#22 の設計 6 節の「確かめてから書く」)。そろわなければ置かず、`refused` に理由を返す。置いたものは null。

- `read-mode`: モードがオンで、終わる時刻が `expires` と同じ。オフ、過ぎた、別の期間なら断る
- `excluded`: その文書を除外していない
- `agent`: エージェントがそのアカウントのもので、取り消していない
- `revision`: 文書の今の版が `revision`。サーバーに文書がないときも断る

エージェントの経路は `Authorization: Bearer <エージェントのトークン>` で、読むだけ。知らないトークン、形の違うトークン、取り消したエージェントのトークンは 401。セッションのトークンはエージェントの経路で、エージェントのトークンは端末の経路で 401。

| 経路                       | 内容                                                                                                                                                                                                         |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GET /agent/writings`      | `{"writings": [{"id", "revision", "updated", "size", "expires"}]}`。このエージェントあての、期限の来ていない写しのある文書                                                                                   |
| `GET /agent/writings/<ID>` | 暗号化した文書(`application/octet-stream`)。`Mai-Revision` に版、`Mai-Wrapped-Key` に包んだ鍵(16 進)、`Mai-Expires` に写しの期限。期限の来た写し、ほかのエージェントやアカウントの文書、写しのない文書は 404 |

エージェントの文書は、本文(封じた文書の 88 バイト目から)を包んだ鍵から開いた文書の鍵で開く(上の「暗号化した文書の形」)。

`Specs/ReadMode` の性質のうち、サーバーが守るもの:

- 除外した文書の写しはない(`NoCopyOfExcluded`)。除外は写しを消し、そのあと写しを受けない。
- 期限の来た写しはエージェントに渡さない(`NoServedCopyPastExpiry`)。読むときに期限を見る。
- 掃除のあと、時刻が進むまで、期限の来た写しもモードも残らない(`ExpiredCopiesSwept`、`ModeEndsOnTime`)。下の「期限の掃除」。
- 写しはモードのある間だけで、期限はモードの終わる時刻(`NoCopyOutsideMode`)。オフ・期間の変更は写しを消す。
- 取り消したエージェントあての写しはない(`NoCopyForRevokedKey`)。取り消した公開鍵は、新しいエージェントとしても承認しない。
- 写しは文書の今の版のものだけ(`CopyIsOfCurrentVersion`)。保存は前の版の写しを消す。

`test/read-mode-properties.test.ts` が、モデルの操作を無作為に並べて Worker と sqld に通し、一歩ごとにこれらを確かめる。端末の見ているものは古くてよく、前の期間や前の版の写しも送る。

端末の経路のうち読み取りモードを変えるもの(`POST /agents`、`DELETE /agents/<ID>`、`PUT`・`DELETE /read-mode`、`PUT`・`DELETE /exclusions/<ID>`、`POST /copies`)は書き込みとして扱い、期限の切れたアカウントは 402(#26 のメモ)。期限が切れると Cron が写しとモードを消し、エージェントにはそれより前から渡さない。エージェントの要求も、そのアカウントの 1 日のリクエスト数に数える(一覧の数には数えない)。

エージェントのトークンを端末からエージェントへどう渡すか(QR コードかコード入力)、公開鍵と署名の形、包み方は、端末とエージェントの側で決める。サーバーはどれもバイト列として置くだけ。

### 購読

アカウントは App Store の自動更新の購読で払われる。購読は `subscriptions` に `originalTransactionId` ごとに 1 行で置き、App Store が署名したもののうち、一番新しい請求の期間(取引の `expiresDate`)についての一番新しいもの(署名した時刻 `signedDate` で比べる)を写す。前の期間の取引(過ぎた期間の返金の通知など)は今の期間を変えない。アカウントのプラン(`accounts.tier`)は一番長く払われている購読の商品のプラン(同じなら大きいプラン)、`accounts.paid_until` はその購読が払われている時刻。購読が払われている時刻は、期限(`expiresDate`)、請求のやり直しの猶予(`gracePeriodExpiresDate`)の終わりのうち遅い方で、返金・取り消しのあとは取り消された時刻(`revocationDate`)。

購読のことはどれも、App Store が署名した取引と更新の情報から読む。通知の種類は見ない。更新(`DID_RENEW`)は新しい期限の取引を、期限切れ(`EXPIRED`・`GRACE_PERIOD_EXPIRED`・猶予のない `DID_FAIL_TO_RENEW`)は過ぎた期限の取引を、猶予(`DID_FAIL_TO_RENEW` の `GRACE_PERIOD`)は猶予の終わりの入った更新の情報を、返金と取り消し(`REFUND`・`REVOKE`)は `revocationDate` の入った取引を、すぐ変わる上のプランへの変更(`DID_CHANGE_RENEWAL_PREF` の `UPGRADE`)は新しい商品の取引を持ってくる。下のプランへの変更(`DOWNGRADE`)は次の更新で新しい商品の取引が来るまで、今のプランのまま。

- **アカウントを作るとき**(`POST /account`): 取引が `src/app-store.ts` で通り(下の「Apple の署名」)、`appAccountToken` がそのアカウント ID で、まだ払われていて(期限切れや返金・取り消しでなく)、`APP_STORE_ENVIRONMENTS` の環境のもので、どれかのプランの商品であること。署名・形・別のアプリ・自動更新の購読でないものは 400、`appAccountToken` が別のアカウントか無いもの、その購読がもう別のアカウントのものなら 409、払われていなければ 402、受けない環境なら 403。
- **送り直し**(`PUT /account/subscription`): 同じように確かめ、更新の情報は同じ `originalTransactionId` の取引のものに限る(別の購読のものは 400)。期限が過ぎたものや取り消されたものも受け、その通りに写す。`appAccountToken` が呼んだアカウントでないか、その購読が別のアカウントのものなら 409。期限の切れたアカウントからも送れる。今のものより古いか同じ時刻のもの、前の期間のものなら何も変えずに 200(アプリが同じ取引を送り直したときも)。
- **通知**(`POST /app-store/notifications`): 署名と環境を同じように確かめ、通らなければ 400、受けない環境なら 403。取引のない通知(`TEST` など)、自動更新の購読でない取引、まだ置いていない購読で `appAccountToken` のアカウントがないものは、何もせず 200。まだ置いていない購読でアカウントがあれば、そのアカウントのものとして置く。今のものより古いか同じ時刻のもの、前の期間のものは何も変えない。Apple は 200 を返すまで送り直す。

`accounts.paid_until` を過ぎたアカウントは期限切れで、文書と写真を読めるが書けない。文書の保存(`PUT /writings/<ID>`)、写真とサムネイル(`PUT /photos/<ID>`、`.../thumbnail`)、自分の鍵の確かめの値(`PUT /account/own-key-check`)は 402 で、何も書かず、数えもしない。一覧・読み出し、アカウントを読むこと(`GET /account`)、購読を戻すための送り直しはそのまま使える。`paid_until` が期限の切れた時刻で、その 90 日あとに Cron が消す(下の「期限切れのあとの削除」)。

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

Cron(毎分)が、最後に使ってから 180 日たったセッションと、前の日までの `usage` と、期限から 1 時間たった `used_challenges` と、期限の来た写しと読み取りモードと、期限の切れたアカウントの写しと読み取りモードを消す(`Store.sweep`)。1 時間たっても書き終わらない写真の取り置きを、R2 のものと一緒に 1 回 1,000 件まで戻す(`sweepUploads`)。

### 期限切れのあとの削除

期限が切れてから(`accounts.paid_until` から)90 日たったアカウントを、Cron が 1 回 10 件まで、その中から無作為に選んで消す(`deleteLapsedAccounts`、`src/account-deletion.ts`)。消し方は上の「アカウントの削除」と同じで、Apple の refresh トークンを取り消し、R2 の `<アカウント ID>/` の下を消し、すべての表の行を消す。

- 90 日のうちに購読し直せば(`paid_until` がまた先になれば)消さない。購読の送り直しと通知は上の「購読」の通りに `paid_until` を変える。
- Apple が取り消したあと、R2 に触る前に `accounts.deleting` を 1 にする。そこまでに購読し直していれば何も消さない。そのあとの購読し直しはもう `paid_until` を変えず、アカウントは消える。
- 無作為に選ぶので、毎回失敗するアカウントが 10 件あっても、ほかのアカウントも消える。
- 1 件の失敗はほかを止めない。失敗したアカウントはログに残り、次の回にやり直す。Apple が答えなければ何も消さない。R2 か行の削除で失敗すれば、`deleting` が 1 のまま次の回に終える。
- `GET /account` の `deletesAt` で、端末はいつ消えるかを知る。

読み取りモードと写しは、期限が切れたときに上の「期限の掃除」が消す(#22 の設計の 7 節)。エージェントと除外の印は 90 日のあいだ残り、この削除で消える。`account_id` を持つ表は `accountTables` に入れる(入れないと `test/account-deletion.test.ts` が落ちる)。

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
- Cloudflare: R2 のバケット `mai-fonts` 1 つと、そこに置く書体のファイル 6 つ(合わせて 28.8 MB)
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
pnpm exec wrangler r2 bucket create mai-fonts
scripts/upload-fonts.sh --remote
pnpm exec wrangler deploy --secrets-file "$secrets"
rm "$secrets"
```

デプロイしたら、アプリの `MaiApp.server` のリリースビルドの値を Worker の URL にする。
