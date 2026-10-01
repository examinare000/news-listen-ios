## iOS リファクタ I-S3b1: 再生ドメイン層の新設（Session・Coordinator・OfflineLibrary・PositionReporter）

## 2026-10-01 目標アーキテクチャ（ADR-110・Spec §8.3）による補正
正本: 親 docs `adr/110-refactor-target-domain-centered-onion-cqrs.md`、iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`（以下「TA Spec」）§8.3 の I-S3b1 の表（補正 1〜10 と型の置き換えの表）。**型の置き換えが主で、状態・遷移・規則・手順・操作の数・再生 Spec §3.6 の表は変えていない**。
- 補正 1: 前提に I-T1・I-T2a・I-T2b を足した（「前提・着手条件」）。
- 補正 2: 型を置き換えた（`Podcast` → `Episode`／`PlayableEpisode`、`fetchPodcast` → `fetchEpisode`、`upNext() -> [QueueEntry]`、`PlaybackQueue<Episode>`、`NowPlaying` は `EpisodeContent` から作る、Reporter の closure は `Episode`、`Episode.decode` を呼ばない、`OfflineLibrary.init(store: AudioFileStore)`、`nowPlayingCenter.update(NowPlayingSnapshot(…))` と closure `lockScreenSubtitle`、純関数 2 つは domain の `PlaybackRules`、Preview は「何もしない」`AudioFileStore`）。導出 I-24〜I-28。
- 補正 3: 対象を 9 本にした（`Models/Episode.swift` を外し、`Podcast/Playback/Domain/` の 2 本・`NowPlaying.swift`・`Podcast/Platform/AudioFileStore+Live.swift` を足した）。完了条件 3 を 9 行に。
- 補正 4: 完了条件 4 に「`Podcast/Playback/` に `DTO`・`AudioCacheManager`・`NowPlayingInfo` が無い」と所属表への登録（`NowPlaying.swift` を `readModelFiles` に）を足した。
- 補正 5: 完了条件 8 の `AudioCacheManager()` を 0 行にした。
- 補正 6: T-T11 を外した（I-T2a で green）。
- 補正 7: 行 ID PS-09〜PS-13 をテスト名に足し、禁止事項の「RS-01〜RS-07 と PS-04 だけ」を直した。
- 補正 8: T-T7a に `nowPlaying()` の導出値 6 つと `upNext()` の `[QueueEntry]`、TA-V6 の PB (1)〜(3) を足した。
- 補正 9: 「`errored` での `play()` は何もしない」に根拠 I-29 を書いた。
- 補正 10: 「Spec §5 CP3 の 7 操作にこれを足した 8 操作」を再生 Spec の現行の本文（8 操作）に合わせた。
- 着手前の前提点検の節を足した（実装は 2026-09-30 の停止のまま。投入の直前に数え直す）。

## 概要
再生ドメインの正本を `Podcast/Playback/` に**新規コードとしてだけ**置く。`PlaybackSession`（再生状態の union）・`PlaybackCoordinator`（use case の判断。`PlaybackLifecycle` の実装）・`OfflineLibrary`・`PositionReporter` と、domain の `PlaybackState`・`PlaybackRules`、リードモデル `NowPlaying`・`QueueEntry` を新設し、port の test double で駆動する契約テストで固定する。**既存コードからは呼ばない**（production の挙動は変わらない。3 段分割の ①）。入口の差し替えは I-S3b2、旧実装の削除は I-S3b3。

正本は Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（冒頭の追記 5 つと §3.1・§3.2・§4・§5）と、型の置き場・依存の向きは TA Spec §5.1・§5.2・§3.1・§4（両者が食い違うときは、構造は TA Spec、状態遷移と契約は再生 Spec。TA Spec §1.2）、親 docs `design/shared-playback-spec.md` §2.11・§2.12・§6.1・§6.4・§6.6、`adr/105-playback-session-out-of-table-operations-and-shared-rules.md`・`adr/106-ios-audio-engine-port-and-session-contract.md`。本タスクは**承認済み指示書に従う実装**で、analyze_order は検証モード（再設計しない）。spec.md は下の契約表の抜粋で足り、新しい契約 ID を作らない。

本 order は 2026-09-30 の前提点検（親 docs `research-reports/2026-09-30-wave3-order-premise-check/ios.md` の #1〜#27）を受けて全面的に書き直した。型・操作・戻り値・手順は本 order が固定する。実装者が決める余地を残していない箇所で判断が要ると感じたら、実装を止めて報告する。order を書く側が確定済みの決定から導いた宣言には **I-1〜I-19・I-21〜I-23** の番号を付けた（一覧は親 docs 監査レポート §5.0 と Spec 冒頭の追記。I-20 は I-S3c）。2026-10-01 の補正で導出 **I-24〜I-29・I-32**（TA Spec §10.1）を足した。書き直しの後、別のレビュー役の再点検（F1〜F21。親 docs `research-reports/2026-09-30-wave3-order-premise-check/ios-recheck.md`）を受け、その指摘も反映してある。

## 前提・着手条件
- 依存: **I-S3a（PR #95）・I-T1・I-T2a・I-T2b の ios PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（親で `git submodule status` の `ios` 行に `+` が無い）。I-T1 の依存の検査（`ArchitectureOracleTests`）が green。
- I-S3a / I-S2 / I-T1 / I-T2a / I-T2b の成果で使うもの:
  - `Podcast/Playback/AudioEngine.swift`: `AudioEngine` port **7 操作**（`load(url:) -> String?` / `play` / `pause` / `seek(to:)` / `setRate` / `stop` / `events`）と `EngineEvent` **10 種**。事象 stream は load ごとに作り直される。
  - `Podcast/Playback/NowPlayingCenter.swift`（I-T2b）: `NowPlayingCenter` port **5 操作**（`update(_ snapshot: NowPlayingSnapshot)` / `updateElapsed` / `clear` / `registerCommands` → token / `unregister`）、`NowPlayingSnapshot`、`RemoteCommand` 7 種、`RemoteCommandResult` 3 種。
  - `Podcast/Playback/PlaybackLifecycle.swift`・`Podcast/Playback/PlayerPresentation.swift`（I-T2b）、`Podcast/Playback/Domain/PlaybackQueue.swift`（`PlaybackQueue<Item>`）・`Podcast/Playback/Domain/PlaybackConstants.swift`（I-T2a）、`Catalog/Domain/Episode.swift`・`EpisodeContent.swift`（`Episode`・`PlayableEpisode`・`GeneratingEpisode`・`FailedEpisode`・`EpisodeContent`。I-T2a）、`Shared/Domain/ApiFailure.swift`（I-T2a）、`Networking/AudioCacheManager.swift`（adapter。`AudioFileStore+Live` が包む）。
  - test double: `NewsListenAppTests/AudioEngineDouble.swift`（`AudioEngineDouble`・`EngineChannel`）、`NewsListenAppTests/AppStateTestSupport.swift` の `NowPlayingCenterSpy`（`currentInfo: NowPlayingSnapshot?`。I-T2b）、`AudioCacheManagerTests.MockFileManager`。
  - test の土台: `NewsListenAppTests/ArchitectureManifest.swift`（所属表・`readModelFiles`・`portFiles`・`domainTestFiles`・許可リスト）。
- コマンドの実行場所: 以下の検査コマンドはすべて **`ios/`（submodule のルート）** で実行する。takt の worktree ルート（親リポ）で実行すると、grep は「ファイルなし」、`git diff` は常に空になり、0 件に見える。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Catalog/Domain/Episode.swift`（rc=0。I-T2a）と `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/NowPlayingCenter.swift`（rc=0。I-T2b）で場所と前提の両方を確かめる。
- `docs/trial-log/`（ios・親）を最初に読む。とくに `player-auto-converge.md`・`mino-design-review-delegation.md`・親 docs `trial-log/i-s3a-order-defects-and-port-gaps.md`。
- 棄却済み（再提案しない）: `Episode.decode(_:)` を domain の static に置く案（変換は adapter の `toEpisode()`。TA Spec §10.2）、`OfflineLibrary` が `AudioCacheManager` を直接包む案（`AudioFileStore` の port を受ける。I-28）、旧 VM を feature flag で温存する段階移行、port を置かない案、`PlaybackQueue` の failable init、停止・失敗を遷移表へ足す案（SG-C24・SG-C52）、開始の操作に「再生できない」を渡す案、Coordinator が失敗状態を別に持つ案、`ready` を待ってから再生する案（SG-C58）。

## 着手前の前提点検（投入の直前に数え直す。値が違えば order を直してから投入する）
2026-10-01 時点では I-T1・I-T2a・I-T2b が未着手なので、下の項目はその 3 本の後の実物で数える。

| 項目 | 期待（前の slice の order が固定した値） | コマンド（`ios/` で） |
|---|---|---|
| `Episode` の形 | `PlayableEpisode(content:audioUrl:serverPosition:)`・`GeneratingEpisode(content:)`・`FailedEpisode(content:reportedMessage:)`、`Episode.content`・`id`・`isPlayable`（I-T2a の宣言） | `grep -n 'struct\|enum\|var \|let ' NewsListenApp/NewsListenApp/Catalog/Domain/Episode.swift` |
| `EpisodeContent` の規則 | `displayTitle`・`hasTranscript`・`hasVocabulary`・`hasQuiz`・`hasSourceArticles`・`showsCcBySaLicense` | `grep -n 'var ' NewsListenApp/NewsListenApp/Catalog/Domain/EpisodeContent.swift` |
| `toEpisode()` の置き場 | `Models/Podcast+Episode.swift` | `grep -rn 'func toEpisode' NewsListenApp/NewsListenApp` |
| `PlaybackQueue` | `Podcast/Playback/Domain/PlaybackQueue.swift` の `PlaybackQueue<Item>`（操作 9 個） | `grep -n 'struct PlaybackQueue\|mutating func\|init(' NewsListenApp/NewsListenApp/Podcast/Playback/Domain/PlaybackQueue.swift` |
| `NowPlayingCenter.update` の引数 | `NowPlayingSnapshot`（6 field） | `grep -n 'func update\|struct NowPlayingSnapshot' NewsListenApp/NewsListenApp/Podcast/Playback/NowPlayingCenter.swift` |
| `NowPlayingCenterSpy.currentInfo` の型 | `NowPlayingSnapshot?` | `grep -n 'currentInfo' NewsListenApp/NewsListenAppTests/AppStateTestSupport.swift` |
| 許可リスト | `Podcast/Playback/` の path の行が 0 | `grep -n '"Podcast/Playback/' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` |
| `readModelFiles` | 空（本 slice で `Podcast/Playback/NowPlaying.swift` を入れる） | `grep -n 'readModelFiles' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` |
| 特性テストの件数 | 下の「特性テスト」の表の値（`TranscriptTimingTests`・`PlaybackQueue*Tests`・`NowPlayingInfoTests` は I-T2a・I-T2b の後も同数）。`EpisodeTests`（I-T2a の T-T11 の 20） | `grep -c 'func test' …` |

## 確定済みの決定（再提案しない。本文は親 docs 監査レポート §5）
| 決定 | 内容 |
|---|---|
| SG-C24 | `stop` は遷移表の外のリセット。分母 16 に数えない |
| SG-C39・C40・C44 | engine 由来の一時停止は Session が自分で遷移する。割り込みの再開の判断は Coordinator |
| SG-C41・C42 | `load` の警告は状態を変えず、開始の結果として 1 回外へ出す。文言は OS の説明文のまま |
| SG-C43・C54 | 総時間は「engine の値（0 より大きい）→ サーバーの値 `content.durationSeconds`（0 より大きい）→ 不明」。不明な間は位置を上限で丸めない |
| SG-C52 | 取得前・開始前の失敗は、遷移表の外の操作 `fail` で `errored` に入れる |
| SG-C58 | 再生開始は `ready` を待たずに続けて行う。`ready` は状態を進めるためだけに使う（呼ぶ順序は I-1） |
| SG-C59 | リモートコマンドは再生開始時に登録し、`stopForLogout()` と Coordinator の破棄の両方で解除する |
| SG-C60 | Coordinator の公開操作は **19**（`minimizePlayer`・`expandPlayer` を含む） |
| SG-C61 | 完聴の記録と総時間の位置書込はこの順で送り始め、次の再生開始は応答を待たない |
| SG-C62 | 手動で選んだエピソードが開始前に再生できないと分かる場合は、キューもセッションも変えず、通知だけを出す |
| SG-C63・C70 | `skipToNext` は共有仕様 §2.12 のとおり。本 slice で作るが、どこにもつながない（リモートコマンドへの接続 = I-S3c は保留） |
| SG-C66 | engine を呼ぶ順序は「読み込み → seek → 再生 → 速度」（I-1 を user が確認） |
| SG-C67 | 巻き戻した位置もサーバーへ送る（値の大小で送信を止めない） |
| SG-C71 | 読み込み中の割り込みの開始・出力機器の切断も一時停止にする（I-21 を user が確認） |
| SG-C72 | 聴き終えた後に待機列へ足しても「聴き終わりました」を残す（I-18 を user が確認） |
| SG-C73 | 利用者の開始と自動で次へ進む開始が重なったら、利用者の開始を採る（I-23 を user が確認） |
| SG-C64 | `partial_failed` は再生不可（T-T11 の表のとおり。backend も B-S6 以降は返さない） |
| SG-C4（2026-09-16） | オンラインで未キャッシュなら再生の直前に `fetchEpisode` で取り直し、失敗したら保持している URL で始める |
| SG-X1・X4・C16 | 完聴時は総時間を 1 回送る。一時停止中は周期送信しない。主体離脱では位置を送らない |
| I-24〜I-28（TA Spec §10.1） | キュー・入口・gateway・Reporter の型は `Episode`。待機列は `QueueEntry`。`NowPlaying` の導出値は 6 つ。ロック画面の port は `NowPlayingSnapshot`。`OfflineLibrary` は `AudioFileStore` を受ける |
| I-29 | `errored` での `PlaybackSession.play()` は何もしない。再試行は Coordinator の `retry()` |

## 対象（ios サブモジュールのみ）
**新規（production 9 本）**

| ファイル | 層（TA Spec §3.1） | capsule | 中身 |
|---|---|---|---|
| `Podcast/Playback/Domain/PlaybackState.swift` | domain | CP1 | `PlaybackState`・`PlaybackErrorReason`・`InterruptionPhase` と派生値 |
| `Podcast/Playback/Domain/PlaybackRules.swift` | domain | CP4 の純関数 | `PlaybackSource`・`resolvePlaybackSource`・`resolveResumePosition`・位置の丸め・「engine が読み込み済みである状態」の判定 |
| `Podcast/Playback/PlaybackSession.swift` | application | CP1 | `SessionEvent`・`PlaybackSession` |
| `Podcast/Playback/PlaybackCoordinator.swift` | application | CP4 | `PlaybackCoordinator`・`PlaybackNotice` |
| `Podcast/Playback/NowPlaying.swift` | application（リードモデル） | CP4 | `NowPlaying`・`QueueEntry` |
| `Podcast/Playback/PlaybackCoordinator+Preview.swift` | application（DEBUG） | CP4 | `PlaybackCoordinator.previewParts(session:queue:)` |
| `Podcast/Playback/PositionReporter.swift` | application | CP9 | `PositionReporter` |
| `Podcast/Playback/OfflineLibrary.swift` | application | CP3 | `OfflineLibrary` と port `AudioFileStore`（closure の束）の宣言 |
| `Podcast/Platform/AudioFileStore+Live.swift` | adapter | — | `AudioFileStore.live(cacheManager: AudioCacheManager)`（`AudioCacheManager` の操作から束を組む） |

**変更（test）**: `NewsListenAppTests/AudioEngineDouble.swift`（下の「test double」）、`NewsListenAppTests/AudioEngineDoubleTests.swift`（Given の追加と新規 2 件）、`NewsListenAppTests/ArchitectureManifest.swift`（`readModelFiles` に `Podcast/Playback/NowPlaying.swift`、`portFiles` に `Podcast/Playback/OfflineLibrary.swift`、`domainTestFiles` に domain の 2 本を対象にするテストファイルを足す。所属表の規則は変えない = 新しいファイルは規則 (2)〜(4) で当たる）。

**新規（test）**: 契約テストのファイル（名前は自由。例 `PlaybackSessionTests.swift`・`PlaybackCoordinatorTests.swift`・`PositionReporterTests.swift`・`OfflineLibraryTests.swift`・`PlaybackRulesTests.swift`（`domainTestFiles`））。

**既存の production ファイルは 1 行も変えない**（`Podcast/Playback/AudioEngine.swift`・`Podcast/Playback/NowPlayingCenter.swift`・`Podcast/Playback/Domain/PlaybackQueue.swift`・`Catalog/Domain/`・`Models/`・`Podcast/Platform/` の既存 3 本を含む）。`project.pbxproj` は synchronized group なので変更は出ない。

## 宣言（型・操作・戻り値。ここに無い公開メンバーを足さない）

### `Episode`（I-T2a が入れた型を使う。本 slice では宣言しない）
- 種別: `Episode.playable(PlayableEpisode)` / `.generating(GeneratingEpisode)` / `.failed(FailedEpisode)`。3 種別とも `content: EpisodeContent` を持つ。`PlayableEpisode` の固有の値は `audioUrl`・`serverPosition`（I-24）。
- 判別（T-T11 の 20 通り）は adapter の `Podcast.toEpisode()`（I-T2a）で済んでいる。Coordinator は `Episode` の**種別を読むだけ**で、判別も `Podcast` も知らない。
- 本 order で「DTO の `displayTitle`」「`podcast.playbackPositionSeconds`」「`podcast.audioUrl`」と書いていた箇所は、`episode.content.displayTitle`・`PlayableEpisode.serverPosition`・`PlayableEpisode.audioUrl` と読む（下の各節は置き換え済み）。

### `Podcast/Playback/Domain/PlaybackState.swift`（domain）と `Podcast/Playback/PlaybackSession.swift`（application）
`PlaybackErrorReason`・`PlaybackState`・`InterruptionPhase` と派生値の extension は `Domain/PlaybackState.swift`、`SessionEvent`・`PlaybackSession` は `PlaybackSession.swift` に置く（TA-M-PB）。中身は下のとおりで変えない。
```swift
enum PlaybackErrorReason: Equatable {
    case offlineUncached, invalidSource, engineFailed(description: String?), fetchFailed(ApiFailure)
}
enum PlaybackState: Equatable {
    case idle
    case loading(episode: PlayableEpisode, resumePosition: Double, speed: Float)
    case playing(episode: PlayableEpisode, position: Double, duration: Double, speed: Float)
    case buffering(episode: PlayableEpisode, position: Double, duration: Double, speed: Float)
    case paused(episode: PlayableEpisode, position: Double, duration: Double, speed: Float)
    case ended(episode: PlayableEpisode, duration: Double)
    case errored(episodeId: String, position: Double, reason: PlaybackErrorReason)
}
extension PlaybackState {            // 読み取り用の派生値（操作に数えない）
    var episodeId: String? { get }   // idle だけ nil
    var position: Double { get }     // loading は resumePosition、ended は duration、idle は 0
    var duration: Double { get }     // loading は Double(episode.content.durationSeconds)、idle・errored は 0
    var speed: Float? { get }        // loading・playing・buffering・paused だけ値を持つ
    var isEnded: Bool { get }
}
enum SessionEvent: Equatable {
    case stateChanged(PlaybackState)
    case positionChanged(seconds: Double, duration: Double)
    case ended(episodeId: String)
    case interruption(InterruptionPhase)
}
enum InterruptionPhase: Equatable { case began(wasPlaying: Bool), ended(shouldResume: Bool) }

@MainActor final class PlaybackSession {
    init(engine: any AudioEngine)
    private(set) var state: PlaybackState            // 初期値 .idle
    func observe(_ handler: @escaping (SessionEvent) -> Void)
    @discardableResult
    func start(episode: PlayableEpisode, url: URL, resumePosition: Double, speed: Float) -> String?
    func play()
    func pause()
    func seek(to seconds: Double)
    func seekRelative(_ delta: Double)
    func setSpeed(_ speed: Float)
    func stop()
    func fail(episodeId: String, reason: PlaybackErrorReason)
}
```
- 公開操作は `start / play / pause / seek / seekRelative / setSpeed / stop / fail / state` の 9 個。`observe` は通知の受け口で、操作に数えない（I-5）。
- 通知は 4 種（Spec の「CP1 の emits は 4 つ」）。`observe` で登録した handler を、**登録した順に、その場で同期に**呼ぶ。解除の操作は持たない（Session・Coordinator・Reporter は同じ寿命）。Coordinator と Reporter は、`observe` に渡す handler と自分が作る Task の中で、自分を**弱参照**で捕捉する（Session が handler を持ち、Coordinator が Session を持つので、強参照だと循環して `deinit` が走らない）。Session の購読 Task も Session を弱参照で捕捉する。
- `stateChanged` は `state` の値が変わるたびに 1 回出す。ただし engine の `timeUpdate` による位置・総時間の更新では `stateChanged` を出さず、`positionChanged` だけを出す（`state` の値は更新する）。
- `errored` は id だけを持つ（I-4。再試行は Coordinator が `queue.current` から行うので、エピソード全体は要らない）。

**engine が読み込み済みなのは `loading / playing / buffering / paused` の間だけ**（I-4）。`ended`・`errored` に入るときと `stop` のとき、Session は「事象の購読 Task を cancel → `engine.stop()`」の順で読み込みを外す。

**`start` の手順**（I-1。どの状態から呼んでもよい）
1. 現在の状態が `loading / playing / buffering` なら、先に `stop` と同じ後始末をする（`stateChanged(.idle)` を 1 回出す）。`paused` からは、前の読み込みの購読 Task を cancel するだけで、`idle` の通知は出さない（`engine.load` が前の読み込みを外す）。保留中の失敗は消す。
2. `speed` が `PlaybackConstants.speeds` に無ければ 1.0 として扱う（I-32）。
3. `let warning = engine.load(url: url)`。**直後に同期で** `let stream = engine.events` を取り、この読み込みの購読 Task を作る（Task の本体で `engine.events` を読み直さない。終了したエピソードの id はここで捕捉する）。
4. `resumePosition > 0` なら `engine.seek(to: resumePosition)`。
5. `engine.play()`。
6. `engine.setRate(speed)`。
7. 状態を `.loading(episode, resumePosition, speed)` にして `stateChanged` を出す。
8. `warning` を返す（`nil` なら警告なし）。

- **5 → 6 の順序を入れ替えない**。`AVPlayer.play()` は速度を 1.0 に戻す（2026-09-30 に macOS の AVFoundation で実測: `rate = 1.5` → `play()` の直後に `rate == 1.0`。`play()` → `rate = 1.5` では 1.5 のまま）。現行 `PodcastViewModel.play` は「速度 → 再生」の順で呼んでおり、1.0 以外の速度が新しいエピソードの開始時に効いていない。SG-C58 の本文（読み込み → 速度 → seek → 再生）はこの順序だけを改める。
- `engine.play()` を呼ぶのは `start` の中の 1 回だけ。実 adapter はこの呼出で読み込みごとの監視を登録する。`ready` を待ってから呼ぶと、実機では `ready` が届かない。
- 購読 Task は、取り出した事象を適用する直前に `Task.isCancelled` を確かめる（cancel 済みなら捨てる）。
- 再開位置を `ready` の後に掛け直さない（I-15。Spec §4 CI-T3 の「`ready` 後に再適用」は SG-C58 により iOS では行わない）。

**操作 × 状態**（「—」は何もしない）

| 操作 | idle | loading | playing | buffering | paused | ended | errored |
|---|---|---|---|---|---|---|---|
| `play()` | — | — | — | — | `engine.setRate(speed)` → `playing`。保留中の失敗があれば続けて `errored` | — | — |
| `pause()` | — | `engine.pause()` → `paused`（位置 = `resumePosition`、総時間 = `content.durationSeconds`） | `engine.pause()` → `paused` | `engine.pause()` → `paused` | — | — | — |
| `seek` / `seekRelative` | — | 丸めた位置へ `engine.seek` し、`resumePosition` を置き換える（`loading` のまま。I-22） | 丸めた位置へ `engine.seek` し、位置を更新 | 同左 | 同左 | — | — |
| `setSpeed(s)` | — | 速度を更新し `engine.setRate(s)` | 同左 | 同左 | 速度だけ更新（engine は呼ばない） | — | — |
| `stop()` | — | 後始末 → `idle` | 同左 | 同左 | 同左 | → `idle` | → `idle` |
| `fail(id, reason)` | `errored` | 後始末 → `errored` | 同左 | 同左 | 同左 | → `errored` | → `errored`（値を置き換える） |
| `start(…)` | 上の手順 | 上の手順 | 上の手順 | 上の手順 | 上の手順 | 上の手順 | 上の手順 |

- `setSpeed` は `PlaybackConstants.speeds` に無い値を無視する。
- `seek` の丸め: 総時間が 0 より大きければ `[0, 総時間]`、不明（0）なら下限 0 だけ（SG-C43）。丸めの式は `Domain/PlaybackRules.swift` の関数（TA-R-PB-5）で、Session はそれを呼ぶ。`loading` の総時間は `Double(content.durationSeconds)`、`seekRelative` の基準は `resumePosition`。現行は読み込み中もシークが効くので、それを保つ。
- `errored` での `play()` は何もしない。再試行は Coordinator の `retry()` が `start` を呼ぶ（導出 I-29。I-4: `errored` は id・位置・理由だけを持ち、Session だけでは再開できない。TA Spec §10.1）。
- `fail` の `errored` は `position: 0`。`reason` に `engineFailed` を渡さない（engine の事象からだけ生まれる）。
- 再開に `engine.play()` を使わない（速度が 1.0 に戻る）。現行 `togglePlayPause` と同じく `setRate` で再開する。

**engine の事象 × 状態**（I-3。「—」は何もしない。表に無い組合せは起こさない）

| 事象 | idle | loading | playing | buffering | paused | ended | errored |
|---|---|---|---|---|---|---|---|
| `ready` | — | → `paused` → `playing`（`stateChanged` を 2 回。engine は呼ばない） | — | — | — | — | — |
| `resumed` | — | `ready` と同じ | — | → `playing` | — | — | — |
| `buffering` | — | — | → `buffering` | — | — | — | — |
| `paused` | — | — | —（SG-C39） | → `paused` | — | — | — |
| `ended` | — | `ready` と同じに進めてから、`playing` の欄 | 後始末 → `ended` → `SessionEvent.ended(episodeId)` | → `playing` に進めてから、`playing` の欄 | 終了を保留する（状態は変えない） | — | — |
| `failed(d)` | — | 後始末 → `errored(engineFailed(d))` | 同左 | 同左 | 失敗を保留する（状態は変えない） | — | — |
| `timeUpdate(s, d)` | — | — | 位置 = `s`、`d > 0` なら総時間 = `d`。`positionChanged` | 同左 | 同左 | — | — |
| `interrupted` | — | `engine.pause()` → `paused`。`interruption(.began(wasPlaying: true))`（I-21） | `engine.pause()` → `paused`。`interruption(.began(wasPlaying: true))` | 同左 | `interruption(.began(wasPlaying: false))` | — | — |
| `interruptionEnded(r)` | — | `interruption(.ended(shouldResume: r))` | 同左 | 同左 | 同左 | 同左 | 同左 |
| `outputDeviceLost` | — | `engine.pause()` → `paused`（I-21） | `engine.pause()` → `paused` | 同左 | — | — | — |

- `ready` で `playing` になるときの位置は `resumePosition`、総時間は `Double(content.durationSeconds)`。
- `errored(engineFailed)` の位置は、直前の状態の位置（`loading` なら `resumePosition`）。
- **`paused` で届いた `failed` と `ended`** は捨てずに保留し、次の `play()` で `playing` に入った直後に `errored(engineFailed)` または `ended` へ進める（辺は既存の `paused → playing`・`playing → errored`・`playing → ended`）。分母 16 に `paused → errored`・`paused → ended`・`buffering → ended` は無く、足さない。捨てると、読み込み中に一時停止して読み込みが失敗したあと、再生を押しても無音のまま再生中の表示になる。終端と一時停止が重なったときに `ended` を捨てると、次へ進まなくなる（実 adapter の `ended` は KVO の事象と別の経路で届き、順序が入れ替わり得る）。保留は `start`・`stop`・`fail` で消す。両方が保留されていれば `failed` を先に扱う。
- **`loading` の `interrupted`・`outputDeviceLost`**（I-21）は `playing` と同じに扱う（辺は既存の `loading → paused`）。SG-C40・C44 の表は `playing`・`buffering` だけを挙げているが、現行は再生を始めた直後から再生中として扱っており、読み込み中の割り込みでも一時停止する。何もしないと、OS が音を止めたまま `ready` で再生中の表示になる。
- `paused` の `resumed`・`buffering`、`playing` の `paused` は、操作より前に engine が出した事象が遅れて届く場合があるので、状態を動かさない。
- Session は割り込みの終了で自分から再開しない（SG-C44）。

**分母 16 の辺と、それを起こす操作・事象**（T-T1 はこの表のとおりに駆動する）

| # | 辺 | 起こすもの |
|---|---|---|
| 1 | idle → loading | `start` |
| 2 | loading → paused | engine `ready`（直後に 4 が続く）。`loading` での `pause()`・`interrupted`・`outputDeviceLost` も同じ辺 |
| 3 | loading → errored | engine `failed` |
| 4 | paused → playing | `play()` |
| 5 | paused → paused（seek） | `seek` / `seekRelative` |
| 6 | paused → loading | `start` |
| 7 | playing → paused | `pause()`（engine 由来は CI-T1c） |
| 8 | playing → buffering | engine `buffering` |
| 9 | buffering → playing | engine `resumed` |
| 10 | buffering → paused | `pause()`（engine 由来は CI-T1c） |
| 11 | playing → ended | engine `ended` |
| 12 | playing → errored | engine `failed` |
| 13 | buffering → errored | engine `failed` |
| 14 | ended → loading | `start`（次のエピソード） |
| 15 | errored → loading（再試行） | `start`（同じエピソード） |
| 16 | errored → loading（別の開始） | `start`（別のエピソード） |

表の外: `stop`（どこからでも `idle`）、`fail`（どこからでも `errored`）、`loading / playing / buffering` からの `start`（`idle` を挟む）。

### `Podcast/Playback/PositionReporter.swift`
```swift
@MainActor final class PositionReporter: ObservableObject {
    @Published private(set) var lastSyncFailure: ApiFailure?
    init(updatePosition: @escaping (_ id: String, _ seconds: Double) async throws -> Episode,
         markCompleted: @escaping (_ id: String) async throws -> Void,
         onPositionSaved: @escaping (Episode) -> Void,
         onCompletionRecorded: @escaping () async -> Void,
         beginBackgroundTask: @escaping () -> (() -> Void),
         now: @escaping () -> Date = Date.init)
    func attach(_ session: PlaybackSession)
    func flush()
    func listenCompleted(id: String)
}
```
規則（I-9。`Timer` を持たない。周期は `positionChanged` と注入した時計で数える）

| 契機 | 動作 |
|---|---|
| `attach` | `session.observe` に自分を登録する。Coordinator が生成時に 1 回呼ぶ |
| `stateChanged(.loading)` | 新しい再生の基準に戻す（送信済みの位置なし・完聴未送信・現在位置 = `resumePosition`） |
| `paused` から `playing` に入った（開始直後の `ready` を含む） | 周期の起点を `now()` にする（**開始直後には送らない**）。`buffering` から戻ったときは起点を変えない |
| `playing` 中の `positionChanged` | 現在位置を更新する。`now()` が起点から 15 秒以上なら 1 回送り、起点を `now()` にする |
| `playing` / `buffering` → `paused` | その位置を 1 回送る（利用者の一時停止も engine 由来も同じ） |
| `loading` → `paused` | 送らない |
| `paused`・`buffering` 中の `positionChanged` | 現在位置だけ更新する（送らない） |
| `ended`・`errored`・`idle` に入った | 送らない。周期も止まる |
| `flush()` | 状態が `playing / buffering / paused` のときだけ、現在位置を 1 回送る。ほかの状態では何もしない |
| `listenCompleted(id)` | 下の「完聴」 |

- **同じ位置は再送しない**（直近に送った値と等しければ送らない）。値の大小では止めない: **巻き戻した位置も送る**（SG-C67）。記録時刻を付けて送る形・オフラインで送れなかった位置を後で送る形・再開時の確認（親 docs ADR-109）は、本 slice には入れない（backend の B-S7 と、I-S3b3 の後に起こす位置同期の slice で入れる）。
- 停止の前に位置を送るのは Coordinator の役目（`session.stop()` や別のエピソードの `start` の前に `flush()` を呼ぶ）。Reporter は `idle` への遷移を見て送らない。`stopForLogout()` は `flush()` を呼ばないので、主体離脱では何も送らない（SG-C16）。
- 送信は待たない（`Task` で送る）。位置の書込が成功したら、応答の `Episode`（gateway の adapter が `toEpisode()` で変換済み）を `onPositionSaved` へ渡す。`lastSyncFailure` は**最後に終わった送信の結果**を表す（位置の書込・完聴の記録のどちらも、成功で `nil`、`ApiFailure` での失敗でその値。ほかの error は無視する）。
- **完聴**（SG-C61・SG-C54・SG-X1）: `listenCompleted(id)` は同期の関数で、すぐ戻る。同じ再生の中で 2 回目以降は何もしない（`loading` で戻るので、同じエピソードをもう一度聴けばまた送る）。1 本の `Task` の中で次を順に行う: `beginBackgroundTask()` → `markCompleted(id)` → 位置の書込 → `onCompletionRecorded()` → 終了の closure。`markCompleted` が失敗しても続きを行う。位置の書込に使う値は「`ended` の状態が持つ総時間（0 より大きい）→ 完聴した時点の現在位置（0 より大きい）」の順で、どちらも 0 なら位置の書込を飛ばす。**id と書込に使う値は `listenCompleted` を呼ばれた時点で確定し、Task の中では Reporter の状態を読まない**（次のエピソードがキャッシュ済みだと、Task が動く前に次の `loading` が来て基準が戻る。現行 VM が位置を Task の前に控えているのと同じ理由）。
- `Podcast/Playback/` に `UIApplication` を書かない。background task は `beginBackgroundTask`（終了の closure を返す）で受ける。

### `Podcast/Playback/OfflineLibrary.swift`
```swift
struct AudioFileStore {                                  // port（application が宣言。closure の束。I-28）
    let url: (String) -> URL?; let exists: (String) -> Bool; let write: (Data, String) throws -> Void
    let remove: (String) throws -> Void; let removeAll: () throws -> Void; let size: () -> Int64
}
@MainActor final class OfflineLibrary: ObservableObject {
    @Published private(set) var savedIds: Set<String>      // 初期値は空
    nonisolated init(store: AudioFileStore)             // 既定引数や static let から作れるようにする（AVPlayerEngine と同じ）
    func save(_ data: Data, for id: String) throws
    func has(_ id: String) -> Bool
    func url(_ id: String) -> URL?
    func remove(_ id: String) throws
    func clearAll() throws
    func usage() -> Int64
    func refresh(candidateIds: [String])
}
```
- `has` / `url` はファイルの実体が正本（`store.exists`・`store.url`）。`OfflineLibrary` は `AudioCacheManager` の型を知らない（I-28）。`Podcast/Platform/AudioFileStore+Live.swift` が `AudioCacheManager` の `cachedURL(for:)`・`isCached`・`cache(_:for:)`・`remove`・`clearCache`・`cacheSize` から束を組む（`url` は `isCached` のときだけ値を返す）。`url` は無ければ `nil`。
- `save` は渡された音声データを保存して `savedIds` に足す。**取得（`fetchEpisode` → URL の検査 → `downloadAudio`）は呼ぶ側に残す**（I-10。呼ぶ側は I-T3 の `OfflineDownloads`。保存庫は App が 1 個持ち、ログインのたびに作り直される `APIClient` をまたいで生きるので、gateway を持てない）。二重実行の抑止もしない（呼ぶ側の `downloadingIds` が行う）。
- `remove` は削除して `savedIds` から外す。`clearAll` は全削除して `savedIds` を空にする。どちらも失敗したら、`savedIds` を実体に合わせ直して（`savedIds.filter(has)`）から error を投げる。
- `refresh(candidateIds:)` は `savedIds = Set(candidateIds.filter(has))`（I-10。`AudioFileStore` に id を列挙する操作が無い。現行 `syncDownloadedState()` と同じ作り方）。操作は再生 Spec §3.1 の現行の本文のとおり 8 つ（I-10。`save`・`has`・`url`・`remove`・`clearAll`・`usage`・`refresh`・`savedIds`）。
- `usage` は `store.size()`。

### `Podcast/Playback/NowPlaying.swift`（リードモデル。`struct`・`let` だけ。TA-D9 の対象）
```swift
struct QueueEntry: Identifiable, Equatable {               // I-25
    let episodeId: String; var id: String { episodeId }
    let introText: String; let difficulty: String; let durationSeconds: Int   // 総時間はサーバーの値（content.durationSeconds）
}
struct NowPlaying: Identifiable, Equatable {
    let episodeId: String; var id: String { episodeId }
    let displayTitle: String; let japaneseIntroText: String
    let segments: [TranscriptSegment]?; let vocabulary: [VocabularyEntry]?; let quiz: [QuizQuestion]?
    let difficulty: String
    let sourceArticles: [PodcastSourceArticle]?; let sourceKind: String?
    // 導出値 6 つ（field に数えない。I-26）: EpisodeContent の規則の結果と、待機列の行としての形を写した let
    let hasTranscript: Bool; let hasVocabulary: Bool; let hasQuiz: Bool
    let hasSourceArticles: Bool; let showsCcBySaLicense: Bool
    let queueEntry: QueueEntry
}
```
- field は共通 7 ＋ iOS 固有 2（SG-C11・C14）のまま。導出値 6 つは `let` で、規則の式は `EpisodeContent` の 1 箇所（I-26。`NowPlaying` に computed の規則を書かない）。

### `Podcast/Playback/Domain/PlaybackRules.swift`（domain）
```swift
enum PlaybackSource: Equatable { case cached, network, unavailable }
enum PlaybackRules {
    static func resolvePlaybackSource(hasCached: Bool, isOnline: Bool) -> PlaybackSource          // TA-R-PB-3
    static func resolveResumePosition(serverSeconds: Double, durationSeconds: Double) -> Double  // TA-R-PB-2（RS-01〜RS-07）
    static func clampPosition(_ seconds: Double, duration: Double) -> Double                      // TA-R-PB-5（duration 0 なら下限 0 だけ）
    static func isLoaded(_ state: PlaybackState) -> Bool                                          // loading / playing / buffering / paused
}
```

### `Podcast/Playback/PlaybackCoordinator.swift`
```swift
enum PlaybackNotice: Equatable { case failure(PlaybackErrorReason), loadWarning(String) }

@MainActor final class PlaybackCoordinator: ObservableObject, PlaybackLifecycle {
    @Published private(set) var session: PlaybackState
    @Published private(set) var presentation: PlayerPresentation      // 初期値 .hidden
    @Published private(set) var queue: PlaybackQueue<Episode>
    @Published private(set) var notice: PlaybackNotice?
    @Published private(set) var isAdvancing: Bool                     // 初期値 false
    init(engine: any AudioEngine, nowPlayingCenter: NowPlayingCenter, library: OfflineLibrary,
         reporter: PositionReporter,
         fetchEpisode: @escaping (String) async throws -> Episode,
         isOnline: @escaping () -> Bool,
         defaultSpeed: @escaping () -> Float,
         lockScreenSubtitle: @escaping (_ difficulty: String) -> String,
         beginBackgroundTask: @escaping () -> (() -> Void))

    // 公開 19 操作（presentation は上の値）
    func startEpisode(_ episode: Episode, expandsPlayer: Bool = true) async
    func startEpisode(id: String) async throws
    func replayCurrent() async
    func retry() async
    func togglePlayPause()
    func seek(to seconds: Double)
    func setSpeed(_ speed: Float)
    func addToQueue(_ episode: Episode) async
    func playNext(_ episode: Episode) async
    func removeFromQueue(id: String)
    func moveUpNext(fromOffsets source: IndexSet, toOffset destination: Int)
    func skipToNext() async
    func nowPlaying() -> NowPlaying?
    func upNext() -> [QueueEntry]
    func dismissError()
    func stopForLogout()
    func minimizePlayer()
    func expandPlayer()

    // 操作に数えないもの
    func onEnded(endedId: String) async
}
```
- 19 操作の数え方: `startEpisode(_:expandsPlayer:)`・`startEpisode(id:)`・`replayCurrent`・`retry`・`togglePlayPause`・`seek`・`setSpeed`・`addToQueue`・`playNext`・`removeFromQueue`・`moveUpNext`・`skipToNext`・`nowPlaying()`・`upNext()`・`presentation`・`dismissError`・`stopForLogout`（ここまで 17。SG-C10）＋ `minimizePlayer`・`expandPlayer`（SG-C60）。
- Coordinator は生成時に `PlaybackSession(engine:)` を作り、**`reporter.attach(session)` を先に呼んでから**自分を `session.observe` に登録する。`PlaybackSession` のオブジェクトは外へ出さない。`session`（`@Published`）は `PlaybackSession.state` の写しで、`stateChanged` と `positionChanged` を受けるたびに更新する。
- `@Published` は上の 5 つだけ（`notice` は I-6、`isAdvancing` は I-18）。`isAdvancing` は「自動で次へ進む途中の待ち」の間だけ true（`onEnded` の 6 で true、待ちが終わったら false。`stopForLogout()` でも false）。ロック画面 port を持つプロパティの名前は `nowPlayingCenter` にする（操作 `nowPlaying()` と同じ名前にしない）。
- `fetchEpisode` は `ApiFailure` のほか、Task の cancel による error（`CancellationError`・`URLError(.cancelled)`）も投げ得る。`Podcast/Playback/` に `APIClient`・`.unauthorized`・通信のデータモデル（`Podcast` ほか `DTO` の型名）・`AudioCacheManager`・`NowPlayingInfo` を書かない（TA-D2・D3。失効の検知は gateway 側の役目。`GrepOracleTests` の O-1 が `.unauthorized` の置き場所を検査している）。
- Coordinator が Session の状態を写した値が `session`。テストは Session のオブジェクトに触れないので、T-T7a の「写しが正しい」は、各操作の後の `coordinator.session` が期待する状態であることで確かめる。
- `nowPlaying()` は、`session` が `idle` のとき `nil`。それ以外は `queue.current` の `Episode` の `content` から作る（`displayTitle` は `content.displayTitle`。導出値 5 つの `Bool` は `EpisodeContent` の同名の規則の結果を写し、`queueEntry` は同じエピソードの `QueueEntry`。field は共通 7 ＋ iOS 固有 2 のまま。I-26）。
- `upNext()` は `queue.upNext` の各 `Episode` を `QueueEntry` に写した配列（I-25）。値型なので、戻り値を書き換えても Coordinator の状態は変わらない。
- 純関数は `PlaybackRules`（domain）。共有仕様 §6.1・§6.4 のとおり。`resolveResumePosition` は RS-01〜RS-07 の表がそのまま仕様。

**通知 `notice`**（I-6）: 利用者に 1 回見せる知らせを 1 つ持つ。次のときに置く。
- 手動の開始が、開始前に再生できないと分かった → `.failure(理由)`（SG-C62）
- Session が `errored` に入った → `.failure(理由)`
- `start` が警告を返した → `.loadWarning(説明文)`（SG-C41）

消すのは `dismissError()` と、開始が確定したとき（下の「開始の確定」の最初）。`errored` の状態そのものは `dismissError()` で変えない（失敗したエピソードが現在のまま残り、再生ボタンが再試行になる）。

**開始の流れ**（I-7。**状態を変えるのは、待ちが終わって世代を確かめた後だけ**）

Coordinator は世代番号（整数）を持つ（I-7・I-23）。
- **待ちに入る入口は、待ちの前に世代を 1 進めて、その値を控える**（手動の開始・`startEpisode(id:)`・`replayCurrent`・`retry`・`skipToNext`・自動の `onEnded`）。待ちの後で世代が控えた値と違っていたら、その開始は捨てる（何も変えない）。後から始めた入口が勝つ。
- 「開始の確定」「`session.stop()`」「`session.fail()`」「`stopForLogout()`」でも 1 進める（待っている開始を捨てさせる）。
- **利用者の操作を自動より優先する**（I-23）: 利用者が起こした入口（`onEnded` 以外）の待ちが 1 つでも残っている間、`onEnded` は完聴を送るだけで、次へ進む処理を始めない（残っている利用者の開始が確定する）。`onEnded` の待ちの間に利用者の入口が始まれば、世代が進むので `onEnded` の側が捨てられる。
- `fetchPodcast` が cancel による error を投げたら、その開始は捨てる（何も変えない）。

`startEpisode(_ episode:, expandsPlayer:)`（手動の入口）
1. `episode` が `.playable` でない、または `URL(string: playable.audioUrl)` が `nil` なら、`notice = .failure(.invalidSource)` として戻る。キューも Session も変えない（以下、この 1 と 2 を「開始前の判定」と呼ぶ）。
2. `PlaybackRules.resolvePlaybackSource(hasCached: library.has(id), isOnline: isOnline())` が `unavailable` なら `notice = .failure(.offlineUncached)` として戻る。何も変えない。
3. 世代を 1 進めて控え、「再生元の用意」を行う。
4. 世代が変わっていたら戻る。
5. キュー: `queue.jump(to: id)` が false なら `queue.playNext(episode)` → `queue.jump(to: id)`。
6. 「開始の確定」。

「再生元の用意」
- `cached`: URL は `library.url(id)`、再開位置の元は `playable.serverPosition`。待たない。
- `network`: `fetchEpisode(id)` を 1 回呼ぶ。成功して、`.playable` で `audioUrl` が `URL` になるなら、取り直した `Episode` を使う。失敗（cancel 以外の error）またはそうでなければ、保持している `episode` を使う（SG-C4。保持している側の `audioUrl` は「開始前の判定」で `URL` になることを確かめてある）。
- `session.start` に渡す `PlayableEpisode`・URL・再開位置の元・総時間は、**同じ 1 つの `Episode`**（取り直したものか、保持しているもの）から作る。

「開始の確定」（待たずに続けて行う）
1. 世代を 1 進め、`notice = nil`、`isAdvancing = false`、割り込みの記憶を消す。
2. `reporter.flush()`（前の再生の位置を送る。送る状態でなければ何も起きない）。
3. `session.start(episode:url:resumePosition:speed:)`。`resumePosition` は `PlaybackRules.resolveResumePosition(serverSeconds:durationSeconds:)`、`speed` は `defaultSpeed()`。警告が返ったら `notice = .loadWarning(警告)`。
4. 表示形態: `expandsPlayer` が true なら `.expanded`。false なら `.hidden` のときだけ `.mini`。
5. リモートコマンドの登録が無ければ登録して token を持つ（SG-C59）。

ほかの入口

| 操作 | 内容 |
|---|---|
| `startEpisode(id:)` | 世代を進めて控え、`fetchEpisode(id)`。失敗は、受けた error をそのまま投げて戻る（キュー・Session・`notice` を変えない。cancel による error も同じ）。世代が変わっていたら戻る。成功したら `startEpisode(_:expandsPlayer: true)` と同じ流れに入る。**解決した `Episode` を「再生元の用意」の再取得の結果として使い、`fetchEpisode` は 1 回しか呼ばない**（I-14） |
| `replayCurrent()` | `nowPlaying()` が `nil` なら何もしない。`queue.current` を手動の入口と同じ流れで始める（開始前に再生できないと分かれば `notice` だけ。`ended` の表示は残る）。キューは変えない。**再開位置は 0**（`start` の後で seek しない。I-14）。表示形態は `expandsPlayer: false` の規則 |
| `retry()` | `session` が `errored` で `queue.current` があるときだけ動く。「開始前の判定」に落ちたら `session.fail(id, 理由)` を呼び、**Coordinator が `notice = .failure(理由)` を自分で置く**（`errored` の値が前と同じだと `stateChanged` が出ないため）。それ以外は世代を進めて控え、「再生元の用意」→ 世代の確認 → 「開始の確定」（`expandsPlayer: false`） |
| `togglePlayPause()` | `loading / playing / buffering` → `session.pause()`。`paused` → `session.play()`。`errored` → `Task { await retry() }`。`idle`・`ended` → 何もしない |
| `seek(to:)`・`setSpeed` | Session の同名の操作を呼ぶ |
| `addToQueue(e)`・`playNext(e)` | 先に「何も再生していないか」（`session == .idle`）を控える。`queue.add(e)` / `queue.playNext(e)`。控えが true なら `startEpisode(e)` と同じ流れ（キューに足したことは、開始できなくても残る） |
| `removeFromQueue(id)` | `id` が `queue.current` のもので `session` が `idle` でなければ、`reporter.flush()` → `queue.remove(id:)` → `session.stop()`。次の要素が `queue.current` になるが、自動では再生しない（CI-P17）。それ以外は `queue.remove(id:)` だけ。表示形態は変えない |
| `moveUpNext` | `queue.reorderUpNext(fromOffsets:toOffset:)` |
| `skipToNext()` | 共有仕様 §2.12。利用者の操作として扱う。`queue.upNext.first` が無ければ何もしない。それが「開始前の判定」に落ちたら `notice` だけ（キューも Session も変えない）。それ以外は世代を進めて控え、「再生元の用意」→ 世代の確認 → 待機列の先頭が用意したものと同じなら `queue.advance()` →「開始の確定」（`expandsPlayer: false`）。先頭が変わっていたら何もしない。完聴は送らない |
| `dismissError()` | `notice = nil` |
| `minimizePlayer()` | `presentation` が `.hidden` なら何もしない。それ以外は `.mini` |
| `expandPlayer()` | `nowPlaying()` が `nil` なら何もしない。それ以外は `.expanded` |
| `stopForLogout()` | 世代を進める → `session.stop()` → `nowPlayingCenter.clear()` → token を解除して手放す → `queue = PlaybackQueue()` → `presentation = .hidden` → `notice = nil` → `isAdvancing = false` → 割り込みの記憶を消す。**`reporter.flush()` を呼ばない**。2 回呼んでも同じ |

`onEnded(endedId:)`（Session の `ended` を受けたら、Coordinator は `Task { await onEnded(endedId:) }` で呼ぶ。購読 Task の cancel に巻き込まれない形にする）
1. `endedId != queue.current?.id` なら何もしない（古い通知）。
2. `reporter.listenCompleted(id: endedId)`（待たない）。
3. 利用者が起こした入口の待ちが残っていれば、ここで終わる（I-23）。
4. `queue.upNext.first` が無ければ、`nowPlayingCenter.clear()` を呼んで終わる（`ended` の状態を残す。キューは進めない）。
5. 次が「開始前の判定」に落ちたら、`queue.advance()` → `session.fail(次の id, 理由)`（共有仕様 §2.11。先にキューを進めるので、失敗したエピソードが現在になり、INV-P1 が保たれる。次へは進まない）。
6. それ以外は、世代を 1 進めて控え、`isAdvancing = true` にし、`beginBackgroundTask()` で囲んで「再生元の用意」を行う（I-16。画面ロック中は音が止まるとアプリが休止され得る）。待ちが終わったら `isAdvancing = false`。
7. 世代が変わっていたら戻る。待機列の先頭が用意したものと違っていたら、4 からやり直す（完聴は送り直さない）。
8. `queue.advance()` →「開始の確定」（`expandsPlayer: false`）。

- 待ちが入るのは `network` のときだけ。`cached` と `unavailable` は待たずに終わる。
- 待ちの間はキューも Session も前のままなので、INV-P1 は途中でも崩れない。
- `fetchFailed` を Coordinator が作る経路は無い（SG-C4 のフォールバックのため。I-8）。共有仕様 PS-01 の「取得が失敗」は、iOS では「取り直しが失敗し、保持している URL の読み込みも engine が失敗した」場合で、理由は `engineFailed` になる。

**Session の通知を受けたときの動作**

| 通知 | Coordinator の動作 |
|---|---|
| `stateChanged(s)` | `session = s`。`s` が `loading / playing / buffering / paused` なら `nowPlayingCenter.update(NowPlayingSnapshot(title: queue.current の content.displayTitle, subtitle: lockScreenSubtitle(content.difficulty), elapsed: s.position, duration: s.duration, rate: s.speed ?? 1.0, isPlaying: s が loading・playing・buffering))`（I-27）。`queue.current` が `nil` のときと、`idle`・`errored` のときは `nowPlayingCenter.clear()`。`ended` では呼ばない（`onEnded` が決める）。`errored` に入ったら `notice = .failure(理由)` |
| `positionChanged(秒, 総時間)` | `session` を写し直し、`nowPlayingCenter.updateElapsed(秒, duration: 総時間)` |
| `ended(id)` | `Task { await onEnded(endedId: id) }` |
| `interruption(.began(w))` | `w` を覚える |
| `interruption(.ended(r))` | `r` が true で、覚えた値が true で、`session` が `paused` なら `session.play()`。覚えた値を消す |

**リモートコマンド**（I-12。handler は Coordinator を弱参照で持ち、無ければ `.commandFailed`）

「操作できる」= `session` が `loading / playing / buffering / paused`。

| コマンド | 操作できるとき | できないとき |
|---|---|---|
| `play` | `paused` なら `session.play()`。`.success` | `.noSuchContent` |
| `pause` | `paused` でなければ `session.pause()`。`.success` | `.noSuchContent` |
| `togglePlayPause` | `togglePlayPause()`。`.success` | `.noSuchContent` |
| `skipBackward` | `session.seekRelative(-PlaybackConstants.skipBackwardSeconds)`。`.success` | `.noSuchContent` |
| `skipForward` | `session.seekRelative(PlaybackConstants.skipForwardSeconds)`。`.success` | `.noSuchContent` |
| `changePosition(秒)` | `seek(to: 秒)`。`.success` | `.commandFailed` |
| `changeRate(速度)` | `setSpeed(速度)`。`.success` | `.noSuchContent` |

Coordinator の `deinit` でも token を解除する（`stopForLogout()` の後なら token は既に無い。二重の解除は無害）。

### `Podcast/Playback/PlaybackCoordinator+Preview.swift`
ファイル全体を `#if DEBUG` … `#endif` で囲む。`extension PlaybackCoordinator { static func previewParts(session: PlaybackState, queue: PlaybackQueue<Episode>) -> (coordinator: PlaybackCoordinator, reporter: PositionReporter, library: OfflineLibrary) }`。engine・ロック画面 port・gateway の closure は、同じファイルの中の private な「何もしない」実装を渡す。保存庫は「何もしない」`AudioFileStore`（`exists` は false、`url` は nil、書込と削除は何もしない、`size` は 0）で `OfflineLibrary(store:)` をこのファイルの 1 箇所で作り（`AudioCacheManager` を作らない。TA-D13）、Reporter も「何もしない」closure で作る（I-S3b2 の `PreviewSupport` は、facade の生成に要る 3 つをここから受け取り、自分では作らない）。`import` は `Foundation` と `Combine` だけ。

写しの値を直接置くために、`PlaybackCoordinator.swift` の側に DEBUG 専用の入口を 1 つだけ持つ（I-17。現行 `previewMarkFinished()` と同じ扱い）。
```swift
#if DEBUG
extension PlaybackCoordinator {
    /// Preview 専用。写しの値を直接置く（Session は動かさない）。
    func previewSet(session: PlaybackState, queue: PlaybackQueue<Episode>)
}
#endif
```

## test double（`NewsListenAppTests/AudioEngineDouble.swift` の変更。I-2）
現行の double は `play / pause / seek / setRate` が何もしないので、Session が engine を正しく動かしたかを観測できず、開始の順序を誤った実装がテストを通る。実 adapter と同じ振る舞いにする。

| 追加するもの | 振る舞い |
|---|---|
| `private(set) var loadedURL: URL?` | `load` で設定、`stop` で `nil` |
| `private(set) var hasStartedPlayback: Bool` | `load`・`stop` で false、`play()` で true |
| `private(set) var rate: Float` | `load`・`stop`・`pause()` で 0。**`play()` で 1.0**（実 adapter と同じく速度を戻す）。`setRate(r)` で `r` |
| `private(set) var lastSeekSeconds: Double?` | `load`・`stop` で `nil`、`seek(to:)` で設定 |
| `send(_:)`（engine 側の入口） | `hasStartedPlayback` が false の間に、読み込みごとの事象（`ready / buffering / resumed / paused / ended / failed / timeUpdate`）を送ろうとしたら `XCTFail` して送らない。`interrupted / interruptionEnded / outputDeviceLost` は読み込み済みならいつでも送れる |

- 読み込み済みでないとき、`play / pause / seek / setRate` は状態を変えない（port の契約どおり）。
- 呼出回数は公開しない（SG-C26）。`EngineChannel` の `deliver / send / yield` は変えない（古い読み込みへの注入に使う）。
- `AudioEngineDoubleTests` の既存 5 件のうち、`engine.send` を `play()` なしで呼んでいる件（D02・D04）は Given に `engine.play()` を足す。Then は変えない。新規 2 件を足す: 「`play()` の前の読み込みごとの事象は届かない（`XCTExpectFailure`）」「`rate`・`lastSeekSeconds`・`loadedURL` が操作に従う（`play()` は 1.0 に戻す）」。
- `PodcastViewModelTests`（72）・`PodcastViewModelPortTests`（13）は、VM が `load` の後に必ず `engine.play()` を呼ぶので、変更なしで green のはず。green にならなければ、テストを直さずに止めて報告する。

## 契約（RED テスト。テスト名またはコメントに `verifies: CI-T*` を持つ）
oracle は公開操作・状態・double の状態・gateway double の呼出列に限る。engine double の呼出回数は assert しない。

| CI | テスト | 行 ID |
|---|---|---|
| CI-T1 | **T-T1**: 上の 16 辺を表のとおりに駆動し `state` を観測（分母 16）。`ready` では `stateChanged` が `paused` → `playing` の順に 2 回出る。表の外の例（`idle` で engine の事象、`ended` で `play()`、`errored` で `play()`、`paused` で `resumed`）で状態が変わらない。古い読み込みの channel へ `yield` した事象で状態が変わらない | — |
| CI-T1 | **T-T1g**（engine を正しく動かしたか）: `start` の後、double が `loadedURL == url`・`hasStartedPlayback`・`rate == 開始の速度`・`lastSeekSeconds == 再開位置`（再開位置 0 なら `nil`）。`pause()` の後 `rate == 0`。`paused` からの `play()` の後 `rate == 速度`。`seek` の後 `lastSeekSeconds` が丸めた値。`ended`・`errored` に入った後 `isLoaded == false` | — |
| CI-T2 | **T-T2**: `failed` → `errored(engineFailed(説明))`。`play()` を続けて呼んでも 1 状態に収束。`paused` で届いた `failed` は状態を変えず、次の `play()` で `playing` → `errored` の順に出る。`paused` で届いた `ended` は次の `play()` で `playing` → `ended` の順に出て `SessionEvent.ended` が 1 回出る。`buffering` で届いた `ended` は `playing` → `ended` の順に出る | — |
| CI-T1b | **T-T1b**: `idle` 以外の 6 状態で `stop` → `idle` かつ `isLoaded == false`。`idle` での `stop` は double の状態も通知も変えない | **PS-09**（テスト名に含める） |
| CI-T1c | **T-T1c**: engine 由来の一時停止の表駆動（`paused` 事象は `buffering` のときだけ。`outputDeviceLost` と `interrupted` は `loading`・`playing`・`buffering` のとき）。`loading` での `seek` は `resumePosition` を置き換え、double の `lastSeekSeconds` がその値になる。`interrupted` は `began(wasPlaying:)` を 1 回、`interruptionEnded` は `ended(shouldResume:)` を 1 回出す。Session は自分から再開しない | — |
| CI-T1d | **T-T1d**: `nextLoadWarning` を置いた `start` は警告をそのまま返し、状態は `loading`。置かなければ `nil` | — |
| CI-T1e | **T-T1e**: 総時間は `durationSeconds` で始まり、`timeUpdate` の総時間が 0 より大きければ置き換わる（0 では置き換わらない）。どちらも 0 の間は `seek` を上限で丸めない。分かっている間は `[0, 総時間]` | — |
| CI-T1f | **T-T1f**: 7 状態それぞれから `fail(id, 理由)` → `errored(episodeId: id, position: 0, reason:)`。理由は `offlineUncached`・`invalidSource`・`fetchFailed` の 3 つ。`idle` 以外からは `isLoaded == false`。`fail` の後の `start` で `loading` へ進める | **PS-10** |
| CI-T3 | **T-T3**: `PlaybackRules.resolveResumePosition` の表駆動（domain のテスト。`domainTestFiles`） | **RS-01〜RS-07**（テスト名に含める） |
| CI-T4 | **T-T4**: 開始のたびに速度が `defaultSpeed()` の値になる（既定 1.5 → 開始 → `setSpeed(2.0)` → 次を開始 → 1.5）。double の `rate` も同じ値。`defaultSpeed` の closure は読むだけ | — |
| CI-T5 | **T-T5**: `unavailable` は `fetchEpisode` 0 回・何も変わらず・`notice == .failure(.offlineUncached)`。`network` は `fetchEpisode` 1 回で、取り直した `audioUrl` が `loadedURL`。取り直しの失敗では保持している URL が `loadedURL`。`cached` は `fetchEpisode` 0 回で `loadedURL == library.url(id)`。`startEpisode(id:)` も `fetchEpisode` 1 回 | **PS-11**（手動の開始の分） |
| CI-T6 | **T-T6**: `[a, b]` で a を再生中に `ended`。(0) b が再生可能でない、または `audioUrl` が `URL` にならない → `queue.current == b`・`errored(invalidSource)`。(1) b がオフラインで未キャッシュ → `queue.current == b`・`errored(offlineUncached)`・`fetchEpisode` 0 回・`isLoaded == false`。(2) b の読み込みで engine が `failed` → `queue.current == b`・`errored(engineFailed)`・c へ進まない。(3) その後の `retry()`（と `togglePlayPause()`）で b が「再生元の用意」からやり直して始まる。`retry()` がまた「開始前の判定」に落ちたときは、`dismissError()` の後でも `notice` が入り直す。(4) `errored` の間は時計を進めても位置の送信が 0 | — |
| CI-T7 | **T-T7a**: 公開 **19** 操作それぞれの後に INV-P1（`session.episodeId == queue.current?.id`。`idle` は対象外）と、`coordinator.session` がその操作の後に期待する状態であること。`startEpisode(id:)` は解決成功と解決失敗（キュー・`session`・`notice` 不変で throw）の両方。`replayCurrent()` は現在あり（再開位置 0 で始まる・表示形態不変）と、なし（何もしない）と、オフライン未キャッシュ（`ended` のまま・`notice`）。`nowPlaying()` の 9 field と導出値 6 つ（5 つの `Bool` は `EpisodeContent` の規則の結果と一致、`queueEntry` は `upNext()` の行と同じ形）が `queue.current` から導かれ、`idle` で `nil`。`upNext()` が `[QueueEntry]` を返す。**TA-V6（PB）**: (1) `coordinator.queue` を変数に取り `remove` / `advance` しても `coordinator.queue`・`nowPlaying()`・`upNext()` が変わらない、(2) `startEpisode` に渡した `Episode` を持つ配列を後から書き換えてもキューが変わらない、(3) `upNext()` の戻り値の配列を書き換えても次の `upNext()` が変わらない | **PS-04** |
| CI-T7 | **T-T7c**（表示形態）: 初期は `hidden`。`startEpisode(expandsPlayer: true)` → `expanded`。`hidden` から `expandsPlayer: false` の開始 → `mini`。`mini` / `expanded` から `expandsPlayer: false` の開始 → 不変。開始前に再生不可・解決失敗 → 不変。`minimizePlayer` は `hidden` で不変・それ以外で `mini`。`expandPlayer` は `nowPlaying()` が `nil` で不変。待機列が尽きた `ended` で不変。`stopForLogout` → `hidden` | — |
| CI-T7 | **T-T7d**（ロック画面）: コマンド 7 種 × （操作できる／できない）の戻り値が上の表どおり。開始で `NowPlayingCenterSpy.currentInfo` が入り、`positionChanged` で `lastElapsedUpdate` が更新され、`idle`・`errored`・待機列が尽きた `ended` で `currentInfo == nil`。開始を 2 回しても `activeRegistrationCount == 1`。`stopForLogout` の後 0。別の Coordinator（同じ spy）を破棄しても、生きている Coordinator の登録は残る | — |
| CI-T7 | **T-T7e**（待ちの間の割り込み）: `fetchEpisode` を保留できる double で、(1) A の開始を保留 → B（キャッシュ済み）を開始 → A を解放 → `queue.current == B`・`session` は B。(2) 保留中は `queue`・`session` が前のまま。(3) 保留中に `stopForLogout` → 解放しても何も始まらない（`isLoaded == false`・キュー空）。(4) 自動で次へ進む途中の保留中に待機列の先頭を削除 → 解放後は新しい先頭が始まる。(5) 手動 B（未キャッシュ）を保留 → a が `ended` → B を解放 → B が始まる（自動は始まらない）。(6) 自動 C を保留 → 手動 B（未キャッシュ）を保留 → C を先に解放 → 何も始まらない → B を解放 → B が始まる。(7) `isAdvancing` は自動の保留中だけ true。(8) 保留中の `fetchEpisode` が `CancellationError` を投げる → 何も変わらない | **PS-13**（(5)(6) の分） |
| CI-T7 | **T-T7f**（`stopForLogout`）: 再生中に呼ぶ → 位置の送信 0・`isLoaded == false`・キュー空・`hidden`・`currentInfo == nil`・`notice == nil`。2 回呼んでも同じ | — |
| CI-T7 | **T-T7g**（そのほかの操作）: `skipToNext` は、次が再生できる → 位置を 1 回送って次が始まり、`markCompleted` 0 回・表示形態不変。次が開始前に再生不可 → `notice` だけ。待機列が空 → 何も変わらない。`removeFromQueue`（現在）→ 位置を 1 回送り `idle`・次の要素が `queue.current`・自動では始まらない。`addToQueue` / `playNext` は `idle` のとき開始し、`idle` でなければキューだけ変わる。`togglePlayPause` は状態ごとに表どおり。割り込みは「再生中に開始 → 終了（再開してよい）」で再開し、「一時停止中に開始」では再開しない。`dismissError` は `notice` を消し `errored` を変えない | **PS-12・PS-12b・PS-12c**（`skipToNext` の分） |
| CI-T8 | **T-T8**: 上の Reporter の規則の表を 1 行ずつ。時計を注入して、(a) `playing` に入って 15 秒未満は 0 回・15 秒で 1 回、(b) 一時停止への遷移で 1 回・一時停止中は時計を進めても 0 回、(c) `flush()` は `playing / buffering / paused` で 1 回・同じ位置の 2 回目は 0・ほかの状態で 0、(d) 送った値より小さい位置（巻き戻し）も、一時停止への遷移と `flush()` で送る、(e) 完聴の呼出列が `markCompleted(id)` → `updatePosition(id, 総時間)` → `onCompletionRecorded` で、同じ再生の 2 回目は増えず、次の `loading` の後はまた送る。`listenCompleted(a)` の直後（Task が動く前）に次のエピソード b の `loading` が来ても、書込は `updatePosition(a, a の総時間)`、(f) 総時間 0 なら完聴時点の位置、それも 0 なら位置の書込なし（`markCompleted` は送る）、(g) `markCompleted` が失敗しても位置の書込は行われる。`lastSyncFailure` は最後に終わった送信の結果（失敗で値・成功で `nil`）、(h) 位置の応答が `onPositionSaved` に 1 回渡る、(i) `markCompleted` を保留しても `listenCompleted` はすぐ戻る、(j) `beginBackgroundTask` の開始と終了が 1 回ずつ | — |
| CI-T10 | **T-T10**: `AudioFileStore.live(cacheManager: AudioCacheManager(fileManager: MockFileManager()))` で組んだ store を渡し、`save` の後 `has` true・`savedIds` に含む。`clearAll` の後 `has` false・`savedIds` 空。`remove` の後も同じ。`refresh(candidateIds:)` は実体のある id だけ。`url` は無ければ `nil`。削除が失敗する double（`AppStateTestSupport.swift` の `FailingRemoveFileManager`。`MockFileManager` は `final` で継承できない）では `savedIds` が実体と一致したまま error | — |

T-T11（`toEpisode()` の 20 通り）は I-T2a の `EpisodeTests` が green にしている。本 slice では書かない（補正 6）。

## 完了条件
1. 契約テストが上の表のとおり green。既存テストが全件 green。
2. 既存の production を変えていない: `git diff --diff-filter=M --name-only origin/main -- NewsListenApp/NewsListenApp` が **0 行**（2026-09-30 実測 0）。
3. 追加した production が 9 本だけ: `git diff --diff-filter=A --name-only origin/main -- NewsListenApp/NewsListenApp` が **ちょうど 9 行**（対象の表の 9 本）。**コミットした後に実行する**（`git diff origin/main` は追跡していない新規ファイルを出さないので、コミット前は 0 行になる）。
4. 依存方向: `grep -rn "^import \(AVFoundation\|MediaPlayer\|UIKit\|SwiftUI\)" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 件。`grep -rn "APIClient" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 件（コメントを含めて）。`grep -rn "\.unauthorized" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 件。`grep -rn "UIApplication\.\|Timer\.\|Timer(" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 件（いずれも 2026-09-30 実測 0）。`grep -rnw "Podcast\|AudioCacheManager\|NowPlayingInfo" NewsListenApp/NewsListenApp/Podcast/Playback/ | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件（通信のデータモデル・保存の具象・辞書の組み立てを知らない。TA-D2・D3）。`ArchitectureOracleTests` が green で、許可リストに `Podcast/Playback/` の path が 0 行、`readModelFiles` に `Podcast/Playback/NowPlaying.swift` があり T-TA-V5b が非空の集合で green（`readModelFiles.isEmpty` の assert を外して非空の assert に改める）、`Podcast/Playback/Domain/` の 2 本が domain に当たる。
5. 既存コードから呼んでいない: `grep -rnw "PlaybackCoordinator\|PlaybackSession\|PlaybackState\|PlaybackNotice\|PlaybackRules\|OfflineLibrary\|PositionReporter\|NowPlaying\|QueueEntry\|AudioFileStore" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Podcast/Playback/" | grep -v "^NewsListenApp/NewsListenApp/Podcast/Platform/AudioFileStore+Live.swift" | grep -v ":[0-9]*:[[:space:]]*//"` が 0 件。
   - **`-w`（単語一致）を外さない**。外すと `OfflineLibrary` が既存の識別子 `clearOfflineLibrary`（`AppState.swift`・`Auth/SubjectCleanup.swift` の 6 行）に、`NowPlaying` が `NowPlayingCenter`・`NowPlayingInfo` に部分一致する。2026-09-30 実測: `-w` ありで 0 件、`-w` なしの `OfflineLibrary` は 6 件。
   - 正の対照: 末尾のコメント除外を外すと、I-S2 が書いた TP2・TP4 のコメント 4 行（`Settings/SettingsViewModel.swift:70,71`・`Podcast/PlaybackLifecycle.swift:7`・`Podcast/PodcastViewModel.swift:686`）が出る。
6. `Episode` の利用者が増えていない: `grep -rlw "Episode\|PlayableEpisode\|GeneratingEpisode\|FailedEpisode" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Catalog/Domain/\|^NewsListenApp/NewsListenApp/Models/Podcast+Episode.swift\|^NewsListenApp/NewsListenApp/Podcast/Playback/"` が 0 件（I-T2a の後は `Catalog/Domain/` と `Models/Podcast+Episode.swift` だけが使う。`-w` なしだと `replayCurrentEpisode` などに一致する）。
7. 状態の公開: `grep -c "@Published private(set) var \(session\|presentation\|queue\|notice\|isAdvancing\)" NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator.swift` → 5、`grep -c "@Published" 同ファイル` → 5。
8. Preview: `grep -n "^import" NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator+Preview.swift` が `Foundation` と `Combine` だけ。`grep -c "#if DEBUG" 同ファイル` → 1。`grep -c "#if DEBUG" NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator.swift` → 1。`grep -rn "AudioCacheManager" NewsListenApp/NewsListenApp/Podcast/Playback/` が 0 行（Preview は「何もしない」`AudioFileStore`。TA-D13）。`grep -rn "AudioCacheManager()" NewsListenApp/NewsListenApp/Podcast/Platform/AudioFileStore+Live.swift` が 0 行（具象は引数で受け、作らない）。

## 禁止事項 / scope 外
- 既存の production ファイルを変えない（`PodcastViewModel.swift`・`Podcast/Playback/Domain/PlaybackQueue.swift`・`Catalog/Domain/`・`Models/Podcast+Episode.swift`・`PodcastRowView.swift`・`PreviewSupport.swift`・`NewsListenAppApp.swift`・`SettingsViewModel.swift`・`AppState.swift`・`Podcast/Platform/`・`Podcast/Playback/AudioEngine.swift`）。入口の差し替えと `PlaybackQueue` の重複除去は I-S3b2。
- PS-01〜PS-03・PS-05・PS-05b・PS-06・PS-07・PS-07b・PS-08 の行 ID を本 slice のテスト名に付けない（入口を差し替える I-S3b2 の準拠テストが付ける）。本 slice が付ける行 ID は RS-01〜RS-07・PS-04・PS-09・PS-10・PS-11・PS-12・PS-12b・PS-12c・PS-13（共有仕様 §4.4 の保留の解除条件。TA Spec §8.3 の補正 7）。
- 分母 16 を変えない。`stop`・`fail` を遷移表に足さない。Spec に無い状態・失敗理由を足さない。
- 公開操作を 19 より増やさない。`NowPlaying` の field を共通 7 ＋ iOS 固有 2 から増やさない（導出値 6 つは field に数えない。I-26）。`Podcast` DTO を `NowPlaying`・`QueueEntry` の field に持たない。`Podcast/Playback/` に `DTO` の型名・`AudioCacheManager`・`NowPlayingInfo` を書かない。
- `skipToNext` をロック画面の「次のトラック」につながない（I-S3c）。
- RO1〜RO7・SG-A7（Spec §5 rejected_overdesign）を作らない。`reorderUpNext` を rename しない。`AudioCacheManager` を protocol にしない（port は closure の束 `AudioFileStore`。I-28・I-36）。
- 仕様にない業務条件を足さない。

## 特性テスト（baseline。着手前に green を記録する。2026-09-30 実測の件数）
`PodcastViewModelTests`（72）・`PodcastViewModelPortTests`（13）・`AudioEngineDoubleTests`（5）・`AVPlayerEngineTests`（6）・`AVPlayerEngineLifecycleTests`（7）・`MediaPlayerNowPlayingTests`（3）・`GrepOracleTests`（10）・`PlaybackQueueTests`（12）・`PlaybackQueueConformanceTests`（32）・`AudioCacheManagerTests`（13）・`NowPlayingInfoTests`（13）・`TranscriptTimingTests`（13）・`SettingsViewModelTests`（36）・`EpisodeTests`（20。I-T2a）・`EpisodeContentTests`（I-T2a）・`ArchitectureOracleTests`（I-T1）。着手後は `AudioEngineDoubleTests` が 7 になり、ほかは同数で green。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`（ios README の現行の形式。`SIMULATOR='<機種名>'` で機種を指定）→ 全 green（既存 ＋ 新規 T-T1・T1b〜T1g・T2〜T8・T7a〜T7g・T10）。
- 完了条件 2〜8 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- 実機・シミュレータでの再生の確認は本 slice では行えない（production から呼ばれない）。開始の順序（速度が効く）と、事象の届く順序の確認は I-S3b2 の目視項目に入れてある。

## 規模（見込み。2026-09-30 実測の基点: `PodcastViewModel.swift` 698 行・`AudioEngineDouble.swift` 285 行）
- production ≈ 900 行: Session ≈ 230・`PlaybackState` ≈ 50・`PlaybackRules` ≈ 40・Coordinator ≈ 360・`NowPlaying`・`QueueEntry` ≈ 40・Reporter ≈ 110・OfflineLibrary と `AudioFileStore` ≈ 70・`AudioFileStore+Live` ≈ 20・Preview ≈ 40（`Episode` は I-T2a へ移った）。
- test ≈ 1,100 行: Session（T-T1 系）≈ 350・Coordinator（T-T4〜T7。TA-V6 を含む）≈ 470・Reporter ≈ 150・Library ≈ 60・`PlaybackRules` ≈ 30・double の変更 ≈ 40。
- 合計 ≈ 2,000 行だが分割しない。production は 1,000 行未満で、巻き戻しは追加ファイルの削除と double の差分だけ（既存の production は不変）。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs へ返すもの: 共有仕様 §4.3 の RS-01〜RS-07 と §4.4 の PS-09〜PS-13 の iOS の保留（解除条件 = 本 slice の完了）を解除できる。TP8（`PlaybackSession` が遷移の決定を持つ。削除は I-T11）を導入したこと。`design/ios-design.md` §11.3 の I-S3b1 行の完了。
- 実装中に本 order の表と食い違う事実（とくに実 adapter の事象の順序）が見つかったら、実装を合わせずに止めて報告する。
