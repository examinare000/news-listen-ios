## iOS リファクタ I-T2b: ロック画面の port を技術中立の値にし、port と adapter の補助の置き場を直す

## 概要
`NowPlayingCenter.update` の引数を MediaPlayer の辞書 `[String: Any]` から技術中立の値 `NowPlayingSnapshot` に替え、辞書の組み立てを adapter（`Podcast/Platform/NowPlayingInfo.swift`）の中へ閉じる。あわせて、application の層に属する port と型（`NowPlayingCenter`・`PlaybackLifecycle`・`PlayerPresentation`）を `Podcast/Playback/` の直下へ、adapter の補助 `NowPlayingInfo.swift`（`import AVFoundation`・`MediaPlayer` を持つ）を `Podcast/Platform/` へ移す。**ロック画面に出る値は変えない**。操作は 5 つのまま（SG-C35）。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §3.2（`NowPlayingCenter.swift`・`NowPlayingInfo.swift`・`PlaybackLifecycle.swift`・`PlayerPresentation.swift` の行）・§5.1「port と adapter」の `NowPlayingCenter` 行とリードモデル `NowPlayingSnapshot` の形・§4 TA-D11・§8.2 の I-T2b 行、導出 I-27（TA Spec §10.1）、再生 Spec §5 CP10（I-S3a の実装は辞書。TA Spec §10.2 で改めた）。**検証モード（再設計しない）**。

応える要求: AQ-5（技術の差し替え。TA Spec §9.2）、`architecture.md` §3「port は外部の技術の API を写さない」。

## 前提・着手条件
- 依存: **I-T1 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**。I-T2a と順序を問わない（対象のファイルが重ならない。ただし I-T2a が先に入っていれば、所属表の明示の行の消し方をそれに合わせる）。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift`（rc=0）。
- 確定済み（再提案しない）: SG-C27（ロック画面 port は App が 1 個作る）、SG-C35（`NowPlayingCenter` は 5 操作）、SG-C37（解除は token 単位）、SG-C59（登録と解除は Coordinator。I-S3b1）。`RemoteCommand` を 8 種にする案は I-S3c（保留）。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| port の宣言と `[String: Any]` | `Podcast/Platform/NowPlayingCenter.swift:59` `func update(_ info: [String: Any])`（68 行のファイル。`RemoteCommand` 7 種・`RemoteCommandResult` 3 種・`RemoteCommandRegistration` を含む） | `grep -n 'String: Any\|func ' NewsListenApp/NewsListenApp/Podcast/Platform/NowPlayingCenter.swift` |
| adapter の `update` | `Podcast/Platform/MediaPlayerNowPlaying.swift:12`（90 行） | `grep -n 'func update' NewsListenApp/NewsListenApp/Podcast/Platform/MediaPlayerNowPlaying.swift` |
| `NowPlayingInfo.swift` の import と中身 | `:11-13` `Foundation`・`AVFoundation`・`MediaPlayer`。`NowPlayingInfo.make(podcast:elapsed:duration:rate:isPlaying:)`（`:28-45`）・`title(for:)`・`InterruptionPolicy`（`AVAudioSession` を使う。`:52-69`）。69 行 | `grep -n '^import\|static func\|^enum' NewsListenApp/NewsListenApp/Podcast/NowPlayingInfo.swift` |
| `NowPlayingInfo.make` の呼び手 | production は `Podcast/PodcastViewModel.swift:621` の 1 箇所。test は `NowPlayingInfoTests.swift` の 4 箇所 | `grep -rn 'NowPlayingInfo.make' NewsListenApp --include='*.swift'` |
| `NowPlayingCenterSpy.currentInfo` の型と読み手 | `AppStateTestSupport.swift:25` `[String: Any]?`。読み手は `PodcastViewModelPortTests.swift` の 5 行（`:229,232,235,270,274`。nil / 非 nil だけを見る） | `grep -rn 'currentInfo' NewsListenApp/NewsListenAppTests` |
| 既存テストの件数 | `NowPlayingInfoTests` 13・`MediaPlayerNowPlayingTests` 3・`PodcastViewModelPortTests` 13・`GrepOracleTests` 10 | `grep -c 'func test' …` |
| G03 の除外 | `GrepOracleTests.swift` の `testG03` が `Podcast/NowPlayingInfo.swift` を除外し、③ の正の対照でその path を要求している | `grep -n 'NowPlayingInfo.swift' NewsListenApp/NewsListenAppTests/GrepOracleTests.swift` |
| `PlaybackLifecycle.swift`・`PlayerPresentation.swift` | 20 行・21 行。どちらも `import Foundation` だけ | `wc -l`、`grep -n '^import' …` |

## 対象（ios サブモジュールのみ）
**移動（production 4 本。`git mv`）**

| 移動元 | 移動先 | 層 | 変更 |
|---|---|---|---|
| `Podcast/Platform/NowPlayingCenter.swift` | `Podcast/Playback/NowPlayingCenter.swift` | application（port） | `update(_ snapshot: NowPlayingSnapshot)` に替える。`NowPlayingSnapshot` の宣言を同じファイルに置く。`RemoteCommand`・`RemoteCommandResult`・`RemoteCommandRegistration` は不変。`import os` は残す（現行の `OSAllocatedUnfairLock` 等が使う。TA-D3 が許す） |
| `Podcast/PlaybackLifecycle.swift` | `Podcast/Playback/PlaybackLifecycle.swift` | application（port） | 中身は不変（TP4 のコメントも I-S3b3 まで残す） |
| `Podcast/PlayerPresentation.swift` | `Podcast/Playback/PlayerPresentation.swift` | application | 中身は不変 |
| `Podcast/NowPlayingInfo.swift` | `Podcast/Platform/NowPlayingInfo.swift` | adapter | `make(snapshot:)` に替える（下）。`InterruptionPolicy` は同じファイルに残す（`AVAudioSession` を読む純関数。adapter の補助） |

**変更（production 2 本）**: `Podcast/Platform/MediaPlayerNowPlaying.swift`（`update(_ snapshot:)` を受け、`NowPlayingInfo.make(snapshot:)` で辞書を組んで `MPNowPlayingInfoCenter` に置く）、`Podcast/PodcastViewModel.swift`（`:616-628` の `updateNowPlayingInfo()` が `NowPlayingSnapshot` を組んで `nowPlaying.update(_:)` を呼ぶ。`subtitle` は `DifficultyLabel.text(for: podcast.difficulty)`。これ以外は変えない）。

**変更（test）**: `AppStateTestSupport.swift` の `NowPlayingCenterSpy`（`currentInfo: NowPlayingSnapshot?`。`update` で記録、`clear` で nil。`lastElapsedUpdate` は不変）、`NowPlayingInfoTests.swift`（Given を `NowPlayingSnapshot` に置き換える。Then = 辞書のキーと値は不変）、`MediaPlayerNowPlayingTests.swift`（`update` の引数を snapshot に）、`GrepOracleTests.swift` の `testG03`（除外を `Podcast/Platform/` だけにし、③ の正の対照の path を `Podcast/Platform/NowPlayingInfo.swift` にする。ほかの 9 件は不変）、`ArchitectureManifest.swift`（所属表の明示の行から `Podcast/PlaybackLifecycle.swift`・`Podcast/PlayerPresentation.swift`・`Podcast/Platform/NowPlayingCenter.swift` を消す。`portFiles` の path を `Podcast/Playback/NowPlayingCenter.swift`・`Podcast/Playback/PlaybackLifecycle.swift` に直す。許可リストから TA-D11 の 1 行を消す）。

**対象外**: `RemoteCommand` の追加・`setNextTrackEnabled`（I-S3c。保留）、操作の数、`AVPlayerEngine.swift`、Coordinator（I-S3b1）、`AudioEngine.swift`。

## 宣言
```swift
// Podcast/Playback/NowPlayingCenter.swift
struct NowPlayingSnapshot: Equatable {      // リードモデル（TA Spec §5.1）。struct・let だけ
    let title: String; let subtitle: String; let elapsed: Double; let duration: Double; let rate: Float; let isPlaying: Bool
}
protocol NowPlayingCenter {
    func update(_ snapshot: NowPlayingSnapshot)
    func updateElapsed(_ elapsed: Double, duration: Double)
    func clear()
    func registerCommands(_ handler: @escaping @MainActor (RemoteCommand) -> RemoteCommandResult) -> RemoteCommandRegistration
    func unregister(_ registration: RemoteCommandRegistration)
}
// Podcast/Platform/NowPlayingInfo.swift（adapter）
enum NowPlayingInfo { static func make(snapshot: NowPlayingSnapshot) -> [String: Any] }
enum InterruptionPolicy { … }   // 不変
```
- `make(snapshot:)` の辞書は現行 `make(podcast:…)` と同じキーと値: `MPMediaItemPropertyTitle` = `title`、`MPMediaItemPropertyArtist` = `subtitle`、`MPMediaItemPropertyPlaybackDuration` は `duration` が有限かつ 0 より大きいときだけ、`MPNowPlayingInfoPropertyElapsedPlaybackTime` = `max(0, elapsed)`、`MPNowPlayingInfoPropertyPlaybackRate` = `isPlaying ? Double(rate) : 0.0`。`title(for:)` は消す（`title` は呼ぶ側が `displayTitle` で作る）。
- `NowPlayingSnapshot.subtitle` は難易度の表示ラベル。作るのは呼ぶ側（旧 VM は `DifficultyLabel.text(for:)`。I-S3b1 以降は合成 root が渡す closure `lockScreenSubtitle`）。port と adapter は難易度のコードを知らない。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| ロック画面へ渡す値の形（`NowPlayingSnapshot`）と port の宣言 | application: `Podcast/Playback/NowPlayingCenter.swift` |
| MediaPlayer の辞書の組み立て・`AVAudioSession` の判定 | adapter: `Podcast/Platform/NowPlayingInfo.swift`・`MediaPlayerNowPlaying.swift` |
| 表示名と難易度ラベルから snapshot を組む | presentation（旧 VM。I-S3b1 では Coordinator が `lockScreenSubtitle` closure で組む） |

## 移行の中間状態
無い。許可リスト（TP10）から TA-D11 の 1 行（`Podcast/Platform/NowPlayingCenter.swift` 1）を消す。所属表の明示の行 3 本を消す。

## 変わる挙動
無い（辞書のキーと値は同じ。`NowPlayingInfoTests` 13 の Then が oracle）。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-D11 | `ArchitectureOracleTests` T-TA-V2d | `portFiles` に `[String: Any]`・framework の型が無い。許可リストの TA-D11 が 0 行 |
| CP10（再生 Spec §5。5 操作） | `MediaPlayerNowPlayingTests`（3） | `update(snapshot)` の後、`MPNowPlayingInfoCenter.default().nowPlayingInfo` のキーと値が現行と同じ。件数不変 |
| 辞書の値 | `NowPlayingInfoTests`（13） | Given の置き換えだけで Then 不変（`title`・`subtitle`・duration の有無・elapsed の丸め・rate の 0） |
| G03 | `GrepOracleTests` | 除外が `Podcast/Platform/` だけで green。③ の正の対照が `Podcast/Platform/NowPlayingInfo.swift` と `AVPlayerEngine.swift` を含む |
| TA-V11 | 全既存テスト | `PodcastViewModelPortTests`（13）は spy の型の変更だけで Then 不変 |

## 完了条件
1. 既存テスト全件 green。`NowPlayingInfoTests` 13・`MediaPlayerNowPlayingTests` 3・`PodcastViewModelPortTests` 13・`GrepOracleTests` 10 の件数が減らない。
2. 変更した production が 6 本だけ: `git diff --name-only -M origin/main -- NewsListenApp/NewsListenApp` が 6 行（移動 4 ＋ 変更 2）。
3. `[String: Any]` が port に無い: `grep -rn "String: Any" NewsListenApp/NewsListenApp/Podcast/Playback` が 0 件。`grep -rn "String: Any" NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が `Podcast/Platform/NowPlayingInfo.swift`・`Podcast/Platform/MediaPlayerNowPlaying.swift` の行だけ（正の対照: 2026-10-01 実測は `Platform/NowPlayingCenter.swift:59`・`NowPlayingInfo.swift:34,35`・`MediaPlayerNowPlaying.swift:12` の 4 行）。
4. 移動元が無い: `test ! -e NewsListenApp/NewsListenApp/Podcast/Platform/NowPlayingCenter.swift && test ! -e NewsListenApp/NewsListenApp/Podcast/PlaybackLifecycle.swift && test ! -e NewsListenApp/NewsListenApp/Podcast/PlayerPresentation.swift && test ! -e NewsListenApp/NewsListenApp/Podcast/NowPlayingInfo.swift`（rc=0）。
5. AV / MP の import が `Platform/` の外に無い: `grep -rn "^import \(AVFoundation\|MediaPlayer\)" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Podcast/Platform/"` が 0 件（2026-10-01 実測: `Podcast/NowPlayingInfo.swift:12,13` の 2 行が出る = 正の対照）。`Podcast/Playback/` の import が `Foundation`・`Combine`・`os` の中: `grep -rhn "^import" NewsListenApp/NewsListenApp/Podcast/Playback/ | grep -v "Foundation\|Combine\|os$"` が 0 件。
6. `NowPlayingSnapshot` が `struct`・`let` だけ: `sed -n '/^struct NowPlayingSnapshot/,/^}/p' NewsListenApp/NewsListenApp/Podcast/Playback/NowPlayingCenter.swift | grep -c "var \|class \|mutating "` → 0（正の対照: 同じ sed の `let` の数が 6）。`readModelFiles` には入れない（同じファイルに protocol と `RemoteCommandRegistration` があり、TA-D9 のファイル単位の検査に合わない。TA Spec §7 TA-D9 の対象は I-S3b1 の `NowPlaying.swift` から。`NowPlayingSnapshot` の形はこの grep で固定する）。
7. `NowPlayingInfo.make(podcast:` が無い: `grep -rn "make(podcast:" NewsListenApp --include='*.swift'` が 0 件。`grep -rn "make(snapshot:" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/Platform/MediaPlayerNowPlaying.swift` の 1 行以上。
8. `ArchitectureOracleTests` が green で、許可リストに `"TA-D11"` の行が無い（`grep -c '"TA-D11"' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` → 0）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜8 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- commit は「NowPlayingSnapshot と port の移動」「NowPlayingInfo の移動と make(snapshot:)」「VM と spy の追随・G03」「所属表」の単位。

## 禁止事項 / scope 外
- 操作を 5 つより増やさない。`RemoteCommand` を増やさない（I-S3c）。`nextTrack` を書かない。
- `NowPlayingSnapshot` に難易度のコード・`Podcast`・`Episode` を持たせない（port は domain の意味も通信の形も知らない値だけを受ける。TA Spec §5.1）。
- `MediaPlayerNowPlaying` の生成箇所（G08 の 3 箇所）を変えない。`AVPlayerEngine.swift`・`AudioEngine.swift` を変えない。
- `PodcastViewModel` の `updateNowPlayingInfo()` 以外を変えない。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: 80 / 120。2026-10-01 実測の基点: `NowPlayingCenter.swift` 68・`NowPlayingInfo.swift` 69・`MediaPlayerNowPlaying.swift` 90）
- production ≈ 80 行: `NowPlayingSnapshot` ≈ 12・port の引数 2・`make(snapshot:)` ≈ 15（−10）・`MediaPlayerNowPlaying` ≈ 8・VM ≈ 10・移動 4 本のヘッダ ≈ 8。
- test ≈ 120 行: `NowPlayingInfoTests` の Given ≈ 50・spy ≈ 10・`MediaPlayerNowPlayingTests` ≈ 10・G03 ≈ 5・所属表 ≈ 10。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: 再生 Spec §5 CP10 の `update` の引数が `NowPlayingSnapshot` になったこと（TA Spec §10.2 の行を「済み」へ）。I-S3c の order の path（`Podcast/Playback/NowPlayingCenter.swift`）はすでに追随済み。README の I-T2b 行を完了へ。
