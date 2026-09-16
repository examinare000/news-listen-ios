## iOS リファクタ S3b: 再生ドメイン本体（Session・Coordinator・OfflineLibrary・Queue・Episode decode）

## 概要
再生ドメインの正本を `Podcast/Playback/` へ切り出し、`PlaybackSession`（transport 状態 union）・`PlaybackCoordinator`（use case orchestration）・`OfflineLibrary`・`PositionReporter` を新設して `PodcastViewModel` を facade 化する。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§3.1 Playback・§3.2 Catalog・§4 CI-T1〜T11・§5 capsule・§6 S3b 行）。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。generate_spec の spec.md は Spec の該当契約（CI-T1〜T11）の抜粋で足り、契約 ID は Spec のものを再利用する。

Spec §8 着手順 3（**一括切替**）。S3a で移植した 17 関数を含む `PodcastViewModelTests`（68）全 green が入口条件。

## 前提・着手条件
- 依存: S3a が merge 済みで `PodcastViewModelTests`（68）が全 green であること。これが満たされない場合は着手しない。
- **Selection Gate 3 件は pending のため現行値を pin する**（gate 確定後に差分 PR）:
  - SG-X1（完聴時の送信値）: iOS 現行の **0** を維持する。`duration` へ変更しない。
  - SG-X3（cleanup 完了待ち）: iOS は **待たない**（S2 の現行方針を継続。`stopForLogout()` は cleanup 完了を待たずに呼ばれる前提のまま）。
  - SG-X5（速度 8 段）: iOS 現行の **`PlaybackConstants` の値域（5 段 Picker）を維持**する。8 段へ拡張しない。
- `docs/trial-log/player-auto-converge.md`・`docs/trial-log/transcript-sync-highlight.md` を必ず読む。stale ガード（`endedId` 引数化）・トランスクリプト自動追従リセット（`.task(id:)` / `.onDisappear`）は既存挙動として維持し、再設計しない。
- 本 slice は一括切替。特性テスト（下記）が全て移植・green になってから production の切替に入る。それ以前は revert 以外の回復手段が無い（Spec §6 rollback）。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`Podcast/Playback/PlaybackSession.swift`（新規）**: Spec §3.1 の 7 状態 union（idle / loading / playing / buffering / paused / ended / errored）と 16 遷移。`position ∈ [0, duration]` の clamp、`errored` からの `play()` は同じ source 解決をやり直す。
2. **`Podcast/Playback/PlaybackCoordinator.swift`（新規）**: `startEpisode(_ podcast:, expandsPlayer:)` を 1 経路に統合（`playNow` / `playById` / `replayCurrentEpisode` の 3 経路を置換。挿入規則は全経路に `queue.jump` → 失敗なら `playNext` → `jump` を適用）。`onEnded(endedId:)`（stale ガード → `PositionReporter.listenCompleted` → `queue.advance()` → 成功なら次を `startEpisode`、**失敗時は停止**して `session = errored(reason)` かつ `queue.currentIndex` は進めたまま）。`removeFromQueue(id:)`・`retry()`・`stopForLogout()`（`PlaybackLifecycle` 実装を引き継ぎ、S2 の TP4 を解消する）。
3. **`Podcast/Playback/OfflineLibrary.swift`（新規）**: 既存 `AudioCacheManager` を包み、合成 root で 1 インスタンスを生成して `PlaybackCoordinator` と `SettingsViewModel` に注入（S2 の TP2 を解消）。`has` / `url` はファイル実体を正本、`savedIds` を `@Published private(set)` で publish。
4. **`Podcast/Playback/PositionReporter.swift`（新規）**: 15 秒 throttle、`pause`/`stop`/背景遷移で即時、完聴 → 位置 0 の順（SG-X1 pin により 0 のまま）。完聴通知はクライアント側で 1 セッション 1 回に抑止。失敗は `lastSyncFailure: ApiFailure?` で観測可能に。
5. **`Podcast/Platform/AVPlayerEngine.swift`・`Podcast/Platform/MediaPlayerNowPlaying.swift`（新規）**: S3a の `AudioEngine` port の実装と `NowPlayingCenter` port の残り操作（`update` / `registerCommands` / `unregister`）。`AudioSession` / `NotificationCenter`（割り込み・route change）は adapter 内部に閉じ、port にしない。
6. **`PlaybackQueue`（既存）**: `init` / `setQueue` に id dedupe の内部 gate を追加（不変条件 1。公開操作は throw しない）。公開操作名・型は変更しない（`reorderUpNext(fromOffsets:toOffset:)` は rename しない。Spec §5 naming_decisions）。
7. **`Models/Episode.swift`（新規）**: `Podcast` DTO の decode 結果として `PlayableEpisode / GeneratingEpisode / FailedEpisode` を判別。未知 `status` は fail-closed で `FailedEpisode`。`PodcastRowView.swift:118-133` の文字列分岐を switch へ置換。
8. **`PodcastViewModel.swift` の facade 化**: `currentPodcast` を `nowPlaying()` 派生の computed に置換（reader 19 箇所は型変更なしで読める形を保つ）。`downloadedIds` → `savedIds`、`didFinishCurrentEpisode` → `session == .ended`。**TP3** として旧公開プロパティ名（`isPlaying` / `currentTime` / `duration` / `playbackSpeed` / `isBuffering` / `errorMessage` / `currentPodcast` / `queue`）を computed で残す（削除条件: S5 で View が `nowPlaying()` / `session` を直接読むよう置換完了）。
9. **`DesignSystem/PreviewSupport.swift:152-166`**: Coordinator の DEBUG ファクトリ経由に置換（LF11 解消）。
10. **`PodcastView.swift:45,135`**: `errorMessage = nil` の直書きを `dismissError()` command へ置換（LF2 / SG-A9）。
11. **`QueueSheet.swift:22`・`PodcastView.swift:90`**: `currentPodcast` の AND 合成・比較を `nowPlaying()?.episodeId` へ置換。

## 契約（CI-T → T-T の表）
| CI | 内容 | T-T |
|---|---|---|
| CI-T1 | 16 遷移以外は起きない。`errored` は `paused`/`buffering` と区別できる | T-T1: double 事象で 16 遷移を駆動し `state` を観測（分母 16） |
| CI-T2 | engine `failed` → `errored(engine_failed)`。重複 `play()` は 1 状態に収束 | T-T2 |
| CI-T3 | `start` 後の位置は server 値（末尾 2 秒以内 or duration 0 なら 0）。`ready` 後に再適用 | T-T3（既存 resume 系を特性テストとして流用）。RS-01〜RS-07（shared-playback-spec §4.3）の行 ID を含む |
| CI-T4 | セッション速度は `start` で既定速度に初期化、以後保持。既定速度は Preferences のみが書く | T-T4。PS-08 の行 ID を含む |
| CI-T5 | `unavailable` → gateway 呼出なし、`errored(offline_uncached)`。`network` → `fetchPodcast` を 1 回呼びその `audioUrl` で開始。取得失敗は保持 URL でフォールバック | T-T5（gateway double の呼出回数と URL を観測） |
| CI-T6 | advance 後の再生失敗: `queue.current` = 失敗エピソード（index は進む）、`errored(reason)`、`retry()` が同エピソードで再実行。15 秒 Timer は停止 | T-T6。PS-01〜PS-03 の行 ID を含む |
| CI-T7 | INV-P1（`session.episode.id == queue.current?.id`）が全公開操作後に成立。読出口は `nowPlaying()` のみ | T-T7a: 全操作後の INV-P1 検査。T-T7b: `grep -rn "currentPodcast\s*=" NewsListenApp/NewsListenApp --include=*.swift` が `Podcast/Playback/` 以外で 0 件。PS-04 の行 ID を含む |
| CI-T8 | 完聴 → 位置 0 の順。同一 episode の完聴通知はクライアント側で 1 セッション内 1 回に抑止。失敗は `lastSyncFailure` に現れる | T-T8（gateway double の呼出列と `lastSyncFailure`）。PS-05〜PS-06 の行 ID を含む |
| CI-T9 | `init`/`setQueue` は id を dedupe。単一要素 `reorderUpNext` は `moveUpNext` と等価。Q-01〜Q-32 不変 | 既存 conformance 32 件（不変）＋ T-T9（重複 id の property test） |
| CI-T9b | 複数要素 `IndexSet` の `reorderUpNext` は `Array.move(fromOffsets:toOffset:)` と同じ結果 | T-T9b: 期待値表（Spec §4 CI-T9b 行）を実測突合 |
| CI-T10 | `has`/`url` はファイル実体が正本。`clearAll` 後は `savedIds` が即 空 | T-T10（`FileStore` double） |
| CI-T11 | DTO → 判別共用体。矛盾 DTO・未知 status は `FailedEpisode`。▶は Playable のみ | T-T11（status 4+未知 × audioUrl 2 × errorMessage 2 = 20）。PS-07 の行 ID を含む |

## 特性テスト（baseline。着手前に green を確認）
S3a で移植済みの `PodcastViewModelTests`（68、facade 切替後の回帰検知として維持）・`PlaybackQueueTests`（12）・`PlaybackQueueConformanceTests`（32）・`NowPlayingInfoTests`（13）・`AudioCacheManagerTests`（13）・`TranscriptTimingTests`（13。`currentTime` 駆動が不変であること）。

## 手順（TDD 順序・一括切替）
1. baseline: 上記特性テスト全件と `xcodebuild test -only-testing:NewsListenAppTests` の green を記録する（S3a の 68 green を含む）。
2. `Episode` decode（T-T11）→ `PlaybackQueue` dedupe（T-T9/T-T9b）→ `OfflineLibrary`（T-T10）→ `PlaybackSession`（T-T1/T-T2）の順に、依存の少ないものから RED → 実装 → GREEN で積み上げる。
3. `PlaybackCoordinator`（T-T3〜T-T7）と `PositionReporter`（T-T8）を実装し、S3a の double を使って `startEpisode` / `onEnded` / advance 失敗の停止を駆動する。
4. `AVPlayerEngine` / `MediaPlayerNowPlaying` の実 adapter を実装する。
5. `PodcastViewModel` を facade化し、TP3 を導入する。既存 68 テストが新 facade 経由で green になることを確認する（大きな一括切替はここで初めて production の呼出経路を新 capsule へ切り替える）。
6. `PodcastView.swift` の `dismissError()`、`QueueSheet.swift` / `PodcastView.swift` の `nowPlaying()` 参照置換、`PreviewSupport` の DEBUG ファクトリ化を行う。
7. S2 の TP2（`OfflineLibrary` の既定引数）・TP4（`PodcastViewModel` の `PlaybackLifecycle` 暫定実装）を解消する（削除条件が本 slice で満たされるため）。
8. 1 slice = 1 PR。commit は「Episode decode」「Queue dedupe」「OfflineLibrary」「Session」「Coordinator/PositionReporter」「facade 切替」の単位で分ける。

## 完了条件
- `xcodebuild test -only-testing:NewsListenAppTests` が全 green（特性テスト＋新規 T-T*）。
- T-T1〜T-T11（T9b 含む）が `verifies: CI-T*` をテスト名またはコメントに持ち、PS-01〜PS-08 / RS-01〜RS-07 の行 ID をテスト名に含める。
- `grep -rn "currentPodcast\s*=" NewsListenApp/NewsListenApp --include=*.swift` が `Podcast/Playback/` 以外で 0 件（T-T7b）。
- `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include=*.swift` が `Networking/` 以外で 0 件（T-T13、S1 からの回帰が無いこと）。
- `Podcast/Playback/` が `AVFoundation` / `MediaPlayer` / `UIKit` / `SwiftUI` を import しない。`APIClient` を import しない（gateway 関数をクロージャで受ける）。
- S2 の TP2・TP4 が削除されている。TP3 は本 slice で導入し維持する（削除は S5）。
- シミュレータ目視 UV3 の 3 項目（logout 後のロック画面に前主体の NowPlaying が残らない、auto-advance 失敗時に停止表示が出る、一覧放置 1 時間後の再生）を確認し、結果を PR 説明に記す。

## 禁止事項 / scope 外
- `AudioCacheManager` の protocol 化（RO7）・`BaseViewModel`（RO3）・再生ソース Strategy（RO2）・汎用 Repository（RO1）・stale guard 共通抽象（RO6）・AVPlayer 鏡写し `AudioEngineProtocol`（RO4）・token provider 注入（SG-A7 default）は作らない。
- `reorderUpNext` の rename はしない（web と逆の判断。Spec §5 naming_decisions）。
- SG-X1 / SG-X3 / SG-X5 の pending 値を先回りして変更しない（0 のまま・待たないまま・5 段のまま）。
- `QueueSheet` / `PodcastView` / `MiniPlayerView` / `AudioPlayerView` の `nowPlaying()` / `session` 直読みへの全面置換（TP3 の削除）は S5 の範囲であり本 slice では行わない（本 slice の対象は §対象 11 の 2 箇所のみ）。
- Spec に無い業務条件（新しい失敗理由・新しい状態）を足さない。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §3.1〜§3.5・§4（CI-T1〜T11, T9b）・§5・§6（S3b 行・S3b の scope 上の注意）
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（SG-A1〜A3, Q2〜Q6, Q8）
- 親 docs: `docs/design/shared-playback-spec.md` §2.7・§2.11・§4.3（RS-01〜07）・§4.4（PS-01〜08, SL-01〜05）・§6.4〜§6.7（SG-X1, SG-X3, SG-X5）
- trial-log: `docs/trial-log/player-auto-converge.md`・`docs/trial-log/transcript-sync-highlight.md`
