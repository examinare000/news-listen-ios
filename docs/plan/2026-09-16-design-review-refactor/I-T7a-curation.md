## iOS リファクタ I-T7a: Curation（Feed・Starred・生成の残り回数）の domain・application・gateway

## 概要
フィードの楽観的な除去・確定待ち・取り消し・まとめて Star、Star した記事の一覧と解除、生成の残り回数の読み取りを、`FeedViewModel`・`StarredViewModel`・`SettingsViewModel` から application（`Feed/Application/FeedCuration`・`Starred/Application/StarredArticles`）と domain（`Feed/Domain/PendingCuration`・`GenerationAllowance`）へ移す。ViewModel は画面の状態（読み込み中・文言・選択モード・展開中の行）だけを持ち、通信のデータモデル `Article`・`GenerationQuota` を持たない。**スワイプの見た目・文言・猶予（4 秒）・確定の順序と失敗の扱いは変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.5（TA-M-CU・TA-C-CU-1〜4・TA-Q-CU-1〜3・TA-R-CU-1〜5・port と adapter・整合性と失敗）・§6 の 6（`loadFeed` の分け方）・§7 TA-V3 の TA-R-CU-3・TA-R-CU-4・TA-V6 の CU・§8.2 の I-T7a 行、§5 冒頭の共通の決まり（gateway は closure の束・変換は `Models/` の extension）、導出 I-36・I-41。**検証モード（再設計しない）**。

応える要求: `F-FEED-04`・`F-FEED-06`、ADR-044・ADR-060・ADR-061・ADR-083、AQ-3（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-T6 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（Star の難易度に `DifficultyLevel` を使う。TA-R-CU-5）。I-T7b と並行可（同じ `Settings/SettingsViewModel.swift`・`Settings/SettingsView.swift` を触るので、後から merge する側が rebase する）。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Shared/Domain/DifficultyLevel.swift`（rc=0）。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| `FeedViewModel` の公開面 | 378 行。`@Published var` 7（`articles: [Article]`・`isLoading`・`errorMessage`・`isSelectionMode`・`selectedIds`・`bulkActionResult`・`expandedId`）と `private(set)` 2（`pendingAction`・`isOnline`）。操作 `loadFeed`（`:101`）・`star(article:difficulty: String?)`（`:133`）・`dismiss`（`:139`）・`undoLast`（`:185`）・`commitPending`（`:196`）・`generationLimitMessage(retryAfter:)`（`:240`。丸めと文言が同居）・`toggleExpand`・`toggleSelection`・`bulkStar`（`:274`）。型 `PendingArticleAction`（`:333`）・`BulkActionResult`（`:364`）。既定引数 `NetworkMonitor()`（`:78`） | `grep -n 'func \|@Published\|^struct\|^enum' NewsListenApp/NewsListenApp/Feed/FeedViewModel.swift` |
| `loadFeed` が先に確定する | `FeedViewModel.swift:108` | `sed -n 101,130p NewsListenApp/NewsListenApp/Feed/FeedViewModel.swift` |
| `StarredViewModel` | 126 行。`@Published var` 3（`articles`・`isLoading`・`errorMessage`）。`loadStarred`（`:65`）・`unstar`（`:101`。404 は成功 `:110`）。既定引数 `NetworkMonitor()`（`:46`） | `grep -n 'func \|@Published\|notFound' NewsListenApp/NewsListenApp/Starred/StarredViewModel.swift` |
| 生成の残り回数 | `Settings/SettingsViewModel.swift:170` `loadGenerationQuota`（404 `.quota` は未提供 `:175`）。無制限の解釈 `Settings/SettingsView.swift:297` `quota.limit == 0` | `grep -n 'generationQuota\|limit == 0' NewsListenApp/NewsListenApp/Settings/*.swift` |
| `localizedDescription` | `FeedViewModel` 2・`StarredViewModel` 2（文言は変えない。TA Spec §5.10） | `grep -c localizedDescription NewsListenApp/NewsListenApp/Feed/FeedViewModel.swift NewsListenApp/NewsListenApp/Starred/StarredViewModel.swift` |
| `Article` を受ける View | `Feed/FeedView.swift`・`Feed/ArticleRowView.swift`・`Feed/SwipeableArticleCard.swift`・`Starred/StarredView.swift` | `grep -rlw 'Article' NewsListenApp/NewsListenApp/Feed NewsListenApp/NewsListenApp/Starred` |
| 既存テスト | `FeedViewModelTests` **42**・`StarredViewModelTests` **17**（TA Spec §8.2 の「40」「15」は机上の値。実測で読む）・`SettingsViewModelTests` の残り回数の分 | `grep -c 'func test' NewsListenApp/NewsListenAppTests/FeedViewModelTests.swift NewsListenApp/NewsListenAppTests/StarredViewModelTests.swift` |

## 対象（ios サブモジュールのみ）
**新規（production 9 本。TA Spec §8.2）**: `Feed/Domain/PendingCuration.swift`・`Feed/Domain/GenerationAllowance.swift`（domain）、`Feed/Application/FeedCuration.swift`（application。Curation の gateway の束 `CurationGateway` の宣言を含む = `portFiles`）・`Feed/Application/ArticleCard.swift`（リードモデル = `readModelFiles`）、`Starred/Application/StarredArticles.swift`（application）、`Models/Article+Card.swift`・`Models/GenerationQuota+Domain.swift`（adapter。変換）、`Networking/Gateways/CurationGateway+Live.swift`（adapter）。
**変更（production）**: `Feed/FeedViewModel.swift`・`Feed/FeedView.swift`・`Feed/ArticleRowView.swift`・`Feed/SwipeableArticleCard.swift`・`Starred/StarredViewModel.swift`・`Starred/StarredView.swift`・`Settings/SettingsViewModel.swift`（残り回数の読み取りを `FeedCuration.generationAllowance()` に）・`Settings/SettingsView.swift`（無制限の表示を `GenerationAllowance.isUnlimited` で）・`NewsListenAppApp.swift`（gateway と application を作って VM に渡す）。`Feed/SafariView.swift` は変えない。
**変更（test）**: `FeedViewModelTests`（42）・`StarredViewModelTests`（17）・`SettingsViewModelTests`（Given の置き換え。Then 不変）、`ArchitectureManifest.swift`。**新規（test）**: `CurationDomainTests.swift`（`domainTestFiles`）・`FeedCurationTests.swift`・`StarredArticlesTests.swift`。

**対象外**: スワイプの見た目とアニメーション、文言（`generationLimitMessage` の文字列、`localizedDescription` の表示）、取り消しのトースト、記事の開き方（I-T6 の `ArticleOpenMode`）、ソースの管理（I-T7b）。

## 宣言（名前は TA Spec §5.5 のとおり。ここに無い公開メンバーを足さない）
```swift
// Feed/Domain/PendingCuration.swift
struct PendingCuration: Equatable { enum Kind: Equatable { case star(DifficultyLevel?), dismiss }; let kind: Kind; let articleId: String; let originalIndex: Int }
//   規則（TA-R-CU-1）: 取り消しは元の位置へ戻す（`restore(into:)` の純関数）。確定の契機の判定（猶予の後・別の操作・再読込・背景遷移）は FeedCuration が時間と合わせて持つ
// Feed/Domain/GenerationAllowance.swift
struct GenerationAllowance: Equatable { let limit: Int; let used: Int; let remaining: Int?; var isUnlimited: Bool { get } }   // TA-R-CU-3: limit == 0 は無制限
enum GenerationLimitWait: Equatable { case soon, minutes(Int), hours(Int) }                                               // TA-R-CU-2: 切り上げの丸め
extension GenerationLimitWait { init(retryAfterSeconds: Int?) }
// Feed/Application/ArticleCard.swift（リードモデル）
struct ArticleCard: Identifiable, Equatable { let id: String; let title: String; let url: String; let source: String; let score: Double?; let publishedAt: String? }
// Feed/Application/FeedCuration.swift
struct CurationGateway { let fetchFeed: …; let star: (String, DifficultyLevel?) async throws -> Void; let dismiss: (String) async throws -> Void; let fetchStarred: () async throws -> [ArticleCard]; let unstar: (String) async throws -> Void; let fetchAllowance: () async throws -> GenerationAllowance? }
enum CurationFailure: Error, Equatable { case api(ApiFailure), rateLimited(GenerationLimitWait) }
struct BulkStarReceipt: Equatable { let succeeded: Int; let failed: Int }          // TA-C-CU-3 の receipt（現行 BulkActionResult の数）
@MainActor final class FeedCuration: ObservableObject {
    @Published private(set) var cards: [ArticleCard]; @Published private(set) var pending: PendingCuration?
    init(gateway: CurationGateway, undoGracePeriod: Duration)
    func star(articleId: String, difficulty: DifficultyLevel?) async; func dismiss(articleId: String) async          // TA-C-CU-1
    func undoLast(); func commitPending() async throws                                                             // TA-C-CU-2
    func bulkStar(articleIds: Set<String>) async -> BulkStarReceipt                                                // TA-C-CU-3
    func reload() async throws                                                                                     // TA-Q-CU-1（確定しない）
    func generationAllowance() async throws -> GenerationAllowance?                                                // TA-Q-CU-3（404 .quota は nil）
}
// Starred/Application/StarredArticles.swift
@MainActor final class StarredArticles { init(gateway: CurationGateway); func list() async throws -> [ArticleCard]; func unstar(articleId: String) async throws }  // TA-Q-CU-2・TA-C-CU-4（404 は成功）
```
- `ArticleCard` の field は `Article` から写す（TA Spec §5.5 の 6 つ。`score`・`publishedAt` の型は `Article` の現行の型に合わせる）。
- `FeedViewModel.loadFeed()` は `try? await curation.commitPending()`（失敗は現行どおり握る）→ `try await curation.reload()` の順で呼ぶ（§6 の 6。順序と結果を変えない）。
- `generationLimitMessage(retryAfter:)` の文言の組み立ては ViewModel（presentation）に残し、丸めは `GenerationLimitWait` を使う（式は 1 箇所。TA-R-CU-2）。
- 猶予は `FeedCuration` に注入（既定値 4 秒は合成 root が渡す）。`NetworkMonitor()` の既定引数は残す（TP11。I-T12）。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 確定待ちの形と取り消しの規則・上限の解釈・待ちの丸め | domain: `Feed/Domain/` |
| 一覧の保持・楽観的な除去・確定の契機と実行・まとめて Star・Star 解除の冪等 | application: `Feed/Application/FeedCuration.swift`・`Starred/Application/StarredArticles.swift` |
| 通信 → カード・残り回数 | adapter: `Models/Article+Card.swift`・`Models/GenerationQuota+Domain.swift`・`Networking/Gateways/CurationGateway+Live.swift` |
| 文言・選択モード・展開中の行・読み込み中 | presentation: ViewModel と View |

## 移行の中間状態
- TP11（`FeedViewModel`・`StarredViewModel` の `NetworkMonitor()` 既定引数）は残る（I-T12）。
- 許可リスト（TP10）の増減: TA-D4・TA-D6 の `Feed/`・`Starred/` の `APIClient`・`DTO` の行、TA-D12 の `FeedViewModel` 7・`StarredViewModel` 3（`isSelectionMode`・`selectedIds`・`expandedId` などの画面の状態は `private(set)` にし、変更は VM の操作を通す）、TA-V3 の TA-R-CU-3（`SettingsView.swift:297`）・TA-R-CU-4（`StarredViewModel` 1）と `SettingsViewModel.swift:175` の `.quota`、TA-D5 の `viewModel.isSelectionMode.toggle()` 1 行を消す。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-R-CU-1〜3 | **T-TA-R-CU-1〜3**（`CurationDomainTests`） | 取り消しで元の位置へ戻る（先頭・中・末尾・元の位置が範囲外）。`GenerationLimitWait` の切り上げ（nil・0・59・60・61 秒・3600・3601 秒。現行 `FeedViewModel.swift:240-255` の境界と同値）。`limit == 0` は無制限 |
| TA-C-CU-1・2 | **T-TA-C-CU-1・2**（`FeedCurationTests`） | Star / Dismiss で `cards` から除かれ `pending` に入る。猶予の後・別の操作・`commitPending` で確定（gateway の呼出 1 回）。`undoLast` で元の位置に戻り呼出 0。確定の失敗で除去が戻る。`rateLimited` は `CurationFailure.rateLimited(wait)` |
| TA-C-CU-3 | **T-TA-C-CU-3** | 成功と失敗の件数の receipt。型注釈つきの代入で戻り値の型を固定（TA-V8） |
| TA-C-CU-4・TA-R-CU-4 | **T-TA-C-CU-4**（`StarredArticlesTests`） | 404 は成功、ほかの失敗は投げる。取消は復元しない |
| TA-Q-CU-1〜3・TA-V8 | **T-TA-Q-CU** | `reload()`・`list()`・`generationAllowance()` の後、gateway の書込（star・dismiss・unstar）が 0 件。`reload()` は確定しない |
| TA-R-CU-5 | **T-TA-R-CU-5** | Star の難易度は `DifficultyLevel?` で渡り、gateway へ `code` が届く |
| TA-V6（CU） | **T-TA-V6-CU** | `cards`・`list()` の戻り値の写しを書き換えても次の query の結果が変わらない |
| TA-V11 | `FeedViewModelTests`（42）・`StarredViewModelTests`（17） | Given の置き換えで Then 不変 |

## 完了条件
1. 上のテストが green。既存テストが全件 green で、`FeedViewModelTests` 42・`StarredViewModelTests` 17 の件数が減らない（2026-10-01 実測）。
2. ViewModel が通信を知らない: `grep -rnw "APIClient\|Article\|GenerationQuota\|FeedResponse\|StarredArticlesResponse" NewsListenApp/NewsListenApp/Feed/FeedViewModel.swift NewsListenApp/NewsListenApp/Starred/StarredViewModel.swift | grep -v '^[^:]*:[0-9]*:[[:space:]]*//'` が 0 件。View 4 本（`FeedView`・`ArticleRowView`・`SwipeableArticleCard`・`StarredView`）でも `Article\b` の型名が 0 件（`ArticleCard` は一致しない `-w` で数える）。
3. 規則の式が domain の 1 箇所: `grep -rn 'limit == 0' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が `Feed/Domain/GenerationAllowance.swift` の 1 行。`grep -rn 'notFound(subject: \.star)\|notFound(subject: \.quota)' NewsListenApp/NewsListenApp --include='*.swift' | grep -v Networking/ | grep -v FailureMessages` が `Starred/Application/StarredArticles.swift`・`Feed/Application/FeedCuration.swift` の行だけ。
4. 公開面: `grep -c "@Published var" NewsListenApp/NewsListenApp/Feed/FeedViewModel.swift NewsListenApp/NewsListenApp/Starred/StarredViewModel.swift` がどちらも 0。`grep -c "@Published var" NewsListenApp/NewsListenApp/Feed/Application/*.swift NewsListenApp/NewsListenApp/Starred/Application/*.swift` がすべて 0。
5. `PendingArticleAction`・`BulkActionResult` が消えている（`PendingCuration`・`BulkStarReceipt` に置き換わる）: `grep -rn "PendingArticleAction\|BulkActionResult" NewsListenApp --include='*.swift'` が 0 件。
6. `ArticleCard.swift` が `struct`・`let` だけ（`readModelFiles` に登録し T-TA-V5b が green）。
7. `ArchitectureOracleTests` が green で、許可リストに `Feed/`・`Starred/` の path が無い（`grep -c '"Feed/\|"Starred/' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` の TA-D4・D5・D6・D12・TA-V3 の行が 0。TA-D13 の `NetworkMonitor()` 既定引数 2 行は残る = I-T12）。
8. 変更した production が「対象」の新規 9 ＋ 変更 9 の 18 本以下: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` の各行が対象の一覧にある。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜8 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。TA-V12 の AQ-3・AQ-4 の問いの答えを書く。
- シミュレータの目視: Star / Dismiss → 4 秒以内の取り消しで元の位置に戻る。上限に達したときの文言が同じ。設定画面の残り回数（無制限を含む）。
- commit は「domain（PendingCuration・GenerationAllowance）」「FeedCuration と StarredArticles（契約テスト）」「gateway と変換」「Feed の VM と View」「Starred の VM と View」「設定の残り回数」「所属表」の単位。

## 禁止事項 / scope 外
- 文言・猶予の長さ・確定の順序・失敗時の扱いを変えない。`localizedDescription` の表示を日本語化しない（TA Spec §5.10）。
- 確定待ちを複数件に広げない（現行は 1 件）。まとめて Star の並行度を変えない。
- `FeedCuration` に記事の開き方・時刻表記を持たせない（I-T6 の `PreferencesStore`）。
- `NetworkMonitor()` の既定引数を消さない（I-T12）。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 300 / 300。基点: `FeedViewModel.swift` 378・`StarredViewModel.swift` 126）
- production ≈ 300 行（application ≈ 170・domain ≈ 60・変換と gateway ≈ 50・VM の削減 ≈ −150・View ≈ 40）。
- test ≈ 300 行（新規 ≈ 200・既存の Given ≈ 100）。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TA Spec §8.2 の I-T7a 行の既存テスト件数（`FeedViewModelTests` 42・`StarredViewModelTests` 17 が実測）。README の I-T7a 行を完了へ。
