## iOS リファクタ I-T8: Learning の domain の型を取り出す（単語テスト・実績・進み・ストリーク・クイズ）

## 概要
学習の規則を通信のデータモデルと View から `Learning/Domain/` へ取り出す: ストリークの表示条件と「増えたか」の判定（`ListeningStreakStatus`）、週の進みの割合（`WeeklyProgress`）、実績のカタログと未表示の判定（`Achievement`・`AchievementCatalog`）、単語テストの状態機械（`VocabularyTest`。要素は `VocabularyTestWord`）と語の正規化、クイズの回答（`QuizAttempt`。全問回答と肯定の閾値 0.5）。**挙動は変えない**。application（取得・保存・音）は I-T9・I-T10。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.7（§5.7.1 の domain の行・§5.7.3 の TA-R-LE-1〜4・TA-R-LV-1・TA-R-LC-1・§5.7.4 の L-R の対応）・§7 TA-V3 の TA-R-LC-1・TA-R-LV-1・§8.2 の I-T8 行、導出 I-37。**検証モード（再設計しない）**。

応える要求: L-R01・L-R04・L-R06・L-R19（学習仕様 `docs/design/learning-engagement-spec.md`）、ADR-062・ADR-086・ADR-087・ADR-070、AQ-3・AQ-5（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-T2a と I-S3b3 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（TA Spec §8.1: 「I-T2a。I-S3b3 の後ならどこでもよい」。`QuizQuestion` が `Catalog/Domain/` にある。`QuizSheetView` が `NowPlaying` を受けている）。
- コマンドの実行場所: `ios/`。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| 単語テストの状態機械 | `Models/VocabularyModels.swift:80-245` `VocabularyTestStateMachine`（要素は通信のデータモデル `VocabularyTestItem`。`start` の `prefix(10)` は `:168`。送信用の `VocabularyTestResultItem` を自分で作る `resultPayload` `:146-155`。選択肢 `[item.meaning] + item.distractors.prefix(3)` `:190`） | `grep -n 'struct VocabularyTestStateMachine\|prefix\|resultPayload' NewsListenApp/NewsListenApp/Models/VocabularyModels.swift` |
| 語の正規化 | `Podcast/AudioPlayerView.swift:496-497` `normalizedTerm`（`trimmingCharacters(in: .whitespacesAndNewlines).lowercased()`） | `grep -n 'normalizedTerm' NewsListenApp/NewsListenApp/Podcast/AudioPlayerView.swift` |
| 週の進み | `Models/LearningEngagement.swift:70-73` `WeeklyGoal.progressFraction`（`progressText` `:66-68` は文言）。履歴の各週の割合 `Learning/LearningView.swift:196` | `grep -n 'progressFraction\|progressText' NewsListenApp/NewsListenApp --include='*.swift' -r` |
| 実績 | DTO `Achievement: Codable`（`Models/LearningEngagement.swift:77`。id と解錠日）、カタログ `AchievementCatalogItem.all`（`:113-143`。7 件）、未表示の判定 `AchievementCelebrationTracker.consumeNewlyUnlocked`（`:146-165`。`UserDefaults` を直接読み書き = I-T10 で移す） | `grep -n 'struct Achievement\|static let all\|AchievementCelebrationTracker' NewsListenApp/NewsListenApp/Models/LearningEngagement.swift` |
| ストリークの表示条件 | `DesignSystem/Components/DSStreakToolbar.swift:17-19`（`lastListenedDay != nil && currentStreakDays > 0`）・`Learning/LearningView.swift:112`。「増えたか」 `AppState.swift:377-381` | `grep -n 'lastListenedDay\|currentStreakDays > ' NewsListenApp/NewsListenApp --include='*.swift' -r` |
| クイズの規則 | `Podcast/QuizSheetView.swift:182`（`answers.count == selections.count`）・`:193`（`correctRate >= 0.5`） | `grep -n 'selections.count\|>= 0.5' NewsListenApp/NewsListenApp/Podcast/QuizSheetView.swift` |
| 名前の衝突 | domain の `Achievement`（TA Spec §5.7.1）と同名の通信のデータモデル `Achievement: Codable` がある | 同上 |
| 既存テスト | `VocabularyTestStateMachineTests` 4・`LearningEngagementModelTests` 7・`AppStateListeningStreakTests` 6 | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ）
**新規（production 5 本。TA Spec §8.2）**: `Learning/Domain/ListeningStreakStatus.swift`・`WeeklyProgress.swift`・`Achievement.swift`・`VocabularyTest.swift`・`QuizAttempt.swift`。
**新規（adapter。TA Spec §8.2「`Models/` の変換」）**: `Models/LearningEngagement+Domain.swift`（`ListeningStreak` → `ListeningStreakStatus`、`WeeklyGoal` → `WeeklyProgress`、`Achievement` の `Codable` 適合の extension）、`Models/VocabularyModels+Domain.swift`（`VocabularyTestItem` → `VocabularyTestWord`、`VocabularyTest` の結果 → `VocabularyTestResultItem`）。
**変更**: `Models/VocabularyModels.swift`（状態機械を外す）、`Models/LearningEngagement.swift`（`Achievement` の宣言・カタログ・`progressFraction` を外す。`AchievementCelebrationTracker` は判定を `Achievement.unseen(…)` に委ね、`UserDefaults` の読み書きだけを残す = I-T10 で消す）、使う側の型名の付け替え: `Learning/VocabularyTestViewModel.swift`・`Learning/VocabularyTestView.swift`・`Learning/LearningView.swift`・`DesignSystem/Components/DSStreakToolbar.swift`・`Podcast/QuizSheetView.swift`・`Podcast/AudioPlayerView.swift`（`normalizedTerm` を domain の関数に）・`AppState.swift`（「増えたか」を `ListeningStreakStatus` の判定に）。
**変更（test）**: `VocabularyTestStateMachineTests`（4）・`LearningEngagementModelTests`（7）・`AppStateListeningStreakTests`（6）（Given の置き換え。Then 不変）、`ArchitectureManifest.swift`（`domainTestFiles` に新しい domain のテストを足す）。**新規（test）**: `LearningDomainTests.swift`。

**対象外**: application（`VocabularyBook`・`VocabularyTesting`・`QuizGrading` = I-T9、`EngagementStore` = I-T10）、効果音・触覚・VoiceOver の置き場（I-T9・I-T10）、画面。

## 宣言（名前は TA Spec §5.7.1 のとおり）
```swift
// Learning/Domain/ListeningStreakStatus.swift
struct ListeningStreakStatus: Equatable { let days: Int; let listenedToday: Bool; let lastListenedDay: String?
    var isShown: Bool { get }                                              // TA-R-LE-1: lastListenedDay != nil && days > 0
    static func didIncrease(from previous: ListeningStreakStatus?, to next: ListeningStreakStatus) -> Bool }   // TA-R-LE-2: 初回（previous nil）は false
// Learning/Domain/WeeklyProgress.swift
struct WeeklyProgress: Equatable { let completed: Int; let goal: Int; var fraction: Double { get } }   // TA-R-LE-3: goal 0 で 0、[0, 1] に丸める
// Learning/Domain/Achievement.swift
struct Achievement: Equatable, Identifiable { let id: String; let unlockedAt: String }   // 通信のデータモデルの同名 struct を移す（Codable は Models/ の extension。I-T2a の葉の値型と同じ扱い）
struct AchievementCatalogItem: Equatable, Identifiable { let id: String; let name: String; let description: String }
enum AchievementCatalog { static let all: [AchievementCatalogItem]; static func unseen(_ unlocked: [Achievement], seenIds: Set<String>) -> [Achievement] }   // TA-R-LE-4（7 件）
// Learning/Domain/VocabularyTest.swift
struct VocabularyTestWord: Equatable, Identifiable { … }                 // VocabularyTestItem の field を写す
struct VocabularyTest { …（VocabularyTestStateMachine の Phase・Transition・RetestFeedback と操作をそのまま。要素は VocabularyTestWord） }   // TA-R-LV-1: 10 語まで・「まだ」だけ再確認・選択肢は意味と誤答 3（重複除去）
enum VocabularyTerm { static func normalize(_ term: String) -> String }    // TA-R-LV-2 の正規化（前後の空白を除き小文字）
// Learning/Domain/QuizAttempt.swift
struct QuizAttempt: Equatable { init(questionCount: Int); mutating func select(_ option: Int, for question: Int); var canSubmit: Bool { get }; var answers: [Int] { get }
    static func isPositive(correct: Int, total: Int) -> Bool }            // TA-R-LC-1: 全問回答で送信可・正答率 0.5 以上で肯定
```
- `Achievement` の field 名は通信のデータモデルの現行の名前に合わせる（移動であり、wire の key は `Models/` の extension の `CodingKeys` で保つ）。
- `VocabularyTest` は結果を domain の値（語の id と自己申告・再確認の結果）で返し、送信用の `VocabularyTestResultItem` への変換は `Models/VocabularyModels+Domain.swift`（`resultPayload` を adapter へ）。
- `QuizAttempt` の `select`・`mutating` は domain の値型の操作（リードモデルではないので TA-D9 の対象外）。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 学習の規則（表示条件・増えたか・割合・カタログ・未表示・単語テスト・正規化・クイズ） | domain: `Learning/Domain/` |
| 通信 ⇄ domain・送信用の形 | adapter: `Models/*+Domain.swift` |
| 文言（`progressText`・実績名の表示）・色・音 | presentation（音の置き場は I-T9・I-T10 まで現状のまま） |

## 移行の中間状態
| 経路 | owner | 導入 | 削除の条件（slice） |
|---|---|---|---|
| 既読の保存が `UserDefaults` を直接扱う（`AchievementCelebrationTracker`） | user | 既存 | I-T10 |
| 効果音・触覚が ViewModel と `AppState` にある | user | 既存 | I-T9（語彙・クイズ）・I-T10（継続） |

許可リスト（TP10）の増減: TA-V3 の TA-R-LV-1（`Models/VocabularyModels.swift:168` 1 行）を消す。TA-R-LC-1（`QuizSheetView.swift:193`）は本 slice で `QuizAttempt.isPositive` を呼ぶ形にして消す（TA Spec §7 は「I-T8・I-T9」）。TA-D2 は増えない（domain が `DTO` を知らない）。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト（`LearningDomainTests`。`domainTestFiles`） | 内容 |
|---|---|---|
| TA-R-LE-1・2 | **T-TA-R-LE-1・2** | `isShown` の 4 通り（日数 0・最後の日なし）。`didIncrease` は初回 false・同じ false・増えた true・減った false。`AppStateListeningStreakTests`（6）は Then 不変 |
| TA-R-LE-3 | **T-TA-R-LE-3** | goal 0・超過・負の値の丸め（現行 `progressFraction` と同値） |
| TA-R-LE-4 | **T-TA-R-LE-4** | カタログ 7 件の id。`unseen` は既読を除く。`LearningEngagementModelTests`（7）は Then 不変 |
| TA-R-LV-1 | `VocabularyTestStateMachineTests`（4）＋ **T-TA-R-LV-1** | 10 語で切る・「まだ」だけ再確認・選択肢の重複除去 |
| TA-R-LV-2（正規化） | **T-TA-R-LV-2-normalize** | `"  Apple\n"` → `"apple"` |
| TA-R-LC-1 | **T-TA-R-LC-1** | 未回答があると `canSubmit` false。0.5 ちょうどで肯定、0.49 で否定 |
| TA-V7 | `ArchitectureOracleTests` | 新しい domain のテストが `domainTestFiles` にあり 0 件 |
| TA-V6（LE・LV・LC の domain の型。新しい domain の型を作る slice が公開面の検査の対象を足す: TA Spec §7） | **T-TA-V6-LE-domain** | `VocabularyTest` に渡した出題の配列（`VocabularyTestWord` の列）を後から書き換えても、進行と次の出題が変わらない。`VocabularyTest`・`AchievementCatalog.unseen` が返した配列を書き換えても、次の読みが変わらない。`QuizAttempt.answers` の戻り値を書き換えても、`canSubmit` と次の `answers` が変わらない |

## 完了条件
1. 上のテストが green。既存テストが全件 green で、`VocabularyTestStateMachineTests` 4・`LearningEngagementModelTests` 7・`AppStateListeningStreakTests` 6 の件数が減らない。
2. 状態機械が domain に 1 つ: `grep -rn "struct VocabularyTestStateMachine" NewsListenApp --include='*.swift'` が 0 件、`grep -rn "^struct VocabularyTest\b\|^struct VocabularyTest " NewsListenApp/NewsListenApp --include='*.swift'` が `Learning/Domain/VocabularyTest.swift` の 1 行。
3. 規則の式が domain の 1 箇所: `grep -rn '>= 0.5' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が `Learning/Domain/QuizAttempt.swift` の 1 行。`grep -rn 'items.prefix(10)' NewsListenApp/NewsListenApp --include='*.swift'` が `Learning/Domain/VocabularyTest.swift` の 1 行。`grep -rn 'lowercased()' NewsListenApp/NewsListenApp/Podcast/AudioPlayerView.swift` が 0 件。`grep -rn 'currentStreakDays > 0\|lastListenedDay != nil' NewsListenApp/NewsListenApp --include='*.swift'` が `Learning/Domain/ListeningStreakStatus.swift` の行だけ。`grep -rn 'progressFraction' NewsListenApp --include='*.swift'` が 0 件。
4. domain が通信のデータモデルを知らない: `grep -rnw "VocabularyTestItem\|VocabularyTestResultItem\|LearningDashboard\|ListeningStreak\|WeeklyGoal\|Codable\|UserDefaults" NewsListenApp/NewsListenApp/Learning/Domain` が 0 件。`grep -rn "^import" NewsListenApp/NewsListenApp/Learning/Domain` が `Foundation` だけ。
5. `Achievement` の宣言が 1 箇所: `grep -rn "^struct Achievement\b\|^struct Achievement:" NewsListenApp/NewsListenApp --include='*.swift'` が `Learning/Domain/Achievement.swift` の 1 行。`grep -c "extension Achievement: Codable" NewsListenApp/NewsListenApp/Models/LearningEngagement+Domain.swift` → 1。
6. `ArchitectureOracleTests` が green で、TA-V3 の TA-R-LV-1・TA-R-LC-1 の許可リストが 0 行。`DTO` の集合から `Achievement` が抜ける（PR 説明に集合の数の前後）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜6 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- commit は型ごと（「ListeningStreakStatus」「WeeklyProgress」「Achievement とカタログ」「VocabularyTest と正規化」「QuizAttempt」「使う側の付け替え」「所属表」）。

## 禁止事項 / scope 外
- 取得・保存・送信の手順を動かさない（I-T9・I-T10）。音・触覚・VoiceOver の置き場を変えない。
- 実績のカタログ（7 件の id・名前・説明）、単語テストの上限・再確認の規則、閾値 0.5 を変えない。
- 「習得」の意味（TA Spec §10.4 の §6 の 1。判断待ち）を domain の語の名前に先取りしない（現行の名前のまま）。

## 種別
適用 slice。判断待ち（§10.4 の §6 の 1「習得」の意味）は iOS の slice を止めない（TA Spec §10.4）。

## 規模（見込み。TA Spec §8.1: 200 / 150）
- production ≈ 200 行（移動が主。domain 5 本 ≈ 230・変換 ≈ 50・`Models/` の削減 ≈ −150・使う側 ≈ 60）。test ≈ 150 行。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TA Spec §5.7.1 の domain の `Achievement` が通信のデータモデルの同名 struct と衝突する件は、I-T2a の葉の値型と同じ扱い（domain へ移し `Codable` を `Models/` の extension に）で解いたこと。README の I-T8 行を完了へ。
