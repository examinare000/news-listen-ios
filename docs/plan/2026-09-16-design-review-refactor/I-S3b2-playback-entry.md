## iOS リファクタ I-S3b2: 入口の差し替え（Platform adapter・facade 化・`startEpisode` 1 経路）

## 概要
I-S3b1 で新設した `Podcast/Playback/` を production の入口に接続する。`Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}` を実装し、合成 root が `OfflineLibrary`・adapter・`PlaybackCoordinator`・`PositionReporter` を生成、`PodcastViewModel` を Coordinator の薄い facade にする（3 段分割の ②）。**共有仕様 §2・Q-01〜Q-32 は挙動不変**（特性テストで判定）。**変わる挙動は下の「変更行」だけ**（準拠テストで判定）。旧公開プロパティは TP3 として computed で暫定維持し、旧実装の物理削除は I-S3b3。正本は Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§2 composition root・§3.1・§3.5・§4 CI-T4〜T9b・T11・§6 S3b 行と scope 上の注意）。検証モード（再設計しない）。新しい契約 ID を作らない。

## 前提・着手条件
- 依存: I-S3b1 が merge 済み（T-T1〜T-T8・T-T10・T-T11 green）。
- 確定済み: SG-X1（完聴時 `duration` 明示送信）・SG-X4（一時停止中は送らない）・SG-X3（待たない）・速度の既定初期化（共有仕様 §6.6）・advance 失敗は停止（§2.11・ADR-103）。
- `docs/trial-log/player-auto-converge.md`・`docs/trial-log/transcript-sync-highlight.md` を読む。stale ガード（`endedId`）・トランスクリプト自動追従リセット（`.task(id:)` / `.onDisappear`）・`RequestRecordingSession` の直列化は既存どおり。AVPlayer 2 系統の併存は棄却済み（`mino-design-review-delegation.md`）: facade 化と同時に旧 VM の AVPlayer 生成を止める。

## 対象（ios サブモジュールのみ）
**新規**: `Podcast/Platform/AVPlayerEngine.swift`（`AudioEngine` 実装。AVPlayer・KVO・periodic observer・didPlayToEnd・AudioSession・割り込み・route change を内包し `AsyncStream<EngineEvent>` を publish）、`Podcast/Platform/MediaPlayerNowPlaying.swift`（`NowPlayingCenter` の `update / registerCommands / unregister`。I-S2 が作った `clear` のみの adapter ファイルはここへ移動・改名して拡張する＝変更対象 10）。
**変更（この 10 ファイルのみ。準拠テストの新規ファイル追加は可）**:
1. `NewsListenAppApp.swift`: App が `OfflineLibrary`・`AVPlayerEngine`・`MediaPlayerNowPlaying` を 1 インスタンス生成。`ContentView` が `PlaybackCoordinator`・`PositionReporter`（background task closure は `UIApplication.beginBackgroundTask` をここで渡す）・facade `PodcastViewModel` を生成し、`AppState.registerPlaybackLifecycle(coordinator)` を登録（TP4 の削除条件成立）。`:170` の `flushPlaybackPosition()` は `PositionReporter.flush()` へ、`:185` の `playById(id)` は facade 経由で `startEpisode` へ。
2. `Podcast/PodcastViewModel.swift`: facade 化。`player` と AVFoundation / MediaPlayer / NotificationCenter / `UIApplication` 依存の private 実装を除去し、Coordinator の 15 操作を中継。**TP3**: `isPlaying / currentTime / duration / playbackSpeed / isBuffering / errorMessage / currentPodcast / queue` を `nowPlaying()` / `session` 派生の computed で維持（`didFinishCurrentEpisode` = `session == .ended`、`downloadedIds` = `library.savedIds`）。`playNow / playById / replayCurrentEpisode / stopPlayback / flushPlaybackPosition / handlePlaybackEnded / previewMarkFinished / resolvePlaybackURL / syncDownloadedState` は Coordinator / PositionReporter / Library への forwarder として名前を残す（削除は I-S3b3）。`download / removeDownload / downloadState(for:) / isPlayableWhileOffline` は facade に残る操作（Library へ委譲）。AVFoundation 型を signature に持つ `shouldProcessPlayerItemCallback / shouldProcessPlayerCallback / handlePlayerItemStatusChange / handleTimeControlStatusChange` は engine 内部として `AVPlayerEngine` へ移し VM から消す（I-S3a でテストは double 駆動へ移植済みのため参照 0）。`import AVFoundation / MediaPlayer / UIKit` を `PodcastViewModel.swift` から外す。owner: user、導入: I-S3b2、削除条件: I-S3b3 で View が `nowPlaying()` / `session` を直読みし forwarder の参照が 0 になった時。
3. `Podcast/PlaybackQueue.swift`: `init` / `setQueue` に id dedupe の内部 gate（CI-T9。公開操作名・型は不変）。
4. `Podcast/PodcastRowView.swift:118-133`: status 文字列分岐を `Episode` 種別の switch へ。▶は `PlayableEpisode` のみ（PS-07）。
5. `Podcast/PodcastView.swift:45,135`: `errorMessage = nil` → `dismissError()`。`:90` の比較を `nowPlaying()?.episodeId` へ。
6. `Podcast/QueueSheet.swift:22`: `currentPodcast != nil && queue.current` の AND 合成を `nowPlaying()?.episodeId` へ。
7. `DesignSystem/PreviewSupport.swift:152-166`: `vm.currentPodcast = …` 等の直書きを Coordinator の DEBUG ファクトリ経由に置換（T-T7b の grep が 0 になる）。
8. `Settings/SettingsViewModel.swift`: 合成 root から `OfflineLibrary` を注入して使う（TP2 の削除条件成立。既定引数 `= AudioCacheManager()` の物理削除は I-S3b3）。
9. `NewsListenAppTests/PodcastViewModelTests.swift`: facade 経由で全件 green にする。書き換えてよいのは「変更行」に該当するテストだけ（下記）。
10. I-S2 の `NowPlayingCenter` adapter ファイル（`clear` のみ）: `Podcast/Platform/MediaPlayerNowPlaying.swift` へ移動・拡張。

TP3 の `errorMessage` は「`session` が `errored` のときの理由文言 ?? 一覧読込（`loadPodcasts`）の失敗文言」の合成 computed とし、一覧読込の失敗文言は facade が保持する（`testLoadPodcasts*` の期待値は不変）。

## 変更行（これ以外の挙動変更は禁止）
| 行 ID | 変わる挙動 | 判定テスト |
|---|---|---|
| PS-01 / PS-02 / PS-03 | advance 後の取得失敗・オフライン未キャッシュで停止し `Queue.current` = 失敗エピソード、手動 play で再解決（現行は未定義） | 準拠テスト（facade＋double。CI-T6） |
| PS-04 | `playById`（通知経路）・`replayCurrentEpisode` も `startEpisode` 1 経路で INV-P1 を満たす（通知経路がキューに載る。Q2） | 準拠テスト（CI-T7）＋ T-T7b grep |
| PS-05 / PS-05b | error / idle で位置同期を送らない。一時停止中は周期送信しない（SG-X4。iOS 現行どおりだが行 ID 付きで pin） | 準拠テスト（CI-T8） |
| PS-06 | 完聴 → **`duration` の位置書込 1 回** → advance（SG-X1。現行は停止時同期の値に任せる）。完聴は 1 セッション 1 回 | 準拠テスト（CI-T8）。既存 `testPlaybackEndedMarksCapturedPodcastBeforeAutoAdvanceAndRefreshesStreak` / `testCompletionFailureDoesNotBlockQueueAutoAdvance` を行 ID 付きへ昇格 |
| PS-07 | `completed` かつ `error_message` 非 null は再生不可・▶なし（現行は文字列分岐） | 準拠テスト（CI-T11）＋ `PodcastRowView` |
| PS-08 | セッション速度を開始時に既定速度で初期化（現行は `1.0` 固定・非初期化）。セッション中の変更は既定速度を書かない | 準拠テスト（CI-T4）。既存 `testSetSpeedUpdatesPlaybackSpeed*` は期待値を既定速度基準に |
| CI-T9 / T9b（行 ID なし） | `init` / `setQueue` の重複 id を dedupe（不変条件 1）。重複入力以外の Q-* は不変 | T-T9（property）・T-T9b（期待値表）＋ conformance 32 件不変 |

上表以外で既存テストの期待値を変える必要が出たら、実装を止めて報告する（scope 逸脱）。`testReplayCurrentEpisode*` 4 件は replay が `startEpisode` 経路になるが期待値は不変（完聴後の server 位置 = `duration` は RS-05 で 0）。

## 完了条件
- 既存テスト全件 green（`PodcastViewModelTests` は facade 経由。`PlaybackQueueConformanceTests` 32 件・`PlaybackQueueTests` 12 件・`NowPlayingInfoTests` 13 件・`TranscriptTimingTests` 13 件・`AudioCacheManagerTests` 13 件は無変更で green）。
- 準拠テストが green で、テスト名に **PS-01〜PS-08（05b 含む）** の行 ID と `verifies: CI-T4/T6/T7/T8/T9/T9b/T11` を持つ。
- T-T7b: `grep -rn "currentPodcast\s*=" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/Playback/` 以外で 0 件。T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include='*.swift'` が `Networking/` 以外で 0 件（S1 の回帰なし）。
- 依存方向: `Podcast/Playback/` の import 禁止 grep（I-S3b1 と同じ）が 0 件。`grep -rn "AVPlayer\|MPNowPlayingInfoCenter\|MPRemoteCommandCenter" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/Platform/` 以外で **コメント行を除き** 0 件（`Podcast/NowPlayingInfo.swift`・`PlaybackConstants.swift`・I-S3a の port 定義のコメント言及は除外。`PodcastViewModel.swift` に AVPlayer 生成が無い＝2 系統にならない）。
- `PlaybackLifecycle` の登録先が `PlaybackCoordinator`（`grep -n "registerPlaybackLifecycle" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` の引数が coordinator）。`AudioCacheManager` の生成が `NewsListenAppApp.swift` の 1 箇所（`grep -rn "AudioCacheManager()" NewsListenApp/NewsListenApp --include='*.swift'` のコード行は `Settings/SettingsViewModel.swift` の既定引数 2 行＝TP2 と `NewsListenAppApp.swift` の 1 行のみ。doc コメント行は除外。`PodcastViewModel.swift:122` の既定引数は facade 化で消える）。
- TP3 の owner / 導入 / 削除条件がコード上のコメントまたは PR 説明にある。
- シミュレータ目視 UV3 の 3 項目（logout 後のロック画面に前主体の NowPlaying が残らない、auto-advance 失敗時に停止表示、一覧放置 1 時間後の再生）を PR 説明に記す。

## 禁止事項 / scope 外
- `AudioPlayerView` / `MiniPlayerView` / `QueueSheet`（`:22` 以外）/ `PodcastView`（`:45,90,135` 以外）の読み替え（TP3 の削除）はしない。forwarder・TP2 / TP4 のコード・`didFinishCurrentEpisode` / `downloadedIds` の物理削除はしない（I-S3b3）。
- 「変更行」以外の挙動を変えない（Q-*・resume 規則・stale ガード・トランスクリプト同期・presentation 遷移）。`reorderUpNext` を rename しない。RO1〜RO7・SG-A7 を作らない。

## 特性テスト（baseline）
着手前に green を記録: `PodcastViewModelTests`（I-S3a 完了時点の全件）・`PlaybackQueueTests`（12）・`PlaybackQueueConformanceTests`（32）・`NowPlayingInfoTests`（13）・`AudioCacheManagerTests`（13）・`TranscriptTimingTests`（13）・`SettingsViewModelTests`（36）・`AppStateAuthTests`。

## 検証
- `xcodebuild test -only-testing:NewsListenAppTests`（README の完全なコマンド）→ 全 green。
- 上記 grep 5 本 → 期待どおり。commit は「Platform adapter」「Queue dedupe」「Episode 切替（PS-07）」「facade 切替＋TP3」「View 2 箇所・Preview」「準拠テスト」の単位。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記。router へ返す: 共有仕様 §4.4 の PS-01〜PS-08 の iOS 保留（解除条件 = I-S3b2）が解除可能。`docs/design/ios-design.md` §8（AVPlayer 設計）を Platform adapter の現状記述へ、§11.3 I-S3b2 行を完了へ。
