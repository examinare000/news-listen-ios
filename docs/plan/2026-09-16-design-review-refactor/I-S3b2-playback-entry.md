## iOS リファクタ I-S3b2: 入口の差し替え（facade 化・`startEpisode` 1 経路・変更行 PS-01〜PS-08）

## 概要
I-S3b1 で新設した `Podcast/Playback/` を production の入口に接続する。合成 root が `OfflineLibrary`・`PlaybackCoordinator`・`PositionReporter` を生成し（`AVPlayerEngine` / `MediaPlayerNowPlaying` は I-S3a で生成済み）、`PodcastViewModel` を Coordinator の薄い facade にする（3 段分割の ②。**決定境界は「入口の差し替え」1 つ**。Platform adapter は I-S3a へ前倒し済み）。**共有仕様 §2・Q-01〜Q-32 は挙動不変**（特性テストで判定）。**変わる挙動は下の「変更行」だけ**（準拠テストで判定）。旧公開プロパティは TP3 として computed で暫定維持し、旧実装の物理削除は I-S3b3。正本は Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§2 composition root・§3.1・§4 CI-T4〜T9b・T11・§6 S3b 行と scope 上の注意）。検証モード（再設計しない）。新しい契約 ID を作らない。

## 前提・着手条件
- 依存: **I-S3b1 の submodule PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（`git -C <親> submodule status` で `ios` に `+` が無い）。T-T1〜T-T8・T-T10・T-T11 green。
- 確定済み: SG-X1（完聴時 `duration` 明示送信）・SG-X4（一時停止中は送らない）・SG-X3（待たない）・速度の既定初期化（共有仕様 §6.6）・advance 失敗は停止（§2.11・ADR-103）。
- `docs/trial-log/player-auto-converge.md`・`docs/trial-log/transcript-sync-highlight.md` を読む。stale ガード（`endedId`）・トランスクリプト自動追従リセット（`.task(id:)` / `.onDisappear`）・`RequestRecordingSession` の直列化は既存どおり。AVPlayer 2 系統の併存は棄却済み（`mino-design-review-delegation.md`）: `AVPlayerEngine` の 1 インスタンスを Session が引き継ぎ、VM 側の engine 消費ループ（I-S3a）を facade 化で消す。

## 対象（ios サブモジュールのみ。変更はこの 8 ファイルのみ。準拠テストの新規ファイル追加は可）
1. `NewsListenAppApp.swift`: App が `OfflineLibrary` を 1 インスタンス生成（`AVPlayerEngine`・`MediaPlayerNowPlaying` は I-S3a 済み）。`ContentView` が `PlaybackCoordinator`・`PositionReporter`（background task closure は `UIApplication.beginBackgroundTask` をここで渡す）・facade `PodcastViewModel` を生成し、`AppState.registerPlaybackLifecycle(coordinator)` を登録（TP4 の削除条件成立）。`:170` の `flushPlaybackPosition()` は `PositionReporter.flush()` へ。**`:185` は forwarder `playById(id)` を呼び続ける**（内部は Coordinator の `startEpisode(id:)`（I-S3b1。`fetchPodcast(id)` → `startEpisode` の 1 経路）。解決失敗は現行どおり facade の `errorMessage` に `FailureMessages.message(for:context: .podcast)`。呼出側の付け替えは I-S3b3）。
2. `Podcast/PodcastViewModel.swift`: facade 化。**TP5 の削除**（2026-09-30 追加。SG-C23）: I-S3a が VM に置いた「engine に音声が読み込まれているか」の private な旗を消し、リモートコマンドと `togglePlayPause` の判定を Coordinator の `session`（`idle` か否か）に置き換える。リモートコマンドの解除を主体離脱の後始末へ移すかは本 slice の着手前に user が判断する（SG-C28 の保留。決まるまでは現行どおり登録者の破棄時）。I-S3a で port 経由になった engine 消費ループ・NowPlaying 更新・`UIApplication` 依存の private 実装を除去し、Coordinator の 17 操作（I-S3b1。SG-C10 で `startEpisode(id:)` / `replayCurrent()` を含む）を中継。**TP3**: `isPlaying / currentTime / duration / playbackSpeed / isBuffering / errorMessage / currentPodcast / queue` を `nowPlaying()` / `session` 派生の computed で維持（`didFinishCurrentEpisode` = `session == .ended`、`downloadedIds` = `library.savedIds`。`nowPlaying()` の `NowPlaying` は `Podcast` DTO を持たない（SG-C11）ため、`currentPodcast` は `nowPlaying() != nil` のとき TP3 の `queue` と同じ読出口（Coordinator の `queue.current`）から導く）。`playNow / playById / replayCurrentEpisode / stopPlayback / flushPlaybackPosition / handlePlaybackEnded / previewMarkFinished / resolvePlaybackURL / syncDownloadedState` は Coordinator / PositionReporter / Library への forwarder として名前を残す（`playById` → `startEpisode(id:)`、`replayCurrentEpisode` → `replayCurrent()`。削除は I-S3b3）。`download / removeDownload / downloadState(for:) / isPlayableWhileOffline` は facade に残る操作（Library へ委譲）。`import UIKit` を外す（AVFoundation / MediaPlayer は I-S3a で除去済み）。`init` の既定引数 `cacheManager: AudioCacheManager = AudioCacheManager()`（`:122`）は facade 化で消える。owner: user、導入: I-S3b2、削除条件: I-S3b3 で View が `nowPlaying()` / `session` を直読みし forwarder の参照が 0 になった時。
   **状態の転写（2026-09-24 導出。操作ではなく状態の写しなので「facade 固有操作なし」は維持）**: facade は Coordinator（I-S3b1 で `ObservableObject`）の `@Published private(set)` 3 値を同名の `@Published private(set) var session: PlaybackState` / `presentation: PlayerPresentation` に転写し（`coordinator.$session` / `$presentation` を `assign(to: &$session)` 等で接続。facade 側で値を書かない）、`queue` は TP3 computed（`coordinator.queue`）として読む。あわせて Coordinator の `objectWillChange` を facade の `objectWillChange` へ接続する（`nowPlaying()` / `upNext()` は関数なので、queue 変化時の View 再描画契機はこれで担保する）。`presentation` の所有者は Coordinator（Spec §5 CP4 の ops に `presentation` を含む）で、facade の `@Published presentation` は所有値の転写であり、現行 `minimizePlayer()` / `expandPlayer()`（`NewsListenAppApp.swift:220`・`MiniPlayerView.swift:42` が呼ぶ）は Coordinator の `presentation` 遷移への forwarder として名前を残す（呼出の付け替え・削除は本 slice の対象外。TP3 と同じく I-S3b3 の表 A に含めず残す = 17 操作の `presentation` 値遷移の入口）。View は Coordinator を直接持たない（`ContentView` が生成して facade にだけ渡す）。
   **`dismissError()`**: facade の `dismissError()` は「自身の `errorMessage = nil`」と「Coordinator の `dismissError()` 中継」の両方を行う（`PodcastView.swift:45,135` の `errorMessage = nil` 置換先として一覧読込の失敗も消せるようにする）。
3. `Podcast/PlaybackQueue.swift`: `init` / `setQueue` に id dedupe の内部 gate（CI-T9。公開操作名・型は不変）。
4. `Podcast/PodcastRowView.swift:118-133`: status 文字列分岐を `Episode` 種別の switch へ。▶は `PlayableEpisode` のみ（PS-07）。
5. `Podcast/PodcastView.swift:45,135`: `errorMessage = nil` → `dismissError()`。`:90` の比較を `nowPlaying()?.episodeId` へ。
6. `Podcast/QueueSheet.swift:22`: `currentPodcast != nil && queue.current` の AND 合成を `nowPlaying()?.episodeId` へ。
7. `DesignSystem/PreviewSupport.swift:152-166`: `vm.currentPodcast = …` 等の直書き 7 箇所（`:153-157`・`:165-166`）を、I-S3b1 が `Podcast/Playback/PlaybackCoordinator+Preview.swift` に置いた `PlaybackCoordinator.preview(session:queue:)`（`#if DEBUG`）で組んだ Coordinator を facade の `init` に渡す形へ置換する（`playerViewModel()` = `session: .playing(position: 72, duration: 247, speed: 1.0)`・`queue` は `podcasts[0]` を current に、`finishedPlayerViewModel()` = `session: .ended`）。ファクトリは I-S3b1 の成果で、本 slice は `Podcast/Playback/` を変更しない（下記「禁止事項」と両立）。置換後は `previewMarkFinished()` の呼出が 0 になるが、forwarder 自体は残す（削除は I-S3b3）。T-T7b の grep が 0 になる。
8. `Settings/SettingsViewModel.swift`: `cacheManager: AudioCacheManager` を `library: OfflineLibrary` に置き換え、合成 root から注入して使う（`usage()` / `clearAll()`。Spec §2 composition root「`OfflineLibrary` を App から受ける」）。**TP2 は型を変えて残す**: 2 つの `init`（`:69,76`）の既定引数を `library: OfflineLibrary = OfflineLibrary(cacheManager: AudioCacheManager())` とし、注入完了＝TP2 の削除条件成立。既定引数の物理削除は I-S3b3。

テスト: `NewsListenAppTests/PodcastViewModelTests.swift` は facade 経由で全件 green にする。**helper（`makeViewModel` / `playingViewModel` 等）と Given の組み立ては facade 構成（Coordinator・double 注入）に合わせて変えてよい。Then（期待値）を変えてよいのは「変更行」に該当するテストだけ**（下記）。`SettingsViewModelTests`（36）は `OfflineLibrary` 注入への Given の書き換えのみ（Then 不変）。

TP3 の `errorMessage` は「`session` が `errored(reason)` のときの理由文言 ?? facade 所有の失敗文言」の合成 computed とする。facade 所有の失敗文言は `@Published private(set) var listErrorMessage: String?` に保持し、**由来は現行 `PodcastViewModel.swift` の書込のうち facade に残る操作のもの**（一覧読込 `loadPodcasts` `:145,151,153`、`download` `:203,213,216`、`removeDownload` `:227`。2026-09-24 実測）。再生由来の書込（`:270,274` play・`:391,393` playById・`:425` engine failed・`:631` audio session）は Coordinator / Session の `errored(reason)` へ移り、facade は書かない。理由 → 文言の写像は本ファイルの `static func playbackErrorMessage(for reason: PlaybackErrorReason) -> String`（純関数。`offline_uncached` = "Offline and not cached"、`invalid_source` = "Invalid audio URL"、`engine_failed(description)` = `description ?? "Playback failed"`、`fetch_failed(f)` = `FailureMessages.message(for: f, context: .podcast)`。現行文言と同値）に置き、I-S3b3 で View が合成に使う（`testLoadPodcasts*`・`testDownload*` の期待値は不変）。`shouldPresentErrorAlert` / `displayState` は合成後の `errorMessage` で判定し、`PodcastView` の alert は 1 つのまま。

## 変更行（これ以外の挙動変更は禁止）
| 行 ID | 変わる挙動 | 判定テスト |
|---|---|---|
| PS-01 / PS-02 / PS-03 | advance 後の取得失敗・オフライン未キャッシュで停止し `Queue.current` = 失敗エピソード、手動 play で再解決（現行は未定義） | 準拠テスト（facade＋double。CI-T6） |
| PS-04 | `playById`（通知経路）・`replayCurrentEpisode` も `startEpisode` 1 経路で INV-P1 を満たす（通知経路がキューに載る。Q2） | 準拠テスト（CI-T7）＋ T-T7b grep |
| PS-05 / PS-05b | error / idle で位置同期を送らない。一時停止中は周期送信しない（SG-X4。iOS 現行どおりだが行 ID 付きで pin） | 準拠テスト（CI-T8） |
| PS-06 | 完聴 → **`duration` の位置書込 1 回** → advance（SG-X1。現行は停止時同期の値に任せる）。完聴は 1 セッション 1 回 | 準拠テスト（CI-T8）。既存 `testPlaybackEndedMarksCapturedPodcastBeforeAutoAdvanceAndRefreshesStreak` / `testCompletionFailureDoesNotBlockQueueAutoAdvance` を行 ID 付きへ昇格 |
| PS-07 | `completed` かつ `error_message` 非 null は再生不可・▶なし（現行は文字列分岐） | 準拠テスト（CI-T11）＋ `PodcastRowView` |
| PS-08 | セッション速度を開始時に既定速度で初期化（現行は `1.0` 固定・非初期化）。セッション中の変更は既定速度を書かない | 準拠テスト（CI-T4）。既存 `testSetSpeedUpdatesPlaybackSpeed*` は期待値を既定速度基準に |
| CI-T1c（行 ID なし。iOS 固有。SG-C39） | 読み込み中（buffering）に engine が止まると、再生中ではなく一時停止の表示になる（現行は buffering 表示だけ消え、再生中のまま） | 準拠テスト（CI-T1c。facade＋double） |
| CI-T1e（行 ID なし。iOS 固有。SG-C43） | 再生開始の直後から総時間が表示される（現行は最初の定期更新まで 0）。総時間が不明な間に先送りしても位置 0 へ戻らない（現行は `min(0, …)` で 0 へ戻る） | 準拠テスト（CI-T1e。facade＋double） |
| CI-T9 / T9b（行 ID なし） | `init` / `setQueue` の重複 id を dedupe（不変条件 1）。重複入力以外の Q-* は不変 | T-T9（property）・T-T9b（期待値表）＋ conformance 32 件不変 |

上表以外で既存テストの Then を変える必要が出たら、実装を止めて報告する（scope 逸脱）。`testReplayCurrentEpisode*` 4 件は replay が `startEpisode` 経路になるが期待値は不変（完聴後の server 位置 = `duration` は RS-05 で 0）。

## 完了条件
- 既存テスト全件 green（`PodcastViewModelTests` は facade 経由。`PlaybackQueueConformanceTests` 32 件・`PlaybackQueueTests` 12 件・`NowPlayingInfoTests` 13 件・`TranscriptTimingTests` 13 件・`AudioCacheManagerTests` 13 件・`AVPlayerEngineTests` 6 件は無変更で green）。
- 準拠テストが green で、テスト名に **PS-01〜PS-08（05b 含む）** の行 ID と `verifies: CI-T4/T6/T7/T8/T9/T9b/T11` を持つ。
- T-T7b: `grep -rn "currentPodcast\s*=[^=]" NewsListenApp/NewsListenApp --include='*.swift'` が `Podcast/Playback/` 以外で 0 件（`==` 比較は除外。2026-09-24 実測: 現行の一致は `PreviewSupport.swift:153,165` と `PodcastViewModel.swift:286` の 3 件で、`:533,542` の `== nil` は一致しない）。T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include='*.swift'` が `Networking/` 以外で 0 件（S1 の回帰なし）。
- 依存方向: `Podcast/Playback/` の import 禁止 grep（I-S3b1 と同じ）が 0 件。`grep -n "^import \(AVFoundation\|MediaPlayer\|UIKit\)" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0 件。I-S3a の grep（`AVPlayer|AVAudioSession|MPNowPlayingInfoCenter|MPRemoteCommandCenter` が `Podcast/Platform/` 以外でコメント行を除き 0 件。除外範囲は I-S3a と同じ）が回帰していない。
- `PlaybackLifecycle` の登録先が `PlaybackCoordinator`（`grep -n "registerPlaybackLifecycle" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` の引数が coordinator）。`grep -rn "AudioCacheManager()" NewsListenApp/NewsListenApp --include='*.swift'` のコード行が `Settings/SettingsViewModel.swift` の既定引数 2 行（TP2。`OfflineLibrary(cacheManager: AudioCacheManager())`）と `NewsListenAppApp.swift` の 1 行のみ（doc コメント行は除外。`PodcastViewModel.swift:122` の既定引数は消えている）。
- TP3 の owner / 導入 / 削除条件がコード上のコメントまたは PR 説明にある。
- シミュレータ目視 UV3 の 3 項目（logout 後のロック画面に前主体の NowPlaying が残らない、auto-advance 失敗時に停止表示、一覧放置 1 時間後の再生）を PR 説明に記す。

## 禁止事項 / scope 外
- `AudioPlayerView` / `MiniPlayerView` / `QueueSheet`（`:22` 以外）/ `PodcastView`（`:45,90,135` 以外）の読み替え（TP3 の削除）はしない。forwarder・TP2 / TP4 のコード・`didFinishCurrentEpisode` / `downloadedIds` の物理削除はしない（I-S3b3）。
- `Podcast/Platform/`・`Podcast/Playback/AudioEngine.swift`（I-S3a）と `Podcast/Playback/` の capsule・`PlaybackCoordinator+Preview.swift`（I-S3b1）を変更しない（Coordinator 側の不足が見つかったら実装を止めて報告する。`git diff --stat origin/main -- NewsListenApp/NewsListenApp/Podcast/Playback NewsListenApp/NewsListenApp/Podcast/Platform` → 0）。
- 「変更行」以外の挙動を変えない（Q-*・resume 規則・stale ガード・トランスクリプト同期・presentation 遷移）。`reorderUpNext` を rename しない。RO1〜RO7・SG-A7 を作らない。

## 特性テスト（baseline）
着手前に green を記録: `PodcastViewModelTests`（I-S3a 完了時点の全件）・`AVPlayerEngineTests`（6）・`PlaybackQueueTests`（12）・`PlaybackQueueConformanceTests`（32）・`NowPlayingInfoTests`（13）・`AudioCacheManagerTests`（13）・`TranscriptTimingTests`（13）・`SettingsViewModelTests`（36）・`AppStateAuthTests`。

## 検証
- `xcodebuild test -only-testing:NewsListenAppTests`（README の完全なコマンド）→ 全 green。
- 上記 grep → 期待どおり。commit は「Queue dedupe」「Episode 切替（PS-07）」「facade 切替＋TP3」「View 2 箇所・Preview・Settings 注入」「合成 root」「準拠テスト」の単位。

## 規模（見込み行数。2026-09-24 実測基点）
実測（現行）: `PodcastViewModel.swift` 861・`NewsListenAppApp.swift` 232・`PlaybackQueue.swift` 143・`PodcastRowView.swift` 160・`PodcastView.swift` 151・`QueueSheet.swift` 82・`PreviewSupport.swift` 196・`SettingsViewModel.swift` 294、`PodcastViewModelTests.swift` 1,302・`SettingsViewModelTests.swift` 547。
- production ≈ 650 行（削除＋追加）: `PodcastViewModel.swift` は I-S3a 後の ≈ 500 行（861 − adapter へ移る ≈ 350）から facade ≈ 250 行へ（削除 ≈ 380・追加 ≈ 130 = 510）。`NewsListenAppApp.swift` ≈ 50（合成 root）・`PlaybackQueue.swift` ≈ 15（dedupe）・`PodcastRowView.swift` ≈ 25（`Episode` switch）・`PodcastView.swift` 3・`QueueSheet.swift` 1・`PreviewSupport.swift` ≈ 20・`SettingsViewModel.swift` ≈ 10。
- test ≈ 550 行: `PodcastViewModelTests.swift` の helper（`makeViewModel` / `playingViewModel`）と Given の facade 構成化 ≈ 150、変更行の Then ≈ 50、準拠テスト新規ファイル（PS-01〜PS-08・T-T9 / T-T9b）≈ 300、`SettingsViewModelTests.swift` の Given ≈ 40。
- 合計 ≈ 1,200 行だが分割しない。理由: 分割基準 1,000 行は巻き戻し範囲 = production に適用する（README「3 段分割の理由」が 1,000 行超と数えたのは一括切替の production 差分）。production ≈ 650 は 1,000 未満で、決定境界は「入口の差し替え」1 つ。これ以上分けると facade と旧 VM の併存（AVPlayer 2 系統。棄却済み）になる。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記。router へ返す: 共有仕様 §4.4 の PS-01〜PS-08 の iOS 保留（解除条件 = I-S3b2）が解除可能。`docs/design/ios-design.md` §8（AVPlayer 設計）を Platform adapter の現状記述へ、§11.3 I-S3b2 行を完了へ。
