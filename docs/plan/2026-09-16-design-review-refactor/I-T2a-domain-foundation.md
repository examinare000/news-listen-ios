## iOS リファクタ I-T2a: 再生と Catalog の domain の土台（`Episode`・`EpisodeContent`・generic な `PlaybackQueue`・`ApiFailure` の置き場・通信 → domain の変換）

## 概要
I-S3b1 が使う domain の型を先に入れる。Catalog の `Episode`（3 種別）と `EpisodeContent`（葉の値型 4 つと表示の規則）、推定タイミングの入力 `TranscriptSource`、再生の `PlaybackQueue<Item>`（generic 化）と `PlaybackConstants` の移動、失敗の意味 `ApiFailure` の `Shared/Domain/` への移動、通信のデータモデル `Podcast` から `Episode` への変換 `toEpisode()`（T-T11 の 20 通り）。**挙動は変えない**。旧 `PodcastViewModel` は `PlaybackQueue<Podcast>` を使い続ける（TP9）。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.1（TA-M-PB の domain 行・変換行）・§5.2（TA-M-CT・TA-R-CT-1・3・4・5）・§5.10（`ApiFailure` の置き場）・§8.2 の I-T2a 行・§8.4 TP9、再生 Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §3.2（`Episode` の固有の値）・§4 CI-T11、I-S3b1 の order の T-T11 の表（20 通り。判別の規則はそのまま）、ADR-092（推定タイミングの差し替え点）。導出 I-24・I-40（TA Spec §10.1）。**検証モード（再設計しない）**。

応える要求: `F-POD-01`・`F-POD-07`（TA Spec §2）、AQ-1・AQ-3（TA Spec §9.2）、共有仕様 §6.6 PS-07 の前提（判別の規則の置き場）、CI-T11。

## 前提・着手条件
- 依存: **I-T1 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（親で `git submodule status` の `ios` 行に `+` が無い）。`ArchitectureOracleTests` が green で、許可リスト（TP10）が実測で固定されている。
- コマンドの実行場所: すべて `ios/` で実行する。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift`（rc=0）で I-T1 の成果を確かめる。
- I-T2b と順序を問わない（対象のファイルが重ならない。TA Spec §8.1）。
- `docs/trial-log/` を最初に読む。棄却済み（再提案しない）: `PlaybackQueue` の failable init、`Episode.decode` を domain の static に置く案（TA Spec §10.2: 変換は adapter）、`Codable` を domain の型に付けたままにする案（TA-D1）。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| 葉の値型 4 つの宣言 | `Models/Podcast.swift:11` `TranscriptSegment: Codable`、`:24` `PodcastSourceArticle: Codable`、`Models/QuizQuestion.swift:13` `QuizQuestion: Codable`、`Models/VocabularyEntry.swift:11` `VocabularyEntry: Codable` | `grep -rn 'struct TranscriptSegment\|struct VocabularyEntry\|struct QuizQuestion\|struct PodcastSourceArticle' NewsListenApp/NewsListenApp` |
| `Podcast` の表示の規則 | `Models/Podcast.swift:153` `displayTitle`、`:162` `hasTranscript`、`:168` `hasVocabulary`、`:174` `hasQuiz`、`:180` `hasSourceArticles`、`:189` `showsCcBySaLicense`（`== "featured"` は `:190`）、`:42` `linkURL` | `grep -n 'displayTitle\|hasTranscript\|hasVocabulary\|hasQuiz\|hasSourceArticles\|showsCcBySaLicense\|linkURL\|== "featured"' NewsListenApp/NewsListenApp/Models/Podcast.swift` |
| `Podcast` の custom `init(from:)` は extension（memberwise init を残す） | `Models/Podcast.swift:115-121` | `grep -n 'init' NewsListenApp/NewsListenApp/Models/Podcast.swift` |
| `PlaybackQueue` の `Podcast` の参照（コメント行を除く） | 10 行（`Podcast/PlaybackQueue.swift:17,21,31,37,47,53,59,65,86,131`） | `grep -nw 'Podcast' NewsListenApp/NewsListenApp/Podcast/PlaybackQueue.swift \| grep -v '^[0-9]*:[[:space:]]*//'`（単一ファイルの `grep -n` は行頭が `行番号:` なので、コメント行の除外はこの形。doc コメント 2 行（`:14,30`）を含めると 12） |
| `PlaybackQueue(` の出現 | test 44・production 2 | `grep -rho 'PlaybackQueue(' NewsListenApp/NewsListenAppTests \| wc -l`、`… NewsListenApp/NewsListenApp \| wc -l` |
| `TranscriptTiming.swift` の `Podcast` の参照 | 2 行（`:20,37`） | `grep -nw 'Podcast' NewsListenApp/NewsListenApp/Podcast/TranscriptTiming.swift \| grep -v '^[0-9]*:[[:space:]]*//'` |
| `ApiFailure`・`NotFoundSubject` の宣言 | `Networking/APIClient.swift:23-43`（10 case） | `grep -n 'enum ApiFailure\|enum NotFoundSubject' NewsListenApp/NewsListenApp/Networking/APIClient.swift` |
| 既存テストの件数 | `ModelTests` 50・`TranscriptTimingTests` 13・`PlaybackQueueTests` 12・`PlaybackQueueConformanceTests` 32・`PodcastViewModelTests` 72 | `grep -c 'func test' NewsListenApp/NewsListenAppTests/<各ファイル>` |
| `DTO` の集合（I-T1 の検査が数える） | 43 | `ArchitectureOracleTests` の T-TA-V2b が出す |

## 対象（ios サブモジュールのみ）
**新規ファイル（production 4 本）と、移動するファイル 1 本**（下の表の 5 行。`Catalog/Domain/TranscriptTiming.swift` は `Podcast/TranscriptTiming.swift` の**移動**で、`git diff -M` では rename の 1 行に数える。`ApiFailure.swift`・`EpisodeContent.swift` は宣言を既存のファイルから移すが、ファイルとしては新規）

| ファイル | 層 | 中身 |
|---|---|---|
| `Shared/Domain/ApiFailure.swift` | domain | `ApiFailure`（10 case）・`NotFoundSubject`（`Networking/APIClient.swift:23-43` から**移動**。case の名前・数・`Equatable` は不変） |
| `Catalog/Domain/Episode.swift` | domain | `Episode`・`PlayableEpisode`・`GeneratingEpisode`・`FailedEpisode`（下の宣言） |
| `Catalog/Domain/EpisodeContent.swift` | domain | `EpisodeContent`・葉の値型 `TranscriptSegment`・`VocabularyEntry`・`QuizQuestion`・`PodcastSourceArticle`（`Models/` から**移動**。`Codable` 適合を外す）・規則 TA-R-CT-3・TA-R-CT-5 |
| `Catalog/Domain/TranscriptTiming.swift` | domain | `Podcast/TranscriptTiming.swift` を**移動**。入力を `TranscriptSource` にする（TA-R-CT-4） |
| `Models/Podcast+Episode.swift` | adapter | `Podcast.toEpisode()`（TA-R-CT-1）、葉の値型 4 つの `Codable` 適合の extension、推定タイミングの移行用の入口 `Podcast.transcriptSource`（I-S3b3 で消す） |

**移動（production 3 本）**: 上の表の `Podcast/TranscriptTiming.swift` → `Catalog/Domain/TranscriptTiming.swift`、`Podcast/PlaybackQueue.swift` → `Podcast/Playback/Domain/PlaybackQueue.swift`（generic 化）、`Podcast/PlaybackConstants.swift` → `Podcast/Playback/Domain/PlaybackConstants.swift`（中身は不変）。

**変更（production 5 本）**: `Models/Podcast.swift`（葉の値型 2 つの宣言を外す。`displayTitle` 等の 6 規則を `EpisodeContent` を呼ぶ形にする）、`Models/VocabularyEntry.swift`・`Models/QuizQuestion.swift`（葉の値型の宣言を外す。`QuizGradeResult`・`QuizAnswerResponse` は残る）、`Networking/APIClient.swift`（`ApiFailure`・`NotFoundSubject` の宣言を外す。参照は同じ module なので import は要らない）、`Podcast/PodcastViewModel.swift`（`PlaybackQueue` の型注釈を `PlaybackQueue<Podcast>` にする。それ以外は変えない）。

**変更（test）**: `ArchitectureManifest.swift`（所属表の明示の行から `Podcast/PlaybackQueue.swift`・`Podcast/PlaybackConstants.swift`・`Podcast/TranscriptTiming.swift` を消す。`domainTestFiles` に `EpisodeTests.swift`・`EpisodeContentTests.swift` を足す。許可リストから TA-D2 の `PlaybackQueue` 10・`TranscriptTiming` 2 を消す）、`TranscriptTimingTests.swift`（Given を `TranscriptSource` に置き換える。Then 不変）、`PlaybackQueueTests.swift`・`PlaybackQueueConformanceTests.swift`（`PlaybackQueue()` に型引数 `<Podcast>` を足す。Then 不変）、`ModelTests.swift`（Then 不変）。**新規（test）**: `EpisodeTests.swift`（T-T11 の 20 通り）・`EpisodeContentTests.swift`（TA-R-CT-3・5）。

**対象外**: Coordinator・Session（I-S3b1）、View の読出（`PodcastRowView` 等は `Podcast` を受け続ける = TP6）、`Podcast` の `CodingKeys`（不変）、`NowPlayingCenter`（I-T2b）、`Models/FeaturedCategory.swift`（I-T7b）。

## 宣言（型・操作。ここに無い公開メンバーを足さない）
```swift
// Catalog/Domain/EpisodeContent.swift
struct TranscriptSegment: Equatable { let speaker: String; let text: String; var role: String? = nil }   // field は現行のまま（`role` の既定値も。memberwise init `(speaker:text:)` を保つ）
struct VocabularyEntry: Equatable { … }                                           // field は現行のまま
struct QuizQuestion: Equatable { … }                                              // field は現行のまま
struct PodcastSourceArticle: Equatable { …; var linkURL: URL? { get } }           // TA-R-CT-5（http / https だけ）
struct EpisodeContent: Equatable {
    let id: String; let title: String; let japaneseIntroText: String; let difficulty: String
    let createdAt: String; let durationSeconds: Int
    let segments: [TranscriptSegment]?; let vocabulary: [VocabularyEntry]?; let quiz: [QuizQuestion]?
    let sourceArticles: [PodcastSourceArticle]?; let sourceKind: String?
    var displayTitle: String { get }          // TA-R-CT-3: 題が空ならイントロ、それも空なら既定の文言（現行 Podcast.displayTitle と同値）
    var hasTranscript: Bool { get }; var hasVocabulary: Bool { get }; var hasQuiz: Bool { get }
    var hasSourceArticles: Bool { get }       // 空の配列は無し
    var showsCcBySaLicense: Bool { get }      // sourceKind == "featured" の完全一致
}
// Catalog/Domain/Episode.swift
struct PlayableEpisode: Equatable { let content: EpisodeContent; let audioUrl: String; let serverPosition: Double }
struct GeneratingEpisode: Equatable { let content: EpisodeContent }
struct FailedEpisode: Equatable { let content: EpisodeContent; let reportedMessage: String? }
enum Episode: Equatable, Identifiable {
    case playable(PlayableEpisode), generating(GeneratingEpisode), failed(FailedEpisode)
    var content: EpisodeContent { get }; var id: String { get }; var isPlayable: Bool { get }   // `Identifiable` に適合する（`PlaybackQueue<Episode>` の要素にするため）
}
// Catalog/Domain/TranscriptTiming.swift
struct TranscriptSource: Equatable { let introText: String; let segments: [TranscriptSegment]?; let durationSeconds: Int }
protocol TranscriptTimingProviding { … }   // 現行と同じ操作。引数の Podcast を TranscriptSource に
struct EstimatedTranscriptTiming: TranscriptTimingProviding { … }
// Podcast/Playback/Domain/PlaybackQueue.swift
struct PlaybackQueue<Item: Identifiable> where Item.ID == String { … }   // 操作 9 個の名前と意味は不変。現行の `PlaybackQueue` は `Equatable` に適合しておらず、`Podcast` も `Equatable` でないので、制約に `Equatable` を足さない（`extension PlaybackQueue: Equatable where Item: Equatable` だけを足す。I-S3b1 の `@Published` の `PlaybackQueue<Episode>` の比較に使う）
// Models/Podcast+Episode.swift（adapter）
extension Podcast { func toEpisode() -> Episode; var transcriptSource: TranscriptSource { get } }   // transcriptSource は移行用（I-S3b3 で消す）
extension TranscriptSegment: Codable {}; extension VocabularyEntry: Codable {}; extension QuizQuestion: Codable {}; extension PodcastSourceArticle: Codable {}
```
- `toEpisode()` の判別は I-S3b1 の order の T-T11 の表（20 通り）そのまま: `completed` かつ `audioUrl` 非空 かつ `errorMessage` なし → `playable`（`serverPosition` = `playbackPositionSeconds`）。`processing` → `generating`。それ以外（`failed`・`partial_failed`・未知・矛盾）→ `failed`。`FailedEpisode.reportedMessage` は `podcast.errorMessage`（無ければ `nil`。I-S3b1 の旧宣言の `"inconsistent"` は作らない。TA Spec §5.2「読み上げ値を現行どおりに保つ」）。
- `EpisodeContent.displayTitle` 等の 6 規則の式は、現行 `Models/Podcast.swift:153-191` を移す。`Podcast` 側の同名の computed は **`toEpisode().content.<同名>` を返すだけ**にする（規則の式は 1 箇所。TA-V3 の `== "featured"` が `Models/Podcast.swift` から消える）。
- 葉の値型の `Codable` 適合は `Models/Podcast+Episode.swift` の extension に**手で書く**（別ファイルの extension では合成されない。TA Spec §5.2）。`CodingKeys` が要る型は現行のキー名をそのまま書く。
- `PlaybackQueue<Item>` は、状態 `items: [Item]`・`currentIndex: Int?`・派生値 `current`・`upNext`・`isEmpty` と、現行の操作 9 個（`init(items:currentIndex:)`・`start(with:)`・`setQueue(_:startAt:)`・`add`・`playNext`・`jump(to:)`・`advance`・`remove(id:)`・`reorderUpNext(fromOffsets:toOffset:)`。2026-10-01 実測 `Podcast/PlaybackQueue.swift:17-131`。private の `applyMove` を含めない）を generic にするだけ。重複 id の除去は入れない（I-S3b2）。`reorderUpNext` を rename しない。
- `ApiFailure` は `Networking/APIClient.swift` の 10 case・`Equatable`・doc コメントごと移す。HTTP status → `ApiFailure` の写像（`APIClient.swift:581-618`）は adapter に残る（CI-T12 不変）。

## 変更の責務（何をどの層へ）
| 責務 | 層・置き場 |
|---|---|
| エピソードの種別の意味と、表示の規則（TA-R-CT-3・5）、推定タイミング（TA-R-CT-4） | domain: `Catalog/Domain/` |
| 順序と現在位置（キュー）・速度の値域 | domain: `Podcast/Playback/Domain/` |
| 失敗の意味の型 | domain（共有）: `Shared/Domain/ApiFailure.swift` |
| 通信の形の判別（TA-R-CT-1）と、通信 → domain の変換、葉の値型の `Codable` | adapter: `Models/Podcast+Episode.swift` |

## 移行の中間状態
| 経路 | owner | 導入 | 削除の条件（slice） |
|---|---|---|---|
| TP9: 旧 `PodcastViewModel` が `PlaybackQueue<Podcast>` を使う | user | 本 slice | I-S3b2（production から `PlaybackQueue<Podcast>` が無くなる） |
| `Podcast.displayTitle` 等の 6 computed が `toEpisode().content` を呼ぶだけの形で残る | user | 本 slice | I-T4（View が `EpisodeRow`・`NowPlaying` を読むようになった時。`Models/Podcast.swift` から消す） |
| `Podcast.transcriptSource`（推定タイミングの移行用の入口） | user | 本 slice | I-S3b3（`AudioPlayerView` が `NowPlaying` から `TranscriptSource` を組む） |

許可リスト（TP10）の増減: TA-D2 の `Podcast/PlaybackQueue.swift` 10・`Podcast/TranscriptTiming.swift` 2 を消す（残りは `Models/FeaturedCategory.swift` 2 だけ）。ほかの規則の行数は増やさない。

## 変わる挙動
無い。`toEpisode()` は新しい型を作るだけで、現行の画面の分岐（`status` の文字列）はそのまま残る（PS-07 が変わるのは I-S3b2）。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| CI-T11 | **T-T11**（`EpisodeTests.swift`。テスト名またはコメントに `verifies: CI-T11`） | I-S3b1 の order の表の 20 通り（`playable` 1・`generating` 4・`failed` 15）。`FailedEpisode.reportedMessage` は DTO の `errorMessage`（nil なら nil）。`content` が 3 種別とも DTO の 11 field を写す |
| TA-R-CT-3・5 | **T-TA-R-CT-3**・**T-TA-R-CT-5**（`EpisodeContentTests.swift`） | `displayTitle`（題あり／題空でイントロ／両方空で既定文言）、`has*` 4 つ（nil・空・非空）、`showsCcBySaLicense`（`featured` だけ true。`user`・`unknown`・nil・大文字違い・空は false）、`linkURL`（`http`・`https` だけ。`ftp`・空は nil）。現行 `ModelTests` の同名テストの Then と同値 |
| TA-R-CT-4 | `TranscriptTimingTests`（13） | Given を `TranscriptSource` に置き換え、Then 不変 |
| Q-01〜Q-32 | `PlaybackQueueConformanceTests`（32）・`PlaybackQueueTests`（12） | 型引数を足すだけで Then 不変 |
| TA-V1・V2・V7 | `ArchitectureOracleTests` | 所属表の更新後に green。TA-D2 の許可リストが `Models/FeaturedCategory.swift` 2 だけ。`domainTestFiles` が 5 本（`TranscriptTimingTests`・`PlaybackQueueTests`・`PlaybackQueueConformanceTests`・`EpisodeTests`・`EpisodeContentTests`）で TA-V7 が 0 件。`DTO` の集合が 39 個（43 − 葉の値型 4） |
| TA-V11 | 既存の全テスト | `ModelTests`（50）は Then 不変で green（葉の値型の手書き `Codable` が自動合成と同じ結果。TA Spec §11） |
| TA-V6（CT・PB の domain の型。新しい domain の型を作る slice が公開面の検査の対象を足す: TA Spec §7） | **T-TA-V6-CT-domain**（`EpisodeTests`）・**T-TA-V6-PB-queue**（`PlaybackQueueTests`） | `toEpisode()` に渡した `Podcast` の `segments`・`vocabulary`・`quiz`・`sourceArticles` を、変換の後で書き換えても、作った `Episode.content` の値が変わらない。`PlaybackQueue<Item>` の生成と操作に渡した配列を後から書き換えても、キューの中身と不変条件（INV-Q）が変わらない。キューが返した配列を書き換えても、次の読みが変わらない（値型の言語の保証に頼らず、実行時に確かめる） |

## 完了条件
1. T-T11（20）・T-TA-R-CT-3・T-TA-R-CT-5 が green。既存テストが全件 green で、`ModelTests` 50・`TranscriptTimingTests` 13・`PlaybackQueueTests` 12・`PlaybackQueueConformanceTests` 32・`PodcastViewModelTests` 72 の件数が減らない。
2. 変更した production が、上の「対象」の 12 本（新規 4・移動 3・変更 5）だけ: `git diff --name-only -M origin/main -- NewsListenApp/NewsListenApp` が 12 行（移動は `-M` で 1 行に数える。新規 = `Shared/Domain/ApiFailure.swift`・`Catalog/Domain/Episode.swift`・`Catalog/Domain/EpisodeContent.swift`・`Models/Podcast+Episode.swift`、移動 = `TranscriptTiming.swift`・`PlaybackQueue.swift`・`PlaybackConstants.swift`、変更 = `Models/Podcast.swift`・`Models/VocabularyEntry.swift`・`Models/QuizQuestion.swift`・`Networking/APIClient.swift`・`Podcast/PodcastViewModel.swift`）。`git diff --stat -M` の最終行の「files changed」の数も 12。2026-10-01 の実測（ios main `ef9e559`）: 移動元・変更対象の 8 本は在り（`Podcast/PlaybackQueue.swift` 143 行・`Podcast/PlaybackConstants.swift` 20・`Podcast/TranscriptTiming.swift` 90・`Models/Podcast.swift` 214・`Models/VocabularyEntry.swift` 24・`Models/QuizQuestion.swift` 46・`Networking/APIClient.swift` 619・`Podcast/PodcastViewModel.swift` 698）、新規・移動先の 5 本は無い（`for f in …; do test -e NewsListenApp/NewsListenApp/$f && wc -l < …; done`）。Xcode の project は `PBXFileSystemSynchronizedRootGroup`（`grep -c '\.swift' NewsListenApp/NewsListenApp.xcodeproj/project.pbxproj` = 0）なので、ファイルの追加と移動で `project.pbxproj` は変わらない。
3. `ApiFailure` の宣言が 1 箇所: `grep -rn "^enum ApiFailure\|^enum NotFoundSubject" NewsListenApp/NewsListenApp --include='*.swift'` が `Shared/Domain/ApiFailure.swift` の 2 行だけ。
4. 葉の値型の宣言が domain に 1 箇所ずつ: `grep -rn "^struct \(TranscriptSegment\|VocabularyEntry\|QuizQuestion\|PodcastSourceArticle\)\b" NewsListenApp/NewsListenApp --include='*.swift'` が `Catalog/Domain/EpisodeContent.swift` の 4 行だけで、その 4 行に `Codable`・`Decodable`・`Encodable` が無い。`grep -c "extension \(TranscriptSegment\|VocabularyEntry\|QuizQuestion\|PodcastSourceArticle\): Codable" NewsListenApp/NewsListenApp/Models/Podcast+Episode.swift` → 4。
5. 規則の正本が 1 箇所: `grep -rn '== "featured"' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が `Catalog/Domain/EpisodeContent.swift` の 1 行だけ（2026-10-01 実測: `Models/Podcast.swift:190` の 1 行）。
6. domain が通信のデータモデルを知らない: `grep -rnw "Podcast\|Codable\|Decodable\|Encodable\|CodingKey" NewsListenApp/NewsListenApp/Catalog/Domain NewsListenApp/NewsListenApp/Podcast/Playback/Domain NewsListenApp/NewsListenApp/Shared/Domain | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件。`grep -rn "^import" 同 3 ディレクトリ` が `Foundation` だけ。
7. TP9: `grep -rn "PlaybackQueue<Podcast>" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/PodcastViewModel.swift` の 2 行（2026-10-01 実測の `PlaybackQueue()` の 2 箇所 `:57,694` に型引数を足したもの）。`grep -rn "PlaybackQueue(" NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件（production に型引数の無い生成が無い）。
8. 移動元が無い: `test ! -e NewsListenApp/NewsListenApp/Podcast/PlaybackQueue.swift && test ! -e NewsListenApp/NewsListenApp/Podcast/PlaybackConstants.swift && test ! -e NewsListenApp/NewsListenApp/Podcast/TranscriptTiming.swift`（rc=0）。
9. `ArchitectureOracleTests` が green で、許可リストの TA-D2 が `("TA-D2", "Models/FeaturedCategory.swift", 2)` の 1 行だけ。`ArchitectureManifest.swift` の所属表に `Podcast/PlaybackQueue.swift`・`Podcast/PlaybackConstants.swift`・`Podcast/TranscriptTiming.swift` の明示の行が無い（`grep -c` → 0）。
10. `PlaybackQueue(` の型引数の追加: test の `PlaybackQueue<Podcast>(` が 44 件（前提点検の値と同数。増減があれば PR 説明に理由を書く）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green（既存 661 ＋ I-T1 の分 ＋ 新規）。
- 完了条件 2〜10 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。正の対照: 完了条件 5 の grep をコメント除外なしで走らせると `Models/Podcast.swift:185`（doc コメント）が出る。
- commit は「ApiFailure の移動」「葉の値型と EpisodeContent」「Episode と toEpisode（T-T11）」「TranscriptTiming の移動」「PlaybackQueue の generic 化と移動」「所属表の更新」の単位。

## 禁止事項 / scope 外
- Coordinator・Session・`NowPlaying`・`QueueEntry` を作らない（I-S3b1）。View・行 View を変えない（TP6）。`PodcastViewModel` は型注釈 1 箇所以外を変えない。
- `PlaybackQueue` の操作を足さない・重複除去を入れない（I-S3b2）。`reorderUpNext` を rename しない。
- `Podcast` の `CodingKeys`・field 名・`APIClient` の公開メソッド・HTTP の形を変えない。`ApiFailure` の case を増減しない。
- `FailedEpisode` に `"inconsistent"` の既定文言を持たせない（I-S3b1 の旧宣言。TA Spec §5.2 で改めた）。
- `Episode.decode(_:)`（domain の static）を作らない。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 250 / 250。2026-10-01 実測の基点: `Models/Podcast.swift` 214・`PlaybackQueue.swift` 143・`TranscriptTiming.swift` 90・`APIClient.swift` 619）
- production ≈ 250 行: `EpisodeContent.swift` ≈ 90（移動を含む）・`Episode.swift` ≈ 40・`Podcast+Episode.swift` ≈ 70・`ApiFailure.swift` ≈ 30（移動）・`PlaybackQueue.swift` の generic 化 ≈ 15・`TranscriptTiming.swift` ≈ 10・`Models/*.swift` −60・`APIClient.swift` −25。
- test ≈ 250 行: `EpisodeTests` ≈ 80・`EpisodeContentTests` ≈ 60・`TranscriptTimingTests` の Given ≈ 30・`PlaybackQueue*Tests` の型引数 44 箇所 ≈ 44・`ArchitectureManifest` ≈ 10。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: `DTO` の集合が 39 個になったこと（TA Spec §4 の表）。TA Spec §11「葉の値型 4 つの `Codable` 適合を手で書いたとき自動合成と同じ結果になる」を確認済みへ。`PlaybackQueue(` 44 箇所の実測（同 §11）。README の I-T2a 行を完了へ。
