# T5 敵対的検証（独立・refute-first）— report-findings.md §4 のみ

対象 HEAD: `c8c1ada`。作業ツリー dirty の 2 ファイル（`DSFeedback.swift` / `LearningEngagementModelTests.swift`）は未参照。
他の Function package（architecture/completeness/contract/boundary）は読んでいない。全て自分で `grep`/`awk` で再取得した。

## (a) finding ごとの verdict

### RF1 (blocker) — **accepted**
- `docs/design/shared-playback-spec.md:312` = 「iOS | FileManager ローカルキャッシュ全体 | `AudioCacheManager.removeAllDownloads()`（ビルトイン。logout 時に自動呼び出し）」逐語一致。
- `AudioCacheManager` の非 private メンバは `cachedURL:45 / isCached:52 / cache:62 / remove:71 / cacheSize:80 / clearCache:90` の 6 個。`removeAllDownloads` は全 `*.swift` に 0 件。
- 反証試行1「別名の一括削除を logout が呼んでいないか」→ `clearCache` の呼出元は `Settings/SettingsView.swift:434` → `Settings/SettingsViewModel.swift:184,186` のみ。`AppState.logout()`（`AppState.swift:282-302`）は deviceToken 解除・`apiClient.logout()`・`UserDefaults` の seenAchievementIDs・`sessionStore.token`・`currentUser`・`authStatus` のみ。**崩れなかった**。
- 反証試行2「NowPlaying を消す別経路」→ `nowPlayingInfo` への代入は `PodcastViewModel.swift:611,733,736,753` の 4 箇所のみ。611 は `stopPlayback` 系、733 は `currentPodcast == nil` ガード内。どちらも logout 経路から呼ばれない（`deinit:796-810` は observer/RemoteCommand 解除のみ）。**崩れなかった**。
- `AppStateAuthTests.swift:34` = `testLogoutClearsTokenAndUser`（assert は token/currentUser/authStatus のみ）、`:87` = `testRegisterDeviceTokenIfPossibleDoesNotCallAPIAfterLogout`。記述一致。
- severity: 仕様に明記された事後条件が未実装 ＋ 共有端末で音声実体が残る。blocker（P7 で降格可）の提案は妥当。

### RF2 (major) — **accepted**
- `APIClient.swift:536-545` の `validateResponse` は 429 のみ `rateLimited`、他は `httpError(statusCode:)`。401 の特別扱いなし。
- 反証試行3「401 を集中処理する箇所」→ `grep -rn '401'` の production ヒットは `Auth/LoginViewModel.swift:59` 1 件のみ（残りは Tests 4 ファイル）。`AppState` に 401 監視なし。**崩れなかった**。
- トークン破棄経路は `refreshAuth():217` と `logout():299` の 2 箇所のみ（`sessionStore.token = nil` の全出現）。`AuthModels.swift:24` `isAdmin` は `currentUser.role` 依存で失効を見ない。記述一致。

### RF3 (major) — **accepted（引用は 1 行ずれ）**
- `AppState.swift:200` = 「未設定・トークン無し・失効はすべて未認証として扱い、トークンを破棄する」。finding は `:199-201` と幅で引用しており実質正しいが、doc 本文は `:200` の 1 行（`:201` は `func refreshAuth()` シグネチャ）。
- `:216-220` の `catch` は分類なしで `token = nil; currentUser = nil; authStatus = .unauthenticated`。URLError/5xx/decode が同経路。**崩れなかった**。
- `AppStateAuthTests.swift:49` = `testRefreshAuthWithoutTokenIsUnauthenticated` → `guard`（`:202-205`）で早期 return する経路であり catch を通らない。「前提不成立経路のみ」という記述は正しい。

### RF5 (major) — **accepted（1 語の過大表現あり → N3）**
- `PodcastViewModel.swift:281` `currentPodcast = podcast` は唯一の書き込み（production 全体では `DesignSystem/PreviewSupport.swift:153,165` にも代入あり。§4.2 RF13 が別掲しているが RF5 本文の「writer `:281` のみ」は字義的には偽）。`currentPodcast = nil` は production に 0 件。
- 反証試行4「playById の後にキューが更新される別経路」→ `playById:381-388` は `fetchPodcast` → `play(podcast:)` のみ。`play()`（`:262-300`）に `queue` 操作なし。`playNow:516-522` だけが `queue.jump/playNext` を行う。**崩れなかった**。
- `removeFromQueue:543-545` → `PlaybackQueue.remove(id:):100-113`。`idx == cur` で `currentIndex = min(cur, items.count-1)`＝次要素が current になる一方 `currentPodcast` は不変。finding の記述と完全一致。
- `:526,535` の `nothingPlaying` 判定が `currentPodcast == nil`（B ではなく A）— 逐語一致。`QueueSheet.swift:22` の AND 条件、`PodcastView.swift:90` の `currentPodcast?.id ==`、spec `:53` の不変条件 4 も一致。

### RF6 (major) — **accepted**
- 反証試行5「15/9 の再計測」→ `@Published` 宣言は 15 行（36,38,40,42,44,46,48,50,53,55,57,59,61,65,69）。`private(set)` 無し＝外部書込可は 36,38,40,42,44,46,48,50,53 の **9**。`private(set)` は 55,57,59,61,65,69 の 6。**15/9 は完全一致、崩れなかった**（コメント行・doc 内の `@Published` 言及 31,316,329,712 は除外）。
- `handlePlayerItemStatusChange:416-420` は `errorMessage` と `isPlaying = false` のみ。`player` 解放なし・`isBuffering` リセットなし（`isBuffering` の writer は `:425` の `handleTimeControlStatusChange` のみ）。一致。
- `PodcastView.swift:45,135` の `viewModel.errorMessage = nil` 直接代入も一致。

### RF7 (major) — **accepted（Evidence パスの基準ずれ → N2）**
- `handlePlaybackEnded:441` `if let next = queue.advance()` → `:442` `await play(podcast: next, expandsPlayer: false)`。`play()` は `:264-267` の guard で `errorMessage = "Offline and not cached"` を置いて **`stopPlayback()`（:280）と `currentPodcast = podcast`（:281）より手前で return**。よって index だけ次へ進み `currentPodcast`・`player`・`isPlaying` は前エピソードのまま。
- 反証試行6「isPlaying を落とす別経路があるか」→ `handlePlaybackEnded` の advance 分岐に `stopPlayback()` はなく（else 分岐 `:447` のみ）、`isPlaying` の writer は `:419`（failed 時）・`:561`（toggle）・`stopPlayback`。auto-advance 失敗経路はどれも通らない。**崩れなかった**。
- `syncPlaybackPositionIfNeeded:843-852` は `currentPodcast`（＝前エピソード）と `currentTime` を送る。`startPlaybackPositionSync:816-826` の 15 秒 Timer は停止されない。finding の記述と一致。
- trial-log `:63` = 「参考指摘（auto-advance時のオフライン早期returnで旧stateが残る既存構造）はスコープ外・followup issue化候補」逐語一致。ただし実ファイルは `ios/docs/trial-log/player-auto-converge.md`（→ N2）。

### RF8 (major) — **weakened**（主張の本体は accepted、テストに関する副主張は refuted、引用 1 件が wrong）
- 本体は成立: `play()` は `resolvePlaybackURL:238-249` の戻り（キャッシュ or `URL(string: podcast.audioUrl)`）をそのまま `AVPlayerItem(url:)`（`:289`）へ渡す。`fetchPodcast(` の呼出は production 全体で `PodcastViewModel.swift:199`（downloadAudio）と `:383`（playById）の **2 箇所のみ**（grep 再現）。`play()` 内に再取得なし。
- doc comment `:254` =「オンライン+未キャッシュの場合は、署名付き URL を再取得して再生（失敗時は元 audioUrl でフォールバック）」— 実装と真っ向から矛盾。ADR-009 `:22` =「エピソード再生開始時に `GET /podcasts/{id}` で当該エピソードを再取得し…一覧で保持していた URL は再生には使わない」一致。
- **引用誤り**: `docs/design/ios-design.md:373` は手順 **2**（AVAudioSession）。「再生直前に `GET /podcasts/{id}` で再取得」は **:374**（手順 3）。→ N1。
- **副主張の反証（試行7）**: 「`PodcastViewModelTests.swift:483` は仕様違反側を pin する green テスト」→ `:483-508` を読むと assert は `XCTAssertEqual(vm.currentPodcast?.id, "p1")`（`:507`）の 1 本のみ。`MockURLSession(data: Data(), statusCode: 200)` なので、仮に ADR-009 どおり再取得を実装しても decode 失敗 → ADR の「失敗時フォールバック」で `currentPodcast` は `p1` のまま＝**このテストは依然 green**。URL の出所を一切 assert していないため「違反側を pin している」は**崩れた**。実態は「契約を検証していない非識別テスト」。required_action（契約側に書き換え）自体は有効。

### RF10 (major) — **accepted（件数は完全再現。文言の帰属に軽微な混同 → N4）**
- 反証試行8「10 箇所 / 10 ファイルの再計測」→ 下表のとおり **10 分岐 / 10 ファイル**、`404`×6 / `409`×2 / `401`×1 / `400`×1。`APIClient.swift` の定義行（`:24` case 定義, `:26` コメント, `:35` errorDescription, `:534` doc, `:544` throw）は分岐ではないので除外。**崩れなかった**。
- 404 の意味も再現: 「機能未提供 / graceful degradation」3（`AppState:263`, `QuizSheetView:199`, `SettingsViewModel:163`）と「冪等削除成功」3（`PasskeyCredentialsViewModel:52`, `SessionsViewModel:57`, `StarredViewModel:108`）。コメント本文で確認済み。**2 種 3+3 は正しい**。
- `errorMessage` 代入の全出現は `PodcastViewModel.swift:145,151,201,211,222,265,269,386,418,624`。finding が挙げる 8 件は nil 代入（145,269）を除いた全件＝正確。
- 「`audio_url` 欠損とオフラインが同じ文言に合流（`:265`）」は成立: `resolvePlaybackURL:244-245` は online でも `URL(string: podcast.audioUrl)` が nil なら nil を返し、呼出側 `:265` は一律 `"Offline and not cached"`。
- 引用 `APIClient.swift:19-39` は実体が `:20-40`（`enum APIError` 20、閉じ括弧 40）。1 行ずれ（軽微）。

### RF9 (major) — **weakened**（(a) は accepted、(f) の件数が再現しない → N5）
- (a) `Settings/AccountSettingsView.swift:317` `guard newPassword.count >= 8`、`Admin/AdminUsersViewModel.swift:47` `guard !newUsername.isEmpty, newPassword.count >= 8` — **生リテラル 8 の 2 実装**を確認。加えて `Admin/AdminUsersView.swift:28` に UI 文言「パスワード（8文字以上）」があり、実質 3 箇所目の重複（finding より悪い方向）。
- (f) 反証試行9「admin ロール文字列は本当に 4 ファイルか」→ role 値としての `"admin"`/`"user"` は `Models/AuthModels.swift:15(コメント),24`、`Admin/AdminUsersView.swift:31,32`、`Admin/AdminUsersViewModel.swift:23,61,84` の **3 ファイル / 7 出現**。`Models/Podcast.swift:86,186` の `"user"` は sourceKind（別ドメイン）で数えるべきでない。Evidence 欄自体も 3 ファイルしか挙げていない。**「4 ファイル」は崩れた**。
- 引用 `AdminUsersView.swift:32` は `"admin"` タグのみ。`"user"` タグは `:31`（範囲指定でないため片側落ち）。

### RF12 (major) — **weakened**（double の性質記述が誤り → N6）
- `APIClientTests.swift:637` の `MockURLSession` は確かに `HTTPURLResponse` を必ず生成して返し、`URLError` を throw しない・非 HTTP 応答を返せない（`:650-658`）。この部分は accepted。
- **反証試行10**: finding の「**常に成功** `HTTPURLResponse` を返し…RF3・**RF2**・CI-A02 の契約テストが現状の double では書けない」→ `MockURLSession(data:statusCode:)` は任意ステータスを取り、`AuthAPIClientTests.swift:59-65` が現に `status: 401` で `httpError(401)` を検証している。**RF2（401 → セッション失効遷移）の契約テストは現状の double で書ける**。「常に成功」も「RF2 が書けない」も**崩れた**。書けないのは URLError 依存の RF3 / CI-A02 のみ。
- テスト参照 0 の production 型 8 と「空テスト 3 ファイル」は `path:line` 添付がなく（`NewsListenAppUITests/*` はグロブ）、本検証では未再現。

## (b) 件数再計測表

`httpError` の数値分岐（production のみ・`APIClient.swift` の定義/throw/doc を除外）

| # | ファイル | 行 | status | 意味 |
|---|---|---|---|---|
| 1 | `AppState.swift` | 263 | 404 | 機能未提供（streak 未記録） |
| 2 | `Auth/LoginViewModel.swift` | 59 | 401 | 認証失敗（ログイン時のみ） |
| 3 | `Onboarding/OnboardingSourcesViewModel.swift` | 66 | 409 | 重複 |
| 4 | `Passkey/PasskeyCredentialsViewModel.swift` | 52 | 404 | 冪等削除成功 |
| 5 | `Passkey/PasskeyRegistrationViewModel.swift` | 70 | 409 | 重複 |
| 6 | `Podcast/QuizSheetView.swift` | 199 | 404 | 機能未提供（graceful-hide） |
| 7 | `Sessions/SessionsViewModel.swift` | 57 | 404 | 冪等削除成功 |
| 8 | `Settings/AccountSettingsView.swift` | 327 | 400 | 入力不正 |
| 9 | `Settings/SettingsViewModel.swift` | 163 | 404 | 機能未提供（旧 backend） |
| 10 | `Starred/StarredViewModel.swift` | 108 | 404 | 冪等削除成功 |

**合計 10 分岐 / 10 ファイル（RF10 主張と一致）**。404×6 = 機能未提供 3 + 冪等削除 3（RF10 と一致）。

| 主張 | finding の値 | 再計測 | 判定 |
|---|---|---|---|
| RF10 status 数値分岐 | 10 箇所 / 10 ファイル | 10 / 10 | 一致 |
| RF10 404 の意味 | 6 件 = 2 種（3+3） | 6 = 3+3 | 一致 |
| RF6 `@Published` | 15 個中 9 が `var` | 15 個中 9 | 一致（定義行のみ計上、doc 内言及 4 行は除外） |
| RF1 `AudioCacheManager` 公開 API | 6 | 6（45/52/62/71/80/90） | 一致 |
| RF9(a) パスワード 8 | 2 実装 | 2 実装（+UI 文言 1） | 一致（過小側） |
| RF9(f) admin ロール文字列 | 4 ファイル | **3 ファイル / 7 出現** | **不一致** |
| RF8 `fetchPodcast` 呼出 | 2（:199, :383） | 2 | 一致 |
| RF2 401 の production 出現 | 1（LoginViewModel:59） | 1 | 一致 |

## (c) 誤り・訂正候補

- **N1（引用誤り・要訂正）** RF8 の `docs/design/ios-design.md:373` → 正しくは **`:374`**（`:373` は手順 2 の AVAudioSession）。
- **N2（パス基準の不整合）** RF7 の `docs/trial-log/player-auto-converge.md:63` は repo ルートに存在せず、実体は `ios/docs/trial-log/player-auto-converge.md:63`。同じ行内の `docs/design/...` はルート基準で解決するため、1 行の中で 2 つの基準が混在している。§4 冒頭でパス基準を明示すべき。
- **N3（過大表現）** RF5「`currentPodcast`（writer `:281` のみ）」→ production には `DesignSystem/PreviewSupport.swift:153,165` の直接代入もある（RF13 が別途指摘）。「`PodcastViewModel` 内の writer は `:281` のみ」と限定すべき。
- **N4（帰属の混同）** RF10「`errorDescription` は 429 以外が英語（"HTTP Error 404" / "Offline and not cached" / "Playback failed"）」→ 後者 2 つは `APIError.errorDescription`（`APIClient.swift:34-37`）ではなく `PodcastViewModel.swift:265,418` の VM リテラル。主張の結論（日本語文言の owner が不在）は変わらないが、出典の書き方は訂正が要る。
- **N5（件数誤り・要訂正）** RF9(f)「4 ファイルに散在」→ **3 ファイル**（`AuthModels.swift` / `AdminUsersView.swift` / `AdminUsersViewModel.swift`）。Evidence 欄自体も 3 ファイルしか挙げていない（本文と自身の引用先の矛盾）。
- **N6（性質記述の誤り・要訂正）** RF12「`MockURLSession` は常に成功 `HTTPURLResponse` を返し…RF2 の契約テストが書けない」→ 任意 statusCode を返せる（`APIClientTests.swift:644,652-657`）。`AuthAPIClientTests.swift:59-65` が 401 で現に検証済み。RF12 の限界は「`URLError`／非 HTTP 応答を再現できない」のみに縮小すべき（RF3・CI-A02 は残る）。
- **N7（副主張の誤り・要訂正）** RF8「`PodcastViewModelTests.swift:483` は仕様違反側を pin する green テスト」→ assert は `currentPodcast?.id == "p1"`（`:507`）のみで URL の出所を検証しない。ADR-009 準拠実装でも green のまま。「違反を pin」ではなく「契約を検証しない非識別テスト」（RF12 の主題）に分類し直すべき。
- **N8（軽微）** RF3 の `AppState.swift:199-201` は doc 本文が `:200` の 1 行、`:201` は関数シグネチャ。RF10 の `APIClient.swift:19-39` は実体 `:20-40`。いずれも 1 行ずれ（読解には支障なし）。
- **N9（§4.4 の過度な一般化）** 「force unwrap 4 件（`APIClient.swift:275,277,303,305`）: `URLComponents(url:resolvingAgainstBaseURL:)!` は…」→ 実際は 275/303 が `URLComponents(...)!`、277/305 は `components.url!`（queryItems 追加後の URL 再構成）で別種。後者は不正なクエリ値で nil を返しうるため「実質到達不能」の根拠が 4 件すべてには及ばない。CI-A04 候補に留める結論自体は妥当だが、根拠の記述は 2 種に分けるべき。

## (d) RC 判定

- **RC1（path:line 無し／未確認転記）**: 抵触**あり（軽微）**。RF10 の中心主張「10 箇所」の根拠が行内では `verification-run §7` への委譲のみ（私の独立再計測では一致したので転記誤りではない）。RF12 の「テスト参照 0 の production 型 8」「空テスト 3 ファイル」は `path:line` なし・`NewsListenAppUITests/*` はグロブで、本検証では再現不能。該当 2 行に `path:line` を補うべき。それ以外の RF1/2/3/5/6/7/8/9 は全て行単位で追跡可能。
- **RC3（verdict と readiness の混同）**: 抵触**なし**。§4 冒頭で「severity は proposed、§7.1 の独立評価で確定」と明示し、RF1 の「降格は P7 の user 判断」も severity 条件であって readiness 宣言ではない。§4 内に「実装可」「完了」等の readiness 断定は 0 件。
- **RC6（pattern 名を根拠にする）**: 抵触**なし**。pattern 語（排他 union / BaseViewModel / smart constructor）は全て required_action 列にあり、finding 列の根拠は具体コードで構成されている。RF14 の `ListDisplayState` も実在（`PodcastViewModel.swift:73`）。
- **RC7（scope 外）**: 抵触**なし〜境界 1 件**。§4.4 で web/backend/android を明示除外し、web 決定は SG へ隔離済み。RF22 が `.github/workflows/ci.yml` と `scripts/test.sh` を扱うが、いずれも ios ビルド・テストのゲートで ios モジュール検証の範囲内。RF9(a) の「web SG7 で 8〜20 文字と決定済み」は iOS 側の決定を断定せず P7 へ送っており、scope 侵犯ではない。

## (e) citations 集計

- `citations_checked`: **71**（RF1:15 / RF2:4 / RF3:3 / RF5:10 / RF6:5 / RF7:4 / RF8:8 / RF9:5 / RF10:11 / RF12:1 / §4.4:5。重複引用は 1 回に集約）
- `citations_wrong`: **1**（`docs/design/ios-design.md:373` → `:374`。N1）
- `citations_loose`（範囲が 1 行ずれ／基準パスずれ／片側落ち）: **4**（`AppState.swift:199-201`、`APIClient.swift:19-39`、`docs/trial-log/...:63` の基準パス、`AdminUsersView.swift:32`）
- `claims_refuted`: **2**（RF8 のテスト副主張、RF12 の double 性質＋RF2 テスト不能主張）
- `counts_mismatched`: **1**（RF9(f) 4 → 3 ファイル）

## (f) 未到達の finding

RF4 / RF11 / RF13 / RF14 / RF15 / RF16 / RF17 / RF18 / RF19 / RF20 / RF21 / RF22 / RF23 は本タスクの指定（上位 8 件＋余力 2 件）により未検証。
§4.4 のうち「web 実装は未反映（`web/docs/design/...` 参照）」「Keychain / ログ / ATS」「test-runner 報告の誤り 2 件の訂正」も未検証（前者は scope 外、後二者は `verification-run.md` を読まずに判定できないため）。

## 総合判定: **CONDITIONAL PASS**

§4 の骨格（RF1 / RF2 / RF3 / RF5 / RF6 / RF7 / RF10、および RF8 の本体）は 10 件の反証試行すべてに耐えた。件数主張 8 つのうち 7 つが per-file で完全一致した点は信頼度が高い。ただし以下を条件とする。

1. N1（`ios-design.md:373`→`:374`）を訂正。
2. N5（RF9(f) 4→3 ファイル）を訂正。Evidence 欄との自己矛盾でもある。
3. N6・N7（RF12 の double 性質、RF8 のテスト副主張）を訂正。特に **RF12 は「RF2 の契約テストが書けない」を撤回**しないと、RF2 の required_action が不要に RF12 へブロックされる（依存グラフの誤り）。
4. N2（trial-log のパス基準）と N3・N4・N8・N9 の文言修正。
5. RF10 / RF12 に行内 `path:line` を補い RC1 を解消。
