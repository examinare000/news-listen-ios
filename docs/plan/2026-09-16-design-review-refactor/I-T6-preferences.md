## iOS リファクタ I-T6: Preferences の値型と `PreferencesStore`（検査・同期・巻き戻し・主体ガード）

## 概要
設定の値域と既定値を domain の値型（`DifficultyLevel`・`WeeklyGoalTarget`・`TimeFormat`・`ArticleOpenMode`・一覧 `PreferenceCatalog`）に置き、設定の現在値の持ち主を application の `PreferencesStore` にする。サーバーとの同期・失敗時の巻き戻し・前の主体の遅延応答の破棄・主体依存の消去を `PreferencesStore` が持ち、設定画面の View が旧値を覚えて戻す処理（`SettingsView.swift:106-121,375-386,398-409`）と `@AppStorage` を無くす。`AppState` から設定の状態を外す。**`UserDefaults` の key 名・難易度の表示ラベルの文言（2 表。SG-D8 で現状維持と確定）・同期の順序は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.4（TA-M-PF・TA-C-PF-1〜3・TA-Q-PF-1・TA-R-PF-1〜6・port と adapter）・§6 の 4（`refreshPreferences` の分け方）・§7 TA-V3 の TA-R-PF-1〜3・TA-V6 の PF・§8.2 の I-T6 行・§10.3 の 1（難易度ラベル。**SG-D8 で (a) 現状維持に確定**）、再生 Spec の CI-T17、共有仕様 §6.5 の分類表。**検証モード（再設計しない）**。

応える要求: `F-SET-02`・`F-SET-04`、L-R04、AQ-3・AQ-6（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-S4 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（同じ `Settings/SettingsView.swift` を I-S4 が速度の Picker で触る）。I-S5 と並行可（対象のファイルが重ならない。`AppState.swift` は両方が触るので、後から merge する側が rebase する）。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Auth/Domain/PasswordPolicy.swift`（rc=0。I-S4 の成果）。
- 確定済み（再提案しない）: SG-D8（難易度の表示ラベルは 2 表と、待機列の行のコード表示のまま。文言を揃えない）、SG-X5（速度 8 段。I-S4 で Picker に反映済み）、CI-T17（主体依存 4 key の分類）。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-S4・I-S5 の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| `AppState` の設定の状態 | `AppState.swift:88-121` に `@Published var` 5 つ（`defaultDifficulty`・`defaultPlaybackSpeed`・`weeklyGoalEpisodes`・`articleOpenMode`・`timeFormat`）と `lastConfirmedWeeklyGoalEpisodes`（`private(set)`）・`preferencesSyncFailed` | `sed -n 86,135p NewsListenApp/NewsListenApp/AppState.swift \| grep -n '@Published'` |
| `refreshPreferences`・主体依存の消去 | `AppState.swift:335-361`・`:446-470` | `grep -n 'func refreshPreferences\|func resetSubjectScopedPreferencesToDefaults' NewsListenApp/NewsListenApp/AppState.swift` |
| View の巻き戻し | `Settings/SettingsView.swift:108-121`（週の目標）・`:375-386`（難易度）・`:398-409`（速度）の `.onChange` と `= oldValue` 3 行（`:120,384,407`） | `grep -n 'onChange\|= oldValue' NewsListenApp/NewsListenApp/Settings/SettingsView.swift` |
| `$appState.<設定>` の Picker | 5 個（`:102` 週の目標・`:138` 記事の開き方・`:144` 時刻表記・`:370` 難易度・`:393` 速度） | `grep -n 'selection: \$appState' NewsListenApp/NewsListenApp/Settings/SettingsView.swift` |
| `SettingsViewModel` の同期 | `:217` `syncDefaultDifficulty`・`:237` `syncDefaultPlaybackSpeed`・`:257` `syncWeeklyGoal`（`[3, 5, 7, 10]` の検査 `:258`）・`:287` `syncPreference` | `grep -n 'func sync' NewsListenApp/NewsListenApp/Settings/SettingsViewModel.swift` |
| `@AppStorage` | 4 行（`Settings/SettingsView.swift:20-21`・`DesignSystem/DSFeedback.swift:31-32`） | `grep -rn '@AppStorage' NewsListenApp/NewsListenApp --include='*.swift'` |
| 値域の literal | 週の目標 `[3, 5, 7, 10]` 3 行（`SettingsView.swift:103`・`SettingsViewModel.swift:258`・`PreferenceRegistry.swift:119`）。時刻表記 `"absolute"`/`"relative"` 6 行（`SettingsView.swift:145,146`・`PreferenceRegistry.swift:142,145`・`Feed/ArticleRowView.swift:48`・`Feed/SwipeableArticleCard.swift:170`・`Podcast/PodcastRowView.swift:86`。`:145` は 1 行に 2 つ）。難易度のコード: `Utilities/DifficultyLabel.swift:14`（`allCodes`）と `:20-25`、`Settings/SettingsView.swift:40-47`、`Settings/PreferenceRegistry.swift:98,101` | `grep -rn '3, 5, 7, 10\|"absolute"\|"relative"' NewsListenApp/NewsListenApp --include='*.swift'`、`grep -rnE '"(toeic\|ielts\|eiken)_' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v ':[0-9]*:[[:space:]]*//'` |
| `PreferenceRegistry` の宣言 | 8 key（`:64-71`）。主体依存 4（`default_difficulty`・`default_playback_speed`・`weekly_goal_episodes`・`seen_achievement_ids`） | `grep -n 'Key = \|subjectScoped: true' NewsListenApp/NewsListenApp/Settings/PreferenceRegistry.swift` |
| `ArticleOpenMode` の宣言 | `AppState.swift:14-30` | `grep -rn 'enum ArticleOpenMode' NewsListenApp/NewsListenApp` |
| O-8 の期待値 | `GrepOracleTests.swift:126-128` に `appState.confirmWeeklyGoalSync(` 1・`appState.defaultDifficulty = ` 1・`appState.defaultPlaybackSpeed = ` 1（ほか `isCurrentSubject(` 3・`refreshPreferences(` 1） | `sed -n 119,147p NewsListenApp/NewsListenAppTests/GrepOracleTests.swift` |
| 既存テスト | `SettingsViewModelTests` 36・`PreferenceRegistryTests` 9・`AppStatePreferencesTests` 3・`AppStateDefaultsTests`・`DifficultyLabelTests`・`RelativeTime*Tests` | `grep -c 'func test' …` |

TA Spec §7 の TA-R-PF-1 の「14 行」は机上の値で、上の実測と数え方（1 行に複数）が違う。I-T1 が固定した許可リストの行数に従い、差は PR 説明に書く。

## 対象（ios サブモジュールのみ）
**新規（production 8 本。TA Spec §8.2 の I-T6 行のとおり）**: `Shared/Domain/DifficultyLevel.swift`、`Settings/Domain/{WeeklyGoalTarget,TimeFormat,ArticleOpenMode,PreferenceCatalog}.swift`、`Settings/Application/PreferencesStore.swift`（port の束 `PreferencesGateway`・`PreferenceStorage` の宣言を含む。`portFiles` に登録）、`Models/Preferences+Domain.swift`、`Networking/Gateways/PreferencesGateway+Live.swift`。
**変更（production 10 本）**: `Settings/PreferenceRegistry.swift`（値域と既定値の宣言を `PreferenceCatalog` から読む。key・codec・読み書きは残す）、`Settings/SettingsView.swift`（Picker を `Binding(get: store の値, set: command)` に。`.onChange` の巻き戻しと `@AppStorage` を消す）、`Settings/SettingsViewModel.swift`（`sync*` 3 つを消す）、`AppState.swift`（設定の状態 5 つ・`refreshPreferences`・主体依存の消去・`ArticleOpenMode` の宣言を外す。後始末の closure は `PreferencesStore.clearSubjectScoped` を呼ぶ）、`DesignSystem/DSFeedback.swift`（`@AppStorage` を `PreferencesStore` の値の読出に）、`Utilities/DifficultyLabel.swift`（`allCodes` を `DifficultyLevel.allCases` に。ラベルの文言は不変）、`Feed/ArticleRowView.swift`・`Feed/SwipeableArticleCard.swift`・`Podcast/PodcastRowView.swift`（`timeFormat == "relative"` を `TimeFormat` の比較に）、`NewsListenAppApp.swift`（`PreferencesStore` を作り環境に置く。起動時の連鎖の順序は変えない）。
**変更（test）**: `SettingsViewModelTests`・`AppStatePreferencesTests`・`AppStateDefaultsTests`・`PreferenceRegistryTests`（Given の置き換え。Then 不変）、`GrepOracleTests`（O-8〜O-13 の期待値を同じ PR で改める。下の完了条件 6）、`ArchitectureManifest.swift`。**新規（test）**: `PreferencesDomainTests.swift`（`domainTestFiles`）・`PreferencesStoreTests.swift`。

**対象外**: 難易度のラベルの文言（2 表のまま。SG-D8）、`UserDefaults` の key 名、`seen_achievement_ids` の読み書きの経路（I-T10）、ソースの管理と生成の残り回数の表示（I-T7a・I-T7b）、起動時の連鎖を合成 root へ移すこと（I-T12。本 slice では `AppState.refreshAuth` の中の呼出先を `PreferencesStore.refreshFromServer()` に替えるだけ）。

## 宣言（ここに無い公開メンバーを足さない）
```swift
// Shared/Domain/DifficultyLevel.swift
struct DifficultyLevel: Equatable, Hashable { let code: String; init?(code: String); static let toeic600, toeic900, ielts55, ielts7, eiken2, eikenP1: DifficultyLevel; static let allCases: [DifficultyLevel]; static let `default`: DifficultyLevel }  // 6 値（表示順は現行 DifficultyLabel.allCodes）・既定 toeic_600（TA-R-PF-1）。コードの literal はここだけ
// Settings/Domain/
struct WeeklyGoalTarget: Equatable { let episodes: Int; init?(episodes: Int); static let allCases: [WeeklyGoalTarget]; static let `default`: WeeklyGoalTarget }  // 3/5/7/10・既定 3
enum TimeFormat: String, CaseIterable { case absolute, relative }   // 既定 absolute
enum ArticleOpenMode: String, CaseIterable, Identifiable { … }      // AppState.swift:14-30 から移動。値・label は不変
enum PreferenceCatalog { … }   // 8 つの設定ごとに: 既定値・主体依存か・サーバー同期か（TA-R-PF-4）。key 名は持たない（adapter の PreferenceRegistry が持つ）
// Settings/Application/PreferencesStore.swift の中の port の宣言
struct PreferencesGateway { let fetch: () async throws -> PreferenceValues; let update: (PreferenceChange) async throws -> Void }
struct PreferenceValues: Equatable { let difficulty: DifficultyLevel?; let playbackSpeed: Float?; let weeklyGoal: WeeklyGoalTarget? }   // 値域の外は nil（変換で捨てる）
enum PreferenceChange: Equatable { case difficulty(DifficultyLevel), playbackSpeed(Float), weeklyGoal(WeeklyGoalTarget) }
struct PreferenceStorage { let read: …; let write: …; let clearSubjectScoped: () -> Void }   // 保存の closure の束（adapter = PreferenceRegistry から組む）
// Settings/Application/PreferencesStore.swift
@MainActor final class PreferencesStore: ObservableObject {
    @Published private(set) var defaultDifficulty: DifficultyLevel
    @Published private(set) var defaultPlaybackSpeed: Float
    @Published private(set) var weeklyGoal: WeeklyGoalTarget
    @Published private(set) var articleOpenMode: ArticleOpenMode
    @Published private(set) var timeFormat: TimeFormat
    @Published private(set) var soundEnabled: Bool
    @Published private(set) var hapticsEnabled: Bool
    @Published private(set) var syncFailed: Bool
    init(gateway: PreferencesGateway?, storage: PreferenceStorage, isCurrentSubject: @escaping (SubjectStamp) -> Bool, subjectStamp: @escaping () -> SubjectStamp, isAuthenticated: @escaping () -> Bool)
    func setDefaultDifficulty(_ v: DifficultyLevel) async throws     // TA-C-PF-1。失敗は ApiFailure（巻き戻し済み）
    func setDefaultPlaybackSpeed(_ v: Float) async throws            // TA-C-PF-1。PlaybackConstants.speeds の外は受けない（無視）
    func setWeeklyGoal(_ v: WeeklyGoalTarget) async throws           // TA-C-PF-1
    func setArticleOpenMode(_ v: ArticleOpenMode); func setTimeFormat(_ v: TimeFormat)
    func setSoundEnabled(_ v: Bool); func setHapticsEnabled(_ v: Bool)   // TA-C-PF-2
    func clearSubjectScoped()                                        // TA-C-PF-3
    func refreshFromServer() async                                   // TA-Q-PF-1。サーバーへ書かない。値域の内だけを反映
}
```
**規則**（現行の挙動をそのまま移す）
| 規則 | 内容 | 現行 |
|---|---|---|
| TA-R-PF-5 | `set*`（サーバー同期の 3 つ）: 値を先に反映して保存 → `stamp` を捕捉 → `gateway.update` → 失敗なら、`isCurrentSubject(stamp)` のときだけ旧値へ戻して `ApiFailure` を投げる。前の主体の遅延応答では書かない | `SettingsView.swift:108-121,375-386,398-409` と `SettingsViewModel.sync*`。週の目標の `lastConfirmedWeeklyGoalEpisodes` の扱い（`confirmWeeklyGoalSync`）も同じ形で `PreferencesStore` の内部に移す |
| TA-R-PF-4 | 主体依存 3 つ（難易度・速度・週の目標。4 つ目の `seen_achievement_ids` は I-T10）は認証済みの間だけ保存する。`clearSubjectScoped()` で既定へ戻して消す | `AppState.swift:446-470`・`persistSubjectScopedOrReset` |
| TA-R-PF-6 | メモリ上の値も値域の内（domain の値型でしか受けない） | `AppState.swift:88-100,469` |
| §6 の 4 | `refreshFromServer()` は取得して端末の保存へ書く。`gateway.update` を呼ばない。失敗で `syncFailed = true` | `AppState.refreshPreferences`（`:335-361`） |

- 起動時の順序（解決 → 設定の同期の完了 → 通知の登録）と主体ガード（`AppState.swift:311-319`）は変えない。本 slice では `AppState.refreshAuth` が呼ぶ先を `preferencesStore.refreshFromServer()` に替える（`AppState` は `PreferencesStore` を closure で受ける）。合成 root への移動は I-T12。
- 効果音・触覚の設定は `DSFeedback` が `PreferencesStore` の値を読む（`@AppStorage` を使わない）。key（`sfx_enabled`・`haptics_enabled`）は `PreferenceRegistry` のまま。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 値域・既定値・主体依存かの分類 | domain: `Shared/Domain/DifficultyLevel.swift`・`Settings/Domain/` |
| 現在値・同期・巻き戻し・主体ガード・消去 | application: `Settings/Application/PreferencesStore.swift` |
| 通信 → 値（値域の外を捨てる）・`UserDefaults` の key と codec | adapter: `Models/Preferences+Domain.swift`・`Networking/Gateways/PreferencesGateway+Live.swift`・`Settings/PreferenceRegistry.swift` |
| Picker の表示ラベル 2 表・`Binding(get:set:)`・失敗の表示 | presentation: `Settings/SettingsView.swift`・`Utilities/DifficultyLabel.swift` |

## 移行の中間状態
- `AppState.refreshAuth` が `PreferencesStore.refreshFromServer()` を closure で呼ぶ（合成 root へ移すのは I-T12。TA Spec §5.3）。
- 許可リスト（TP10）の増減: TA-D3 の `AppState.swift` の `UserDefaults`・`Preferences`（`DTO`）の行、TA-D4 の `@AppStorage` 4 行、TA-D5 の `Settings/` の `= oldValue` 3 行、TA-D12 の `AppState.swift` の設定 5 個、TA-V3 の TA-R-PF-1〜3 の全行を消す（0 にする）。
- TP11（`SettingsViewModel` の既定引数）は I-S3b3 で消えている。

## 変わる挙動
無い。同期の失敗時の巻き戻し・文言・主体ガード・key 名・ラベルの文言は同じ。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-R-PF-1〜3 | **T-TA-R-PF-1〜3**（`PreferencesDomainTests`） | `DifficultyLevel(code:)` は 6 値だけ・既定 `toeic_600`。`WeeklyGoalTarget` は 3/5/7/10 だけ・既定 3。`TimeFormat` の 2 値 |
| TA-R-PF-4 | **T-TA-R-PF-4** | 主体依存の分類が `PreferenceRegistry` の `subjectScopedKeys`（I-S2 の 4 key）と一致する |
| TA-C-PF-1・TA-R-PF-5 | **T-TA-C-PF-1** | `MockURLSession` つき `APIClient` から組んだ gateway で、成功 → 値と保存が新しい値。失敗 → 旧値へ戻り `ApiFailure` を投げる。`update` の応答の前に主体が変わる → 書かない |
| TA-C-PF-2・3 | **T-TA-C-PF-2**・**T-TA-C-PF-3** | 端末の設定 4 つの保存。`clearSubjectScoped` の後、主体依存 3 つが既定で保存から消える（CI-T17 不変） |
| TA-Q-PF-1・TA-V8 | **T-TA-Q-PF-1** | `refreshFromServer()` の後、gateway の書込（`PUT`/`PATCH`/`POST`）が 0 件。値域の外の値は反映しない。失敗で `syncFailed` |
| TA-V6（PF） | **T-TA-V6-PF** | 値域の外の値を渡す入口が無い（`DifficultyLevel(code: "x")` が nil）。公開する状態へ外から代入できない（TA-V5 の静的検査） |
| CI-T17（不変） | `PreferenceRegistryTests`（9）・`AppStatePreferencesTests` | Then 不変 |
| O-8〜O-13 | `GrepOracleTests` | 期待値を改める（完了条件 6） |

## 完了条件
1. 上のテストが green。既存テストが全件 green で、`SettingsViewModelTests`（同期 3 つの分は `PreferencesStoreTests` へ 1 対 1 で移し、照合表を PR 説明に）・`PreferenceRegistryTests` 9 の件数が減らない。
2. 変更した production が上の 18 本（新規 8 ＋ 変更 10）だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 18 行。
3. 巻き戻しが View に無い: `grep -rn "= oldValue\|\.onChange(of: appState\." NewsListenApp/NewsListenApp/Settings --include='*.swift'` が 0 件（正の対照: 2026-10-01 実測 `= oldValue` 3 行・`.onChange(of: appState.` 3 行）。`grep -rn 'selection: \$appState' NewsListenApp/NewsListenApp --include='*.swift'` が 0 件。
4. `@AppStorage` が 0: `grep -rn '@AppStorage' NewsListenApp/NewsListenApp --include='*.swift'` が 0 件。
5. 値域の literal が domain の 1 箇所: `grep -rn '3, 5, 7, 10' NewsListenApp/NewsListenApp --include='*.swift'` が `Settings/Domain/WeeklyGoalTarget.swift` の 1 行。`grep -rn '"absolute"\|"relative"' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件（`TimeFormat` は `rawValue` で、`PreferenceRegistry` の codec も `TimeFormat(rawValue:)` を使う。正の対照: 2026-10-01 実測 6 行）。難易度のコードの literal（`grep -rnE '"(toeic|ielts|eiken)_' …`）は `Shared/Domain/DifficultyLevel.swift`（6 値）と、`#if DEBUG` の中の Preview の fixture だけ。ラベル表 2 つ（`Utilities/DifficultyLabel.swift`・`Settings/SettingsView.swift`）は `DifficultyLevel` の定数を key にして文言だけを持つ（文言は不変。SG-D8）。T-TA-V3 の TA-R-PF-1〜3 の許可リストが 0 行。
6. `GrepOracleTests` の O-8 の期待値: `appState.defaultDifficulty = `・`appState.defaultPlaybackSpeed = `・`appState.confirmWeeklyGoalSync(`・`appState.refreshPreferences(` を消し、`appState.isCurrentSubject(` を 3 から 0 に改める（3 行は `SettingsView.swift:120,384,407` の巻き戻しで、`PreferencesStore` の内部の closure 呼出に替わる。どれも 0 になる）。O-9（revert 3 行）〜O-13 は対象が `PreferencesStore` の内部へ移るので、同じ oracle（revert 3 行が `isCurrentSubject(stamp)` を同じ行に持つ・stamp の捕捉が最初の await より前）を `Settings/Application/PreferencesStore.swift` に向けて書き直す。件数（10）は変えない。改めた期待値を PR 説明に前後で載せる。
7. `AppState` に設定の状態が無い: `grep -n "defaultDifficulty\|defaultPlaybackSpeed\|weeklyGoalEpisodes\|articleOpenMode\|timeFormat\|enum ArticleOpenMode" NewsListenApp/NewsListenApp/AppState.swift` が 0 件。
8. `PreferencesStore` の公開面: `grep -c "@Published private(set) var" NewsListenApp/NewsListenApp/Settings/Application/PreferencesStore.swift` → 8、`grep -c "@Published var" 同ファイル` → 0。`grep -rn "UserDefaults\|APIClient\|import SwiftUI" NewsListenApp/NewsListenApp/Settings/Application NewsListenApp/NewsListenApp/Settings/Domain NewsListenApp/NewsListenApp/Shared/Domain` が 0 件。
9. `ArchitectureOracleTests` が green で、許可リストから TA-D4 の `@AppStorage`・TA-D5 の `Settings/`・TA-D12 の `AppState.swift` の設定 5 個・TA-V3 の TA-R-PF-1〜3 が消えている（PR 説明に前後の行数）。
10. ラベルの文言が不変: `DifficultyLabelTests` が Then 不変で green。`Settings/SettingsView.swift` の Picker の 6 つのラベル文字列が 2026-10-01 の `:40-47` と同じ（`git diff` で文字列の行が変わっていないことを PR 説明に示す）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜10 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータの目視（PR 説明に記す）: 設定画面で 3 つの同期設定を変える → 再起動後も残る。通信を切って変える → 元の値に戻り、失敗の表示が出る。効果音・触覚のトグルが効く。
- commit は「値型と PreferenceCatalog」「PreferencesStore（契約テスト）」「gateway と registry」「SettingsView の Binding 化」「AppState から外す」「DSFeedback・行 View 3 本」「GrepOracle と所属表」の単位。

## 禁止事項 / scope 外
- 難易度のラベルの文言を変えない・2 表を 1 つにしない（SG-D8）。待機列の行のコード表示を変えない。
- `UserDefaults` の key 名・`subjectScoped` の集合を変えない。`seen_achievement_ids` の扱いを変えない（I-T10）。
- 同期の順序（起動時の解決 → 設定の同期 → 通知の登録）を変えない。合成 root へ移さない（I-T12）。
- `PreferencesStore` の外から設定の値を書く入口を作らない（`Binding(set:)` は command を呼ぶ）。

## 種別
適用 slice。判断待ち（TA Spec §10.3 の 1）は SG-D8 で確定済み。

## 規模（見込み。TA Spec §8.1: 350 / 350。基点: `SettingsView.swift` 564・`SettingsViewModel.swift` 298・`AppState.swift` 557・`PreferenceRegistry.swift` 199）
- production ≈ 350 行: 値型 4 本 ≈ 80・`PreferencesStore` ≈ 150・gateway と変換 ≈ 40・`SettingsView` ≈ −40・`AppState` ≈ −70・`SettingsViewModel` ≈ −60・ほか ≈ 30。
- test ≈ 350 行: `PreferencesStoreTests` ≈ 180・`PreferencesDomainTests` ≈ 50・既存の Given ≈ 60・`GrepOracleTests` の O-8〜O-13 ≈ 50・所属表 ≈ 10。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TA Spec §10.3 の 1 を「SG-D8 で (a)」へ。TA-R-PF-1 の literal の行数の実測。`GrepOracleTests` の O-9〜O-13 の向け先の変更（`design/ios-design.md` の oracle の記述）。README の I-T6 行を完了へ。
