## iOS リファクタ I-T12: 仕上げ（`AppState` を Account だけにする・Push と Observability の入口・adapter の生成を合成 root だけにする・許可リストを空にする）

## 概要
目標アーキテクチャの最後の slice。`AppState` に残った他 context の状態（通知の端末トークンと通知で選ばれたエピソード、adapter の既定の生成、`APIClient` の生成）を外し、Push の application `PushRegistration` を置く。起動時の連鎖（認証の解決 → 設定の同期の完了 → 通知の登録）は、`AppState` の中ではなく合成 root が遷移を見て順に呼ぶ形にする（順序と主体ガードは不変）。`CrashReporter` が自分で作っていた `APIClient` を合成 root から受ける。接続状態の port の宣言を `Shared/Application/Connectivity.swift` へ、失敗の文言を `Shared/Presentation/FailureMessages.swift` へ移す。ViewModel の既定引数が作っていた adapter を消す（TP11）。最後に依存の検査の許可リスト（TP10）を空にし、空であることを検査する。**挙動は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §3.2（`AppState.swift`・`Networking/FailureMessages.swift`・`NetworkMonitoring.swift`・`Push/`・`Observability/` の行）・§5.3（TA-C-AC-3 と注記）・§5.8（TA-M-PU・TA-C-PU-1・2・TA-Q-PU-1・TA-R-PU-1）・§5.9（TA-C-OB-1）・§5.10・§6 の 3・§4 TA-D3・D5・D13・§7 の許可リストの段落・§8.2 の I-T12 行・§8.4 TP10・TP11。**検証モード（再設計しない）**。

応える要求: `NFR-09`・`NFR-10` の全体（TA Spec §9.2）、AQ-1〜AQ-7 の検査が許可リストなしで green。

## 前提・着手条件
- 依存: **I-T4・I-T5・I-T6・I-T7a・I-T7b・I-T7c・I-T8・I-T9・I-T10・I-T11 の ios PR がすべて main に merge 済み、かつ親リポのポインタが進んでいる**（TA Spec §8.1）。I-S4・I-S5 はその前提として済んでいる。
- コマンドの実行場所: `ios/`。最初に、許可リストに残る行を数える: `grep -c '("TA-' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift`。**残る行が下の「本 slice で消す集合」以外の path を含むなら、投入しない**（前の slice の消し忘れ。その slice へ戻す）。
- 確定済み（再提案しない）: SG-C12（logout での通知の解除はサーバーの連鎖に任せる。I-S5 で client の呼出は消えている）、SG-C27・C29（合成 root の生成）、起動時の順序と主体ガード（`AppState.swift:311-319`）。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。前の slice の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| `AppState` の Push | `:144` `@Published var selectedPodcastId`・`:170` `deviceTokenRegistrationTask`・`:260-272` `didRegisterDeviceToken`・`:279-286` `registerDeviceTokenIfPossible`・`:288-290` `handleNotificationPodcastId`。logout での cancel `:410` | `grep -n 'selectedPodcastId\|deviceToken\|handleNotificationPodcastId\|apnsDeviceToken' NewsListenApp/NewsListenApp/AppState.swift` |
| `AppState` の adapter の生成 | `:203` `APIClient(`・`:532` `KeychainSessionStore()`・`:535` `PreferenceRegistry()`・`:536` `MediaPlayerNowPlaying()`・`:537` `AudioCacheManager()`（I-S5 の後は形が変わる） | `grep -nE '(APIClient\|KeychainSessionStore\|AudioCacheManager\|MediaPlayerNowPlaying\|PreferenceRegistry)\(' NewsListenApp/NewsListenApp/AppState.swift` |
| `refreshAuth` の連鎖 | `:298-330`（解決 → `:311-316` 設定の同期 → `:319` 通知の登録の予約。`:318` 主体ガード）。I-T6 の後は設定の同期の呼出先が `PreferencesStore` | `sed -n 298,330p NewsListenApp/NewsListenApp/AppState.swift` |
| `AppDelegate` | `Push/AppDelegate.swift`（106 行）が `AppState` を直接呼ぶ `:54,86,98,102`。`UIApplication` 6 行 | `grep -n 'appState\|UIApplication' NewsListenApp/NewsListenApp/Push/AppDelegate.swift` |
| `CrashReporter` | `Observability/CrashReporter.swift:96-106` が `APIClient` を自分で作る（Bundle の注入値の読み方を `AppState` と複製） | `grep -n 'APIClient\|Bundle' NewsListenApp/NewsListenApp/Observability/CrashReporter.swift` |
| 失敗の文言の利用者 | `FailureMessages` を参照するファイル 6 本 | `grep -rln 'FailureMessages' NewsListenApp/NewsListenApp --include='*.swift'` |
| 接続状態の port | `Networking/NetworkMonitoring.swift:19` `protocol NetworkMonitoring` | `grep -n protocol NewsListenApp/NewsListenApp/Networking/NetworkMonitoring.swift` |
| TP11 の残り | `Feed/FeedViewModel.swift:78`・`Starred/StarredViewModel.swift:46` の `NetworkMonitor()`、`Podcast/PodcastViewModel.swift` の既定引数（I-S3b2 の後に残っていれば） | `grep -rnE '= (NetworkMonitor\|AudioCacheManager\|MediaPlayerNowPlaying\|AVPlayerEngine\|KeychainSessionStore\|PreferenceRegistry)\(' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v NewsListenAppApp.swift` |
| O-8・G08 の期待値 | `GrepOracleTests` の O-8（`appState.didRegisterDeviceToken(` 2・`appState.handleNotificationPodcastId(` 2・`appState.selectedPodcastId = ` 1・`appState.refreshAuth(` 1 など）と G08（`MediaPlayerNowPlaying(` の生成箇所） | `sed -n 115,147p NewsListenApp/NewsListenAppTests/GrepOracleTests.swift`、`sed -n 332,345p …` |

## 対象（ios サブモジュールのみ）
**新規（production。TA Spec §8.2）**: `Push/Application/PushRegistration.swift`（gateway の束 `PushGateway` を含む = `portFiles`）、`Networking/Gateways/PushGateway+Live.swift`、`Shared/Application/Connectivity.swift`（`NetworkMonitoring` の宣言を移す = `portFiles`）、`Shared/Presentation/FailureMessages.swift`（`Networking/FailureMessages.swift` を移動）。
**変更（production）**: `AppState.swift`（Push・adapter の既定の生成・`APIClient` の生成・起動時の連鎖を外す。`resolve()`（旧 `refreshAuth`）は解決と遷移だけ）、`Push/AppDelegate.swift`（`PushRegistration` を呼ぶ）、`Observability/CrashReporter.swift`（送信の closure を受ける）、`NewsListenAppApp.swift`（adapter の生成を全部ここに。遷移を見て `PreferencesStore.refreshFromServer()` → `PushRegistration.registerIfPossible()` を順に呼ぶ。`ContentView` の `selectedPodcastId = nil` を `consumePendingEpisode()` に）、既定引数で adapter を作る ViewModel（`FeedViewModel`・`StarredViewModel` ほか、前提点検で残っていた全部）、`Networking/NetworkMonitoring.swift`（protocol を外し `NetworkMonitor` だけ）。
**変更（test）**: `ArchitectureManifest.swift`（**許可リストを空にする**。`portFiles`・`readModelFiles` の path を最終形に）、`ArchitectureOracleTests.swift`（許可リストが空であることを検査に足す）、`GrepOracleTests.swift`（O-8・G08 の期待値を改める。完了条件 5）、`AppStateAuthTests`（起動時の連鎖のテストは合成の関数を対象に書き直す。Then 不変）、`CrashReporterTests`・`PushSupportTests`（Given の置き換え）。**新規（test）**: `PushRegistrationTests.swift`・起動時の連鎖のテスト（`AppLaunchSequenceTests.swift`）。

**対象外**: 挙動（通知の登録の条件・logout との競合の cancel・通知のタップで再生する経路・クラッシュ報告の整形）、`APIClient` の公開メソッドと HTTP の形、`DesignSystem/`。

## 宣言（名前は TA Spec §5.3・§5.8・§5.9 のとおり）
```swift
// Push/Application/PushRegistration.swift
struct PushGateway { let register: (String) async throws -> Void }
@MainActor final class PushRegistration: ObservableObject {
    @Published private(set) var pendingEpisodeId: String?                 // TA-Q-PU-1（旧 AppState.selectedPodcastId）
    init(gateway: @escaping () -> PushGateway?, isAuthenticated: @escaping () -> Bool, subjectStamp: @escaping () -> SubjectStamp, isCurrentSubject: @escaping (SubjectStamp) -> Bool)
    func didReceiveDeviceToken(_ token: String)                           // TA-C-PU-1（登録の予約。前の予約を cancel）
    func registerIfPossible() async                                       // TA-C-PU-1（認証済みの間だけ。best-effort。TA-R-PU-1）
    func cancelPendingRegistration()                                      // logout が呼ぶ（旧 AppState.swift:410 の cancel）
    func openEpisode(id: String); func consumePendingEpisode()           // TA-C-PU-2
}
// Observability/CrashReporter.swift
init(send: @escaping (ClientErrorPayload) async throws -> Void)           // TA-C-OB-1（送信は合成 root が APIClient から組む）
```
- `AppState.logout()` は `PushRegistration.cancelPendingRegistration()` を登録の closure 経由で呼ぶ（順序は現行どおり: cancel → 破棄 → 遷移 → 後始末）。
- 起動時の連鎖（§6 の 3）: 合成 root は `AppState.session` の遷移を購読し、`authenticated` に入ったときに `await preferencesStore.refreshFromServer()` → `stamp` の照合（現行 `:318` と同じ主体ガード）→ `pushRegistration.registerIfPossible()` を順に呼ぶ。順序と「設定の同期の完了を待ってから登録」は変えない。この手順は合成 root の `NewsListenAppApp.swift` の中の 1 つの関数 `static func runLaunchSequence(preferences:push:isCurrentSubject:subjectStamp:) async`（`extension NewsListenAppApp`。依存は引数の closure で受け、テストから呼べる）に置き、`AppLaunchSequenceTests` で順序を固定する。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 認証の解決と遷移だけ | application: `AppState.swift` |
| 端末トークンの保持と登録・通知で選ばれたエピソード | application: `Push/Application/PushRegistration.swift` |
| 起動時の連鎖の配線・adapter の生成 | composition root: `NewsListenAppApp.swift` |
| OS の通知の入口 | presentation: `Push/AppDelegate.swift` |
| クラッシュ報告の整形と送信の実行 | adapter: `Observability/` |
| 失敗の文言 | presentation: `Shared/Presentation/FailureMessages.swift` |

## 移行の中間状態
- **TP10（許可リスト）を消す**: `ArchitectureManifest.allowlist` を空にし、`ArchitectureOracleTests` に「許可リストが空」の検査を足す。
- **TP11（既定引数の adapter の生成）を消す**。
- 本 slice で消す許可リストの集合（前の slice の後に残っているはずのもの。これ以外が残っていれば投入しない）: TA-D3 の `AppState.swift`（`APIClient`・`KeychainSessionStore`・`PreferenceRegistry`・`MediaPlayerNowPlaying`・`AudioCacheManager`（または I-S5 後の保存庫）・`UIFacility`）、TA-D5 の `NewsListenAppApp.swift` の `appState.selectedPodcastId = nil` 1 行、TA-D12 の `AppState.selectedPodcastId`、TA-D13 の合成 root 以外の生成（`AppState.swift`・ViewModel の既定引数・`Observability/CrashReporter.swift`）。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-C-PU-1・TA-R-PU-1 | **T-TA-C-PU-1**（`PushRegistrationTests`） | 未認証では登録しない。トークンの到着が 2 回なら前の予約を cancel。logout の cancel で登録が送られない。主体が変わった後の登録は送らない |
| TA-C-PU-2・TA-Q-PU-1 | **T-TA-C-PU-2** | `openEpisode` → `pendingEpisodeId`、`consumePendingEpisode` で nil |
| TA-C-AC-3・§6 の 3 | **T-TA-C-AC-3**（`AppLaunchSequenceTests`） | 呼出の順序が「解決 → 設定の同期の完了 → 通知の登録」。同期の途中で主体が変わったら登録しない。`AppState.resolve()` は gateway の書込を呼ばない |
| TA-C-OB-1 | `CrashReporterTests` | 送信の closure に整形済みの payload が渡る（Then 不変） |
| TA-V1〜V5（許可リストなし） | `ArchitectureOracleTests` | 許可リストが空で、全検査が green |

## 完了条件
1. 上のテストが green。既存テストが全件 green で件数が減らない（全体の `func test` が I-T11 完了時以上）。
2. 許可リストが空: `ArchitectureManifest.allowlist` が `[]`（`grep -c '("TA-' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` → 0）。`ArchitectureOracleTests` に `XCTAssertTrue(ArchitectureManifest.allowlist.isEmpty)` がある。TA-D12 の恒久の 6 個（`publishedDraftAllowlist`）は残る。
3. adapter の生成が合成 root と `#if DEBUG` だけ（TA-D13）: `ArchitectureOracleTests` の T-TA-V1e が許可リストなしで green。`grep -rnE '(APIClient|KeychainSessionStore|AudioCacheManager|MediaPlayerNowPlaying|AVPlayerEngine|NetworkMonitor|PreferenceRegistry|CrashReporter|ASAuthorizationPasskeyProvider)\(' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//' | grep -v NewsListenAppApp.swift` の各行が `#if DEBUG` の中（PR 説明に一覧）。
4. `AppState` が Account だけ: `grep -n "selectedPodcastId\|deviceToken\|handleNotificationPodcastId\|refreshPreferences\|refreshListeningStreak\|onboarding\|APIClient(" NewsListenApp/NewsListenApp/AppState.swift` が 0 件。`grep -c "@Published var" NewsListenApp/NewsListenApp/AppState.swift` → 0。
5. `GrepOracleTests` の期待値: O-8 から `appState.didRegisterDeviceToken(`・`appState.handleNotificationPodcastId(`・`appState.selectedPodcastId = ` を消し、`appState.refreshAuth(` を `appState.resolve(` に改める。G08 は `MediaPlayerNowPlaying(` の生成が `NewsListenAppApp.swift` 1 箇所だけ（TA Spec §8.2: 「G08 の期待値を 1 箇所（合成 root）に改める」）。件数（10）は不変。前後を PR 説明に。
6. 失敗の文言の置き場: `test ! -e NewsListenApp/NewsListenApp/Networking/FailureMessages.swift` かつ `Shared/Presentation/FailureMessages.swift` がある。`Networking/` に presentation の型が無い。
7. 接続状態の port: `grep -rn "protocol NetworkMonitoring" NewsListenApp/NewsListenApp --include='*.swift'` が `Shared/Application/Connectivity.swift` の 1 行。
8. `ci.yml` の `statusCode ==` / `httpError(` の grep の step（I-S4 は残す。I-S4 の補正 6）と T-TA-V9 が両方 green。
9. TA-V12 の AQ-1〜AQ-4 の問いの答えを PR 説明に書く（最終形として）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜9 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータまたは実機の目視: 起動 → ログイン済みで設定が同期され、通知の許可済みなら登録が送られる。通知のタップで該当のエピソードが再生される。logout → 再ログインで登録が 1 回。
- commit は「PushRegistration」「AppState から Push を外す・AppDelegate」「起動時の連鎖を合成 root へ」「CrashReporter の送信の注入」「FailureMessages・Connectivity の移動」「既定引数の削除」「許可リストを空にする・GrepOracle」の単位。

## 禁止事項 / scope 外
- 起動時の順序・主体ガード・通知の登録の条件・logout との競合の扱いを変えない。logout で client から通知を解除しない（SG-C12）。
- 許可リストを空にするために検査を緩めない（規則・量化する集合を変えない。TA-D14）。違反が残っていれば、その違反を直すか、前の slice へ戻す。
- `APIClient` の公開メソッドと HTTP の形を変えない。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 300 / 300。基点: `AppState.swift` 557・`AppDelegate.swift` 106・`CrashReporter.swift` 111）
- production ≈ 300 行（`PushRegistration` ≈ 80・合成 root ≈ 80・`AppState` の削減 ≈ −120・`CrashReporter` ≈ −15・移動 2 本・既定引数の削除 ≈ 20）。test ≈ 300 行。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TP10・TP11 の削除（TA Spec §8.4）。`design/ios-design.md` §4〜§8 を目標の構造の現状記述へ書き換え、§11 を削除する（本フォルダの README「完了後」）。README の I-T12 行を完了へ。
