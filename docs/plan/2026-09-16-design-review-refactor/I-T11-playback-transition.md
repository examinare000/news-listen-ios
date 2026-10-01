## iOS リファクタ I-T11: 再生の遷移の決定を domain の純関数へ取り出す（TP8 を消す）

## 概要
I-S3b1 が `PlaybackSession`（application）に入れた「状態と入力から、次の状態・engine への指示・通知を決める」部分を、domain の純関数 `PlaybackTransition` に取り出す。`PlaybackSession` は決定を純関数に委ね、engine への指示と通知の発行と購読 Task の管理だけを行う。**再生 Spec §3.6 の表（操作 × 状態、事象 × 状態、16 辺）と `PlaybackSession` の公開面は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.1（TA-M-PB の「遷移の決定」の行・TA-R-PB-1）・§8.2 の I-T11 行・§8.4 TP8・§11「残る危険」の 3 つ目、導出 I-39、再生 Spec §3.6.2・§3.6.3（表）と I-S3b1 の order の「操作 × 状態」「engine の事象 × 状態」「分母 16 の辺」の 3 表。**検証モード（再設計しない）**。

応える要求: AQ-3（規則の正本が 1 箇所。TA Spec §9.2）、`architecture.md` §4.1（状態の遷移は domain の関数が行う）。

## 前提・着手条件
- 依存: **I-S3b3 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**。ほかの slice と並行可（`Podcast/Playback/PlaybackSession.swift` を触る slice は本 slice だけ。I-S3c は保留）。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackSession.swift`（rc=0）。
- 確定済み（再提案しない）: SG-C24（`stop` は表の外）・SG-C52（`fail` は表の外）・SG-C39・C40・C44・SG-C58・SG-C66・SG-C71、導出 I-1〜I-5・I-15・I-21・I-22・I-29・I-32（I-S3b1 の order）。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。I-S3b1〜I-S3b3 の後の実物で数える。2026-10-01 時点では `PlaybackSession.swift` は未作成）

| 項目 | 数え直すこと | コマンド（`ios/` で） |
|---|---|---|
| `PlaybackSession` の公開面 | 9 操作（`start`・`play`・`pause`・`seek`・`seekRelative`・`setSpeed`・`stop`・`fail`・`state`）と `observe`。宣言が I-S3b1 の order のとおり | `grep -n 'func \|private(set) var state' NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackSession.swift` |
| `PlaybackState` の置き場 | `Podcast/Playback/Domain/PlaybackState.swift`（I-S3b1 の補正後） | `ls NewsListenApp/NewsListenApp/Podcast/Playback/Domain` |
| T-T1 系の件数 | I-S3b1 の T-T1・T1b〜T1g・T2 のテスト関数の数（`PlaybackSessionTests` 等） | `grep -c 'func test' NewsListenApp/NewsListenAppTests/PlaybackSession*Tests.swift` |
| 行数 | `PlaybackSession.swift` の行数（I-S3b1 の見込み ≈ 260） | `wc -l …` |

## 対象（ios サブモジュールのみ）
**新規（production 1 本）**: `Podcast/Playback/Domain/PlaybackTransition.swift`（domain）。
**変更（production 1 本）**: `Podcast/Playback/PlaybackSession.swift`（決定を純関数に委ねる）。
**新規（test）**: `PlaybackTransitionTests.swift`（表駆動。`domainTestFiles` に登録）。
**変更（test）**: `ArchitectureManifest.swift`（`domainTestFiles`）。**T-T1 系のテストは 1 行も変えない**（oracle）。

**対象外**: Coordinator・Reporter・`OfflineLibrary`・`OfflineDownloads`、位置同期（未起票）、`AudioEngine` port。

## 宣言（ここに無い公開メンバーを足さない）
```swift
// Podcast/Playback/Domain/PlaybackTransition.swift
enum PlaybackInput: Equatable {            // 操作と engine の事象（I-S3b1 の 2 つの表の行）
    case play, pause, seek(Double), seekRelative(Double), setSpeed(Float)
    case engineReady, engineResumed, engineBuffering, enginePaused, engineEnded, engineFailed(String?), engineTimeUpdate(Double, Double)
    case engineInterrupted, engineInterruptionEnded(Bool), engineOutputDeviceLost
}
enum EngineCommand: Equatable { case pause, seek(Double), setRate(Float), unload }   // engine への指示（unload = 購読 Task の cancel → engine.stop）
enum PlaybackOutput: Equatable { case stateChanged(PlaybackState), positionChanged(seconds: Double, duration: Double), ended(episodeId: String), interruption(InterruptionPhase) }
struct PendingEngineOutcome: Equatable { var failed: String??; var ended: Bool }    // paused の間に届いた failed / ended の保留（I-S3b1 の order の注）
enum PlaybackTransition {
    static func next(state: PlaybackState, pending: PendingEngineOutcome, input: PlaybackInput)
        -> (state: PlaybackState, pending: PendingEngineOutcome, commands: [EngineCommand], outputs: [PlaybackOutput])
}
```
- `start`・`stop`・`fail` は表の外の操作（SG-C24・C52）で、`PlaybackSession` に残す（engine の `load` と購読 Task の作り直しを含むため）。純関数が受けるのは上の入力だけ。
- 純関数の結果は I-S3b1 の order の 2 つの表の各セルをそのまま写す（「—」は状態不変・指示なし・通知なし）。`ready` の 2 回の `stateChanged`（`paused` → `playing`）、`timeUpdate` で `stateChanged` を出さない規則、保留の扱い（`failed` を先に）を含む。
- 型の名前（`PlaybackInput`・`EngineCommand`・`PlaybackOutput`・`PendingEngineOutcome`）は TA Spec に無い内部の名前で、公開面にも利用者に見える挙動にも出ない（`PlaybackSession` の公開面は不変）。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 状態と入力から次の状態・指示・通知を決める（TA-R-PB-1） | domain: `Podcast/Playback/Domain/PlaybackTransition.swift` |
| engine への指示の実行・通知の発行・購読 Task・`start`・`stop`・`fail` | application: `Podcast/Playback/PlaybackSession.swift` |

## 移行の中間状態
- **TP8 を消す**。許可リスト（TP10）の増減: 無し（`Podcast/Playback/` は I-S3b1 から違反 0）。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-R-PB-1 | **T-TA-R-PB-1**（`PlaybackTransitionTests`。表駆動） | 再生 Spec §3.6.2・§3.6.3（= I-S3b1 の order の「操作 × 状態」のうち表の外（`start`・`stop`・`fail`）を除く操作 5 つ（`play`・`pause`・`seek`・`seekRelative`・`setSpeed`。表では `seek` / `seekRelative` が 1 行）× 7 状態、「engine の事象 × 状態」10 行 × 7 状態）の**全セル**を 1 行ずつ。期待値は状態・指示列・通知列。16 辺がすべて現れ、表の外の辺が現れないこと（遷移の集合を数える） |
| CI-T1・T1b〜T1g・T2（不変） | T-T1 系 | **無変更で green**（`PlaybackSession` を engine の double で駆動する oracle） |
| TA-V7 | `ArchitectureOracleTests` | `PlaybackTransitionTests` が `domainTestFiles` にあり 0 件 |
| TA-V6（PB の domain の型。新しい domain の型を作る slice が公開面の検査の対象を足す: TA Spec §7） | **T-TA-V6-PB-transition**（`PlaybackTransitionTests`） | `PlaybackTransition.next` が返した `commands`・`outputs` の配列を書き換えても、同じ入力での次の呼出の結果が変わらない（純関数で、内部に状態を持たない）。`PlaybackSession` の公開面の TA-V6（I-S3b1）は不変で green |

## 完了条件
1. T-TA-R-PB-1 が green で、セルの数が 5 × 7 ＋ 10 × 7 = 105（`XCTAssertEqual(cases.count, 105)` をテストに持つ）。T-T1 系が無変更で green: `git diff --name-only origin/main -- NewsListenApp/NewsListenAppTests | grep -i 'PlaybackSession'` が 0 行。
2. 変更した production が 2 本だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 2 行（新規 1 ＋ 変更 1）。
3. `PlaybackSession` の公開面が不変: `git diff origin/main -- NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackSession.swift | grep '^[-+].*\(func \(start\|play\|pause\|seek\|seekRelative\|setSpeed\|stop\|fail\|observe\)\b\|var state\)'` が 0 行（宣言の行が変わっていない）。
4. 決定が `PlaybackSession` に残っていない: `grep -c "case (\.\(idle\|loading\|playing\|buffering\|paused\|ended\|errored\)" NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackSession.swift` → 0（状態 × 入力の `switch` は純関数の中だけ。正の対照: 同じ grep を `Domain/PlaybackTransition.swift` に掛けると 1 以上）。
5. domain の純度: `grep -n "^import" NewsListenApp/NewsListenApp/Podcast/Playback/Domain/PlaybackTransition.swift` が `Foundation` だけ。`grep -n "AudioEngine\|Task\|class " 同ファイル` が 0 件。
6. `ArchitectureOracleTests` が green。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 1〜6 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- commit は「表駆動テスト（RED）」「PlaybackTransition」「PlaybackSession の委譲」の単位。

## 禁止事項 / scope 外
- 再生 Spec §3.6 の表・分母 16・`PlaybackSession` の公開面を変えない。`stop`・`fail` を表に足さない。
- T-T1 系のテストを変えない（落ちたら実装を直す。テストを直さずに止めて報告する）。
- Coordinator・Reporter に触らない。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 250 / 200）
- production ≈ 250 行（純関数 ≈ 180・`PlaybackSession` の書き直し ≈ ±70）。test ≈ 200 行（105 セルの表）。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TP8 の削除（TA Spec §8.4）。内部の型名 4 つ。README の I-T11 行を完了へ。
