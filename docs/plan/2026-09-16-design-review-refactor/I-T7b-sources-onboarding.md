## iOS リファクタ I-T7b: RSS ソースと Onboarding の application・gateway

## 概要
RSS ソースの一覧・追加・更新・削除・おすすめの取得と購読を application `SourceSubscriptions` に、初回 Onboarding の完了の状態と記録を `OnboardingProgress` に置く。おすすめのカテゴリの値域・正規化・並べ方を `Onboarding/Domain/FeaturedCategory.swift` に移し、2 つの ViewModel に重複していたカテゴリ分けを 1 実装にする。`AppState` から Onboarding の状態を外す。**追加シートの入力の検査と文言、Onboarding が取れないときに完了として扱う規則（行き止まりを作らない）は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.6（TA-M-SO・TA-C-SO-1〜3・TA-Q-SO-1・2・TA-R-SO-1〜4・port と adapter）・§6 の 5（`refreshOnboardingStatus` の分け方）・§4 TA-D2（`FeaturedCategory` の 2 行）・§8.2 の I-T7b 行。**検証モード（再設計しない）**。

応える要求: `F-FEED-01`・`F-SET-01`・`F-SET-08`、ADR-012・ADR-047（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-T6 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（同じ `Settings/SettingsViewModel.swift`）。I-T7a と並行可（後から merge する側が rebase する）。
- コマンドの実行場所: `ios/`。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-T6・I-T7a の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| `FeaturedCategory` | `Models/FeaturedCategory.swift`（69 行）: `enum FeaturedCategory: String, CaseIterable`（`:12`）・`normalize(_:)`（`:44`）・`groupByCategoryInOrder(_ items: [FeaturedSite])`（`:56`。通信のデータモデルを受ける = TA-D2 の 2 行） | `grep -n 'enum\|static func\|FeaturedSite' NewsListenApp/NewsListenApp/Models/FeaturedCategory.swift` |
| カテゴリ分けの重複 | `Settings/SettingsViewModel.swift:47-53` `categorizedFeaturedSites`・`Onboarding/OnboardingSourcesViewModel.swift:30-36` `categorizedSites` | `grep -n 'categorized' NewsListenApp/NewsListenApp/Settings/SettingsViewModel.swift NewsListenApp/NewsListenApp/Onboarding/OnboardingSourcesViewModel.swift` |
| ソースの操作 | `SettingsViewModel.swift:87` `loadSources`・`:107` `loadFeaturedSites`・`:123` `addSource`・`:141` `updateSource`・`:155` `removeSource`（応答の一覧で置き換える）。`@Published var` 4（`sources: [RssSource]`・`featuredSites: [FeaturedSite]`・`isLoading`・`errorMessage`） | `grep -n 'func \|@Published' NewsListenApp/NewsListenApp/Settings/SettingsViewModel.swift` |
| Onboarding の購読 | `OnboardingSourcesViewModel.swift:60` `subscribe`（409 は成功 `:66`）。`@Published var` 2（`loadErrorMessage`・`subscribeErrorMessage`） | `grep -n 'func \|@Published\|conflict' NewsListenApp/NewsListenApp/Onboarding/OnboardingSourcesViewModel.swift` |
| `AppState` の Onboarding | `AppState.swift:128` `@Published var onboardingCompleted: Bool?`・`:481-492` `refreshOnboardingStatus`（失敗を完了として書く `:488-491`）・`:497-506` `completeOnboarding`（記録の失敗でも完了 `:503-505`）。主体ガード `:486,489,504` | `grep -n 'onboarding' NewsListenApp/NewsListenApp/AppState.swift` |
| 呼び手 | `NewsListenAppApp.swift` の `fullScreenCover`（`onboardingCompleted`）と `appState.refreshOnboardingStatus(`・`appState.completeOnboarding(`（O-8 の期待値に各 1） | `grep -rn 'onboardingCompleted\|refreshOnboardingStatus\|completeOnboarding' NewsListenApp/NewsListenApp --include='*.swift'` |
| 管理者だけの編集の導線 | `Settings/SettingsView.swift:205`（`currentSubject?.role.isAdmin`。I-T5 の後） | `grep -n 'isAdmin' NewsListenApp/NewsListenApp/Settings/SettingsView.swift` |
| 既存テスト | `OnboardingSourcesViewModelTests` 5・`FeaturedCategoryTests`・`SettingsViewModelTests` のソースの分 | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ）
**新規（production 4 本。TA Spec §8.2）**: `Onboarding/Domain/FeaturedCategory.swift`（`Models/FeaturedCategory.swift` を移動。並べ方は `FeaturedSiteCard` を受ける）、`Settings/Application/SourceSubscriptions.swift`（application。リードモデル `SourceEntry`・`FeaturedSiteCard` と gateway の束 `SourcesGateway` の宣言を含む = `portFiles`）、`Onboarding/Application/OnboardingProgress.swift`（application）、`Networking/Gateways/SourcesGateway+Live.swift`（adapter。`RssSource` → `SourceEntry`、`FeaturedSite` → `FeaturedSiteCard` の変換を含む）。
**変更（production）**: `Settings/SettingsViewModel.swift`・`Settings/SettingsView.swift`・`Onboarding/OnboardingSourcesViewModel.swift`・`Onboarding/OnboardingSourcesView.swift`・`AppState.swift`（Onboarding の状態と 2 操作を外す）・`NewsListenAppApp.swift`（`OnboardingProgress` を作り `fullScreenCover` の条件と起動時の取得を付け替える。起動時の順序は変えない）。
**変更（test）**: `OnboardingSourcesViewModelTests`・`FeaturedCategoryTests`・`SettingsViewModelTests`・`GrepOracleTests`（O-8 の `appState.refreshOnboardingStatus(`・`appState.completeOnboarding(` を消す。完了条件 6）・`ArchitectureManifest.swift`（所属表の明示の行から `Models/FeaturedCategory.swift` を消す。許可リストの TA-D2 を 0 に）。**新規（test）**: `SourceSubscriptionsTests.swift`・`OnboardingProgressTests.swift`。

**対象外**: 追加シートの入力の検査と文言、ソースの行の見た目、Onboarding 画面の構成、管理者の判定そのもの（I-T5 の `Role`）。

## 宣言（名前は TA Spec §5.6 のとおり）
```swift
// Settings/Application/SourceSubscriptions.swift
struct SourceEntry: Identifiable, Equatable { let name: String; let url: String; var id: String { url } }
struct FeaturedSiteCard: Identifiable, Equatable { let id: String; let name: String; let url: String; let thumbnailURL: String?; let description: String?; let category: FeaturedCategory }
struct SourcesGateway { let list: …; let add: …; let update: …; let remove: …; let featured: …; let subscribe: (String) async throws -> Void }
@MainActor final class SourceSubscriptions {
    init(gateway: SourcesGateway)
    func list() async throws -> [SourceEntry]                                                  // TA-Q-SO-1
    func featured() async throws -> [(category: FeaturedCategory, sites: [FeaturedSiteCard])]  // TA-Q-SO-1（カテゴリ分けは 1 実装）
    func add(name: String, url: String) async throws; func update(oldURL: String, name: String, url: String) async throws; func remove(url: String) async throws   // TA-C-SO-1
    func subscribe(featuredSiteId: String) async throws                                        // TA-C-SO-2（409 は成功。TA-R-SO-2）
    func canEdit(role: Role) -> Bool                                                           // TA-R-SO-4（管理者だけ）
}
// Onboarding/Application/OnboardingProgress.swift
@MainActor final class OnboardingProgress: ObservableObject {
    @Published private(set) var isCompleted: Bool?
    init(fetchStatus: @escaping () async throws -> Bool, recordCompleted: @escaping () async throws -> Void, subjectStamp: @escaping () -> SubjectStamp, isCurrentSubject: @escaping (SubjectStamp) -> Bool)
    func refresh() async                // TA-Q-SO-2。取得に失敗したら完了として扱う（TA-R-SO-3）。前の主体の遅延応答は捨てる
    func complete() async               // TA-C-SO-3。記録に失敗しても完了
}
```
- `thumbnailURL`・`description` の型は `FeaturedSite` の現行の型に合わせる（TA Spec §5.6 の field 名のとおり）。
- 追加・更新の応答が返す一覧は、gateway の adapter が捨てずに `list()` の結果として使ってよい（TA Spec §5.6。通信の回数を増やさない）。application の入口は command と query に分け、ViewModel が command の後に `list()` を呼ぶ。
- `OnboardingProgress.refresh()` の主体ガードと失敗時の扱いは `AppState.swift:481-506` をそのまま移す。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| カテゴリの値域・正規化・表示順 | domain: `Onboarding/Domain/FeaturedCategory.swift` |
| ソースの操作・おすすめのカテゴリ分け・409 の冪等・編集の可否 | application: `Settings/Application/SourceSubscriptions.swift` |
| Onboarding の状態・失敗時に完了とする規則・主体ガード | application: `Onboarding/Application/OnboardingProgress.swift` |
| 通信 → リードモデル | adapter: `Networking/Gateways/SourcesGateway+Live.swift` |

## 移行の中間状態
無い。許可リスト（TP10）の増減: TA-D2 の `Models/FeaturedCategory.swift` 2 を消す（TA-D2 が 0 になる）。TA-D3 の `AppState.swift` の `OnboardingStatusResponse`（`DTO`）の行、TA-D12 の `AppState.onboardingCompleted`・`SettingsViewModel` 4・`OnboardingSourcesViewModel` 2、TA-D4・D6 の `Settings/`・`Onboarding/` の `APIClient`・`DTO`、TA-V3 の TA-R-SO-2（`OnboardingSourcesViewModel` 1）を消す。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-R-SO-1 | `FeaturedCategoryTests`（移動。Then 不変）＋ **T-TA-R-SO-1** | 正規化（未知は既定）・表示順・空のカテゴリを出さない |
| TA-C-SO-1・TA-Q-SO-1・TA-V8 | **T-TA-C-SO-1** | 追加・更新・削除が gateway を 1 回ずつ呼ぶ。`conflict`・`validation` は `ApiFailure` で投げる。`list()`・`featured()` は書込 0 件 |
| TA-C-SO-2・TA-R-SO-2 | **T-TA-C-SO-2** | 409 は成功、ほかは投げる |
| TA-R-SO-3・TA-Q-SO-2・TA-C-SO-3 | **T-TA-R-SO-3**（`OnboardingProgressTests`） | 取得の失敗 → `isCompleted == true`。記録の失敗でも完了。主体が変わった後の応答は書かない（`AppState.swift:486,489,504` の 3 ガードと同値） |
| TA-R-SO-4 | **T-TA-R-SO-4** | `canEdit(role: .admin)` true・`.user` と未知は false |
| TA-V6（SO） | **T-TA-V6-SO** | `list()` の戻り値を書き換えても次の `list()` が変わらない |

## 完了条件
1. 上のテストが green。既存テストが全件 green で件数が減らない（`OnboardingSourcesViewModelTests` 5 を含む）。
2. カテゴリ分けが 1 実装: `grep -rn "groupByCategoryInOrder\|categorized" NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` の実装（`func`・`var … {`）が `Onboarding/Domain/FeaturedCategory.swift` と `Settings/Application/SourceSubscriptions.swift` の中だけ（2026-10-01 実測: 2 つの ViewModel に 1 つずつ）。
3. `Models/FeaturedCategory.swift` が無い（`test ! -e`）。domain が通信のデータモデルを知らない: `grep -rnw "FeaturedSite\|RssSource\|Codable" NewsListenApp/NewsListenApp/Onboarding/Domain` が 0 件。
4. `AppState` に Onboarding が無い: `grep -n "onboarding" NewsListenApp/NewsListenApp/AppState.swift` が 0 件（大文字小文字を区別しない `grep -in` で 0）。
5. ViewModel が通信を知らない: `grep -rnw "APIClient\|RssSource\|FeaturedSite\|OnboardingStatusResponse" NewsListenApp/NewsListenApp/Settings/SettingsViewModel.swift NewsListenApp/NewsListenApp/Onboarding/OnboardingSourcesViewModel.swift NewsListenApp/NewsListenApp/Onboarding/OnboardingSourcesView.swift NewsListenApp/NewsListenApp/Settings/SettingsView.swift | grep -v '^[^:]*:[0-9]*:[[:space:]]*//'` が 0 件。
6. `GrepOracleTests` の O-8 の期待値から `appState.refreshOnboardingStatus(`・`appState.completeOnboarding(` を消す（どちらも 0 になる）。件数（10 件）は不変。前後を PR 説明に。
7. `ArchitectureOracleTests` が green で、TA-D2 の許可リストが空（`grep -c '"TA-D2"' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` → 0）。所属表の明示の行に `Models/FeaturedCategory.swift` が無い。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜7 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータの目視: 初回 Onboarding（通信断でも先へ進める）・設定のソースの追加・削除・おすすめのカテゴリの並び。
- commit は「FeaturedCategory の移動」「SourceSubscriptions」「OnboardingProgress と AppState から外す」「VM と View」「GrepOracle と所属表」の単位。

## 禁止事項 / scope 外
- 入力の検査・文言・画面の構成を変えない。Onboarding を「取れないときは未完了」にしない（TA-R-SO-3）。
- 起動時の順序（`fullScreenCover` を出す条件の評価の時点）を変えない。合成 root へ連鎖を移すのは I-T12。
- 追加・更新の command に一覧を返させない（ADR-110 決定 5）。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 200 / 200）
- production ≈ 200 行（application ≈ 120・gateway ≈ 40・VM と `AppState` の削減 ≈ −90・View ≈ 30）。test ≈ 200 行。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: `design/ios-design.md` §11.2 の「Onboarding は `AppState` に残す」を改める（TA Spec §10.2）。README の I-T7b 行を完了へ。
