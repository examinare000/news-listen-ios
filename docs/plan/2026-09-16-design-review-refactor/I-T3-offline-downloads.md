## iOS リファクタ I-T3: オフライン保存の use case `OfflineDownloads`（新規コードとして入れる）

## 概要
ダウンロードの手順（取り直し → URL の検査 → 取得 → 保存）・同じ id の二重実行の抑止・`downloadingIds`・cancel を、application の `Podcast/Playback/OfflineDownloads.swift` に**新規コードとしてだけ**置き、port の double で駆動する契約テストで固定する。**既存コードからは呼ばない**（I-S3b1 と同じ ①。facade の旧い手順は I-S3b2 が中継に替える）。保存庫 `OfflineLibrary`（I-S3b1。`AudioFileStore` を受ける）は変えない。主体の固定と `reclaim` は I-S5。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.1（TA-M-PB の application 行・リードモデル `DownloadState`・TA-C-PB-20〜22・TA-Q-PB-4・TA-R-PB-8・port `AudioFileStore`・整合性の表の「主体の離脱」）・§7 TA-V6（PB）・TA-V8・§8.2 の I-T3 行、導出 I-10・I-28（TA Spec §10.1）、ADR-104 決定 9（cancel して待たない）、共有仕様 §6.3・SL-06（主体の固定は I-S5 で足す）。**検証モード（再設計しない）**。

応える要求: `F-POD-10`（オフライン再生。TA Spec §9.2）、AQ-4・AQ-6。

## 前提・着手条件
- 依存: **I-S3b1 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**。`Podcast/Playback/OfflineLibrary.swift`（`AudioFileStore` の宣言を含む）と `Podcast/Platform/AudioFileStore+Live.swift` があること: `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/OfflineLibrary.swift`（rc=0）。
- コマンドの実行場所: `ios/`。
- I-S3b1 が固定した `OfflineLibrary` の 8 操作（`save(_:for:)`・`has`・`url`・`remove`・`clearAll`・`usage`・`refresh(candidateIds:)`・`savedIds`）と `AudioFileStore`（closure の束: `url`・`exists`・`write`・`remove`・`removeAll`・`size`）を使う。本 slice はどちらも変えない。
- `docs/trial-log/` を最初に読む。棄却済み: `OfflineLibrary` に取得と Task を持たせる案（I-10。保存庫は `APIClient` をまたいで生きる）、`AudioCacheManager` の protocol 化（RO7）。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測は revision `ef9e559` の旧 VM。I-S3b1 の後は `OfflineLibrary` の実物も確かめる）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| 現行の手順 | `Podcast/PodcastViewModel.swift:190-217` `download(podcast:)`: `downloadingIds`・`downloadedIds` で二重実行を抑止 → `apiClient.fetchPodcast(id:)` → `URL(string: fresh.audioUrl)` が nil なら `"Invalid audio URL"` → `apiClient.downloadAudio(from:)` → `cacheManager.cache(_:for:)` → `downloadedIds.insert`。`ApiFailure` は `FailureMessages.message(for:context: .podcast)`、ほかの error は `localizedDescription` | `sed -n 185,230p NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` |
| `DownloadState` の宣言と規則 | `PodcastViewModel.swift:14-22`（3 値）。`downloadState(forId:downloaded:downloading:)`（`:166-178`。downloading を downloaded より優先）。`isPlayableWhileOffline`（`:182-184`） | `grep -n 'enum DownloadState\|static func downloadState\|isPlayableWhileOffline' NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` |
| `removeDownload`・設定の全削除・容量 | `PodcastViewModel.swift:221-228`、`Settings/SettingsViewModel.swift:190-203`（`loadCacheSize`・`clearCache`） | `grep -n 'func removeDownload\|func clearCache\|func loadCacheSize' …` |
| gateway の実体 | `Networking/APIClient.swift:134` `fetchPodcast(id:) -> Podcast`、`:169` `downloadAudio(from: URL) -> Data` | `grep -n 'func fetchPodcast\|func downloadAudio' NewsListenApp/NewsListenApp/Networking/APIClient.swift` |
| 現行のダウンロードのテスト | `PodcastViewModelTests` に `download` を名前に含む 6 件（I-S3b2 で facade の中継に付け替える。本 slice では触らない） | `grep -c 'func test.*[Dd]ownload' NewsListenApp/NewsListenAppTests/PodcastViewModelTests.swift` |
| I-S3b1 の成果 | `OfflineLibrary.swift` の操作 8 個と `AudioFileStore` の closure 6 個（名前は I-S3b1 の order の宣言のとおり） | `grep -n 'func \|let ' NewsListenApp/NewsListenApp/Podcast/Playback/OfflineLibrary.swift` |

## 対象（ios サブモジュールのみ）
**新規（production 1 本）**: `Podcast/Playback/OfflineDownloads.swift`（application）。
**新規（test）**: `NewsListenAppTests/OfflineDownloadsTests.swift`（契約テスト）。
**変更（test）**: `ArchitectureManifest.swift`（`Podcast/Playback/OfflineDownloads.swift` は所属表の規則 (3) で application に当たる。追加の行は要らない。`readModelFiles` は変えない = `DownloadState` は `OfflineDownloads.swift` の中の enum で、ファイル単位のリードモデル検査には載せない）。
**既存の production は 1 行も変えない**（`PodcastViewModel.swift`・`OfflineLibrary.swift`・`SettingsViewModel.swift` を含む）。

## 宣言（ここに無い公開メンバーを足さない）
```swift
// Podcast/Playback/OfflineDownloads.swift
enum DownloadReceipt: Equatable { case saved, alreadySaved, alreadyRunning }
enum DownloadFailure: Error, Equatable { case api(ApiFailure), invalidSource, store(String) }   // store は保存の失敗の説明文

@MainActor final class OfflineDownloads: ObservableObject {
    /// 旧 VM の `DownloadState`（`PodcastViewModel.swift:14-22`）と同じ 3 値。同じ module に同名の型を 2 つ置けないので
    /// 本 slice では入れ子で宣言し、I-S3b2 が旧 enum を消すと同時に `typealias DownloadState = OfflineDownloads.State` を足す（View の型名を変えない）。
    enum State: Equatable { case notDownloaded, downloading, downloaded }
    @Published private(set) var downloadingIds: Set<String>          // 初期値は空
    init(library: OfflineLibrary,
         fetchEpisode: @escaping (String) async throws -> Episode,
         downloadAudio: @escaping (URL) async throws -> Data)
    @discardableResult func download(episodeId: String) async throws -> DownloadReceipt     // TA-C-PB-20
    func remove(episodeId: String) throws                                                     // TA-C-PB-21
    func removeAll() throws                                                                   // TA-C-PB-21
    func cancelAll()                                                                          // TA-C-PB-22
    func state(for episodeId: String) -> State                                                // TA-Q-PB-4
}
```
**規則（TA-R-PB-8）**
| 契機 | 動作 |
|---|---|
| `download(id)` で、`library.has(id)` | `alreadySaved` を返す。何もしない |
| `download(id)` で、`downloadingIds` に含む | `alreadyRunning` を返す。何もしない（二重実行の抑止） |
| `download(id)` の本体 | `downloadingIds.insert(id)` → `fetchEpisode(id)`（取り直し）→ `playable` でないか `URL(string: audioUrl)` が nil なら `invalidSource` → `downloadAudio(url)` → `library.save(data, for: id)` → `saved`。終わり（成功・失敗・cancel）で `downloadingIds.remove(id)` |
| 失敗 | `ApiFailure` は `.api(f)`、保存の失敗は `.store(error.localizedDescription)`（文言は呼ぶ側が作る。I-S3b2 の facade が現行と同じ文言に写す）。cancel による error（`CancellationError`・`URLError(.cancelled)`）は**そのまま投げる**（変換しない。adapter と同じ扱い） |
| `remove(id)` | `library.remove(id)`。失敗は `.store` |
| `removeAll()` | `library.clearAll()`（I-S5 で `remove(subject:)` に替わる）。失敗は `.store` |
| `cancelAll()` | 実行中の全 Task を cancel し、**待たない**（ADR-104 決定 9）。`downloadingIds` は各 Task の終わりで空になる |
| `state(for:)` | `downloadingIds` に含めば `downloading`、`library.has(id)` なら `downloaded`、それ以外 `notDownloaded`（downloading を優先。現行 `downloadState(forId:…)` と同じ） |

- 取り直しの失敗で保持している URL にフォールバックする規則（SG-C4）は**再生**の規則で、ダウンロードには無い（現行 `download` も取り直しの失敗で止まる）。本 slice もフォールバックしない。
- `Podcast/Playback/` に `APIClient`・`FailureMessages`・`UIApplication`・`Timer`・`AudioCacheManager` を書かない。
- 主体キー（開始時に控える・`save(data, for: id, subject:)`）は I-S5 で足す（I-S5 の補正 3）。本 slice の `save` は I-S3b1 の 2 引数のまま。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| ダウンロードの手順・二重実行の抑止・cancel・`downloadingIds`・`DownloadState` の導出 | application: `Podcast/Playback/OfflineDownloads.swift` |
| ファイルの実体の保存・有無・削除・容量 | application の `OfflineLibrary`（I-S3b1。変えない）→ port `AudioFileStore` → adapter `Podcast/Platform/AudioFileStore+Live.swift` |
| 失敗の文言 | presentation（I-S3b2 の facade） |

## 移行の中間状態
- 既存の production は変えない。facade の旧い手順（`download(podcast:)`・`removeDownload`・`downloadState(for:)`・`downloadingIds`）は I-S3b2 まで残る（I-S3b2 の補正 1）。
- 許可リスト（TP10）の増減: 無し。

## 変わる挙動
無い（production から呼ばれない）。

## 契約と検査
oracle は公開操作・状態・`OfflineLibrary` の状態（`MockFileManager` つきの `AudioCacheManager` から組んだ `AudioFileStore`）・gateway double の呼出列に限る。テスト名またはコメントに `verifies:` を持つ。

| ID | テスト | 内容 |
|---|---|---|
| TA-C-PB-20・TA-R-PB-8 | **T-TA-C-PB-20** | (a) 未保存 → `fetchEpisode` 1 回・`downloadAudio` 1 回・`library.has(id)` true・receipt `saved`。(b) 保存済み → 呼出 0・`alreadySaved`。(c) 実行中（`downloadAudio` を保留する double）に同じ id → `alreadyRunning`・`fetchEpisode` は合計 1 回。(d) 取り直しが `generating` / `failed` / `audioUrl` が URL にならない → `invalidSource`・`downloadAudio` 0 回・`has` false。(e) `fetchEpisode` が `ApiFailure` → `.api(f)`。(f) 保存の失敗（`FailingRemoveFileManager` 相当の書込失敗 double）→ `.store`・`has` false。(g) 各分岐の後 `downloadingIds` が空 |
| TA-C-PB-21 | **T-TA-C-PB-21** | `remove` の後 `has` false・`state` が `notDownloaded`。`removeAll` の後 `library.savedIds` が空。失敗は `.store` で、`savedIds` は実体と一致（I-S3b1 の T-T10 と同じ double） |
| TA-C-PB-22 | **T-TA-C-PB-22** | `downloadAudio` を保留する double で 2 件を開始 → `cancelAll()` がすぐ戻る（保留を解放する前に戻る）→ 解放後、`has` はどちらも false・`downloadingIds` が空・`download` は cancel の error を投げる（`.api` に変換しない） |
| TA-Q-PB-4 | **T-TA-Q-PB-4** | `state(for:)` の 3 値と優先順（downloading > downloaded）。`library.savedIds`・`library.usage()` は I-S3b1 の T-T10 のまま |
| TA-V6（PB のオフライン保存） | **T-TA-V6-PB-downloads** | `downloadingIds` の写しを取って書き換えても `state(for:)` が変わらない。`OfflineDownloads`・`OfflineLibrary` の公開する状態へ外から代入する文が無い（`private(set)`。静的には TA-V5） |
| TA-V8 | **T-TA-V8-PB-downloads** | `state(for:)` を呼んだ後、gateway double の呼出が 0 件（query は書き込む port を呼ばない）。`download` の戻り値を `let receipt: DownloadReceipt = try await …` の型注釈つきの代入で固定する |

## 完了条件
1. 上の契約テストが green。既存テストが全件 green で件数が減らない。
2. 既存の production を変えていない: `git diff --diff-filter=M --name-only origin/main -- NewsListenApp/NewsListenApp` が 0 行。追加した production が 1 本だけ: `git diff --diff-filter=A --name-only origin/main -- NewsListenApp/NewsListenApp` が**ちょうど 1 行**（コミット後に実行）。
3. 依存方向: `grep -rn "APIClient\|FailureMessages\|UIApplication\|Timer\|AudioCacheManager\|MockFileManager" NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift` が 0 件（コメントを含めて）。`grep -n "^import" 同ファイル` が `Foundation`・`Combine` の中。
4. 既存コードから呼んでいない: `grep -rnw "OfflineDownloads\|DownloadReceipt\|DownloadFailure" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift" | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件。
5. 型名の衝突が無い: `grep -rn "^enum DownloadState" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/PodcastViewModel.swift` の 1 行だけ（旧 VM。I-S3b2 で消す）。`grep -c "enum State: Equatable" NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift` → 1。`grep -c "typealias DownloadState" 同ファイル` → 0（typealias は I-S3b2 が足す）。
6. 状態の公開: `grep -c "@Published private(set) var downloadingIds" NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift` → 1、`grep -c "@Published" 同ファイル` → 1。
7. `ArchitectureOracleTests` が green（許可リストの増減なし。所属表で `Podcast/Playback/OfflineDownloads.swift` が application に当たる）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green（既存 ＋ 新規 T-TA-C-PB-20〜22・T-TA-Q-PB-4・T-TA-V6/V8）。
- 完了条件 2〜7 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- 実機・シミュレータの確認は本 slice では行えない（production から呼ばれない）。ダウンロードの目視は I-S3b2 の UV3 に含める。

## 禁止事項 / scope 外
- 既存の production を変えない。facade の `download` を差し替えない（I-S3b2）。`OfflineLibrary`・`AudioFileStore` の操作を変えない・増やさない（主体キーの引数と `reclaim` は I-S5）。
- 主体の固定（開始時の主体キー）・`bind(subject:)` を入れない（I-S5）。
- `OfflineDownloads` に一覧（`podcasts`）や `Episode` の保持を持たせない（一覧は Catalog。TP6 は facade）。
- 取り直しの失敗で保持 URL にフォールバックしない（SG-C4 は再生の規則）。
- `DownloadState` の値を増やさない。receipt に一覧や `Episode` を入れない（ADR-110 決定 5）。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 120 / 200）
- production ≈ 120 行（`OfflineDownloads.swift`）。
- test ≈ 200 行（`OfflineDownloadsTests.swift`。保留できる gateway double ≈ 30 を含む）。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: 完了条件 5 の入れ子の名前（`OfflineDownloads.State` と I-S3b2 の `typealias`）を TA Spec §5.1 の `DownloadState` の行に注記する。README の I-T3 行を完了へ。
