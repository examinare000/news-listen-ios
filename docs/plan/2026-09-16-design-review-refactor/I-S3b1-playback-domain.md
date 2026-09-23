## iOS リファクタ I-S3b1: 再生ドメイン層の新設（Session・Coordinator・OfflineLibrary・PositionReporter）

## 概要
再生ドメインの正本を `Podcast/Playback/` に**新規コードとしてだけ**置く。`PlaybackSession`（transport 状態 union）・`PlaybackCoordinator`（use case orchestration・`PlaybackLifecycle` 実装）・`OfflineLibrary`・`PositionReporter` と、Coordinator が判定に使う `Episode` decode を新設し、契約テスト（port double 駆動・表駆動）で固定する。**既存コードからは呼ばない**（production の挙動は変わらない。3 段分割の ①）。入口の差し替えは I-S3b2、旧実装の削除は I-S3b3。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§3.1 Playback・§3.2 Catalog・§4 CI-T1〜T8・T10・T11・§5 CP1/CP3/CP4/CP5/CP9）。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（再設計しない）。generate_spec の spec.md は上記 CI-T の抜粋で足り、新しい契約 ID を作らない。

## 前提・着手条件
- 依存: **I-S3a の submodule PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（`git -C <親> submodule status` で `ios` に `+` が無い）。I-S3a の成果: `Podcast/Playback/AudioEngine.swift`（port・`EngineEvent` 8 種）と test double、`Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}`、`PodcastViewModelTests` 全件 green。I-S2 の `PlaybackLifecycle` port・`NowPlayingCenter` port（I-S3a で `update / registerCommands / unregister` まで拡張済み）・`PreferenceRegistry`・`ApiFailure` が使えること。
- 確定済み Selection Gate（共有仕様 §6.4〜§6.7）を新規コードにそのまま実装する: SG-X1 = 完聴時に `duration` を明示的に 1 回送る（順序: 完聴イベント → `duration` の位置書込 → advance）、SG-X4 = 一時停止中は周期送信しない、SG-X3 = `stopForLogout()` は cleanup 完了を待たない。速度の既定初期化は Preferences の既定速度（共有仕様 §6.6）。
- 棄却済み案（再提案しない）: 旧 VM を feature flag で温存する段階移行（AVPlayer 2 系統の競合）、port を置かず純関数ガード拡張で済ませる案、`PlaybackQueue` の failable init（`docs/trial-log/mino-design-review-delegation.md`）。stale ガードは `endedId` 引数化の既存方式を踏襲する（`docs/trial-log/player-auto-converge.md`）。

## 対象（ios サブモジュールのみ。すべて新規。既存ファイルの変更は 0）
| 新規ファイル | capsule | 内容 |
|---|---|---|
| `Podcast/Playback/PlaybackSession.swift` | CP1 | Spec §3.1 の 7 状態 union と 16 遷移。`position ∈ [0, duration]` の clamp。`AudioEngine` port を駆動し `stateChanged / positionChanged / ended(episodeId)` を emit。公開操作 `start / play / pause / seek / seekRelative / setSpeed / stop / state` |
| `Podcast/Playback/PlaybackCoordinator.swift` | CP4 | `startEpisode(_:expandsPlayer:)`（`queue.jump` → 失敗なら `playNext` → `jump`、`Episode` decode、`resolvePlaybackSource`、network なら `fetchPodcast` 再取得・失敗は保持 URL、`resolveResumePosition`、`session.start(speed: 既定速度)`）、`onEnded(endedId:)`（stale ガード → `listenCompleted` → `advance` → 次を `startEpisode`。失敗は停止し `errored`）、`removeFromQueue / retry / togglePlayPause / seek / setSpeed / addToQueue / playNext / moveUpNext / skipToNext / nowPlaying() / upNext() / presentation / dismissError / stopForLogout`。`PlaybackLifecycle` に準拠。純関数 `resolvePlaybackSource(hasCached:isOnline:) → cached \| network \| unavailable` と `resolveResumePosition(serverSeconds:durationSeconds:)` は本ファイルの `static func`（別ファイルを増やさない） |
| `Podcast/Playback/OfflineLibrary.swift` | CP3 | 既存 `AudioCacheManager` を包む。`save / has / url / remove / clearAll / usage / savedIds`（`@Published private(set)`）。`has` / `url` はファイル実体が正本 |
| `Podcast/Playback/PositionReporter.swift` | CP9 | `attach(session) / flush / listenCompleted(id) / lastSyncFailure`。再生中 15 秒 throttle、`pause / stop / 背景遷移` で即時 1 回、一時停止中は送らない、error / idle では送らない。完聴 → `duration` 書込 1 回 → advance。完聴通知は 1 セッション 1 回。応答の `Podcast` を Catalog 側へ返す。background task は closure port で受ける（`UIApplication` は書かない） |
| `Models/Episode.swift` | CP5 | `Podcast` DTO → `PlayableEpisode / GeneratingEpisode / FailedEpisode`。未知 status・矛盾 DTO は `FailedEpisode`（fail-closed）。`decode(Podcast) → Episode` / `isPlayable`。Coordinator の Playable 判定に必要なため本 slice に含める（`PodcastRowView` の切替は I-S3b2） |
| `NewsListenAppTests/`（新規テストファイル） | — | 下表 T-T*。port double（`AudioEngine`（I-S3a）・`NowPlayingCenter`（I-S2）・gateway closure・`FileStore`）を注入し、内部実装を観測しない |

`Podcast/Playback/AudioEngine.swift`（I-S3a で新設済みの port 定義）は本 slice の新規 5 本に数えない。`PlaybackSession` はこの既存 port を駆動する（port を作り直さない・別名の protocol を足さない）。Coordinator の既定速度は `PreferenceRegistry` の値を closure（`defaultSpeed: () -> Float`）で受ける（`AppState` 型を `Podcast/Playback/` に書かない）。

gateway 依存は closure（`fetchPodcast / updatePosition / markCompleted / downloadAudio`）で受ける。`APIClient` 型を `Podcast/Playback/` に書かない（`ApiFailure` の値は読んでよい）。

## 完了条件
- 新規ファイルが上表の 5 本＋テストであること。`git diff --stat origin/main -- NewsListenApp/NewsListenApp` に既存ファイルの変更が無い（`project.pbxproj` は synchronized group のため diff 0。`Podcast/Playback/AudioEngine.swift`・`Podcast/Platform/` も変更 0）。
- 契約テストが green で、`verifies: CI-T*` をテスト名またはコメントに持つ:

| CI | T-T | 行 ID（テスト名に含める） |
|---|---|---|
| CI-T1 / CI-T2 | T-T1（16 遷移を double 事象で駆動。分母 16）・T-T2（`failed` → `errored(engine_failed)`、重複 `play()` 収束） | — |
| CI-T3 | T-T3: `resolveResumePosition` の表駆動 | **RS-01〜RS-07**（共有仕様 §4.3 の 7 行すべて） |
| CI-T4 | T-T4: `start` で既定速度に初期化、以後保持。既定速度は書かない | — |
| CI-T5 | T-T5: `unavailable` は gateway 呼出 0・`errored(offline_uncached)`、`network` は `fetchPodcast` 1 回、失敗は保持 URL | — |
| CI-T6 | T-T6: advance 後の失敗で `queue.current` = 失敗エピソード・`errored`・`retry()` 再実行・Timer 停止 | — |
| CI-T7 | T-T7a: 全 15 公開操作の後に INV-P1（`session.episode.id == queue.current?.id`） | **PS-04** |
| CI-T8 | T-T8: gateway double の呼出列（completed → position(duration) → advance）、完聴 1 回、一時停止中 0 回、`lastSyncFailure` | — |
| CI-T10 | T-T10: `FileStore` double で `clearAll` 後の `has` false・`savedIds` 空 | — |
| CI-T11 | T-T11: status 4＋未知 × audioUrl 2 × errorMessage 2 = 20 通り | — |

- 既存テスト全件 green（`xcodebuild test -only-testing:NewsListenAppTests`）。
- 依存方向: `grep -rn "^import \(AVFoundation\|MediaPlayer\|UIKit\|SwiftUI\)" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 件、`grep -rn "APIClient" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 件（コメント行を含めて 0）。
- 既存コードから呼ばない: `grep -rn "PlaybackCoordinator\|PlaybackSession\|OfflineLibrary\|PositionReporter" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Podcast/Playback/"` が **コメント行（`//`）を除き 0 件**（I-S2 が TP2 / TP4 の削除条件をコメントに書いている行は除外）。`Episode` decode も同様に `Models/Episode.swift` 以外の production から参照 0 件。

## 禁止事項 / scope 外
- `PodcastViewModel.swift`・`PlaybackQueue.swift`・`PodcastRowView.swift`・`PreviewSupport.swift`・`NewsListenAppApp.swift`・`SettingsViewModel.swift` を変更しない（I-S3b2）。`PlaybackQueue` の dedupe gate も I-S3b2。
- `Podcast/Platform/`（`AVPlayerEngine` / `MediaPlayerNowPlaying`。I-S3a で新設済み）と `Podcast/Playback/AudioEngine.swift` を変更しない。
- PS-01〜PS-03・PS-05・PS-05b・PS-06・PS-07・PS-08 の行 ID を本 slice のテスト名に付けない（これらは production 入口の挙動変更行として I-S3b2 の準拠テストで判定する。本 slice の T-T6 / T-T8 / T-T11 は CI-T の契約テストとして同じ内容を新規コードに対して検証するが、行 ID の付与は入口切替後に行う）。
- RO1〜RO7・SG-A7（Spec §5 rejected_overdesign）を作らない。`reorderUpNext` を rename しない。Spec に無い状態・失敗理由を足さない。

## 特性テスト（baseline）
既存テスト全件（production 不変のため全件が特性テスト）。とくに `PlaybackQueueTests`（12）・`PlaybackQueueConformanceTests`（32）・`AudioCacheManagerTests`（13）・`PodcastViewModelTests`（I-S3a 完了時点の件数）・`TranscriptTimingTests`（13）が着手前後で同数 green。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:NewsListenAppTests` → 全 green（既存件数 ＋ 新規 T-T1〜T-T8・T-T10・T-T11）。
- 上記 3 本の grep → それぞれ 0 件。
- `git diff --stat origin/main -- NewsListenApp/NewsListenApp` → 追加 5 ファイルのみ。

## 規模の目安（巻き戻し範囲）
新規 5 ファイル（Session / Coordinator / OfflineLibrary / PositionReporter / Episode）で約 600〜700 行＋契約テスト。既存ファイルの変更 0 のため revert は追加ファイルの削除だけ。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記。親 docs `docs/design/shared-playback-spec.md` §4.3 の「RS-01〜RS-07 は iOS 未追随（I-S3b1）」の保留は本 slice 完了で解除対象（router へ返す）。`docs/design/ios-design.md` §11.3 I-S3b1 行の完了記録。
