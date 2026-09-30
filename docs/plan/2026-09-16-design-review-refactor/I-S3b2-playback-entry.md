## iOS リファクタ I-S3b2: 入口の差し替え（facade 化・`startEpisode` 1 経路・変わる挙動の確定）

## 概要
I-S3b1 で新設した `Podcast/Playback/` を production の入口につなぐ。合成 root が `OfflineLibrary`・`PositionReporter`・`PlaybackCoordinator` を生成し（`AVPlayerEngine`・`MediaPlayerNowPlaying` は I-S3a で生成済み）、`PodcastViewModel` を Coordinator の薄い facade にする（3 段分割の ②。**決定境界は「入口の差し替え」1 つ**）。**共有仕様 §2・Q-01〜Q-32 の挙動は変えない**（特性テストで判定）。**変わる挙動は下の「変わる挙動」の表だけ**（準拠テストで判定）。旧公開プロパティは TP3 として computed で残し、旧実装の物理削除は I-S3b3。

正本は Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（冒頭の追記と §2 composition root・§3.1・§4・§6 S3b 行）と、I-S3b1 の order が固定した宣言（型・操作・手順）。検証モード（再設計しない）。新しい契約 ID を作らない。

2026-09-30 の前提点検（親 docs `research-reports/2026-09-30-wave3-order-premise-check/ios.md`）を受けて書き直した。I-S3b1 の書き直しで決まった形（公開 19 操作・通知 `notice`・`PlaybackState` の形・保存庫の操作）に合わせ、現行との差を「変わる挙動」に数え上げ直している。

## 前提・着手条件
- 依存: **I-S3b1 の ios PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（親で `git submodule status` の `ios` 行に `+` が無い）。I-S3b1 の契約テストが green。
- コマンドの実行場所: 検査コマンドはすべて **`ios/`（submodule のルート）** で実行する。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator.swift`（rc=0）で、場所と I-S3b1 の成果の両方を確かめる。
- 確定済み（再提案しない。親 docs 監査レポート §5）: SG-X1・SG-X4・SG-X3・SG-C16（位置の送信）、SG-C4（署名付き URL の取り直しと保持 URL へのフォールバック）、SG-C23（TP5 の削除）、SG-C27（ロック画面 port は App が 1 個作る）、SG-C39・C43（buffering 中の一時停止・総時間）、SG-C50（`setQueue` の重複 id）、SG-C59（リモートコマンドの登録と解除は Coordinator。I-S3b1 で実装済み）、SG-C60（公開 19 操作）、SG-C62（手動で開始前に再生不可なら通知だけ）。
- `docs/trial-log/player-auto-converge.md`・`docs/trial-log/transcript-sync-highlight.md` を読む。トランスクリプト自動追従のリセット（`.task(id:)` / `.onDisappear`）と `RequestRecordingSession` の直列化は既存どおり。AVPlayer を 2 系統持つ案は棄却済み（`mino-design-review-delegation.md`）。App が作った `AVPlayerEngine` の 1 個を Coordinator（の Session）が使い、VM 側の engine 消費を消す。

## 対象（ios サブモジュールのみ。production の変更はこの 9 ファイルだけ。準拠テストの新規ファイルは可）
1. **`NewsListenAppApp.swift`**（合成 root）
   - App が `OfflineLibrary` を 1 個作る（`audioEngine`・`nowPlayingCenter` と同じ `private static let`。`OfflineLibrary(cacheManager: AudioCacheManager())`。`OfflineLibrary.init` は `nonisolated`）。
   - `AppState` の生成に `clearOfflineLibrary: { try NewsListenAppApp.offlineLibrary.clearAll() }` を渡す（既存の `NewsListenAppApp.nowPlayingCenter` と同じく、`Self` ではなく型名で書く）（現行は `AppState.swift:537` の既定引数が別の `AudioCacheManager()` を作るので、主体離脱の全削除が保存庫を通らず `savedIds` が古いまま残る）。
   - `ContentView` は facade を `@StateObject` で 1 個だけ持つ。Coordinator・Reporter・facade の組み立ては、`StateObject(wrappedValue:)` の中から呼ぶ 1 つの関数にまとめる（`ContentView.init` は再描画のたびに走るので、init の本体で Coordinator を作らない）。`ContentView` の `appState` は `@EnvironmentObject` で `init` の中では読めないので、`appState` に依る依存（`defaultSpeed`・既存の `refreshListeningStreak:`）は、`NewsListenAppApp` の `ContentView(…)` の呼出側で closure にして渡す。`GrepOracleTests` の O-8（`testTT14_24`）は `appState.refreshListeningStreak(` の出現を 5 件、`registerPlaybackLifecycle(` を 1 件に固定しているので、この 2 つの出現数を変えない（完聴後の更新は既存の `refreshListeningStreak:` の引数をそのまま Reporter の `onCompletionRecorded` へ通す）。渡す依存: `engine` = `Self.audioEngine`、`nowPlayingCenter` = `Self.nowPlayingCenter`、`library` = `Self.offlineLibrary`、`fetchPodcast` / `updatePosition` / `markCompleted` = `apiClient` の同名の呼出、`isOnline` = `networkMonitor.isOnline`、`defaultSpeed` = `Float(appState.defaultPlaybackSpeed)`、`onCompletionRecorded` = `appState.refreshListeningStreak`、`onPositionSaved` = facade の一覧更新（facade は後から作るので、弱参照の箱を介す）、`beginBackgroundTask` = `UIApplication.shared.beginBackgroundTask` / `endBackgroundTask` を包んだ closure（`UIApplication` を書くのはこのファイルだけ）。
   - `:185` の `appState.registerPlaybackLifecycle(playerViewModel)` を `appState.registerPlaybackLifecycle(playerViewModel.playbackLifecycle)` へ（実体は Coordinator。TP4 の削除条件が成立）。
   - `:193` の `playerViewModel.flushPlaybackPosition()` を `playerViewModel.positionReporter.flush()` へ。
   - `:208` は forwarder `playById(id)` を呼び続ける（呼出の付け替えは I-S3b3）。
   - `:163` の `SettingsView(appState: appState)` に `library: Self.offlineLibrary` を足す。
2. **`Podcast/PodcastViewModel.swift`**（facade 化）
   - `init` は `apiClient`・`coordinator`・`positionReporter`・`library`・`networkMonitor` を受ける。`engine:`・`nowPlaying:`・`cacheManager:`・`refreshListeningStreak:` の引数と、engine の事象の購読・ロック画面の更新・リモートコマンド・位置同期の Timer・`UIApplication` の利用を消す。`import UIKit` を外す。
   - **TP5 の削除**（SG-C23）: 旗 `isAudioLoaded` を消す。判定は Coordinator の `session` に置き換わっている。
   - **合成 root 用の 2 つの読み取り専用プロパティ**: `let playbackLifecycle: any PlaybackLifecycle`（Coordinator）と `let positionReporter: PositionReporter`。View はこれ以外の形で Coordinator に触らない。
   - **状態の写し**（`isAdvancing` は写さず、`isFinished` の中で Coordinator の値を読む）: `@Published private(set) var session: PlaybackState`・`presentation: PlayerPresentation`・`notice: PlaybackNotice?` を、Coordinator の同名の `@Published` から `assign(to:)` で写す（facade は値を書かない）。Coordinator の `objectWillChange` を facade の `objectWillChange` へつなぐ（`nowPlaying()`・`upNext()` は関数なので、キューの変化で View が再描画される経路が要る）。`library.savedIds` の変化も同じくつなぐ。
   - **Coordinator の 19 操作の中継**: `startEpisode(_:expandsPlayer:)`・`startEpisode(id:)`・`replayCurrent`・`retry`・`togglePlayPause`・`seek`・`setSpeed`・`addToQueue`・`playNext`・`removeFromQueue`・`moveUpNext`・`skipToNext`・`nowPlaying()`・`upNext()`・`presentation`・`dismissError`・`stopForLogout`・`minimizePlayer`・`expandPlayer`。facade は中継するだけで、判断を足さない。例外は次の 2 つ。
     - `dismissError()` は、自分の `listErrorMessage = nil` と Coordinator の `dismissError()` の両方を行う。
     - `startEpisode(id:)` の中継は、投げられた `ApiFailure` を `listErrorMessage = FailureMessages.message(for:context: .podcast)` に書く（現行 `playById` と同じ文言）。
   - **TP3（旧公開プロパティ。computed で残す）**: owner: user／導入: I-S3b2／削除条件: I-S3b3 で View が `nowPlaying()`・`session` を直接読むようになった時。

     | 旧名 | 導き方 |
     |---|---|
     | `isPlaying` | `session` が `loading / playing / buffering` |
     | `isBuffering` | `session` が `buffering` |
     | `currentTime` | `session.position` |
     | `duration` | `session.duration` |
     | `playbackSpeed` | `session.speed`。無ければ既定速度 |
     | `currentPodcast` | `nowPlaying()` が `nil` でなければ Coordinator の `queue.current`、`nil` なら `nil` |
     | `queue` | Coordinator の `queue` |
     | `errorMessage` | `notice` があればその文言、無ければ `listErrorMessage` |
     | `didFinishCurrentEpisode` | `isFinished`（下） |
     | `downloadedIds` | `library.savedIds` |
   - **`isFinished: Bool`**（computed。I-S3b3 の後も残す読み取り専用の派生値。I-18）: `session.isEnded` かつ Coordinator の `isAdvancing` が false。オンラインで未キャッシュの次へ自動で進む途中（取り直しの待ち）に「聴き終わりました」が一瞬出るのを防ぐ。聴き終えた後に待機列へ足しても、表示は「聴き終わりました」のまま（現行と同じ）。
   - **文言**: `@Published private(set) var listErrorMessage: String?` は、facade に残る操作（一覧読込 `:142,148,150`・`download` `:200,210,213`・`removeDownload` `:224`。2026-09-30 実測）の失敗だけを持つ。再生由来の書込（`:267,271,290` play・`:344,346` playById・`:365` engine failed）は消える。理由 → 文言は `static func playbackErrorMessage(for reason: PlaybackErrorReason) -> String`（`offlineUncached` = "Offline and not cached"、`invalidSource` = "Invalid audio URL"、`engineFailed(d)` = `d ?? "Playback failed"`、`fetchFailed(f)` = `FailureMessages.message(for: f, context: .podcast)`。現行と同じ文言）。`notice` の文言は `.failure(理由)` がこの関数、`.loadWarning(説明文)` は説明文そのまま（SG-C42）。`shouldPresentErrorAlert`・`displayState` は合成後の `errorMessage` で判定し、alert は 1 つのまま。
   - **開始で一覧のエラーを消す**: `session` が `loading` になったら `listErrorMessage = nil`（現行の「再生開始で前回の失敗を消す」。issue #58）。
   - **forwarder（名前を残す。削除は I-S3b3）**: `playNow(p)` → `startEpisode(p)`、`playById(id)` → `startEpisode(id:)`、`replayCurrentEpisode()` → `replayCurrent()`、`stopPlayback()` → 使われなくなる（中身は空でよい）、`flushPlaybackPosition()` → `positionReporter.flush()`、`handlePlaybackEnded(endedId:)` → Coordinator の `onEnded(endedId:)`、`previewMarkFinished()` → 空、`resolvePlaybackURL` → そのまま、`syncDownloadedState()` → `library.refresh(candidateIds: podcasts.map(\.id))`。
   - **facade に残る操作**: `loadPodcasts`（始めに、自分の `listErrorMessage` と Coordinator の `notice` の両方を消す = `dismissError()` と同じ。現行の `errorMessage = nil` は再生の失敗の表示も消している。終わりに `library.refresh(candidateIds:)`）・`download`・`removeDownload`・`downloadState(for:)`・`isPlayableWhileOffline`・`submitQuizAnswers`・`fetchSavedVocabulary`・`saveVocabulary`。`download` は現行の流れ（`fetchPodcast` → URL の検査 → `downloadAudio`）のまま、保存だけを `library.save(data, for: id)` に替える。`removeDownload` は `library.remove(id)`。`downloadingIds` は facade が持ち続ける。
   - **位置の応答の反映**: `onPositionSaved` で受けた `Podcast` で、`podcasts` の同じ id の要素を置き換える。
3. **`Podcast/PlaybackQueue.swift`**: `init` と `setQueue` に、id の重複を先勝ちで除く内部の gate を入れる（CI-T9。公開操作の名前と型は変えない）。`setQueue` の開始位置は、元の入力で clamp して id を決め、重複を除いた後のその id の位置を現在にする（SG-C50・共有仕様 Q-33）。
4. **`Podcast/PodcastRowView.swift:119-133`**: status の文字列分岐を `Episode.decode(podcast)` の種別の switch に替える。`playable` はバッジなし、`generating` は「生成中」、`failed` は「失敗」（PS-07）。「失敗」バッジの `accessibilityValue` は、現行どおり DTO の `podcast.errorMessage ?? ""` を使う（`FailedEpisode.errorMessage` の `"inconsistent"` を読み上げさせない）。
5. **`Podcast/PodcastView.swift`**: `:45` と `:135` の `errorMessage = nil` を `dismissError()` へ。`:90` の比較を `nowPlaying()?.episodeId == podcast.id` へ。
6. **`Podcast/QueueSheet.swift:22`**: `currentPodcast != nil` と `queue.current` の合成を `nowPlaying()` へ。
7. **`DesignSystem/PreviewSupport.swift:151-168`**: `vm.currentPodcast = …` などの直書き 7 箇所（`:153-157`・`:165-166`）を、`PlaybackCoordinator.previewParts(session:queue:)`（I-S3b1）が返す Coordinator・Reporter・保存庫を facade の `init` に渡す形へ替える（`PreviewSupport` では保存庫も Reporter も作らない）。`playerViewModel()` は `session: .playing(episode: <podcasts[0] を decode した PlayableEpisode>, position: 72, duration: 247, speed: 1.0)`、`finishedPlayerViewModel()` は `session: .ended(episode: 同じ, duration: 247)`。どちらも `queue` は `PlaybackQueue(items: [podcasts[0]], currentIndex: 0)`。
8. **`Settings/SettingsViewModel.swift`**: `cacheManager: AudioCacheManager` を `library: OfflineLibrary` に替える（`usage()`・`clearAll()`）。**TP2 は型を変えて残す**: 2 つの `init`（`:73,80`）の既定引数を `library: OfflineLibrary = OfflineLibrary(cacheManager: AudioCacheManager())` にする。既定引数の物理削除は I-S3b3。
9. **`Settings/SettingsView.swift`**: `init(appState:)` に `library: OfflineLibrary` を足し、`:57` の `SettingsViewModel(appState:)` に渡す（起票時はこのファイルが対象に無く、App の保存庫を設定画面へ渡す経路が無かった）。

**`Podcast/Playback/` と `Podcast/Platform/` は変えない**。Coordinator 側の不足が見つかったら、実装を止めて報告する。

テスト: `NewsListenAppTests/PodcastViewModelTests.swift`（72）と `PodcastViewModelPortTests.swift`（13）は facade 経由で全件 green にする。**helper（`makeViewModel` など）と Given の組み立ては facade の構成（Coordinator・double の注入）に合わせて変えてよい。Then（期待値）を変えてよいのは、下の「変わる挙動」に当たるテストだけ**。`SettingsViewModelTests`（36）は `OfflineLibrary` を渡す Given の書き換えだけ（Then 不変）。`testTT15_09`・`testTT15_10`（主体離脱で位置を送らない・engine が読み込みを外す）は Then 不変で green。

`GrepOracleTests` の `testG08_mediaPlayerNowPlayingIsCreatedOnlyAtTheDocumentedPlaces` だけは期待値を改める: `MediaPlayerNowPlaying(` の生成箇所は、facade 化で `PodcastViewModel` の既定引数が消えるので、`NewsListenAppApp.swift` 1・`AppState.swift` 1 の 2 箇所になる（SG-C29 の 3 箇所から 1 つ減る）。ほかの 9 件は無変更で green。

## 変わる挙動（これ以外の挙動変更は禁止）
| 行 ID | 変わる挙動 | 現行 | 判定テスト |
|---|---|---|---|
| PS-01 / PS-02 / PS-03 | 自動で次へ進んだ先が再生できないと、そこで止まる。失敗したエピソードが現在のまま残り、再生ボタンが再試行になる。オフラインで未キャッシュなら取得を試みない | 未定義（`play` が失敗しても前の表示のまま） | 準拠テスト（facade ＋ double。CI-T6）。**iOS の PS-01 の読み方**: 取り直しが失敗したら保持している URL で始める（SG-C4）ので、「取得が失敗」は「取り直しが失敗し、保持 URL の読み込みも engine が失敗した」場合で、理由は `engineFailed` |
| PS-04 | 通知からの再生（`playById`）と「もう一度聴く」も同じ 1 経路を通り、キューに載る | 通知経路はキューに載らない | 準拠テスト（CI-T7）＋ T-T7b の grep |
| PS-05 | `errored`・`idle` では位置を送らない | engine の失敗後も 15 秒ごとに送り続ける | 準拠テスト（CI-T8） |
| PS-05b | **一時停止中は 15 秒ごとの送信をしない**。代わりに、一時停止した時点で 1 回送る | 一時停止中も 15 秒ごとに送る（Timer に再生中かの判定が無い）。一時停止の時点では送らない | 準拠テスト（CI-T8） |
| PS-06 | 完聴 → 総時間の位置書込 1 回 → 次へ（SG-X1・SG-C61）。完聴は 1 回の再生につき 1 回 | 位置は停止時の値に任せる | 準拠テスト（CI-T8）。既存 `testPlaybackEndedMarksCapturedPodcastBeforeAutoAdvanceAndRefreshesStreak`・`testCompletionFailureDoesNotBlockQueueAutoAdvance` を行 ID 付きへ昇格 |
| PS-07 | 再生できるのは「`completed` かつ音声 URL あり かつ `error_message` なし」だけ。それ以外の行をタップすると、何も変えずに "Invalid audio URL" を出す。未知の status の行と、`completed` なのに `error_message` がある・音声 URL が空の行に「失敗」バッジが付く | どの行もタップで再生を試みる（`processing` は "Offline and not cached"、`partial_failed` は音声があれば再生される）。未知の status と `completed` の行はバッジなし | 準拠テスト（CI-T11）＋ `PodcastRowView` |
| PS-08 | エピソードの開始ごとに、速度を既定速度に戻す。**その速度が実際に効く** | 前のエピソードで選んだ速度の表示が残るが、新しいエピソードは 1.0 で再生される（`play()` が速度を戻すため。I-1） | 準拠テスト（CI-T4）。既存 `testSetSpeedUpdatesPlaybackSpeed*` は期待値を既定速度の基準に |
| —（CI-T1c。SG-C39） | 読み込み待ち（buffering）の間に engine が止まると、一時停止の表示になる | buffering の表示だけ消えて再生中のまま | 準拠テスト |
| —（CI-T1e。SG-C43） | 開始の直後から総時間が出る。総時間が不明な間に先送りしても 0 へ戻らない。位置は `[0, 総時間]` に丸める | 最初の定期更新まで総時間 0。不明な間の先送りで 0 へ戻る。`seek(to:)` は丸めない | 準拠テスト |
| —（CI-T5。SG-C4） | オンラインで未キャッシュのエピソードは、再生の直前に URL と再開位置を取り直す。開始（プレイヤーの切替を含む）は、その応答の後になる | 一覧を取得した時点の URL と位置でそのまま始める | 準拠テスト（gateway double の呼出と、double の `loadedURL` を観測）。既存 `testResolvePlaybackURL*` 3 件（`PodcastViewModelTests.swift:401,422,439`）は純関数の forwarder が残るので不変 |
| —（CI-T8。G12・§6.4） | 位置を送った応答で、一覧の再開位置を更新する。同じ再生の中で、送った値より小さい位置（巻き戻し）は送らない | 応答を捨てる。巻き戻した位置も送る | 準拠テスト |
| —（CI-P17） | 現在のエピソードをキューから外すと、再生が止まる（次の要素が現在になるが、自動では始まらない） | 止まらない（画面からは待機列しか外せないので、画面操作では起きない） | 準拠テスト |
| —（I-12） | 再生に失敗した後は、ロック画面の再生情報が消える | 残る | 準拠テスト |
| CI-T9 / T9b | `init`・`setQueue` の重複 id を除く。重複の無い入力の Q-* は不変 | 除かない | T-T9（property）・T-T9b（期待値表）・Q-33 ＋ conformance 32 件不変 |

上の表以外で既存テストの Then を変える必要が出たら、実装を止めて報告する（scope 逸脱）。次は **変わらない** ことを既存テストで確かめる。
- 手動で選んだエピソードがオフラインで未キャッシュなら、再生中のものは続き、"Offline and not cached" だけが出る（SG-C62。`testReplayWhileOfflineNotCachedKeepsFinishedStateAndSetsError` を含む）。
- `testReplayCurrentEpisode*` 3 件（先頭から始まる。表示形態は変わらない）。
- 表示形態の遷移（`testPresentationIsHiddenUntilFirstPlay`・`testMinimizeThenExpandRoundTrip`・`testQueueEndKeepsMiniPresentationForFinishedState`・`testAutoAdvanceKeepsCurrentPresentation`）。
- 再生開始で前回のエラーが消える（`testPlaySuccessClearsStaleErrorMessage`）。
- 主体離脱（`testTT15_09`・`testTT15_10`）。

## 完了条件
- 既存テスト全件 green。`PlaybackQueueConformanceTests`（32）・`PlaybackQueueTests`（12）・`NowPlayingInfoTests`（13）・`TranscriptTimingTests`（13）・`AudioCacheManagerTests`（13）・`AVPlayerEngineTests`（6）・`AVPlayerEngineLifecycleTests`（7）・`MediaPlayerNowPlayingTests`（3）・`AudioEngineDoubleTests`（7）と、I-S3b1 の契約テストは無変更で green。
- 準拠テストが green で、テスト名に **PS-01〜PS-08（05b を含む）** の行 ID と `verifies: CI-T4/T5/T6/T7/T8/T9/T9b/T11` を持つ。
- 変更した production が対象の 9 本だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 9 行。`git diff --name-only origin/main -- NewsListenApp/NewsListenApp/Podcast/Playback NewsListenApp/NewsListenApp/Podcast/Platform` が 0 行。
- T-T7b: `grep -rn "currentPodcast\s*=[^=]" NewsListenApp/NewsListenApp --include='*.swift'` が 0 件（`==` の比較は一致しない。2026-09-30 実測: 現行の一致は `DesignSystem/PreviewSupport.swift:153,165` と `Podcast/PodcastViewModel.swift:280,693` の 4 件）。T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include='*.swift'` が `Networking/` 以外で 0 件。
- 依存方向: I-S3b1 の完了条件 4 の grep が 0 件のまま。`grep -n "^import \(AVFoundation\|MediaPlayer\|UIKit\)" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` が 0 件。`GrepOracleTests`（10。G08 の期待値だけ上のとおり改める）が green。
- TP5 が消えている: `grep -rnw "TP5\|isAudioLoaded" NewsListenApp/NewsListenApp --include='*.swift'` が 0 件（2026-09-30 実測: `PodcastViewModel.swift` に `TP5` 1 行・`isAudioLoaded` 12 行）。
- 主体離脱の登録先: `grep -n "registerPlaybackLifecycle" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` の引数が `playerViewModel.playbackLifecycle`。
- 保存庫が 1 個: `grep -rn "AudioCacheManager()" NewsListenApp/NewsListenApp --include='*.swift' | grep -v ":[0-9]*:[[:space:]]*//"` が 5 行（`NewsListenAppApp.swift` の生成 1 行、`Settings/SettingsViewModel.swift` の既定引数 2 行 = TP2、`AppState.swift` の `clearOfflineLibrary` の既定引数 1 行 = Preview とテスト用、`Podcast/Playback/PlaybackCoordinator+Preview.swift` の 1 行 = I-S3b1 の Preview 用）。`Podcast/PodcastViewModel.swift` には無い。`grep -n "clearOfflineLibrary" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` が 1 行。
- TP3 の owner・導入・削除条件が、コード上のコメントか PR 説明にある。
- シミュレータの目視（UV3）を PR 説明に記す: (1) logout の後、ロック画面に前の主体の再生情報が残らない。(2) 自動で進んだ先が再生できないとき、止まった表示になる。(3) 一覧を 1 時間放置した後に再生できる。(4) **既定速度を 1.5 にして再生を始めると、実際に 1.5 倍で進む**（I-1 の確認。実機かシミュレータでしか確かめられない）。(5) 再生を始めてすぐに一時停止・再開ができる（事象の届く順序の確認）。(6) 画面をロックしたまま、オンラインで未キャッシュの次のエピソードへ自動で進む（I-16）。

## 禁止事項 / scope 外
- `AudioPlayerView`・`MiniPlayerView`・`QueueSheet`（`:22` 以外）・`PodcastView`（`:45,90,135` 以外）の読み替え（TP3 の削除）はしない。forwarder・TP2・TP4 のコード・`didFinishCurrentEpisode`・`downloadedIds` の物理削除はしない（I-S3b3）。
- `Podcast/Playback/`・`Podcast/Platform/` を変えない。
- 「変わる挙動」以外を変えない（Q-*・再開位置の規則・古い終了通知の無視・トランスクリプト同期・表示形態の遷移）。`reorderUpNext` を rename しない。RO1〜RO7・SG-A7 を作らない。
- `skipToNext` を画面やロック画面につながない（I-S3c）。

## 特性テスト（baseline。着手前に green を記録する）
I-S3b1 完了時点の全件。とくに `PodcastViewModelTests`（72）・`PodcastViewModelPortTests`（13）・`SettingsViewModelTests`（36）・`AppStateAuthTests`・`PlaybackQueueConformanceTests`（32）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test …`（README のコマンド）→ 全 green。
- 完了条件のコマンドを `ios/` で実行し、結果を PR 説明に貼る。commit は「Queue の重複除去」「Episode の切替（PS-07）」「facade への切替と TP3」「View 2 箇所・Preview・Settings への注入」「合成 root」「準拠テスト」の単位。

## 規模（見込み。2026-09-30 実測の基点: `PodcastViewModel.swift` 698・`NewsListenAppApp.swift` 255・`PlaybackQueue.swift` 143・`PodcastRowView.swift` 160・`PodcastView.swift` 151・`QueueSheet.swift` 82・`PreviewSupport.swift` 196・`SettingsViewModel.swift` 298、`PodcastViewModelTests.swift` 1,319・`SettingsViewModelTests.swift` 547）
- production ≈ 700 行（削除と追加の合計）: `PodcastViewModel.swift` は 698 行から facade ≈ 300 行へ（削除 ≈ 450・追加 ≈ 100）。`NewsListenAppApp.swift` ≈ 60・`PlaybackQueue.swift` ≈ 15・`PodcastRowView.swift` ≈ 25・`PodcastView.swift` 3・`QueueSheet.swift` 1・`PreviewSupport.swift` ≈ 20・`SettingsViewModel.swift` ≈ 10・`SettingsView.swift` ≈ 5。
- test ≈ 600 行: `PodcastViewModelTests.swift` の helper と Given ≈ 170、変わる挙動の Then ≈ 60、準拠テスト（新規ファイル）≈ 330、`SettingsViewModelTests.swift` の Given ≈ 40。
- 合計 ≈ 1,300 行だが分割しない。分割の基準 1,000 行は巻き戻しの範囲 = production に当てる。決定境界は「入口の差し替え」1 つで、これ以上分けると facade と旧 VM が併存する（AVPlayer 2 系統。棄却済み）。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記する。
- 親 docs へ返すもの: 共有仕様 §4.4 の PS-01〜PS-08 の iOS の保留（解除条件 = 本 slice の完了）を解除できる。`design/ios-design.md` §8（AVPlayer 設計）を Platform adapter の現状の記述へ、§11.3 の I-S3b2 行を完了へ。
