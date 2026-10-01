## iOS リファクタ I-T4: 一覧を Catalog の application とリードモデル `EpisodeRow` に切り替える（TP6 を消す）

## 概要
facade（`PodcastViewModel`）が通信のデータモデル `[Podcast]` で持っていた一覧を、Catalog の application `EpisodeCatalog`（`Catalog/Application/`）が `[Episode]` として保持し、一覧の行 View はリードモデル `EpisodeRow` を受ける。id からの引き当て（`episode(id:)`）と、位置の応答の反映（`applyPositionSaved`）も `EpisodeCatalog` に置き、合成 root の closure（TP6 の一部）を消す。**行の見た目と文言、オフライン時の薄表示の条件は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.2（TA-M-CT の application・リードモデル行、TA-Q-CT-1・2、TA-C-CT-1、TA-R-CT-2、port `fetchEpisodes`）・§5.1（`startEpisode` の引き先は TA-Q-CT-2）・§6 の 7（`loadPodcasts` の分け方）・§8.2 の I-T4 行・§8.4 TP6、導出 I-25（TA Spec §10.1）。**検証モード（再設計しない）**。

応える要求: `F-POD-01`・`F-POD-07`、AQ-1・AQ-4（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-S3b3 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**。facade が TP6 の形（`podcasts: [Podcast]` を `@Published private(set)` で持ち、開始の入口で `toEpisode()` を呼び、行 View が `Podcast` を受け、バッジの種類を facade が導く。I-S3b2 の補正 4〜6、I-S3b3 の補正 2）であること。
- I-T5 と並行可（対象のファイルが重ならない。`NewsListenAppApp.swift` は両方が触るので、後から merge する側が rebase する）。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator.swift`（rc=0）と、facade の `podcasts` が `[Podcast]` であること（`grep -n "private(set) var podcasts" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift`）を確かめる。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測は revision `ef9e559` の旧 VM。I-S3b3 の後の facade で数え直す）

| 項目 | 実測（旧 VM） | コマンド（`ios/` で） |
|---|---|---|
| 一覧の保持と取得 | `Podcast/PodcastViewModel.swift:34` `podcasts`、`:140-154` `loadPodcasts`（取得 → `syncDownloadedState()`。§6 の 7） | `grep -n 'var podcasts\|func loadPodcasts' NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` |
| 行 View が読む `Podcast` の field | `Podcast/PodcastRowView.swift:54` `displayTitle`、`:59` `difficulty`、`:60` `formattedDuration`、`:87` `createdAt`、`:120` `status`、`:127` `errorMessage`（`accessibilityValue`） | `grep -n 'podcast\.' NewsListenApp/NewsListenApp/Podcast/PodcastRowView.swift` |
| 一覧 View | `Podcast/PodcastView.swift:87` `List(viewModel.podcasts)`、`:90-92` 行の引数（`isPlaying`・`downloadState`・`isOffline`）、`:95,102,109,114` 行の操作 | `grep -n 'podcasts\|PodcastRowView' NewsListenApp/NewsListenApp/Podcast/PodcastView.swift` |
| `Podcast` の表示の規則の読み手（`Models/Podcast.swift` 以外） | `AudioPlayerView` 7・`MiniPlayerView` 2・`NowPlayingInfo` 3・`PodcastRowView` 4・`QueueSheet` 1・`QuizSheetView` 1（I-S3b3 の後は `PodcastRowView` 以外が `NowPlaying` へ付け替わっている） | `grep -rn 'displayTitle\|hasTranscript\|hasQuiz\|hasVocabulary\|showsCcBySaLicense\|hasSourceArticles\|formattedDuration' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v Models/Podcast.swift` |
| `status` の文字列の分岐（TA-V3 の TA-R-CT-1・2） | I-S3b2 の後は facade がバッジの種類を導く（`"completed"` 等の literal は `Models/Podcast+Episode.swift` に 1 箇所） | `grep -rn '"processing"\|"completed"\|"partial_failed"' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v ':[0-9]*:[[:space:]]*//'` |
| Preview の一覧 | `DesignSystem/PreviewSupport.swift:54` `podcasts: [Podcast]`、`:181` `PodcastListResponse` の JSON | `grep -n 'podcasts' NewsListenApp/NewsListenApp/DesignSystem/PreviewSupport.swift` |
| 位置の応答の反映 | I-S3b2 の補正 5 で合成 root の closure が facade の一覧を置き換える | `grep -n 'onPositionSaved' NewsListenApp/NewsListenApp/NewsListenAppApp.swift` |
| 既存テスト | `PodcastViewModelTests`（I-S3b3 後の件数）・`ModelTests` 50 | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ）
**新規（production 3 本）**

| ファイル | 層 | 中身 |
|---|---|---|
| `Catalog/Application/EpisodeCatalog.swift` | application | `EpisodeCatalog`（下の宣言） |
| `Catalog/Application/EpisodeRow.swift` | application（リードモデル） | `EpisodeRow`・`EpisodeBadge` |
| `Networking/Gateways/CatalogGateway+Live.swift` | adapter | `CatalogGateway.live(apiClient:)`（`fetchEpisodes` = `apiClient.fetchPodcasts().podcasts.map { $0.toEpisode() }`） |

**変更（production 6 本）**: `Podcast/PodcastViewModel.swift`（`podcasts: [Podcast]` と `loadPodcasts` の取得の部分を `EpisodeCatalog` に委ね、`rows` を写す。開始の入口は `catalog.episode(id:)` で `Episode` を引く。バッジの導出を消す）、`Podcast/PodcastView.swift`（`List(viewModel.rows)`。行の操作は `episodeId` を渡す）、`Podcast/PodcastRowView.swift`（`EpisodeRow` を受ける。`m:ss` の整形は行 View に残す）、`NewsListenAppApp.swift`（`EpisodeCatalog` を作って facade に渡す。`onPositionSaved` = `catalog.applyPositionSaved`。一覧を置き換える closure を消す）、`Models/Podcast.swift`（`displayTitle`・`hasTranscript`・`hasVocabulary`・`hasQuiz`・`hasSourceArticles`・`showsCcBySaLicense`・`formattedDuration` の computed を消す。I-T2a の中間状態の削除。`CodingKeys`・field は不変）、`DesignSystem/PreviewSupport.swift`（Preview の一覧を `EpisodeCatalog` の `#if DEBUG` の入口か `[Episode]` の fixture で組む）。

**変更（test）**: `PodcastViewModelTests`（一覧の Given を `EpisodeCatalog` ＋ `MockURLSession` つき `APIClient` から組む。Then 不変）、`ModelTests`（`displayTitle` 等の `Podcast` 側のテストを `EpisodeContent` 側（I-T2a の `EpisodeContentTests`）へ 1 対 1 で移し、件数を減らさない。照合表を PR 説明に載せる）、`ArchitectureManifest.swift`（`readModelFiles` に `Catalog/Application/EpisodeRow.swift` を足す。許可リストの TA-D4・TA-D6 の `Podcast/` の分（`DTO` の行）を消す）。**新規（test）**: `EpisodeCatalogTests.swift`。

**対象外**: 行の見た目・文言・レイアウト、オフライン時の薄表示の条件（`DownloadState` と `isOffline` から presentation が選ぶ。現行のまま）、Coordinator・Session、`AudioPlayerView` ほか（I-S3b3 で付け替え済み）、学習の中継（TP7。I-T9）。

## 宣言（ここに無い公開メンバーを足さない）
```swift
// Catalog/Application/EpisodeRow.swift（リードモデル。struct・let だけ）
enum EpisodeBadge: Equatable { case none, generating, failed(detail: String) }    // TA-R-CT-2
struct EpisodeRow: Identifiable, Equatable {
    let episodeId: String; var id: String { episodeId }
    let title: String            // EpisodeContent.displayTitle
    let difficulty: String; let durationSeconds: Int; let createdAt: String
    let badge: EpisodeBadge      // playable → .none、generating → .generating、failed → .failed(detail: reportedMessage ?? "")
}
// Catalog/Application/EpisodeCatalog.swift（application）
struct CatalogGateway { let fetchEpisodes: () async throws -> [Episode] }        // port（portFiles に登録）
@MainActor final class EpisodeCatalog: ObservableObject {
    @Published private(set) var rows: [EpisodeRow]          // 初期値は空
    init(gateway: CatalogGateway)
    func reload() async throws                               // TA-Q-CT-1。取得して保持を置き換える。失敗は ApiFailure
    func episode(id: String) -> Episode?                     // TA-Q-CT-2
    func applyPositionSaved(_ episode: Episode)              // TA-C-CT-1。同じ id の要素を置き換える（後勝ち）
}
// Networking/Gateways/CatalogGateway+Live.swift（adapter）
extension CatalogGateway { static func live(apiClient: APIClient) -> CatalogGateway }
```
- `rows` は `episodes.map(EpisodeRow.init)` の写しで、`reload()`・`applyPositionSaved` のたびに作り直す。`Episode` の配列は `private`（外へ出さない。TA-V6）。
- `reload()` は書き込む port を呼ばない（TA-V8）。`applyPositionSaved` は保持している id に無ければ何もしない。
- `EpisodeBadge.failed(detail:)` の `detail` は `FailedEpisode.reportedMessage ?? ""`（現行の `accessibilityValue` = `podcast.errorMessage ?? ""` と同じ値。TA Spec §5.2）。
- facade（`PodcastViewModel`）: `@Published private(set) var rows: [EpisodeRow]`（`catalog.rows` を `assign(to:)` で写す）。`loadPodcasts()` は `dismissError()` → `try await catalog.reload()` → `library.refresh(candidateIds: rows.map(\.episodeId))` の順（§6 の 7。順序と失敗の扱いは現行のまま）。`startEpisode(episodeId:)`（View 用の入口。`catalog.episode(id:)` で引いて Coordinator の `startEpisode(_:expandsPlayer:)` へ。無ければ何もしない）と `playNext(episodeId:)`・`addToQueue(episodeId:)`・`download(episodeId:)` も同じ引き方。facade の公開する状態の名前 `podcasts` は消す。
- 行 View: `PodcastRowView(row: EpisodeRow, isPlaying:, downloadState:, isOffline:, …)`。`m:ss` は `row.durationSeconds` から行 View の private 関数で整形する（`Podcast.formattedDuration` と同じ式）。バッジは `row.badge` の `switch`（`status` の文字列を読まない）。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 一覧の保持と更新・id からの引き当て・位置の応答の反映 | application: `Catalog/Application/EpisodeCatalog.swift` |
| 行のリードモデルとバッジの種類（TA-R-CT-2） | application（リードモデル）: `Catalog/Application/EpisodeRow.swift` |
| 通信 → `[Episode]` | adapter: `Networking/Gateways/CatalogGateway+Live.swift`（`toEpisode()` は I-T2a） |
| `m:ss` の整形・薄表示・バッジの文言と色 | presentation: `Podcast/PodcastRowView.swift` |

## 移行の中間状態
| 経路 | 扱い |
|---|---|
| TP6（facade の `[Podcast]`・開始の入口の `toEpisode()`・行 View の `Podcast`・位置の応答の closure） | **消す**（本 slice） |
| `Podcast.displayTitle` 等の computed（I-T2a の中間状態） | **消す**（本 slice） |
| TP7（学習の中継 3 本） | 残る（I-T9） |
| TP11（`SettingsViewModel` 以外の既定引数） | 残る（I-T12） |

許可リスト（TP10）の増減: TA-D4・TA-D6 の `Podcast/`（`PodcastView.swift`・`PodcastRowView.swift`・`PodcastViewModel.swift`）の `DTO` の行を消す。TA-D4 の `APIClient`（`Podcast/` の分）があれば消す。

## 変わる挙動
無い。行の表示（題・難易度・`m:ss`・日時・バッジ・薄表示・読み上げ値）は同じ値。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-Q-CT-1 | **T-TA-Q-CT-1**（`EpisodeCatalogTests`） | `MockURLSession` の `PodcastListResponse` から `reload()` → `rows` が `[EpisodeRow]`（種別ごとのバッジ）。失敗は `ApiFailure` で `rows` 不変。`reload()` の後、gateway double の書込（`POST`/`PUT`/`PATCH`/`DELETE`）が 0 件（TA-V8）。戻り値の型注釈つきの代入で固定 |
| TA-Q-CT-2 | **T-TA-Q-CT-2** | `episode(id:)` が `Episode?` を返し、無ければ nil。戻り値の `content.segments` を書き換えても次の `episode(id:)` が変わらない（TA-V6 の CT） |
| TA-C-CT-1 | **T-TA-C-CT-1** | `applyPositionSaved` で同じ id の要素が置き換わり `rows` が更新される。無い id は何も変わらない。後から届いた応答が勝つ |
| TA-R-CT-2 | **T-TA-R-CT-2** | `EpisodeRow.badge`: `playable` → `.none`、`generating` → `.generating`、`failed(reportedMessage: "x")` → `.failed(detail: "x")`、`failed(nil)` → `.failed(detail: "")` |
| TA-V6（CT） | **T-TA-V6-CT** | `rows` の写しを書き換えても次の読みが変わらない |
| TA-V5（TA-D9） | `ArchitectureOracleTests` | `readModelFiles` に `EpisodeRow.swift` が入り green |
| TA-V11 | `PodcastViewModelTests`・`ModelTests` | Given の置き換えで Then 不変。`ModelTests` の `displayTitle` 等の分は `EpisodeContentTests` へ移して件数不変（照合表） |

## 完了条件
1. 上の契約テストが green。既存テストが全件 green で、`PodcastViewModelTests`・`ModelTests`（移した分を含めて 50 以上）の件数が減らない。
2. 変更した production が上の 9 本（新規 3 ＋ 変更 6）だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 9 行。`Podcast/Playback/`・`Podcast/Platform/`・`Catalog/Domain/` に変更が無い（同 `-- …/Podcast/Playback …/Podcast/Platform …/Catalog/Domain` が 0 行）。
3. TP6 が消えている: `grep -rnw "Podcast" NewsListenApp/NewsListenApp/Podcast --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件（`Podcast/` 配下の View・facade・Playback に通信のデータモデルの型名が無い。正の対照: I-S3b3 直後は `PodcastViewModel.swift`・`PodcastView.swift`・`PodcastRowView.swift` に 1 行以上ある）。`grep -rn "toEpisode()" NewsListenApp/NewsListenApp --include='*.swift'` が `Networking/Gateways/` と `Models/` の行だけ。
4. `Podcast` の表示の規則が消えている: `grep -n "displayTitle\|hasTranscript\|hasVocabulary\|hasQuiz\|hasSourceArticles\|showsCcBySaLicense\|formattedDuration" NewsListenApp/NewsListenApp/Models/Podcast.swift` が 0 件。
5. `status` の文字列の分岐が 1 箇所: `grep -rn '"processing"\|"completed"\|"partial_failed"' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//' | grep -v "#if DEBUG" ` が `Models/Podcast+Episode.swift` の行だけ（Preview の fixture の JSON は `#if DEBUG` の中で対象外。`ArchitectureOracleTests` の T-TA-V3 の TA-R-CT-1・2 の許可リストが 0 行）。
6. 公開面: `grep -c "@Published private(set) var rows" NewsListenApp/NewsListenApp/Catalog/Application/EpisodeCatalog.swift` → 1、`grep -c "@Published" 同ファイル` → 1。`grep -n "var podcasts" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` が 0 件。
7. `EpisodeRow.swift` が `struct`・`let`・`enum` だけ: `grep -c "class \|mutating \|@Published\|var [a-z][A-Za-z]*:" NewsListenApp/NewsListenApp/Catalog/Application/EpisodeRow.swift` → 0（`var id: String { episodeId }` は computed で一致しない）。
8. 依存方向: `grep -rn "APIClient\|URLSession\|import SwiftUI\|import UIKit" NewsListenApp/NewsListenApp/Catalog/Application` が 0 件。`grep -rn "^import" NewsListenApp/NewsListenApp/Catalog/Application` が `Foundation`・`Combine` の中。
9. `ArchitectureOracleTests` が green で、許可リストの TA-D4・TA-D6 に `Podcast/` の path が無い（`grep -c '"Podcast/' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` の TA-D4・TA-D6 の行が 0。TA-D5・TA-D12 の `Podcast/` は I-S3b2・I-S3b3 で 0 になっている）。
10. `ModelTests` の照合表（`Podcast` 側で消したテスト → `EpisodeContentTests` の同じ Then）が PR 説明にある。TA-V12 の AQ-1・AQ-4 の問いの答えが PR 説明にある。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜9 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータの目視（PR 説明に記す）: 一覧の題・難易度・時間・日時・バッジ（生成中・失敗）と、オフライン時の薄表示が I-S3b3 の時点と同じ。
- commit は「EpisodeRow と EpisodeCatalog（契約テスト）」「CatalogGateway+Live」「facade と View の切替」「Podcast の computed の削除と ModelTests の移し替え」「所属表」の単位。

## 禁止事項 / scope 外
- 行の見た目・文言・薄表示の条件を変えない。バッジの種類を 3 つより増やさない。
- `EpisodeCatalog` に再生の状態・保存の状態を持たせない（`DownloadState` は `OfflineDownloads`、`isPlaying` は Coordinator の `session`）。
- `Catalog/Application/` に `APIClient`・`Podcast`（通信のデータモデル）・`URLSession` を書かない。
- `Podcast` の `CodingKeys`・field を変えない。`toEpisode()` の判別を変えない。
- 位置の「新しい方を選ぶ」比較（ADR-109）を入れない（位置同期の slice）。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 250 / 250。2026-10-01 実測の基点: `PodcastRowView.swift` 160・`PodcastView.swift` 151・`PreviewSupport.swift` 196・`Models/Podcast.swift` 214）
- production ≈ 250 行: `EpisodeCatalog.swift` ≈ 70・`EpisodeRow.swift` ≈ 35・`CatalogGateway+Live.swift` ≈ 20・facade ≈ 40（−30）・`PodcastView` ≈ 15・`PodcastRowView` ≈ 30・`NewsListenAppApp` ≈ 15・`Models/Podcast.swift` −45・`PreviewSupport` ≈ 20。
- test ≈ 250 行: `EpisodeCatalogTests` ≈ 120・`PodcastViewModelTests` の Given ≈ 60・`ModelTests` の移し替え ≈ 50・所属表 ≈ 10。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TP6 の削除（TA Spec §8.4）。`design/ios-design.md` §11.3 の該当行。README の I-T4 行を完了へ。
