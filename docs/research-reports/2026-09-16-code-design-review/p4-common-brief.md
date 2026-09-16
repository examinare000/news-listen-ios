# P4 共通ブリーフ（ios モジュール設計レビュー・review mode・read-only）

## 0. routing_context（必須・変更不可）
```yaml
routing_context: {origin: integrated, mode: review, requested_by: router, requested_artifact: <各体に指定>, return_to: router, mutation_authorized: false}
```
- 再 routing・peer 呼び出し・サブエージェント起動は禁止。成果物は自分の Function package 1 つだけ。
- **ソース・設定・git・docs を一切変更しない**。書けるのは scratchpad の指定ファイルのみ。
- 他 package（並列作成中）が無ければ読まず、必要な owner 情報は `obligation`（OB-*）として返す。

## 1. 対象と参照資料（優先順: 実コード > 共有仕様/設計書/ADR > rule > Explorer 報告）
- 対象コード: `/Users/rio/git/news-listen/ios/NewsListenApp/NewsListenApp/`（83 ファイル / 11,115 行）。テスト: `/Users/rio/git/news-listen/ios/NewsListenApp/NewsListenAppTests/`（36 / 7,879）。
- 共有再生仕様（正本）: `/Users/rio/git/news-listen/docs/design/shared-playback-spec.md`（§2 キュー状態モデル・不変条件 1〜5・操作契約、§4 Q-01〜Q-32 / RT-01〜15 / RT-A01-02、§6 オフライン・logout）。
- iOS 設計書: `/Users/rio/git/news-listen/docs/design/ios-design.md` §5〜§8（MVVM・AppState・APIClient・AVPlayer）。
- ルール: `/Users/rio/git/news-listen/agent-rules/11-testing-strategy.md`（:70-75 本番経路同一性）、`12-security-guidelines.md`、`ios/CLAUDE.md`。
- Explorer 報告（既知観測。**引用前に必ず自分で該当行を再読**）: `/private/tmp/claude-501/-Users-rio-git-news-listen-ios/553632af-0e6e-4210-bef5-56d77d1b3e4d/scratchpad/p1-domain.md`、`p1-entry.md`、`p1-test-ci-sec.md`、検証実測 `verification-run.md`（同 dir）。
- web モジュールの同種レビュー（書式と粒度の参照例。内容は流用しない）: `/Users/rio/git/news-listen/web/docs/research-reports/2026-09-16-code-design-review/<function>-package.md`。

## 2. 棄却済み案（再提案禁止。`docs/trial-log/` 由来）
- `AudioPlayerView` の `@State` を XCTest で観測する案。SwiftUI View 内部状態はテスト対象外とし純粋関数境界を固定する方針が既定。
- `handlePlaybackEnded` のレースを処理順序の入替だけで解消する案。stale ガードは `endedId` 引数方式（実装済み）。
- `isAtEnd` 判定から `durationSeconds > 0` 前置ガードを外す案。
- 「環境制限で実行不可」を根拠に green 未実測で進める案。
- `Queue` の意味論を SwiftUI onMove 規約から変える案（正本 = iOS onMove 方式、ADR-053）。

## 3. Quality lens（ユーザー確定）
- QL1 maintainability/modifiability（primary）、QL2 maintainability/testability（primary）、QL3 reliability/fault tolerance（secondary）、QL4 security/confidentiality（constraint・must-hold）。性能は intentionally_not_optimized（Evidence なし）。

## 4. Requirement Catalog seed（router 起草。inferred。各体は自分の Function の観点で参照し、足りなければ R 追加候補を `requirement_candidates` で返す）
| ID | statement | kind | QL |
|---|---|---|---|
| R1 | 業務ルール（パスワード規則・404 の意味・admin 判定・quota 解釈・featured grouping・再開位置閾値）は Model/policy 層に単一所有され、View / 複数 VM に重複しない | policy | QL1 |
| R2 | 再生セッションの不正状態（error と paused の判別不能、advance 後に current と queue が別エピソード、`@Published var` の外部書込）を公開経路から構築できない | invariant | QL3/QL2 |
| R3 | 「現在再生中」「再生速度（既定/セッション）」「再生位置」「キャッシュ有無」「ネットワーク状態」「認証状態」の source of truth が一意で、writer が 1 owner を通る | invariant | QL1/QL3 |
| R4 | 消費者（VM/View）は失敗の**意味**（network/unauthorized/forbidden/not_found(subject)/conflict/rate_limited(retryAfter)/server）を受け取り、`APIError.httpError(statusCode)` の数値比較や英語 `localizedDescription` の露出に依存しない | policy | QL1/QL3 |
| R5 | 実行中のセッション失効（API 401）で未認証へ遷移し、認可判定（isAdmin）は単一 policy を通る | prohibition | QL4 |
| R6 | logout・失効時に前利用者の主体データ（音声キャッシュ・NowPlaying 情報・UserDefaults の主体依存値）が端末に残らない。共有仕様 §6.3 は「iOS: `AudioCacheManager.removeAllDownloads()` を logout 時に自動呼び出し」と記すが実装に該当 API・呼出は無い（contradiction 候補） | prohibition | QL4 |
| R7 | テストは production 経路（実 APIClient + URLSession double）を通り契約に対応付く。テスト 0 の VM・KeychainSessionStore・テンプレート空テスト・`MockURLSession` が URLError を再現しない点を扱う | policy | QL2 |
| R8 | CI と `make test` が同一経路で、lint / 独立 build / UI テストのゲート方針が明文化される | policy | QL2 |
| R9 | `PlaybackQueue` は共有仕様 §2 不変条件 1〜5 と Q-01〜Q-32 を満たし、名前差（`reorderUpNext` vs `moveUpNext`、IndexSet 複数移動）は契約として明示される | invariant | QL1 |

## 5. 既知観測（router が再読で確認済み。`path:line` は HEAD c8c1ada）
- `Podcast/PodcastViewModel.swift:36-69` `@Published` 15 atom（排他 enum は `PlayerPresentation` / `DownloadState` のみ）。`:264-267` オフライン未キャッシュで `errorMessage = "Offline and not cached"` して return（英語）。`:281` `currentPodcast = podcast`（唯一の本番 writer）。`:381-388` `playById` は queue に触れない。`:435-465` `handlePlaybackEnded`: `queue.advance()` → `play()`、失敗しても `currentIndex` は進んだまま・`currentPodcast` は前のまま。`:462` `try? markCompleted`。`:516-540` playNow/addToQueue/playNext（`currentPodcast == nil` で判定）。`:548-550` `moveUpNext` → `queue.reorderUpNext`。`:576` `setSpeed`（`AppState.defaultPlaybackSpeed` と未接続）。`:840-853` `syncPlaybackPositionIfNeeded`（戻り値 `_ =` 破棄、catch コメントのみ）。`:399-409` stale ガード純関数。`:416-420` `.failed` → errorMessage + isPlaying=false のみ。
- `Podcast/PlaybackQueue.swift`（143 行）: `start:47-50`, `setQueue:53-56`（本番未使用）, `add:59-62`, `playNext:65-75`, `jump:79-83`, `advance:86-97`, `remove:100-113`, `reorderUpNext:118-128`, `applyMove:131-141`（範囲外 no-op `:133`）。`init:21-28` は範囲外 index を clamp。
- `AppState.swift:137-142` `apiClient` computed（毎アクセス新規生成・token スナップショット）。`:196-222` `refreshAuth`（catch で全例外 → token 破棄・未認証）。`:282-302` `logout`（音声キャッシュ・NowPlaying は消さない）。`:312-314` onboarding 失敗 → `onboardingCompleted = true`。`:40-47` UserDefaults Keys 5 件。`:63-64` `defaultPlaybackSpeed`。
- `Networking/APIClient.swift:19-39` `APIError`（httpError(statusCode) / rateLimited(retryAfter) / invalidURL / decodingError）、`:534-546` `validateResponse`（429 のみ意味化）、`:159-164` `downloadAudio`（buildRequest 非経由）、`:275,277,303,305` force unwrap、`:12-17,57,71` URLSession seam。
- `Networking/SessionStore.swift:19` `InMemorySessionStore`（production ターゲット、DEBUG ガードなし）、`:27-82` Keychain 実装（テスト 0）。
- status 数値分岐 10 箇所（verification-run.md §7）。パスワード最小長 8 の 2 実装: `Settings/AccountSettingsView.swift:317`（View）、`Admin/AdminUsersViewModel.swift:47`。
- `Settings/AccountSettingsView.swift:305-333` View 内で API 直呼び・`appState.currentUser = updated`（:308）。`Podcast/QuizSheetView.swift:180-204` 採点ロジックが View。
- `Networking/AudioCacheManager.swift` 公開 API: `cachedURL:45`, `isCached:52`, `cache:62`, `remove:71`, `cacheSize:80`, `clearCache:90`。`removeAllDownloads` は存在しない。2 箇所で独立インスタンス化（`PodcastViewModel.swift:122`, `SettingsViewModel.swift:69,76`）。
- テスト: V1 = 509/509 green。conformance Q 32/32・RT 17/17 存在。seam は URLSession 層（rule 11 :70-75 に良好）。`MockURLSession`（`APIClientTests.swift:637`）は常に成功 HTTPURLResponse。
- CI: `ci.yml` = test（`-only-testing:NewsListenAppTests`）+ gitleaks のみ。

## 6. 出力契約
- Skill の canonical schema（YAML）で書く。`subject_verdict`（対象の良否）と package 自体の `decision`（成果物 readiness）を分ける。
- 空欄埋め禁止: `not_applicable` には scope と Evidence に基づく理由、`unknown` には確認方法と未解決時の影響、`assumption` には反証条件。未作成の後続 ID（他 package の CI*/G* 等）を捏造しない。
- Evidence 状態 `confirmed | inferred | assumption | unknown | contradiction` を各項目に付ける。
- 手段（リファクタ案）は選択しない。複数の手段があれば Selection Gate（SG*）として候補・選択条件・owner: user を書く。
- iOS の挙動が web の確定決定（後述 §7）と異なる場合は finding ではなく **Selection Gate（クロスプラットフォーム決定）** として返す。

## 7. web で確定した決定（P7 で iOS 整合を確認する。ここでは前提として参照のみ）
- 「現在再生中」の正本 = Queue の `currentIndex`（共有仕様 §2.1 不変条件 4）。VM 側の `currentPodcast` 相当は派生値。
- 再生速度は 2 概念: 既定速度（設定・永続）とセッション速度（非永続、再生開始時に既定から初期化）。
- 自動次再生の取得失敗は**停止**（失敗エピソードを current に保持し error 状態、手動 play で再試行）。
- 失効時は SW/キャッシュ相当の主体データを消す（web: shell-*/api-*）。

## 8. 運用規律（turn 上限 20 対策・必須）
1. 読みは **最初の 1〜2 回の Bash に束ねる**（`for f in ...; do echo "=== $f"; sed -n 'a,bp' "$f"; done`）。ファイルを 1 つずつ Read しない。
2. **10 ターン以内に成果物ファイルへ heredoc で書き始める**。読み切れなくても部分成果を先に書き、`unknown` として残す。書けなくなる前に出す。
3. `path:line` 規律: 行番号は **1 ファイル 1 `grep -Hn` か `sed -n`** で取る。複数ファイルを連結して読んだ出力の行番号や `cat -n` の累積行番号を引用しない。提出前に自分の package 内の全 `file:N` について `N ≤ wc -l` を **1 コマンドで検査**し、結果を package 末尾に記す。
4. 件数主張は per-file 内訳を出し、定義行・import 行・コメント行・DEBUG 内・テストコードの扱いを明示する。「同一ルールの重複」と言う前に各出現の意味が同じか確認する。
5. 成果物は指定の scratchpad パスへ書く。最終メッセージは **≤60 行**（verdict・上位 finding・obligation・unknown・パス）。
