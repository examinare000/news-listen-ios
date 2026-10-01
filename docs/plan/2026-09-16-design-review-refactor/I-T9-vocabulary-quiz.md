## iOS リファクタ I-T9: 語彙とクイズの application（View の `@State` と facade の中継を引き取る。TP7 を消す）

## 概要
語の登録と重複の抑止（`VocabularyBook`）、単語テストの出題と送信（`VocabularyTesting`）、クイズの送信と「機能なし」（404）の扱い（`QuizGrading`）を application に置く。`AudioPlayerView` の語彙の `@State`（登録済みの語・保存中の語・保存の失敗）と保存の手順、`QuizSheetView` の送信と採点の受け取り、facade（`PodcastViewModel`）の学習の中継 3 本（TP7）を引き取る。クイズの画面には `Learning/QuizViewModel.swift` を足す。効果音・触覚・VoiceOver の読み上げは presentation（ViewModel と View）が application の結果を見て行う。**画面の構成・文言・鳴る契機と種類は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.7（§5.7.1 の LV・LC の application・リードモデル、§5.7.2 の TA-Q-LV-1・2・TA-C-LV-1・2・TA-C-LC-1、§5.7.3 の TA-R-LV-2・TA-R-LC-2、port `LearningGateway`、整合性と失敗、効果音の置き場の段落）・§4 TA-D4（`QuizSheetView.swift:199` の `ApiFailure`）・§8.2 の I-T9 行・§8.4 TP7。**検証モード（再設計しない）**。

応える要求: L-R05・L-R09・L-R18・L-R19、ADR-069・ADR-070・ADR-087・ADR-088（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-S3b3 と I-T8 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（`VocabularyTest`・`QuizAttempt`・`VocabularyTerm.normalize` がある。`AudioPlayerView` が `NowPlaying` を受け、語彙の関数が `episodeId` を受けている = I-S3b3）。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Learning/Domain/QuizAttempt.swift`（rc=0）。
- `docs/trial-log/` を最初に読む（とくに `transcript-sync-highlight.md`。`AudioPlayerView` の `.task(id:)`・`.onDisappear` を変えない）。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測は revision `ef9e559`。I-S3b3・I-T8 の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| facade の中継（TP7） | `Podcast/PodcastViewModel.swift:460` `submitQuizAnswers`・`:465` `fetchSavedVocabulary`・`:470` `saveVocabulary`（通信のデータモデルを返す） | `grep -n 'func submitQuizAnswers\|func fetchSavedVocabulary\|func saveVocabulary' NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` |
| `AudioPlayerView` の語彙の状態と手順 | `@State` `registeredTerms`（`:60`）・`savingTerms`（`:62`）・`vocabularySaveError`（`:63`）、`loadSavedVocabulary`（`:545`）・`save`（`:555`。古い応答は今のエピソードと違えば捨てる `:547,562`） | `grep -n '@State\|func loadSavedVocabulary\|func save' NewsListenApp/NewsListenApp/Podcast/AudioPlayerView.swift` |
| `QuizSheetView` の送信 | `:179-204` `submitAnswers`（`DSFeedback.shared.play` `:193`・`catch ApiFailure.notFound(subject: .quiz)` `:199`）。`submit` closure を受ける | `sed -n 175,210p NewsListenApp/NewsListenApp/Podcast/QuizSheetView.swift` |
| `VocabularyTestViewModel` | 75 行。`import UIKit`（`:3`）・`apiClient`・`DSFeedback` `:39,42`・`UIAccessibility.post` `:46`・`load`・`assess`・`answerRetest`・`retrySubmission`・`restart`・`submit` | `grep -n 'import\|func \|DSFeedback\|UIAccessibility\|APIClient' NewsListenApp/NewsListenApp/Learning/VocabularyTestViewModel.swift` |
| Preview の `APIClient(` | `Learning/VocabularyTestView.swift:279,287`（`#if DEBUG`） | `grep -n 'APIClient(' NewsListenApp/NewsListenApp/Learning/VocabularyTestView.swift` |
| 既存テスト | `VocabularyTestStateMachineTests`（I-T8 の後）・`LearningEngagementAPIClientTests` 5。`VocabularyTestViewModel`・`QuizSheetView` の単体テストは無い（2026-10-01 実測） | `ls NewsListenApp/NewsListenAppTests \| grep -i 'vocab\|quiz'` |

## 対象（ios サブモジュールのみ）
**新規（production 5 本。TA Spec §8.2）**: `Learning/Application/VocabularyBook.swift`（リードモデル `VocabularyBookView`・`RegisteredTerms` と gateway の束 `LearningGateway` の宣言を含む = `portFiles`）、`Learning/Application/VocabularyTesting.swift`、`Learning/Application/QuizGrading.swift`（リードモデル `QuizGrade`）、`Learning/QuizViewModel.swift`（presentation）、`Networking/Gateways/LearningGateway+Live.swift`（adapter。I-T10 も同じファイルに closure を足す）。
**変更（production）**: `Podcast/AudioPlayerView.swift`（語彙の `@State` 3 つと保存の手順を外し、`VocabularyBook` の query と command を呼ぶ。画面のトグル `isVocabularyExpanded` 等は残す）、`Podcast/QuizSheetView.swift`（`QuizViewModel` を持ち、送信・採点・音を VM に。`ApiFailure` を書かない）、`Podcast/PodcastViewModel.swift`（中継 3 本を消す）、`Learning/VocabularyTestViewModel.swift`（`VocabularyTesting` を呼ぶ。`APIClient`・`import UIKit` を外す。音と VoiceOver の読み上げは View へ）、`Learning/VocabularyTestView.swift`（VM の結果を見て `DSFeedback` と `UIAccessibility.post` を行う。Preview は `#if DEBUG` の gateway の double で組む）、`NewsListenAppApp.swift`（gateway と use case を作って渡す）。
**変更（test）**: `ArchitectureManifest.swift`（`readModelFiles` は use case と同居のため入れず、完了条件 6 の grep で固定）。**新規（test）**: `VocabularyBookTests.swift`・`VocabularyTestingTests.swift`・`QuizGradingTests.swift`・`QuizViewModelTests.swift`・`VocabularyTestViewModelTests.swift`（移す前の特性を先に固定する。下の手順 1）。

**対象外**: 画面の構成・文言、学習ダッシュボード（I-T10。`LearningViewModel` の `fetchVocabulary`・`fetchVocabularyTestSession` の呼出は I-T10 が `VocabularyBook.book()`・`VocabularyTesting.due()` に付け替える）、ストリーク・実績（I-T10）、`AudioPlayerView` のトランスクリプト同期。

## 宣言（名前は TA Spec §5.7 のとおり）
```swift
// Learning/Application/VocabularyBook.swift
struct LearningGateway { let fetchVocabulary: …; let saveVocabulary: (String, String) async throws -> Void; let fetchTestSession: …; let submitTestResult: …; let submitQuiz: (String, [Int]) async throws -> QuizGrade; …（I-T10 が fetchDashboard・fetchStreak を足す） }
struct VocabularyBookView: Equatable { let count: Int; let firstTerms: [String] }      // 語数・先頭 5 語
struct RegisteredTerms: Equatable { let episodeId: String; let terms: Set<String> }   // 正規化済みの語
enum VocabularySaveReceipt: Equatable { case saved, alreadySaved, alreadySaving }
@MainActor final class VocabularyBook: ObservableObject {
    @Published private(set) var savingTerms: Set<String>
    func book() async throws -> VocabularyBookView                                     // TA-Q-LV-1
    func registeredTerms(episodeId: String) async throws -> RegisteredTerms           // TA-Q-LV-1
    func save(episodeId: String, term: String) async throws -> VocabularySaveReceipt  // TA-C-LV-1（TA-R-LV-2: 正規化した語で重複を判定）
}
// Learning/Application/VocabularyTesting.swift
@MainActor final class VocabularyTesting { func due() async throws -> (words: [VocabularyTestWord], dueCount: Int); func submit(_ test: VocabularyTest) async throws }   // TA-Q-LV-2・TA-C-LV-2
// Learning/Application/QuizGrading.swift
struct QuizGrade: Equatable { let correctCount: Int; let total: Int; let perQuestion: [Bool]; let isPositive: Bool }
enum QuizGradingResult: Equatable { case graded(QuizGrade), unavailable }         // TA-C-LC-1（404 の主語が quiz なら unavailable。TA-R-LC-2）
@MainActor final class QuizGrading { func submit(episodeId: String, attempt: QuizAttempt) async throws -> QuizGradingResult }
```
- 「古い応答は今のエピソードと違えば捨てる」（TA-R-LV-2 の後半）は View の表示の都合なので、`registeredTerms(episodeId:)` の戻り値の `episodeId` と現在の `nowPlaying()?.episodeId` を View が比べる（現行 `AudioPlayerView.swift:547,562` と同じ判定。application は結果に id を付けて返す）。
- `VocabularyTesting.due()` は `GET /vocabulary/test-session` で、サーバー側の間引きがある読み取り（TA Spec §5.7.2。query として扱う）。
- `QuizViewModel` は `QuizAttempt` の選択の状態と送信中・結果・文言を持ち、送信の結果で `DSFeedback.shared.play(grade.isPositive ? .correct : .incorrect)` を鳴らす（現行と同じ契機と種類）。`unavailable` は現行どおりクイズを隠す。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 語の重複の抑止・保存中の語・出題と送信・クイズの送信と 404 の意味 | application: `Learning/Application/` |
| 単語テストの状態・正規化・クイズの全問回答と閾値 | domain（I-T8） |
| 通信 ⇄ リードモデル | adapter: `Networking/Gateways/LearningGateway+Live.swift`・`Models/*+Domain.swift` |
| 効果音・触覚・VoiceOver・古い応答の破棄・文言 | presentation: View と `QuizViewModel`・`VocabularyTestViewModel` |

## 移行の中間状態
- **TP7 を消す**（facade の中継 3 本）。
- 許可リスト（TP10）の増減: TA-D4 の `ApiFailure`（`QuizSheetView.swift`）・`DTO`（`AudioPlayerView`・`QuizSheetView`・`VocabularyTestView` の分）、TA-D6 の `VocabularyTestViewModel` の `APIClient`・`UIFacility`（`DSFeedback`・`UIAccessibility`）・`import UIKit`、TA-D8 の `QuizSheetView.swift` の Preview 1 行（`Codable` の fixture を `#if DEBUG` の `QuizGrade` の値に置き換える）、TA-V3 の TA-R-LC-2（`QuizSheetView` 1）と TA-R-CT-1・2 の `QuizSheetView` 1（Preview の `"completed"`）を消す。`PodcastViewModel` の学習の分（`DTO`）も消す。

## 変わる挙動
無い。

## 手順（TDD 順序）
1. 特性テストを先に書く: `VocabularyTestViewModel` の現行の挙動（読み込み・自己申告・再確認・送信の失敗で回答を保持して再試行）を `MockURLSession` つき `APIClient` で固定する（現行は単体テストが無い）。
2. use case の契約テスト（RED）→ 実装（GREEN）。
3. View・VM の付け替え。特性テストが green のまま。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-C-LV-1・TA-R-LV-2 | **T-TA-C-LV-1**（`VocabularyBookTests`） | 同じ語（大文字・空白違い）の 2 回目は `alreadySaved`、保存中は `alreadySaving`。gateway の保存は 1 回。失敗は `ApiFailure` で `savingTerms` から外れる |
| TA-Q-LV-1・TA-V8 | **T-TA-Q-LV-1** | `book()` が語数と先頭 5 語。`registeredTerms` が正規化済み。どちらも書込 0 件 |
| TA-Q-LV-2・TA-C-LV-2 | **T-TA-Q-LV-2**・**T-TA-C-LV-2** | `due()` が最大 10 語と件数。送信の失敗は投げ、`VocabularyTest` は回答を保持（再試行できる） |
| TA-C-LC-1・TA-R-LC-2 | **T-TA-C-LC-1**（`QuizGradingTests`） | `graded` の正誤と `isPositive`。404 の主語が quiz なら `unavailable`、ほかの 404 は投げる |
| 音の契機 | **T-QuizViewModel**・**T-VocabularyTestViewModel** | 結果の値（肯定か・正誤）が VM の状態に出る。音は View が鳴らす（VM のテストは結果の値だけを見る） |
| TA-V6（LV・LC） | **T-TA-V6-LV** | 返した配列を書き換えても次の query が変わらない。`VocabularyTest` に渡した出題の配列を後から書き換えても進行が変わらない |

## 完了条件
1. 上のテストが green。既存テストが全件 green で件数が減らない。
2. TP7 が消えている: `grep -rn "func submitQuizAnswers\|func fetchSavedVocabulary\|func saveVocabulary" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` が 0 件。`grep -rnw "QuizAnswerResponse\|VocabularyListResponse\|VocabularyItem" NewsListenApp/NewsListenApp/Podcast` が 0 件。
3. View が `ApiFailure` を書かない: `grep -rn "ApiFailure" NewsListenApp/NewsListenApp/Podcast/QuizSheetView.swift NewsListenApp/NewsListenApp/Podcast/AudioPlayerView.swift` が 0 件（正の対照: 2026-10-01 実測 `QuizSheetView.swift:199` の 1 行）。
4. 語彙の `@State` が消えている: `grep -n "registeredTerms\|savingTerms\|vocabularySaveError" NewsListenApp/NewsListenApp/Podcast/AudioPlayerView.swift | grep "@State"` が 0 件。
5. `VocabularyTestViewModel` が通信と OS を知らない: `grep -n "APIClient\|import UIKit\|DSFeedback\|UIAccessibility" NewsListenApp/NewsListenApp/Learning/VocabularyTestViewModel.swift NewsListenApp/NewsListenApp/Learning/QuizViewModel.swift` が 0 件。`DSFeedback.shared.play(.correct)` 等の鳴らす文が `Learning/VocabularyTestView.swift`・`Podcast/QuizSheetView.swift` にある（契機が同じであることを PR 説明に前後の行で示す）。
6. リードモデル（`VocabularyBookView`・`RegisteredTerms`・`QuizGrade`）の本体に `var `・`class`・`mutating` が無い（I-T7c の完了条件 6 と同じ `sed` の形で 3 型とも 0）。
7. `ArchitectureOracleTests` が green で、上の「移行の中間状態」の許可リストの行が消えている（PR 説明に前後）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜7 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータの目視: プレイヤーの語彙の登録（2 回目は登録済み表示）・クイズの送信と正誤の音・クイズの無いエピソード・単語テストの正誤の音と VoiceOver の読み上げ。
- commit は「VocabularyTestViewModel の特性テスト」「VocabularyBook」「VocabularyTesting」「QuizGrading と QuizViewModel」「AudioPlayerView・QuizSheetView の付け替え」「TP7 の削除」「所属表」の単位。

## 禁止事項 / scope 外
- 画面の構成・文言・鳴る契機と種類を変えない。`AudioPlayerView` を分割しない。トランスクリプト同期（`.task(id:)`・`.onDisappear`）を変えない。
- application で音・触覚・VoiceOver を鳴らさない。
- 語の削除の導線を足さない（L-R05 の削除は無い）。
- `LearningViewModel` を変えない（I-T10）。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 250 / 300）
- production ≈ 250 行（use case 3 本 ≈ 150・`QuizViewModel` ≈ 50・gateway ≈ 40・View と VM の削減 ≈ −60・facade −20）。test ≈ 300 行（特性 ≈ 70 を含む）。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TP7 の削除（TA Spec §8.4）。再生 Spec §6「保留 views」の `QuizSheetView` の採点 VM 化が完了したこと。README の I-T9 行を完了へ。
