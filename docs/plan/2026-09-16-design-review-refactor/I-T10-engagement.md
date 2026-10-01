## iOS リファクタ I-T10: 継続（ストリーク・ダッシュボード・実績の既読）の application。音と触覚を presentation へ

## 概要
ストリークの保持と更新、学習ダッシュボードの取得、実績の既読の記録を application の `EngagementStore` に置き、ダッシュボードのリードモデル `LearningDashboardView` と `StreakBadge` を作る。`AppState` からストリークを外し、`DSStreakToolbar` は `AppState` を持たずに `StreakBadge` を読む。1 つの操作が読むと書くを両方している 2 箇所（`LearningViewModel.load` の既読の記録、`AppState.refreshListeningStreak` の効果音）を、順序と結果を変えずに query と command に分ける。既読の保存は `PreferenceRegistry` 経由にし、`UserDefaults` の直接の利用を `Settings/PreferenceRegistry.swift` だけにする。**設定画面の聴取ストリークの文言、鳴る契機と種類は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.7（§5.7.1 の LE の application・リードモデル・データモデル、§5.7.2 の TA-Q-LE-1〜3・TA-C-LE-1 と注記、§5.7.3 の TA-R-LE-1・2、効果音の置き場の段落）・§6 の 1・2・§8.2 の I-T10 行。**検証モード（再設計しない）**。

応える要求: L-R02・L-R10・L-R21、ADR-086・ADR-088（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-T8・I-T6・I-T9 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（`ListeningStreakStatus`・`WeeklyProgress`・`AchievementCatalog`、`PreferencesStore`、`VocabularyBook`・`VocabularyTesting` と `Networking/Gateways/LearningGateway+Live.swift`）。TA Spec §8.1 の依存は「I-T8・I-T6」だが、`LearningViewModel.load()` が I-T9 の 2 つの query を呼び、gateway のファイルを共有するので、順 17（I-T9）→ 18（本 slice）に固定する（README の投入順）。
- コマンドの実行場所: `ios/`。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-T6・I-T8 の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| `AppState` のストリーク | `AppState.swift:137` `@Published var listeningStreak`・`:140` `listeningStreakLoadFailed`・`:368-391` `refreshListeningStreak`（前の日数を控え、増えたら `DSFeedback.shared.play(.streakUp)` `:380`。404 `.streak` で nil `:382`） | `grep -n 'listeningStreak\|refreshListeningStreak\|DSFeedback' NewsListenApp/NewsListenApp/AppState.swift` |
| `refreshListeningStreak(` の呼出 | O-8 の期待値で 5（`GrepOracleTests.swift`）。`Settings/SettingsView.swift:94,359` ほか | `grep -rn 'refreshListeningStreak(' NewsListenApp/NewsListenApp --include='*.swift'` |
| `DSStreakToolbar` | `DesignSystem/Components/DSStreakToolbar.swift:11` `@ObservedObject var appState: AppState`・`:17-19` 表示条件（I-T8 の後は `ListeningStreakStatus.isShown`）・Preview `:53-55` | `grep -n 'appState\|AppState' NewsListenApp/NewsListenApp/DesignSystem/Components/DSStreakToolbar.swift` |
| `LearningViewModel` | 55 行。`@Published private(set)` 6（`dashboard: LearningDashboard?`・`vocabulary: VocabularyListResponse?`・`dueVocabularyCount`・`newlyUnlocked`・`isLoading`・`loadFailed`）。`load()`（`:25-50`: 取得 → `achievementTracker.consumeNewlyUnlocked`（読む操作が既読を書く `:33`）→ `DSFeedback.shared.play(.achievement)` `:36` → `fetchVocabulary` `:44` → `fetchVocabularyTestSession` `:47`） | `grep -n 'func \|@Published\|DSFeedback\|tracker\|apiClient\.' NewsListenApp/NewsListenApp/Learning/LearningViewModel.swift` |
| 既読の保存 | `Models/LearningEngagement.swift:146-165` `AchievementCelebrationTracker`（`UserDefaults` 直接。key は `PreferenceRegistry.seenAchievementIdsKey`） | `grep -rn 'UserDefaults' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v PreferenceRegistry.swift \| grep -v ':[0-9]*:[[:space:]]*//'` |
| Preview の `APIClient(` | `Learning/LearningView.swift:301,308`（`#if DEBUG`） | `grep -n 'APIClient(' NewsListenApp/NewsListenApp/Learning/LearningView.swift` |
| 既存テスト | `AppStateListeningStreakTests` 6・`LearningEngagementModelTests` 7・`LearningEngagementAPIClientTests` 5。`LearningViewModel` の単体テストは無い（2026-10-01 実測） | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ）
**新規（production 2 本。TA Spec §8.2）**: `Learning/Application/EngagementStore.swift`（`StreakBadge` を含む）、`Learning/Application/LearningDashboardView.swift`（リードモデル = `readModelFiles`）。
**変更（production）**: `Learning/LearningViewModel.swift`（`EngagementStore`・`VocabularyBook`・`VocabularyTesting` を呼ぶ。`APIClient` を外す。音は View へ）、`Learning/LearningView.swift`（音を鳴らす・ストリークは `StreakBadge`。Preview は `#if DEBUG` の double）、`AppState.swift`（ストリークを外す）、`DesignSystem/Components/DSStreakToolbar.swift`（`EngagementStore` を読む）、`Settings/PreferenceRegistry.swift`（既読の読み書きの closure を出す）、`Models/LearningEngagement.swift`（`AchievementCelebrationTracker` を消す）、`Settings/SettingsView.swift`（聴取ストリークの節が `EngagementStore` を読む。文言不変）、`NewsListenAppApp.swift`（`EngagementStore` を作る。完聴後のストリーク更新 `onCompletionRecorded` の配線先を `engagement.refreshStreak` に）、`Networking/Gateways/LearningGateway+Live.swift`（I-T9 が作ったファイルに `fetchDashboard`・`fetchStreak` を足す）、`Learning/Application/VocabularyBook.swift`（I-T9 がここで宣言した `LearningGateway` に `fetchDashboard`・`fetchStreak` の closure を足す。宣言の行だけ）。
**変更（test）**: `AppStateListeningStreakTests`（6。`EngagementStoreTests` へ 1 対 1 で移し、照合表を PR 説明に）、`GrepOracleTests`（O-8 の `appState.refreshListeningStreak(` 5 を消す。完了条件 5）、`ArchitectureManifest.swift`。**新規（test）**: `EngagementStoreTests.swift`・`LearningViewModelTests.swift`（移す前の順序と音の契機の特性を先に固定する）。

**対象外**: 設定画面の聴取ストリークの文言、ダッシュボードの画面の構成、Freeze（L-R03。iOS に無い）、ウィジェット（L-R14・L-R15）。

## 宣言（名前は TA Spec §5.7 のとおり）
```swift
// Learning/Application/LearningDashboardView.swift（リードモデル。struct・let だけ）
struct LearningDashboardView: Equatable {
    let streak: StreakBadge; let weekly: WeeklyProgress; let weeklyHistory: [WeeklyProgress]
    let achievements: [UnlockedAchievement]          // 名前と解錠日
    let monthlyListeningDays: [MonthlyListening]
    let completedCount: Int; let masteredVocabularyCount: Int; let currentLevel: String?
    let quizTrend: [QuizTrendEntry]
}
struct UnlockedAchievement: Equatable { let item: AchievementCatalogItem; let unlockedAt: String }
struct MonthlyListening: Equatable { let month: String; let days: Int }
struct QuizTrendEntry: Equatable { let date: String; let rate: Double }
// Learning/Application/EngagementStore.swift
struct StreakBadge: Equatable { let isShown: Bool; let days: Int }       // TA-R-LE-1 を ListeningStreakStatus から写す
@MainActor final class EngagementStore: ObservableObject {
    @Published private(set) var streak: StreakBadge?
    @Published private(set) var streakLoadFailed: Bool
    init(gateway: LearningGateway, seenStore: (read: () -> Set<String>, write: (Set<String>) -> Void))
    func dashboard() async throws -> LearningDashboardView              // TA-Q-LE-1
    func unseenAchievements(in dashboard: LearningDashboardView) -> [Achievement]   // TA-Q-LE-2（保存を読むだけ）
    func markAchievementsSeen(_ ids: [String])                          // TA-C-LE-1
    @discardableResult func refreshStreak() async -> Bool               // TA-Q-LE-3。「前回より増えたか」を返す（TA-R-LE-2。初回は false）
}
```
- 入れ子の 3 型（`UnlockedAchievement`・`MonthlyListening`・`QuizTrendEntry`）は同じファイルの `struct`・`let` だけ（`Equatable` を満たすため。TA Spec に無い内部の名前で、公開面にも利用者に見える挙動にも出ない）。field の意味と数は TA Spec §5.7.1 のとおり。`month`・`date`・`days`・`rate` の型は通信のデータモデル（`MonthlyActivity`・`QuizTrendPoint`）の現行の型に合わせる。
- `LearningViewModel.load()` の順序は現行と同じ: `dashboard()` → `unseenAchievements(in:)` → `markAchievementsSeen` → （新しく解錠があれば）View が `.achievement` を鳴らす → `VocabularyBook.book()` → `VocabularyTesting.due()`（§6 の 1。I-T9 の use case）。
- ストリークの効果音（`.streakUp`）は、`refreshStreak()` が true を返したときに呼んだ側の View が鳴らす（§6 の 2。契機は現行と同じ「増えたときだけ」）。404 `.streak` は `streak = nil`・失敗にしない（現行 `AppState.swift:382` と同じ）。
- 既読の保存は `PreferenceRegistry` の `seen_achievement_ids`（主体依存。key 名不変）。主体の離脱で消す扱いは I-S2 の `subjectScoped` のまま（CI-T17）。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| ストリークの保持と更新・ダッシュボードの取得と写像・既読の記録 | application: `Learning/Application/EngagementStore.swift` |
| ダッシュボードの形 | application（リードモデル）: `Learning/Application/LearningDashboardView.swift` |
| 既読の保存 | adapter: `Settings/PreferenceRegistry.swift` |
| 効果音・触覚・表示の文言 | presentation: `LearningView`・`SettingsView`・`DSStreakToolbar`・ストリークを更新する画面 |

## 移行の中間状態
- 許可リスト（TP10）の増減: TA-D3 の `AppState.swift` の `ListeningStreak`（`DTO`）・`DSFeedback`（`UIFacility`）、TA-D12 の `AppState.listeningStreak`・`listeningStreakLoadFailed`、TA-D6 の `LearningViewModel` の `APIClient`・`DSFeedback`・`DTO`、TA-D4 の `LearningView`・`DSStreakToolbar` の `DTO`、TA-V3 の `AppState.swift:382` は対象外のまま（TA Spec §7）。
- `UserDefaults` の直接の利用が `Settings/PreferenceRegistry.swift` だけになる。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-Q-LE-1・TA-V8 | **T-TA-Q-LE-1** | `MockURLSession` の応答から `LearningDashboardView` を作る。書込 0 件（`GET /users/me/learning-dashboard` は §5 の明示の例外で、クライアントからは読み取り） |
| TA-Q-LE-2・TA-C-LE-1 | **T-TA-Q-LE-2**・**T-TA-C-LE-1** | `unseenAchievements` は保存を読むだけ（2 回呼んでも同じ結果）。`markAchievementsSeen` の後は出ない |
| TA-Q-LE-3・TA-R-LE-1・2 | **T-TA-Q-LE-3**（`AppStateListeningStreakTests` 6 を移す） | 初回 false・増えた true・同じ false・404 で nil・失敗で `streakLoadFailed` |
| §6 の 1 | **T-LearningViewModel-order** | `load()` の呼出順（ダッシュボード → 未表示 → 既読 → 語彙 → 出題）と、新しい解錠があるときだけ VM の `newlyUnlocked` が非空（音は View。VM のテストは値を見る） |
| TA-V6（LE） | **T-TA-V6-LE** | `dashboard()` の戻り値を書き換えても次の結果が変わらない |
| CI-T17（不変） | `PreferenceRegistryTests` | `subjectScopedKeys` が不変 |

## 完了条件
1. 上のテストが green。既存テストが全件 green で、`AppStateListeningStreakTests` の 6 件は `EngagementStoreTests` に 1 対 1 で移って件数が減らない。
2. `AppState` にストリークが無い: `grep -n "listeningStreak\|ListeningStreak\|DSFeedback" NewsListenApp/NewsListenApp/AppState.swift` が 0 件。
3. `UserDefaults` の直接の利用が 1 ファイル: `grep -rln 'UserDefaults' NewsListenApp/NewsListenApp --include='*.swift' | xargs grep -ln '^\s*[^/ ].*UserDefaults'` が `Settings/PreferenceRegistry.swift` だけ（`NewsListenAppApp.swift` に `UserDefaults` があれば合成 root として残り、PR 説明に書く）。`grep -rn "AchievementCelebrationTracker" NewsListenApp --include='*.swift'` が 0 件。
4. `LearningViewModel` が通信と OS を知らない: `grep -n "APIClient\|DSFeedback\|LearningDashboard\b\|VocabularyListResponse" NewsListenApp/NewsListenApp/Learning/LearningViewModel.swift | grep -v '^[0-9]*:[[:space:]]*//'` が 0 件。
5. `GrepOracleTests` の O-8 の期待値から `appState.refreshListeningStreak(` を消す（0 になる）。完聴後の更新が `onCompletionRecorded` から `EngagementStore.refreshStreak` に届くことを `PodcastViewModel` 系のテストか合成 root の配線の確認で示す。件数（10 件）は不変。
6. `DSStreakToolbar` が `AppState` を持たない: `grep -n "AppState" NewsListenApp/NewsListenApp/DesignSystem/Components/DSStreakToolbar.swift` が 0 件。
7. `LearningDashboardView.swift` が `struct`・`let` だけ（`readModelFiles` に登録し T-TA-V5b が green）。
8. 効果音の契機が同じ: `grep -rn 'play(.streakUp)\|play(.achievement)' NewsListenApp/NewsListenApp --include='*.swift'` が presentation のファイル（View）だけで、`AppState.swift`・`*ViewModel.swift` に無い。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜8 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータの目視: 完聴後にツールバーのストリークが増えて音が鳴る（初回は鳴らない）。学習タブで新しい実績の祝いが 1 回だけ出る。設定画面の聴取ストリークの文言。
- commit は「LearningViewModel の特性テスト」「EngagementStore と LearningDashboardView」「既読の保存を registry へ」「AppState から外す・DSStreakToolbar」「LearningViewModel と View」「GrepOracle と所属表」の単位。

## 禁止事項 / scope 外
- 鳴る契機と種類・文言を変えない。application で音を鳴らさない。
- 既読の key 名・主体依存の扱いを変えない。
- ダッシュボードの取得で書く経路を足さない（読み取りのまま）。
- 起動時の連鎖（解決 → 設定の同期 → 通知の登録）に手を入れない（I-T12）。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 200 / 200）
- production ≈ 200 行（`EngagementStore` ≈ 90・リードモデル ≈ 50・VM と `AppState` の削減 ≈ −80・View ≈ 40・registry ≈ 15）。test ≈ 200 行（特性 ≈ 50 を含む）。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: §6 の 1・2 が解けたこと。TA Spec §8.1 の I-T10 の依存に I-T9 を足すこと（本 order は I-T9 の後に固定した）。README の I-T10 行を完了へ。
