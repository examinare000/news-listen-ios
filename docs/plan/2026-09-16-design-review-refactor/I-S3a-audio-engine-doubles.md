## iOS リファクタ I-S3a: Platform adapter の導入と `PodcastViewModel` の port 経由化・engine 結合テストの double 移植（挙動不変）

## 概要
`PlaybackSession`（I-S3b1）の 16 遷移を AVFoundation 抜きで XCTest できるようにするため、`AudioEngine` port と test double を導入し、`PodcastViewModelTests` のうち AVFoundation 型・`vm.player`・KVO ハンドラを直接扱うテストを double 駆動へ移植する。**double で VM を駆動するには VM が port から事象を受ける必要がある**ため、本 slice は `Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}` の 2 adapter を作り、現行 `PodcastViewModel` の AVPlayer / MediaPlayer 直結部分を port 経由に置き換える（**production の挙動は変えない**。公開操作・View・`@Published` の一覧は不変で、特性テスト全件 green が oracle）。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§2 port 表・§3.5 Platform・§4 CI-T1 の根拠・§6 S3a 行）。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。新しい契約 ID を作らない。

> **2026-09-23 夜の切り直し**: 起票時の本 order は「`PodcastViewModel.swift` の diff 0」と「17 関数を double 駆動へ移植」を同時に要求していたが、対象 15 関数のうち 14 は VM の公開 API（`handlePlayerItemStatusChange` / `handleTimeControlStatusChange` / `vm.player` / `didPlayToEndTimeNotification`）を AVFoundation 型で駆動しており、VM が port を消費しない限り double では駆動できない（受入検査 2: 条項の相互矛盾）。また「17」は Spec のレビュー実測値で、2026-09-23 の再実測は **15 関数**（`grep -n` の行数は 13、コメント行の一致 2 件を含めると 17）だった（受入検査 1: 集合の数え違い）。したがって adapter 2 本と VM の port 経由化を I-S3b2 から本 slice へ前倒しし、I-S3b2 を facade 化（入口の差し替え）1 境界に絞った。この変更は親 docs `ios-design.md` §11.3 の I-S3a / I-S3b2 行と Spec §6 S3a / S3b 行の adapter 所属を変えるため、完了時に router へ返す（README「記録」参照）。

> **2026-09-30 の前提点検（wave 1 完了後）**: I-S2 の成果で本 order の前提が 4 点変わった。(1) I-S2 が `PodcastViewModelTests` に T-T15 の 2 本（`testTT15_09_…` / `testTT15_10_…`）を足し、どちらも `XCTAssertNil(vm.player)` を持つ。関数数は 76 → **78**、AVFoundation / `vm.player` を直接扱う集合は 15 → **17**。(2) `NowPlayingCenter` port と adapter は I-S2 が既に `Podcast/Platform/` に置いた（移動・改名は不要）。(3) `AppState.init` が既定引数で `MediaPlayerNowPlaying()` を生成する。(4) 本文の行番号は I-S2 の変更で約 5 行ずれた（本文は 2026-09-30 実測へ更新済み）。再生の停止の扱いは user 判断で確定済み（親 docs 監査レポート §5 の **SG-C21〜C28**。Spec 冒頭の 2026-09-30 追記）。再提案しない。

Spec §8 着手順 3 の入口条件（親 plan の I-S3a）。

## 前提・着手条件
- 依存: **I-S2 の submodule PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（`git -C <親> submodule status` で `ios` に `+` が無い）。I-S2 の `NowPlayingCenter` port（`clear`）と `PlaybackLifecycle` port・TP4 が存在すること。
- 本 slice は `Podcast/Playback/` 配下の capsule（Session / Coordinator / OfflineLibrary / PositionReporter）を作らない。作るのは port 定義・adapter 2 本・double・テストの移植だけ。
- `docs/trial-log/scripted-session-lost-wakeup.md` を必ず読む（2026-09-30 追加）。test double の到着通知と保留登録を別のロック区間に置いて lost wakeup を起こした記録で、本 slice が作る `AsyncStream` の double に同種の問題を再現しない。
- `docs/trial-log/player-auto-converge.md` を必ず読む。stale ガード（`endedId` を引数で閉じ込める）・`RequestRecordingSession` の直列化（`OSAllocatedUnfairLock`）など、adapter / double 実装時に同種の並行性問題を再現しないための既知の落とし穴が記録されている。再提案しない。
- I-S2 本文の「`update` / `registerCommands` 等の port 化は I-S3b2 で行う」は本切り直しで **I-S3a へ前倒し**（I-S2 は投入済みのため本文は直さず、README の slice 表を正とする）。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`Podcast/Playback/AudioEngine.swift`（新規。port 定義）**: load / play / pause / seek / rate（setRate）/ **stop** / 事象 stream（`AsyncStream<EngineEvent>`）の **7 操作**（Spec 冒頭の 2026-09-30 追記。SG-C22）。`stop` は「止めて読み込みを外す。以後も `load` で再利用できる」。`EngineEvent` は `ready / buffering / resumed / ended / failed(description) / timeUpdate(seconds) / interrupted / interruptionEnded(shouldResume)` の 8 種（Spec §5 CP1 note）。`AVFoundation` を import しない（I-S3b1 の依存方向 grep がこのファイルにも掛かる）。置き場を `Podcast/Playback/` に固定する理由: Playback 側が実装（Platform）を知らずに参照できる向き（Spec §2 依存方向）で、I-S3b1 の grep 条件と両立するのはこの置き場だけ。
2. **`Podcast/Platform/AVPlayerEngine.swift`（新規。`AudioEngine` 実装）**: 現行 `PodcastViewModel.swift` の AVPlayer 生成（`:295`）・periodic time observer（`:316`）・`AVPlayerItem.status` / `timeControlStatus` の KVO（`:335,345`）・`didPlayToEndTimeNotification`（`:364`）・`AVAudioSession` の category / activate（`:631-632`）・割り込み / route change 通知（`:728-733` の登録と以降のハンドラ）を**そのまま移す**。`stop()` は現行 `tearDownPlayback()`（`:598-`）のうち engine に属する部分（observer 4 種の解除・`pause`・player の破棄）を行う。停止後に事象を publish しない。KVO / 通知の stale ガード（現行 `shouldProcessPlayerItemCallback` / `shouldProcessPlayerCallback` の判定）は adapter 内部に閉じ、**旧 4 関数名（`shouldProcessPlayerItemCallback / shouldProcessPlayerCallback / handlePlayerItemStatusChange / handleTimeControlStatusChange`）を移動先で使わない**（I-S3b3 の参照 0 grep が旧名で数えるため）。
3. **`Podcast/Platform/MediaPlayerNowPlaying.swift`（`NowPlayingCenter` 実装）**: I-S2 が同じ場所に作った `clear` のみの adapter（port 定義は `Podcast/Platform/NowPlayingCenter.swift`）に `update(info) / registerCommands(handler) / unregister` を足す（Spec §5 CP10。移動・改名は不要）。現行 VM の `MPNowPlayingInfoCenter` 直書き（`:623, :740-765`）と `MPRemoteCommandCenter` 配線（`:651-726`）を移す。リモートコマンド 7 本の `guard vm.player != nil` は、VM の旗（対象 4）を読む判定へ置き換える（返す値 `.noSuchContent` / `.commandFailed` は変えない）。`Podcast/NowPlayingInfo.swift`（辞書を組み立てる純粋関数）は変更しない。
4. **`Podcast/PodcastViewModel.swift`（変更。挙動不変）**: `init` に `engine: AudioEngine` と `nowPlaying: NowPlayingCenter` を受け、`private(set) var player: AVPlayer?` と上記 4 関数を削除し、「engine に音声が読み込まれているか」を private な旗で持つ（`load` を呼んだら立て、`stop` を呼んだら倒す。現行の `player != nil` と同じ真偽。**TP5**: owner user／導入 I-S3a／削除条件 I-S3b2 で Session の状態に置き換わった時。SG-C23）。`togglePlayPause()` の `guard let player` はこの旗で判定する。`tearDownPlayback()` は `engine.stop()` を呼ぶ。`deinit` は現行どおりリモートコマンドを解除する（`nowPlaying.unregister()`。SG-C28）。`EngineEvent` を受けて既存の派生値（`isPlaying / isBuffering / errorMessage / currentTime / duration / didFinishCurrentEpisode`）を従来どおり更新する。`import AVFoundation` / `import MediaPlayer` を外す（`UIKit` は background task のため I-S3b2 まで残る）。**それ以外の公開操作名・`@Published` 名・引数・戻り値は変えない**（`play / playById / replayCurrentEpisode / playNow / addToQueue / playNext / removeFromQueue / moveUpNext / togglePlayPause / seek / setSpeed / stopPlayback / flushPlaybackPosition / handlePlaybackEnded / download / removeDownload / downloadState(for:) / isPlayableWhileOffline / minimizePlayer / expandPlayer / previewMarkFinished / submitQuizAnswers / fetchSavedVocabulary / saveVocabulary / loadPodcasts / syncDownloadedState` と TP4 の `PlaybackLifecycle` 準拠）。
5. **`NewsListenAppApp.swift`（変更）**: App が `AVPlayerEngine` と `MediaPlayerNowPlaying` を 1 インスタンスずつ生成し、`ContentView` の `PodcastViewModel` 生成（`:124-131`）に渡す。**同じ `MediaPlayerNowPlaying` を `AppState(nowPlayingCenter:)` にも渡す**（現行は `:19` の `AppState()` が既定引数で別インスタンスを作る。SG-C27）。`AppState.init` の既定引数は Preview とテスト用に残す。`OfflineLibrary` の生成は I-S3b2。
6. **test double（`NewsListenAppTests/` 内、production からは参照されない）**: `AudioEngine` を実装し、テストから `EngineEvent` を注入できる double。double は「読み込み済みか」を状態として持つ（`load` で真、`stop` で偽）。テストはこの状態を観測し、呼出回数は assert しない（SG-C26）。`NowPlayingCenter` の double は I-S2 の T-T15 のものを再利用する。
7. **17 関数の移植**（`NewsListenAppTests/PodcastViewModelTests.swift`、2026-09-30 実測 78 関数中。集合は次の列挙で閉じる。着手時に同じ awk / grep で再実測し、増減があれば増減分も本表に足して PR 説明に書く。**増減で止めない**）:
   - double 駆動へ書き換える **11 関数**（`EngineEvent` を注入し `vm` の派生値を観測。Then は `vm.player` の assert 3 行の置換を除き不変）: `testHandlePlayerItemStatusChangeFailedSetsErrorMessageAndStopsPlaying`・`testHandlePlayerItemStatusChangeFailedUsesDefaultMessageWhenDescriptionMissing`・`testHandlePlayerItemStatusChangeIgnoresNonFailedStatus`・`testHandleTimeControlStatusChangeWaitingSetsIsBuffering`・`testHandleTimeControlStatusChangePlayingClearsIsBuffering`・`testStopPlaybackResetsIsBuffering`・`testFlushPlaybackPositionSyncsCurrentPositionWithoutStopping`（`XCTAssertNotNil(vm.player)` は「engine double が読み込み済み」へ）・`testEndOfPlaybackObserverCapturesEndedIdAtRegistrationNotAtFireTime`・`testEndOfPlaybackObserverTriggersConvergenceForCurrentEpisode`（`ended` 事象の注入）・`testTT15_09_stopForLogoutResetsPlaybackWithoutSyncingPosition`・`testTT15_10_stopForLogoutIsIdempotent`（I-S2 の T-T15。`XCTAssertNil(vm.player)` は「engine double が読み込み済みでない」へ。他の assert と `verifies:` の対応は変えない。SG-C21）。
   - `NewsListenAppTests/AVPlayerEngineTests.swift`（新規）へ移す **6 関数**（adapter 内部の stale ガードの特性テスト。AVFoundation 型を使い続けてよい）: `testShouldProcessPlayerItemCallback{TrueWhenMatchesCurrentItem,FalseForDifferentItem,FalseWhenPlayerNil}`・`testShouldProcessPlayerCallback{TrueWhenMatchesCurrentPlayer,FalseForDifferentPlayer,FalseWhenPlayerNil}`。
   - **残り 61 関数は Then 不変**（78 − 17）。`makeViewModel` / `playingViewModel` 等の helper が double を注入する変更は可（Given の組み立てのみ）。`PodcastViewModelTests.swift` から `import AVFoundation` を外す。

## 契約（CI-T → T-T の表）
本 slice は新しい CI-T を持たない。I-S3b1 の CI-T1（`PlaybackSession` の 16 遷移）を double で駆動するための土台であり、oracle は「特性テストが移植前後で green のまま」と「AVFoundation / MediaPlayer が `Podcast/Platform/` の外に無い」。

| 確認事項 | 由来 | 検証 |
|---|---|---|
| `AudioEngine` port が VM / Session の状態遷移を AVPlayer 抜きでテストできる | Spec §2 port 表（AudioEngine の根拠） | 11 関数が double 経由で green。`PodcastViewModelTests.swift` に AVFoundation 型・`vm.player` の参照が無い |
| production の挙動が変わらない | Spec §6 S3a 行「挙動変更なし」、ios-design §11.3 I-S3a 行 | `PodcastViewModelTests` 全件（2026-09-30 実測 78）green。`Podcast/*View*.swift`・`DesignSystem/`・`Settings/` の diff 0。VM の公開操作・`@Published` の一覧が着手前後で同一（削除は `player` と上記 4 関数のみ） |
| 主体離脱時に engine が空になる | SG-C21・SG-C26、Spec CI-T15 | T-T15 の 2 本が engine double の状態（読み込み済みでない）を観測して green |
| AVPlayer が 2 系統にならない | `docs/trial-log/mino-design-review-delegation.md`（棄却案） | `AVPlayer(` の生成が `Podcast/Platform/AVPlayerEngine.swift` の 1 箇所 |

## 特性テスト（baseline。着手前に green を確認）
`PodcastViewModelTests`（実測 78）・`NowPlayingInfoTests`（13）・`PlaybackQueueTests`（12）・`PlaybackQueueConformanceTests`（32）・`TranscriptTimingTests`（13）・`AppStateAuthTests`（38。I-S2 完了時点。TP4 経由の `stopForLogout` を含む）。

## 手順（TDD 順序）
1. baseline: 上記特性テストと `xcodebuild test -only-testing:NewsListenAppTests` の green を記録する。
2. 17 関数の集合を再実測する（`awk '/func test/{n=$0} /AVPlayer|AVPlayerItem|CMTime|vm\.player|handlePlayerItemStatusChange|handleTimeControlStatusChange|shouldProcessPlayer|didPlayToEndTimeNotification/{if(n!=""){print n; n=""}}' NewsListenAppTests/PodcastViewModelTests.swift`。コメント行の一致は除外）。増減は PR 説明に書き、止めない。
3. `Podcast/Playback/AudioEngine.swift`（port）と double を追加する（この時点では production から参照されない。コンパイルが通ることだけを確認）。
4. `AVPlayerEngine` を新規追加し、6 関数を `AVPlayerEngineTests` へ移して green にする（adapter の stale ガードを先に固定）。
5. `MediaPlayerNowPlaying` を I-S2 の adapter から拡張する。
6. VM を port 経由化する。11 関数を 1 つずつ double 駆動へ書き換え、1 関数ごとに `-only-testing:NewsListenAppTests/PodcastViewModelTests` で green を確認する（大きな一括書き換えをしない）。
7. `NewsListenAppApp.swift` で adapter を生成して渡す。全件 green を確認する。
8. 1 slice = 1 PR。commit は「port＋double」「AVPlayerEngine＋6 関数移動」「MediaPlayerNowPlaying」「VM の port 経由化＋11 関数移植」「合成 root」の単位で分ける。

## 完了条件
- `xcodebuild test -only-testing:NewsListenAppTests` が全 green。`PodcastViewModelTests` の関数数が着手時の実測値（2026-09-30: 78）から **6 減**（`AVPlayerEngineTests` へ移動）で、`AVPlayerEngineTests` が 6 件 green。
- `grep -n "^import \(AVFoundation\|MediaPlayer\)" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0 件。`grep -n "AVPlayer\|AVPlayerItem\|CMTime\|vm\.player" NewsListenApp/NewsListenAppTests/PodcastViewModelTests.swift` → コメント行を除き 0 件。
- `grep -rn "AVPlayer\|AVAudioSession\|MPNowPlayingInfoCenter\|MPRemoteCommandCenter" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/Platform/` 以外で **コメント行を除き 0 件**（除外: `Podcast/NowPlayingInfo.swift` の import 2 行＝純粋ヘルパで据置、`Models/Podcast.swift:58`・`PlaybackConstants.swift:6`・`PlaybackQueue.swift:6`・`NowPlayingInfo.swift:5-6,15` のコメント）。`AVPlayer(` の生成は `Podcast/Platform/AVPlayerEngine.swift` の 1 箇所。
- `grep -rn "^import \(AVFoundation\|MediaPlayer\|UIKit\|SwiftUI\)" NewsListenApp/NewsListenApp/Podcast/Playback/` → 0 件。
- `git -C ios diff --stat origin/main -- 'NewsListenApp/NewsListenApp/Podcast/*View*.swift' NewsListenApp/NewsListenApp/DesignSystem NewsListenApp/NewsListenApp/Settings` → 0（View・Preview・Settings は触らない）。**submodule の中で実行する**（worktree ルートで実行すると対象 path が親リポに無く、常に空になる。親 docs `trial-log/git-oracle-submodule-base-sha.md`）。実行前に `git -C ios cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/PodcastView.swift` が exit 0 であることを確認する。
- VM の公開面: `grep -n "^    func \|@Published" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` の一覧が着手前と同一（差分は 4 関数の削除と `init` の引数追加のみ）。`grep -n "var player" …/PodcastViewModel.swift` → 0 件。
- `PlaybackLifecycle` の実装は引き続き `PodcastViewModel`（TP4。削除条件は I-S3b2 で不変）。
- `MediaPlayerNowPlaying(` の生成が production で `NewsListenAppApp.swift` と `AppState.swift` の既定引数の 2 箇所だけで、App が作った 1 個が `AppState` と `PodcastViewModel` の両方に渡っている（SG-C27）。
- 本 slice の完了（全件 green）が I-S3b1 着手の入口条件であることと、17 関数の実測集合を PR 説明に明記する。

## 禁止事項 / scope 外
- `PlaybackSession` / `PlaybackCoordinator` / `OfflineLibrary` / `PositionReporter` / `Episode`（I-S3b1）は作らない。facade 化・`startEpisode` 1 経路・TP3・`PlaybackQueue` dedupe・`PodcastRowView` の切替（I-S3b2）は行わない。
- 利用者に見える挙動（再生・割り込み・ロック画面・位置同期・auto-advance）を変えない。共有仕様 §4 の行 ID（PS-* / RS-*）を本 slice のテスト名に付けない。
- 61 関数の Then を変えない。T-T15 の 2 本は `vm.player` の assert 1 行だけを置換し、他の assert を足さない・消さない。View・`DesignSystem/`・`Settings/` を変えない。
- AVPlayer 鏡写しの `AudioEngineProtocol`（RO4）は作らない。port は Session が必要な 7 操作（`stop` を含む）＋事象 stream に絞る（Spec §5 rejected_overdesign と 2026-09-30 追記）。port に問い合わせ（`isLoaded` 等）を足さない（SG-C23）。engine double の呼出回数を assert しない（SG-C26）。リモートコマンドの解除を `stopForLogout()` へ移さない（SG-C28）。`AudioSession` / `NotificationCenter` は adapter 内部に閉じ、port にしない（Spec §2）。

## 規模の目安（巻き戻し範囲）
VM から adapter へ移る約 350 行（`:316-364, :598-632, :651-800`）＋ port / adapter の新規約 300 行＋テスト 17 関数＋helper。1 PR で読める規模（1,000 行未満）。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §2（port 表・composition root）・§3.5（Platform）・§5（CP1 / CP10）・§6（S3a 行 = I-S3a）
- 親 docs: `docs/design/ios-design.md` §11.1（Platform 行）・§11.3（I-S3a 行）
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（SG-A6/SG-A10/SG-B3, Q8）
- trial-log: `docs/trial-log/player-auto-converge.md`・`docs/trial-log/mino-design-review-delegation.md`
- 検証: `docs/research-reports/2026-09-16-code-design-review/verification-run.md` §7（AVPlayer 参照 2 ファイル）
