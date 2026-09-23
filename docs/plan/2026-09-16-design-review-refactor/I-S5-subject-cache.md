## iOS リファクタ I-S5: 主体別音声キャッシュと起動時の回収・logout の明示ヘッダ

## 概要
端末ローカル資産（音声キャッシュ）に主体を持たせ、主体離脱の後始末を「端末単位の全削除」から「離脱主体の範囲だけ」へ改める。音声キャッシュを `Caches/NewsListenApp/audio/{user_id}/{podcast_id}.mp3` に分け、起動時に現在の主体以外を回収し、ダウンロードジョブは開始時に主体を固定する。あわせて logout で離脱主体のトークンを明示ヘッダで送る。正本は `docs/adr/104-subject-departure-and-subject-scoped-assets.md`（決定 1〜3・5〜9・14〜16・25・26、追記 SG-A1）、共有仕様 `docs/design/shared-playback-spec.md` §6.3（性質 1〜5・iOS 行）・§6.5・§4.4 SL-01/02/06/07、`docs/design/ios-design.md` §4・§11.3 I-S5 行、Spec §3.1 OfflineLibrary（CI-T10）・§3.3（CI-T15）。検証モード（再設計しない）。新しい契約 ID を作らない。

## 確定済みの判断（2026-09-23 夜 dig-me。旧 U-5-1 は閉じた。未決なし）
| ID | 決定 | 反映先 |
|---|---|---|
| SG-C12（旧 U-5-1） | 選択肢 (a)。logout 時の `apiClient.unregisterDeviceToken(token)` の client 呼出（`AppState.swift:292`）を**削除**し、B-S5b のセッション削除連鎖（ADR-104 決定 10）に任せる。SG-B4（Android）の iOS への拡張。`APIClient.unregisterDeviceToken` 自体と `APIClientTests` の T-T12-21 は残す（他の呼出 0 で method は残置。削除は本 slice の対象外）。共有仕様 §6.5 iOS 行に反映済み | 対象 5・完了条件の logout 行 |
| SG-C13 | 起動時に主体が未確定（`unavailable`）のまま、同じ起動中に login（password / passkey）が成功した場合も「主体の確定」に含め、起動時回収を 1 回走らせる。確定の契機 = `getMe` 成功・401・login 成功のいずれか。iOS の login 成功は password / passkey とも `AppState.completeLogin(_:)` が唯一の入口（`NewsListenAppApp.swift:57` → `LoginView(onSuccess:)` → `LoginViewModel` / `PasskeyLoginViewModel`。iOS に register 画面は無い）。共有仕様 §6.3 決定 2 に反映済み | 対象 4 の経路 (v)・テスト |

## 前提・着手条件
- 依存（他 module の契約）: **backend main に「`GET /auth/me` と `POST /auth/login` の応答が `user_id`（`[A-Za-z0-9_-]`）を返す」契約があり（B-S5 の成果。backend-design §14.2）、親リポのポインタがその backend main を指している**（`git -C <親> submodule status` で `backend` に `+` が無い）。PR 番号ではなく契約の有無で判定する。
- 依存（iOS 内）: **I-S3b3 の submodule PR が main に merge 済み、かつ親リポのポインタが進んでいる**（`ios` に `+` が無い。`OfflineLibrary` が合成 root の 1 インスタンスで、`SettingsViewModel` が注入必須になっていること）。**I-S4 の完了は不要**（変更ファイルが重ならない。README「投入順」の並行組）。
- 確定値: 主体の交差は待機ではなく主体識別で防ぐ（SG-X3 revised・ADR-104 選択肢 (A)）。既存の平置きキャッシュ（`Caches/NewsListenApp/audio-cache/*.mp3`）は初回起動で全削除・移行なし（決定 7・SG-A1）。`user_id` 欠落・形式不正時は**キャッシュ無効＋起動時回収は未認証と同じ扱い（全ディレクトリ削除）**（決定 16 を 3 platform 共通に適用。2026-09-23 user 判断 Q13 = A）。主体依存の UserDefaults 削除は I-S2 の `PreferenceRegistry.subjectScoped`（共有仕様 §6.5 分類表）に従い、本 slice で対象 key を増減しない。
- 棄却済み案: 離脱時に全削除（決定 2 を満たさない。ADR-104「採らなかった案」）、後始末完了を待つ (b)。
- **logout の明示ヘッダ（決定 14）は新ヘッダを作らない**（2026-09-23 user 判断・ADR-104 追記）: トークン破棄の前に捕捉したトークンで既存の `Authorization: Bearer <token>` を付けて `POST /auth/logout` を送り、await しない。実現手段は `APIClient` の既存構造で足りる: `sessionToken` は `init` で受ける `let`（`APIClient.swift:9,29`）なので、破棄前の `apiClient` インスタンス（または捕捉したトークンで生成した `APIClient`）が破棄後も同じ `Authorization: Bearer` を付ける。`APIClient` のヘッダ付与規則（`:281-283`）は変えない。
- 起動時回収の契機（2026-09-23 user 判断 Q10 = A・SG-C13）: 主体が定まらない間（`resolving` / `unavailable`）は回収せず、`authenticated` または未認証（`anonymous`）に確定した時点で同じ回収を 1 回走らせる。確定の契機は `getMe` 成功・401・**同じ起動中の login 成功（`completeLogin`）** のいずれか（起動時の `getMe` に限ると、通信断で起動 → 別主体でログイン、の順で前主体の資産が次回起動まで残る）。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`Models/AuthModels.swift`（変更）**: `AuthUser` に `userId: String?`（`CodingKeys` = `user_id`。任意。既存 `username / role / displayName` は不変）。`LoginResponse.user` 経由で login 応答からも取れる。主体キーの妥当性 `^[A-Za-z0-9_-]+$` を判定する純関数を同ファイルに置く（無効なら主体キー nil 扱い）。
2. **`Networking/AudioCacheManager.swift`（変更）**: 保存先を `Caches/NewsListenApp/audio/{user_id}/{id}.mp3` に。操作は主体キー引数付き（`cachedURL(for:subject:)` / `isCached(_:subject:)` / `cache(_:for:subject:)` / `remove(_:subject:)` / `cacheSize(subject:)` / `removeSubject(_:)`）と `reclaim(keeping: subject?)`（`audio/` 直下の `keeping` 以外のディレクトリと旧 `audio-cache/` ディレクトリを削除。`keeping` が nil なら全削除。冪等。初回起動フラグは持たず、旧ディレクトリが存在すれば毎回消す）。`clearCache()`（端末単位全削除）は削除。
3. **`Podcast/Playback/OfflineLibrary.swift`（変更）**: 現在の主体キーを `bind(subject: String?)` で受ける。nil（未認証・`user_id` 欠落・形式不正）のときは**無効**: `has` false・`url` nil・`savedIds` 空・`save` は格納しない。`save(episode)` は**開始時の主体を固定**し、途中で `bind` が変わっても開始時主体のディレクトリへ書く（性質 3）。`cancelDownloads()` は実行中の `Task` を cancel し**完了を待たない**（性質 4）。`clearAll()` を `remove(subject:)` に置き換える（共有仕様 §6.3 iOS 行）。`usage()` は現在主体のみ。
4. **`Auth/SubjectCleanup.swift`・`AppState.swift`（変更）**: 事後条件 (2) を `OfflineLibrary.cancelDownloads()` → `OfflineLibrary.remove(subject: 離脱主体)` に置換（順序: トークン破棄 → 認証状態の遷移 → 後始末。完了を待たない）。遷移 ④ `authenticated(A) → authenticated(B)`（`completeLogin` が `authenticated` 中に呼ばれた場合）でも A に対して `SubjectCleanup` を実行し、B の確立は A の後始末を待たない（SL-07。ios-design §4 の遷移 ①②④）。`SubjectCleanup` は離脱主体の主体キー（`user_id`。無効・欠落なら nil = 消すディレクトリ無し）を引数で受ける。起動時回収（確定値 Q10 = A・SG-B3）は「起動後に主体が最初に確定した時点で 1 回」。主体が確定する経路は次の 5 つで全数（SG-C13 で (v) を追加）: (i) 保存トークン無し → `anonymous` 即確定（`refreshAuth` を呼ばない経路。ここでも `reclaim(keeping: nil)` を走らせる）、(ii) `refreshAuth` 成功 → `authenticated(user)` → `reclaim(keeping: user.userId が有効ならその値、無効・欠落なら nil)`、(iii) `refreshAuth` が `unauthorized` → `anonymous` → `reclaim(keeping: nil)`、(iv) `refreshAuth` が `unavailable`（主体未確定・トークン保持）→ 回収せず、`retryResolve` で (ii)/(iii) に確定した時点で同じ回収を 1 回、(v) `unavailable` のまま `completeLogin(response)`（password / passkey login の唯一の入口）で `authenticated(B)` に確定 → `reclaim(keeping: B.userId が有効ならその値、無効・欠落なら nil)` を 1 回（保持していた旧トークンの主体 A のディレクトリはこの回収で消える。`unavailable → authenticated(B)` を主体離脱として `SubjectCleanup` の対象にするかは I-S2 の遷移表の管轄で、本 slice では変えない）。「起動後に最初の確定で 1 回」の規則は (i)〜(v) で共通: (i)/(ii)/(iii)/(iv)→(ii)/(iii) の後に login で `authenticated(B)` になっても再回収はしない（(i)/(iii) は全ディレクトリ削除済み、(ii) からの交代は遷移 ④ の `SubjectCleanup` が A を消す）。回収済みかは `AppState` の起動単位のフラグ 1 つで持つ（永続化しない）。
5. **`AppState.logout()`（変更。`APIClient` のヘッダ付与規則は変えない）**: `sessionStore.token` を破棄する**前**に破棄前の `apiClient`（`sessionToken` を保持）またはトークンを捕捉し、`sessionStore.token = nil` → 認証状態の遷移の**後**に、捕捉した client で `POST /auth/logout` を送る（既存 endpoint・既存 `Authorization: Bearer`。新ヘッダは作らない。`Task` に投げて `await` しない。失敗は無視）。現行の `_ = try? await apiClient.logout()`（`:294`。破棄前の await）は削除する。`_ = try? await apiClient.unregisterDeviceToken(token)`（`:292`）と `if let token = apnsDeviceToken` の囲いも**削除**し、APNs 登録の解除はサーバのセッション削除連鎖に任せる（SG-C12。`deviceTokenRegistrationTask?.cancel()`（`:284`）は残す）。logout 内の `apiClient` 呼出は `POST /auth/logout` の 1 本だけになる。
6. **`Settings/SettingsViewModel.swift`（変更）**: 「キャッシュ全削除」と容量表示を現在主体の範囲に（注入済み `OfflineLibrary` の `remove(subject:)` / `usage()`。VM は主体キーを持たず Library の `bind` 済み主体に従う）。文言は変えない。
7. **テスト**: `AudioCacheManagerTests`（13）のうちパス・全削除を pin する `testCachedURLReturnsCorrectPath` / `testClearCacheRemovesAllFilesAndIsCachedReturnsFalse` / `testClearCacheIsIdempotentWhenCacheDirectoryMissing` は主体付きへ書き換え、他 10 件は主体引数を足すだけで期待値不変。`AppStateAuthTests` に SL-06 / SL-07、`reclaim` の 5 分岐（authenticated 有効 / 無効・欠落 / anonymous / unavailable では走らず `retryResolve` 確定後に 1 回 / unavailable のまま `completeLogin` で確定したとき 1 回だけ = SG-C13）、旧 `audio-cache/` の削除、logout の送信順（破棄前に捕捉したトークンが `Authorization: Bearer` に載り、送信行が破棄行の後、`await` なし）、logout で `/notifications/device-tokens` への DELETE が送られないこと（SG-C12。`MockURLSession` の記録 request に無い）を追加。`SettingsViewModelTests`（36）は注入を足すだけ。

## 完了条件
- 準拠テストが green で、テスト名に **SL-06**（開始時主体固定＋cancel が間に合わない double で次回起動の回収で消える）・**SL-07**（④ の直接交代で A の事後条件が成立し B は待たない）・SL-01 / SL-02（音声キャッシュ部分が「離脱主体のディレクトリが空」で成立）を含み、`verifies: CI-T10 / CI-T15` を持つ。
- `grep -rn "clearAll\|clearCache" NewsListenApp/NewsListenApp --include='*.swift'` の出現が `Settings/SettingsViewModel.swift` の `func clearCache()`（VM の操作名。実装は現在主体のみ）と `Settings/SettingsView.swift` の呼出だけ（`AudioCacheManager` / `OfflineLibrary` / `SubjectCleanup` に端末単位の全削除経路が無い。テストは除外）。
- `grep -rn "audio-cache" NewsListenApp/NewsListenApp --include='*.swift'` の出現は `AudioCacheManager.reclaim` の旧ディレクトリ削除 1 箇所のみ。
- `grep -rn "user_id\|userId" NewsListenApp/NewsListenApp --include='*.swift'` の出現が `Models/AuthModels.swift`・`AppState.swift`・`Auth/SubjectCleanup.swift`（離脱主体キーの受け渡し）・`Podcast/Playback/OfflineLibrary.swift`・`Networking/AudioCacheManager.swift` の 5 ファイルに閉じる（`Settings/SettingsViewModel.swift` は Library 経由で主体を知らない。admin ユーザー一覧の型 `UserListResponse` に `user_id` を足さない。決定 15）。
- logout: `AppState.logout()` 内で `sessionStore.token = nil` の行が `/auth/logout` 送信の行より前にあり、送信は破棄前に捕捉したトークンの `Authorization: Bearer` を持ち、`await` しない（`MockURLSession` で記録した request の header 値と、破棄 → 送信の順序をテストで pin）。`grep -rn "X-" NewsListenApp/NewsListenApp/Networking/APIClient.swift` の追加が無い（新ヘッダ 0）。`grep -n "await apiClient.logout\|await apiClient.unregisterDeviceToken" NewsListenApp/NewsListenApp/AppState.swift` → 0 件（破棄前の await が無い）。`grep -rn "unregisterDeviceToken" NewsListenApp/NewsListenApp --include='*.swift'` の出現が `Networking/APIClient.swift`・`Networking/APIEndpoint.swift` だけ（client 呼出 0。SG-C12）。
- `subjectScopedKeys` の集合が I-S2 完了時点と同一（`PreferenceRegistry` テストの件数・期待値が不変）。
- 既存テスト全件 green。

## 禁止事項 / scope 外
- 平置きキャッシュの移行（コピー・rename）をしない。後始末の完了を待つ実装をしない。`user_id` 欠落時にログイン不能・起動不能にしない（決定 16）。
- logout 用の新ヘッダを作らない（既存 `Authorization: Bearer` のみ）。`UserListResponse` / admin 画面に `user_id` を出さない。
- Keychain の service 名・UserDefaults の key 名・共有仕様 §2・`PreferenceRegistry` の `subjectScoped` 集合を変えない。キャッシュ無効時の UI 表示（ダウンロード導線の見せ方）は本 slice で変えない。

## 特性テスト（baseline）
`AudioCacheManagerTests`（13。うち 3 件は上記のとおり主体付きへ書き換え、10 件は期待値不変）・`AppStateAuthTests`（I-S2 完了時点の全件。SL-01〜SL-05）・`SettingsViewModelTests`（36）・`PodcastViewModelTests`（I-S3b3 完了時点の全件）・I-S3b1 の T-T10。

## 検証
- `xcodebuild test -only-testing:NewsListenAppTests`（README のコマンド）→ 全 green。
- 完了条件の grep 4 本 → 期待どおり。シミュレータ目視: A でダウンロード → logout → B でログイン → B の一覧にダウンロード済み表示が無く、A のディレクトリが起動後に残っていない（`Caches/NewsListenApp/audio/` を確認）。
- commit は「AuthUser.userId」「AudioCacheManager 主体別化＋reclaim」「OfflineLibrary bind / 主体固定 / cancel」「SubjectCleanup ④ と起動時回収」「logout 送信順」「Settings」の単位。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記。router へ返す: 共有仕様 §4.4 SL-06 / SL-07 と SL-01 / SL-02 の音声キャッシュ部分の iOS 保留を解除、§6.3 iOS 行を「実装済み」へ。`docs/design/ios-design.md` §4・§8「オフライン再生キャッシュ」（パスを主体別へ）・§11.3 I-S5 行を現状記述へ。ADR-104 決定 26 の iOS 実施を記録。
