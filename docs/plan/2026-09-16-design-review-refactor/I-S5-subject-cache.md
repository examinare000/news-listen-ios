## iOS リファクタ I-S5: 主体別音声キャッシュと起動時の回収・logout の明示ヘッダ

> **投入の保留（2026-10-01）**: backend の **B-S5b**（セッション削除が通知登録を連鎖して消す契約）が親リポの main に入るまで、本 order を投入しない。logout の `unregisterDeviceToken` の client 呼出を消す根拠（SG-C12）が B-S5b で、先に出すと logout の後も前の利用者宛の通知が端末に届き得る（現行の backend の `POST /auth/logout` は `delete_session` だけを呼ぶ。`backend/api/routers/auth.py:187-206`）。TA Spec §8.1・§8.3・§10.1「判断済み」。

## 2026-10-01 目標アーキテクチャ（ADR-110・Spec §8.3）による補正
正本: 親 docs `adr/110-refactor-target-domain-centered-onion-cqrs.md`、iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`（以下「TA Spec」）§8.3 の I-S5 の表（補正 1〜10）。ADR-104 の決定・SG-C12・SG-C13・起動時の回収の 5 経路は変えていない。
- 補正 1: 依存に backend の **B-S5b** を足した。前提の「B-S5 の成果」を、`user_id` の契約 = **B-S5a**（完了）と、連鎖削除 = **B-S5b**（未着手）に書き分けた。B-S5b が親 main に入るまで投入しない（冒頭の保留）。
- 補正 2: 依存に I-T3（`OfflineDownloads`）と I-T5（`SubjectKey`）を足した。
- 補正 3: 対象 3 を書き直した。主体の固定と cancel は、取得と Task を持つ `OfflineDownloads` に置く（`download` は開始時に主体キーを控え、保存のとき `library.save(data, for: id, subject: 控えたキー)` を呼ぶ。`cancelAll()` は実行中の Task を cancel して待たない）。`OfflineLibrary` は `bind(subject:)`・主体つきの保存・`remove(subject:)`・`reclaim(keeping:)` を持つ（ADR-104 決定 9・SL-06・導出 I-28）。
- 補正 4: 対象 1 の主体キーの妥当性の判定を `Models/AuthModels.swift` に置かず、`Auth/Domain/Subject.swift` の `SubjectKey` の検査つきの生成（I-T5）に置いた。`AuthUser` に足すのは `userId` の field だけで、`toSubject()` がキーを作る（TA-R-AC-4・TA-D8）。
- 補正 5: 後始末の手順に「実行中のダウンロードの cancel（待たない）」を足した。入口は `OfflineDownloads.cancelAll()` で、`AppState` への登録は `PlaybackLifecycle` と同じ弱参照の登録（登録が無ければ何もしない）。
- 補正 6: 行 ID SL-08・SL-09・SL-10 をテスト名に足した（回収の 5 分岐のうち (iv) が SL-08、(v) が SL-09、`user_id` の欠落・形式不正が SL-10）。
- 補正 7: 回収済みの旗は `AppState`（Account の application）の起動単位の状態と書いた（導出 I-34）。
- 補正 8: `Networking/AudioCacheManager.swift` を `Podcast/Platform/` へ移す。`AudioFileStore` に主体キーの引数と `reclaim(keeping:)` を足す。完了条件の「`user_id` / `userId` の出現が 5 ファイルに閉じる」の一覧を置き場の変更に合わせて直した。
- 補正 9: 設定画面の「全削除」と容量表示は `OfflineDownloads.removeAll()`・`OfflineLibrary.usage()` を呼ぶ（TA-C-PB-21・TA-Q-PB-4）。
- 補正 10: 行番号を現行に直した（`AppState.swift:292,294,284` → 現行 `:417,419,410`）。
- 着手前の前提点検の節を足し、検証コマンドを ios README の現行の形式（`make test`）にした。

## 概要
端末ローカル資産（音声キャッシュ）に主体を持たせ、主体離脱の後始末を「端末単位の全削除」から「離脱主体の範囲だけ」へ改める。音声キャッシュを `Caches/NewsListenApp/audio/{user_id}/{podcast_id}.mp3` に分け、起動時に現在の主体以外を回収し、ダウンロードジョブは開始時に主体を固定する。あわせて logout で離脱主体のトークンを明示ヘッダで送る。正本は `docs/adr/104-subject-departure-and-subject-scoped-assets.md`（決定 1〜3・5〜9・14〜16・25・26、追記 SG-A1）、型の置き場と依存の向きは TA Spec §5.1（`OfflineLibrary`・`OfflineDownloads`・`AudioFileStore`）・§5.3（`SubjectKey`・TA-R-AC-3・4、起動時の回収 = 導出 I-34）・§5.8（TA-R-PU-1）、共有仕様 `docs/design/shared-playback-spec.md` §6.3（性質 1〜5・iOS 行）・§6.5・§4.4 SL-01/02/06/07、`docs/design/ios-design.md` §4・§11.3 I-S5 行、Spec §3.1 OfflineLibrary（CI-T10）・§3.3（CI-T15）。検証モード（再設計しない）。新しい契約 ID を作らない。

## 確定済みの判断（2026-09-23 夜 dig-me。旧 U-5-1 は閉じた。未決なし）
| ID | 決定 | 反映先 |
|---|---|---|
| SG-C12（旧 U-5-1） | 選択肢 (a)。logout 時の `apiClient.unregisterDeviceToken(token)` の client 呼出（`AppState.swift:417`。2026-10-01 実測）を**削除**し、B-S5b のセッション削除連鎖（ADR-104 決定 10）に任せる。SG-B4（Android）の iOS への拡張。`APIClient.unregisterDeviceToken` 自体と `APIClientTests` の T-T12-21 は残す（他の呼出 0 で method は残置。削除は本 slice の対象外）。共有仕様 §6.5 iOS 行に反映済み | 対象 5・完了条件の logout 行 |
| SG-C13 | 起動時に主体が未確定（`unavailable`）のまま、同じ起動中に login（password / passkey）が成功した場合も「主体の確定」に含め、起動時回収を 1 回走らせる。確定の契機 = `getMe` 成功・401・login 成功のいずれか。iOS の login 成功は password / passkey とも `AppState.completeLogin(_:)` が唯一の入口（`NewsListenAppApp.swift:57` → `LoginView(onSuccess:)` → `LoginViewModel` / `PasskeyLoginViewModel`。iOS に register 画面は無い）。共有仕様 §6.3 決定 2 に反映済み | 対象 4 の経路 (v)・テスト |

## 前提・着手条件
- 依存（他 module の契約。PR 番号ではなく契約の有無で判定する。親リポのポインタがその backend main を指していること = `git -C <親> submodule status` で `backend` に `+` が無い）:
  - **B-S5a**（完了）: `GET /auth/me` と `POST /auth/login` の応答が `user_id`（`[A-Za-z0-9_-]`）を返す（backend-design §14.2）。
  - **B-S5b**（2026-10-01 時点で未着手）: セッション削除（logout を含む）が、そのセッションに紐づく通知登録を連鎖して消す（ADR-104 決定 10・13）。**B-S5b が親 main に入るまで投入しない**。確かめ方: 親 main の backend で、`POST /auth/logout` の経路が通知登録の削除まで連鎖することを、B-S5b の契約テスト（`backend/tests/contract/` の連鎖削除のテスト）が main にあることで確かめる。
- 依存（iOS 内）: **I-S3b3・I-T3・I-T5 の submodule PR が main に merge 済み、かつ親リポのポインタが進んでいる**（`ios` に `+` が無い。`OfflineLibrary` が合成 root の 1 インスタンスで、`SettingsViewModel` が注入必須になっていること。`OfflineDownloads`（I-T3）と `SubjectKey`・`Subject.key`（I-T5）があること）。**I-S4 の完了は不要**（変更ファイルが重ならない。README「投入順」の並行組）。
- 確定値: 主体の交差は待機ではなく主体識別で防ぐ（SG-X3 revised・ADR-104 選択肢 (A)）。既存の平置きキャッシュ（`Caches/NewsListenApp/audio-cache/*.mp3`）は初回起動で全削除・移行なし（決定 7・SG-A1）。`user_id` 欠落・形式不正時は**キャッシュ無効＋起動時回収は未認証と同じ扱い（全ディレクトリ削除）**（決定 16 を 3 platform 共通に適用。2026-09-23 user 判断 Q13 = A）。主体依存の UserDefaults 削除は I-S2 の `PreferenceRegistry.subjectScoped`（共有仕様 §6.5 分類表）に従い、本 slice で対象 key を増減しない。
- 棄却済み案: 離脱時に全削除（決定 2 を満たさない。ADR-104「採らなかった案」）、後始末完了を待つ (b)。
- **logout の明示ヘッダ（決定 14）は新ヘッダを作らない**（2026-09-23 user 判断・ADR-104 追記）: トークン破棄の前に捕捉したトークンで既存の `Authorization: Bearer <token>` を付けて `POST /auth/logout` を送り、await しない。実現手段は `APIClient` の既存構造で足りる: `sessionToken` は `init` で受ける `let`（`APIClient.swift:9,29`）なので、破棄前の `apiClient` インスタンス（または捕捉したトークンで生成した `APIClient`）が破棄後も同じ `Authorization: Bearer` を付ける。`APIClient` のヘッダ付与規則（`:281-283`）は変えない。
- 起動時回収の契機（2026-09-23 user 判断 Q10 = A・SG-C13）: 主体が定まらない間（`resolving` / `unavailable`）は回収せず、`authenticated` または未認証（`anonymous`）に確定した時点で同じ回収を 1 回走らせる。確定の契機は `getMe` 成功・401・**同じ起動中の login 成功（`completeLogin`）** のいずれか（起動時の `getMe` に限ると、通信断で起動 → 別主体でログイン、の順で前主体の資産が次回起動まで残る）。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-S3b3・I-T3・I-T5 の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| logout の手順 | `AppState.swift:406-` `logout()`: `:410` `deviceTokenRegistrationTask?.cancel()`、`:417` `_ = try? await apiClient.unregisterDeviceToken(token)`（`if let token = apnsDeviceToken` の中）、`:419` `_ = try? await apiClient.logout()`（どちらも破棄の前の await） | `grep -n 'func logout\|deviceTokenRegistrationTask?.cancel\|unregisterDeviceToken\|apiClient.logout' NewsListenApp/NewsListenApp/AppState.swift` |
| `AudioCacheManager` の操作 | `Networking/AudioCacheManager.swift`: `cachedURL(for:)` `:45`・`isCached` `:52`・`cache(_:for:)` `:62`・`remove` `:71`・`cacheSize` `:80`・`clearCache` `:90`。保存先 `Caches/NewsListenApp/audio-cache/`（`:39`） | `grep -n 'func \|audio-cache' NewsListenApp/NewsListenApp/Networking/AudioCacheManager.swift` |
| `user_id` / `userId` の出現 | 0 | `grep -rn 'user_id\|userId' NewsListenApp/NewsListenApp --include='*.swift' \| wc -l` |
| `SubjectKey`（I-T5） | `Auth/Domain/Subject.swift` に `SubjectKey.init?(_:)`。`AuthUser.toSubject()` の `key` は nil | `grep -n 'SubjectKey\|key:' NewsListenApp/NewsListenApp/Auth/Domain/Subject.swift NewsListenApp/NewsListenApp/Models/AuthModels+Subject.swift` |
| `OfflineDownloads`（I-T3） | `download(episodeId:)`・`cancelAll()`・`removeAll()`。`OfflineLibrary.save(_:for:)` の 2 引数 | `grep -n 'func ' NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift NewsListenApp/NewsListenApp/Podcast/Playback/OfflineLibrary.swift` |
| `AudioFileStore`（I-S3b1） | closure 6 つ（`url`・`exists`・`write`・`remove`・`removeAll`・`size`）。`Podcast/Platform/AudioFileStore+Live.swift` | `grep -n 'let ' NewsListenApp/NewsListenApp/Podcast/Playback/OfflineLibrary.swift` |
| 既存テスト | `AudioCacheManagerTests` 13・`AppStateAuthTests`（I-T5 の後の件数）・`SettingsViewModelTests`・`OfflineDownloadsTests`（I-T3）・`SubjectCleanupTests` 17 | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`Models/AuthModels.swift`・`Models/AuthModels+Subject.swift`（変更）**: `AuthUser` に `userId: String?`（`CodingKeys` = `user_id`。任意。既存 `username / role / displayName` は不変）を足すだけ。`LoginResponse.user` 経由で login 応答からも取れる。主体キーの妥当性 `^[A-Za-z0-9_-]+$` の判定は `Auth/Domain/Subject.swift` の `SubjectKey.init?(_:)`（I-T5。TA-R-AC-4）で、`toSubject()` が `key: SubjectKey(userId)` を作る（無効・欠落なら nil）。`Models/` に判定を置かない（TA-D8・TA Spec §8.3 の補正 4）。
2. **`Networking/AudioCacheManager.swift` → `Podcast/Platform/AudioCacheManager.swift`（移動と変更。TA Spec §3.2）**: 保存先を `Caches/NewsListenApp/audio/{user_id}/{id}.mp3` に。操作は主体キー引数付き（`cachedURL(for:subject:)` / `isCached(_:subject:)` / `cache(_:for:subject:)` / `remove(_:subject:)` / `cacheSize(subject:)` / `removeSubject(_:)`）と `reclaim(keeping: subject?)`（`audio/` 直下の `keeping` 以外のディレクトリと旧 `audio-cache/` ディレクトリを削除。`keeping` が nil なら全削除。冪等。初回起動フラグは持たず、旧ディレクトリが存在すれば毎回消す）。`clearCache()`（端末単位全削除）は削除。主体キーの引数は `SubjectKey`（`rawValue` をディレクトリ名に使う）。`Podcast/Platform/AudioFileStore+Live.swift` の束も主体キーの引数つきの closure と `reclaim(keeping:)` に合わせる（`AudioFileStore` の宣言は `Podcast/Playback/OfflineLibrary.swift`）。
3. **`Podcast/Playback/OfflineLibrary.swift`・`Podcast/Playback/OfflineDownloads.swift`・`Podcast/Playback/OfflineLibrary.swift` の `AudioFileStore`（変更。TA Spec §8.3 の補正 3。導出 I-28）**:
   - `OfflineLibrary`（保存庫。取得も Task も持たない。I-10）: 現在の主体キーを `bind(subject: SubjectKey?)` で受ける。nil（未認証・`user_id` 欠落・形式不正）のときは**無効**: `has` false・`url` nil・`savedIds` 空・`save` は格納しない。保存は主体つき `save(_ data: Data, for id: String, subject: SubjectKey?)`（渡された主体のディレクトリへ書く。nil なら格納しない）。`clearAll()` を `remove(subject:)` に置き換える（共有仕様 §6.3 iOS 行）。`reclaim(keeping: SubjectKey?)` を足す（`AudioFileStore` の `reclaim` を呼び、`savedIds` を作り直す）。`usage()` は現在主体のみ。
   - `OfflineDownloads`（取得と Task の持ち主）: `download(episodeId:)` は**開始時に主体キーを控え**（`library` の `bind` 済みの値。注入した closure `currentSubject: () -> SubjectKey?` で読む）、保存のとき `library.save(data, for: id, subject: 控えたキー)` を呼ぶ。途中で `bind` が変わっても開始時主体のディレクトリへ書く（性質 3・SL-06）。`cancelAll()` は実行中の Task を cancel し**完了を待たない**（性質 4・ADR-104 決定 9）。`removeAll()` は `library.remove(subject: 現在の主体)`。
4. **`Auth/SubjectCleanup.swift`・`AppState.swift`（変更）**: 事後条件 (2) を「実行中のダウンロードの cancel（`OfflineDownloads.cancelAll()`。待たない）→ `OfflineLibrary.remove(subject: 離脱主体)`」に置換（順序: トークン破棄 → 認証状態の遷移 → 後始末。完了を待たない）。`OfflineDownloads` はログインごとに作り直されるので、`AppState` への登録は `PlaybackLifecycle` と同じ**弱参照の登録**（`registerDownloads(_:)`。登録が無ければ何もしない。TA Spec §8.3 の補正 5）。遷移 ④ `authenticated(A) → authenticated(B)`（`completeLogin` が `authenticated` 中に呼ばれた場合）でも A に対して `SubjectCleanup` を実行し、B の確立は A の後始末を待たない（SL-07。ios-design §4 の遷移 ①②④）。`SubjectCleanup` は離脱主体の主体キー（`SubjectKey?`。`Subject.key`。無効・欠落なら nil = 消すディレクトリ無し）を引数で受ける。起動時回収（確定値 Q10 = A・SG-B3）は「起動後に主体が最初に確定した時点で 1 回」。主体が確定する経路は次の 5 つで全数（SG-C13 で (v) を追加）: (i) 保存トークン無し → `anonymous` 即確定（`refreshAuth` を呼ばない経路。ここでも `reclaim(keeping: nil)` を走らせる）、(ii) `refreshAuth` 成功 → `authenticated(subject)` → `reclaim(keeping: subject.key)`（無効・欠落なら nil）、(iii) `refreshAuth` が `unauthorized` → `anonymous` → `reclaim(keeping: nil)`、(iv) `refreshAuth` が `unavailable`（主体未確定・トークン保持）→ 回収せず、`retryResolve` で (ii)/(iii) に確定した時点で同じ回収を 1 回、(v) `unavailable` のまま `completeLogin(receipt)`（password / passkey login の唯一の入口。I-T5 で引数は `LoginReceipt`）で `authenticated(B)` に確定 → `reclaim(keeping: B.key)` を 1 回（保持していた旧トークンの主体 A のディレクトリはこの回収で消える。`unavailable → authenticated(B)` を主体離脱として `SubjectCleanup` の対象にするかは I-S2 の遷移表の管轄で、本 slice では変えない）。「起動後に最初の確定で 1 回」の規則は (i)〜(v) で共通: (i)/(ii)/(iii)/(iv)→(ii)/(iii) の後に login で `authenticated(B)` になっても再回収はしない（(i)/(iii) は全ディレクトリ削除済み、(ii) からの交代は遷移 ④ の `SubjectCleanup` が A を消す）。回収済みかは `AppState`（Account の application）の起動単位のフラグ 1 つで持つ（永続化しない。導出 I-34）。
5. **`AppState.logout()`（変更。`APIClient` のヘッダ付与規則は変えない）**: `sessionStore.token` を破棄する**前**に破棄前の `apiClient`（`sessionToken` を保持）またはトークンを捕捉し、`sessionStore.token = nil` → 認証状態の遷移の**後**に、捕捉した client で `POST /auth/logout` を送る（既存 endpoint・既存 `Authorization: Bearer`。新ヘッダは作らない。`Task` に投げて `await` しない。失敗は無視）。現行の `_ = try? await apiClient.logout()`（`:419`。破棄前の await。2026-10-01 実測）は削除する。`_ = try? await apiClient.unregisterDeviceToken(token)`（`:417`）と `if let token = apnsDeviceToken` の囲いも**削除**し、APNs 登録の解除はサーバのセッション削除連鎖（**B-S5b**）に任せる（SG-C12。`deviceTokenRegistrationTask?.cancel()`（`:410`）は残す）。logout 内の `apiClient` 呼出は `POST /auth/logout` の 1 本だけになる。
6. **`Settings/SettingsViewModel.swift`（変更）**: 「キャッシュ全削除」は `OfflineDownloads.removeAll()`（TA-C-PB-21）、容量表示は `OfflineLibrary.usage()`（TA-Q-PB-4）を呼び、現在主体の範囲にする（VM は主体キーを持たず Library の `bind` 済み主体に従う。TA Spec §8.3 の補正 9）。文言は変えない。
7. **テスト**: `AudioCacheManagerTests`（13）のうちパス・全削除を pin する `testCachedURLReturnsCorrectPath` / `testClearCacheRemovesAllFilesAndIsCachedReturnsFalse` / `testClearCacheIsIdempotentWhenCacheDirectoryMissing` は主体付きへ書き換え、他 10 件は主体引数を足すだけで期待値不変。`AppStateAuthTests` に SL-06 / SL-07、`reclaim` の 5 分岐（authenticated 有効 / 無効・欠落 = **SL-10** / anonymous / unavailable では走らず `retryResolve` 確定後に 1 回 = **SL-08** / unavailable のまま `completeLogin` で確定したとき 1 回だけ = **SL-09**・SG-C13）、`OfflineDownloadsTests` に開始時の主体の固定（保存の前に `bind` を変えても開始時主体のディレクトリに入る）と `cancelAll()` が待たないこと、旧 `audio-cache/` の削除、logout の送信順（破棄前に捕捉したトークンが `Authorization: Bearer` に載り、送信行が破棄行の後、`await` なし）、logout で `/notifications/device-tokens` への DELETE が送られないこと（SG-C12。`MockURLSession` の記録 request に無い）を追加。`SettingsViewModelTests`（36）は注入を足すだけ。

## 完了条件
- 準拠テストが green で、テスト名に **SL-06**（開始時主体固定＋cancel が間に合わない double で次回起動の回収で消える）・**SL-07**（④ の直接交代で A の事後条件が成立し B は待たない）・**SL-08**（`unavailable` → `retryResolve` で確定した時点の回収 1 回）・**SL-09**（`unavailable` のまま login で確定した時点の回収 1 回）・**SL-10**（`user_id` の欠落・形式不正でキャッシュ無効・回収は未認証と同じ）・SL-01 / SL-02（音声キャッシュ部分が「離脱主体のディレクトリが空」で成立）を含み、`verifies: CI-T10 / CI-T15` を持つ（SL-08〜SL-10 は共有仕様 §4.4 の保留の解除条件。TA Spec §8.3 の補正 6）。
- `grep -rn "clearAll\|clearCache" NewsListenApp/NewsListenApp --include='*.swift'` の出現が `Settings/SettingsViewModel.swift` の `func clearCache()`（VM の操作名。実装は `OfflineDownloads.removeAll()` = 現在主体のみ）と `Settings/SettingsView.swift` の呼出だけ（`AudioCacheManager` / `OfflineLibrary` / `OfflineDownloads` / `AudioFileStore` / `SubjectCleanup` に端末単位の全削除経路が無い。`AppState` の `clearOfflineLibrary` の closure は名前を変えず、中身を離脱主体の `remove(subject:)` にする（引数に離脱主体の `SubjectKey?` を受ける形に型を改める）。テストは除外）。
- `grep -rn "audio-cache" NewsListenApp/NewsListenApp --include='*.swift'` の出現は `AudioCacheManager.reclaim` の旧ディレクトリ削除 1 箇所のみ。
- `grep -rn "user_id\|userId" NewsListenApp/NewsListenApp --include='*.swift'` の出現が `Models/AuthModels.swift`（field と `CodingKeys`）と `Models/AuthModels+Subject.swift`（`SubjectKey(userId)`）の 2 ファイルに閉じる（TA Spec §8.3 の補正 8。主体キーは domain の `SubjectKey` として `AppState`・`Auth/SubjectCleanup.swift`・`Podcast/Playback/`・`Podcast/Platform/AudioCacheManager.swift` に渡り、そこでは `user_id` / `userId` の名前を書かない。`Settings/SettingsViewModel.swift` は Library 経由で主体を知らない。admin ユーザー一覧の型 `UserListResponse` に `user_id` を足さない。決定 15）。`grep -rn "SubjectKey" NewsListenApp/NewsListenApp --include='*.swift' -l` が `Auth/Domain/Subject.swift`・`Models/AuthModels+Subject.swift`・`AppState.swift`・`Auth/SubjectCleanup.swift`・`Podcast/Playback/OfflineLibrary.swift`・`Podcast/Playback/OfflineDownloads.swift`・`Podcast/Platform/AudioCacheManager.swift`・`Podcast/Platform/AudioFileStore+Live.swift` の中にある。
- logout: `AppState.logout()` 内で `sessionStore.token = nil` の行が `/auth/logout` 送信の行より前にあり、送信は破棄前に捕捉したトークンの `Authorization: Bearer` を持ち、`await` しない（`MockURLSession` で記録した request の header 値と、破棄 → 送信の順序をテストで pin）。`grep -rn "X-" NewsListenApp/NewsListenApp/Networking/APIClient.swift` の追加が無い（新ヘッダ 0）。`grep -n "await apiClient.logout\|await apiClient.unregisterDeviceToken" NewsListenApp/NewsListenApp/AppState.swift` → 0 件（破棄前の await が無い）。`grep -rn "unregisterDeviceToken" NewsListenApp/NewsListenApp --include='*.swift'` の出現が `Networking/APIClient.swift`・`Networking/APIEndpoint.swift` だけ（client 呼出 0。SG-C12）。
- `GrepOracleTests` の O-8 の期待値に、弱参照の登録の呼出 `appState.registerDownloads(` 1 を足す（合成 root の 1 行。`registerPlaybackLifecycle(` 1 と同じ形。TA Spec §8.3 の補正 5 が足す呼出で、O-8 は名前の集合と件数を固定しているため。ほかの期待値は不変）。
- `subjectScopedKeys` の集合が I-S2 完了時点と同一（`PreferenceRegistry` テストの件数・期待値が不変）。
- 置き場: `test ! -e NewsListenApp/NewsListenApp/Networking/AudioCacheManager.swift && test -e NewsListenApp/NewsListenApp/Podcast/Platform/AudioCacheManager.swift`（rc=0）。`grep -rn "A-Za-z0-9_-" NewsListenApp/NewsListenApp --include='*.swift'` が `Auth/Domain/Subject.swift` の 1 行だけ（主体キーの判定が `Models/` に無い）。
- ダウンロードの主体の固定と cancel が `OfflineDownloads` にある: `grep -n "subject" NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift` が 1 行以上、`grep -n "Task" NewsListenApp/NewsListenApp/Podcast/Playback/OfflineLibrary.swift` が 0 件（保存庫は Task を持たない。I-10）。
- `ArchitectureOracleTests` が green（`Podcast/Platform/AudioCacheManager.swift` が adapter に当たる。許可リストの増減なし）。
- 既存テスト全件 green。

## 禁止事項 / scope 外
- 平置きキャッシュの移行（コピー・rename）をしない。後始末の完了を待つ実装をしない。`user_id` 欠落時にログイン不能・起動不能にしない（決定 16）。
- logout 用の新ヘッダを作らない（既存 `Authorization: Bearer` のみ）。`UserListResponse` / admin 画面に `user_id` を出さない。
- Keychain の service 名・UserDefaults の key 名・共有仕様 §2・`PreferenceRegistry` の `subjectScoped` 集合を変えない。キャッシュ無効時の UI 表示（ダウンロード導線の見せ方）は本 slice で変えない。

## 特性テスト（baseline）
`AudioCacheManagerTests`（13。うち 3 件は上記のとおり主体付きへ書き換え、10 件は期待値不変）・`AppStateAuthTests`（I-T5 完了時点の全件。SL-01〜SL-05）・`SettingsViewModelTests`（36）・`PodcastViewModelTests`（I-S3b3 完了時点の全件）・I-S3b1 の T-T10・I-T3 の `OfflineDownloadsTests`。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`（ios README の現行の形式）→ 全 green。
- 完了条件の grep 4 本 → 期待どおり。シミュレータ目視: A でダウンロード → logout → B でログイン → B の一覧にダウンロード済み表示が無く、A のディレクトリが起動後に残っていない（`Caches/NewsListenApp/audio/` を確認）。
- commit は「AuthUser.userId と toSubject の key」「AudioCacheManager の移動・主体別化＋reclaim」「OfflineLibrary bind / 主体つきの保存」「OfflineDownloads の主体固定 / cancel」「SubjectCleanup ④ と起動時回収」「logout 送信順」「Settings」の単位。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記。router へ返す: 共有仕様 §4.4 SL-06 / SL-07 と SL-01 / SL-02 の音声キャッシュ部分の iOS 保留を解除、§6.3 iOS 行を「実装済み」へ。`docs/design/ios-design.md` §4・§8「オフライン再生キャッシュ」（パスを主体別へ）・§11.3 I-S5 行を現状記述へ。ADR-104 決定 26 の iOS 実施を記録。
