# verification-run（ios / 2026-09-16 / T1 test-execution ＋ router 再計測）

対象: `ios/` HEAD `c8c1ada`（作業ツリー dirty: `DesignSystem/DSFeedback.swift`・`NewsListenAppTests/LearningEngagementModelTests.swift` 変更、`.takt/` 未追跡。レビューは HEAD 内容を対象とし、dirty 差分は不変のまま）。
環境: macOS、Xcode 26.6（17F113）。`xcode-select -p` は CommandLineTools のため `DEVELOPER_DIR` 必須。シミュレータ iPhone 17 `14BBBBE4-70F0-47BF-9BFF-517D7F6B1AF7`。

## 1. ユニットテスト（V1）

```
cd ios && rm -rf build/TestResults.xcresult && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp \
  -destination 'platform=iOS Simulator,id=14BBBBE4-70F0-47BF-9BFF-517D7F6B1AF7' \
  -only-testing:NewsListenAppTests -resultBundlePath build/TestResults.xcresult
```
結果: exit 0、**Executed 509 tests, with 0 failures (0 unexpected)**、21.6 s。`make test`（`scripts/test.sh` の `name=` 指定）はこの環境では不可（memory `ios-test-environment-quirks`）。

## 2. lint（V2）
`which swiftlint swiftformat` → 両方 not found。`.swiftlint.yml` / `.swiftformat` なし（リポジトリにも CI にも lint 無し）。→ **未導入**（not_applicable ではなく unexecuted: 導入判断は user）。

## 3. 規模（V6a）
- production `NewsListenApp/NewsListenApp/**/*.swift`: 83 ファイル / 11,115 行。test `NewsListenAppTests/`: 36 ファイル / 7,879 行、`func test` 509、`XCTestCase` サブクラス 38、`@testable import` 35。
- 上位 15 行数: PodcastViewModel 854 / AudioPlayerView 606 / SettingsView 557 / APIClient 547 / FeedViewModel 372 / AppState 366 / AccountSettingsView 333 / LearningView 313 / VocabularyTestView 292 / SettingsViewModel 286 / QuizSheetView 277 / FeedView 246 / VocabularyModels 245 / NewsListenAppApp 232 / Podcast.swift 214。

## 4. `@Published` 宣言行 per-file（V6b。`^\s*@Published` の行数＝宣言のみ。コメント内言及を除く）
PodcastViewModel 15（T1 報告の 19 はコメント 4 行を含む誤計上）/ AppState 13 / FeedViewModel 9 / SettingsViewModel 8 / LearningViewModel 6 / AdminUsersViewModel 6 / OnboardingSourcesViewModel 5 / StarredViewModel 4 / SessionsViewModel 4 / LoginViewModel 4 / PasskeyCredentialsViewModel 3 / PasskeyRegistrationViewModel 2 / PasskeyLoginViewModel 2 / NetworkMonitoring 1 / VocabularyTestViewModel 1。計 83。

## 5. 失敗の黙殺（V6c）
- `try?` 22 件 / 13 ファイル: AppState 4（188,292,294,323）/ PreviewSupport 3（DEBUG）/ PodcastViewModel 2（462,777）/ AudioPlayerView 2（408,546）/ AudioCacheManager 2（81,91）/ LearningViewModel 2（44,47）/ PasskeyOptionsDecoder 116 / CrashReporter 90 / FileManagerProtocol 37 / Podcast.swift 205 / VocabularyTestViewModel 51 / VocabularyTestView 264 / FeedViewModel 175。うち `Task.sleep` 4、ネットワーク失敗の黙殺 8。
- 本文がコメントのみの `catch`: **1 件** `PodcastViewModel.swift:849-851`（`updatePlaybackPosition` 失敗）。**erratum**: T1 報告の「空 catch 4 件（AppState:241 / LearningViewModel:38 / PodcastViewModel:621 / :849）」は router 再読で :241 `preferencesSyncFailed = true`、:38 `loadFailed = true`、:621 `errorMessage = ...` と状態へ反映しており黙殺ではない。正は 1 件。
- 空 `catch {}` 0。`AppState.swift:312-314` は onboarding 取得失敗 → `onboardingCompleted = true`（fail-open、`:305-306` に WHY）。

## 6. force unwrap / try! / fatalError（V6d、production）
リリース経路: `Networking/APIClient.swift:275,277,303,305`（`URLComponents(...)!` / `components.url!`）4 件のみ。`#if DEBUG` 内: PreviewSupport 5（うち try! 1）/ LearningView 2 / VocabularyTestView 2 / QuizSheetView 1（try!）。fatalError 0。

## 7. seam・依存（V6e）
- `URLSession` 出現: APIClient 8、PreviewSupport 2（DEBUG）、FeedViewModel 1（`URLError(.cancelled)` の catch）。APIClient 以外に URLSession を直接叩く箇所なし。
- `AVPlayer|AVFoundation` をコード行で参照: **PodcastViewModel（9 行）と NowPlayingInfo（1 行）の 2 ファイル**。**erratum**: T1 報告の「4 ファイル（Podcast.swift / PlaybackQueue.swift を含む）」は doc コメント中の言及のみで型参照ではない。
- `UserDefaults`: AppState 22 / SessionStore 2（コメント）/ LearningEngagement 2 / SettingsViewModel 1。`SecItem`: SessionStore 5 のみ。
- ログ API（print/NSLog/os_log/Logger/debugPrint）: production 0。
- HTTP status 数値での分岐（`statusCode == N` / `httpError(N)` / `code == N`）: **10 箇所 / 10 ファイル**（定義行 `APIClient.swift:26,539` を除く）: `AppState.swift:263`(404) / `SettingsViewModel.swift:163`(404) / `AccountSettingsView.swift:327`(400) / `PasskeyCredentialsViewModel.swift:52`(404) / `LoginViewModel.swift:59`(401) / `PasskeyRegistrationViewModel.swift:70`(409) / `StarredViewModel.swift:108`(404) / `SessionsViewModel.swift:57`(404) / `QuizSheetView.swift:199`(404, View) / `OnboardingSourcesViewModel.swift:66`(409)。

## 8. テスト double・conformance（V6f）
- double 定義 12 / 7 ファイル（詳細 p1-test-ci-sec.md §3）。`MockFileManager` が 2 ファイルで重複定義。URLProtocol スタブ 0。APIClient を protocol mock で置換する箇所 0（seam は URLSession 層）。
- conformance: `PlaybackQueueConformanceTests.swift` testQ01〜Q32 = 32/32、`RelativeTimeConformanceTests.swift` RT01〜15 + RTA01/02 = 17/17。欠落 0。V1 で全 green。
- テスト参照 0 の production 型: AdminUsersViewModel / SessionsViewModel / LearningViewModel / VocabularyTestViewModel / PasskeyCredentialsViewModel / PlayerPresentation / PlaybackConstants / KeychainSessionStore。
- Xcode テンプレート空テスト: `NewsListenAppTests.swift:20,30`、UITests 3 件（`-only-testing:NewsListenAppTests` のため未実行）。

## 9. CI（V6g）
`.github/workflows/ci.yml`（64 行）: `ios-test`（macos-15）= Secrets.example 複製 `:30` → `xcodebuild test`（`name=` 動的選択、`-only-testing:NewsListenAppTests`）`:32-51`。`secret-scan` = gitleaks `:61-64`。lint・独立 build・UI テスト・カバレッジ計測なし。`make test`（`scripts/test.sh`）とは別経路（正規表現・resultBundlePath・xcbeautify が異なる）。

## 10. 未実行
- UV1: UI テスト（XCUITest 3 件はテンプレートのみ・アサーション 0）。
- UV2: lint（未導入）。
- UV3: 実機/シミュレータ目視（logout 後のロック画面 NowPlaying 残留、auto-advance 失敗時の UI）。
- UV4: conformance 各行の期待値と正本 §4 の突合（テスト名の存在と green は確認、期待値の一致は Contract package が読解）。
