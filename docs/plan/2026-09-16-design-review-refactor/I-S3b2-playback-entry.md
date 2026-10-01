## iOS リファクタ I-S3b2: 入口の差し替え（facade 化・`startEpisode` 1 経路・変わる挙動の確定）

## 2026-10-01 目標アーキテクチャ（ADR-110・Spec §8.3）による補正
正本: 親 docs `adr/110-refactor-target-domain-centered-onion-cqrs.md`、iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`（以下「TA Spec」）§8.3 の I-S3b2 の表（補正 1〜12）。決定境界（入口の差し替え 1 つ）と、共有仕様 §2・Q-* の挙動不変は変えていない。
- 補正 1: 前提に I-T3 を足した。`download`・`removeDownload`・`downloadState(for:)` は `OfflineDownloads` の中継にし、手順と `downloadingIds` を facade に書かない。旧 `DownloadState` enum を消し `typealias DownloadState = OfflineDownloads.State` を足す（I-T3 の完了条件 5）。
- 補正 2: 合成 root が gateway の closure を `toEpisode()` の変換つきで配線する（`Networking/Gateways/PlaybackGateway+Live.swift` を対象に足した）。`lockScreenSubtitle`・`AudioFileStore`・`OfflineDownloads` も合成 root で作る。
- 補正 3: facade の `positionReporter` を外へ出さない。`NewsListenAppApp.swift:193` は facade の command `flushPosition()` を呼ぶ。`playbackLifecycle` の公開は残す（導出 I-30）。
- 補正 4: TP3 の `currentPodcast` と `queue` は、Coordinator の `Episode` から表示用の `Podcast` を組み立てて返す（移行用の変換を `Models/Podcast+Episode.swift` に足す。削除は I-S3b3）。forwarder の `playNow(p)` は `startEpisode(p.toEpisode())`。
- 補正 5: 一覧は通信のデータモデルのまま（TP6）。位置の応答の反映は、合成 root の gateway の closure が応答の `Podcast` で facade の一覧を置き換える形にした。
- 補正 6: 対象 4（行のバッジ）を、facade がバッジの種類を導き、行 View は種類を引数で受ける形にした（View が `Episode` を判別しない）。
- 補正 7: facade の `podcasts`・`isLoading`・`listErrorMessage` を `private(set)` にした。
- 補正 8: 「変わる挙動」に背景遷移の 2 行を足した。
- 補正 9: 「変わる挙動」の CI-T1e の行に、画面の ±秒ボタンへ届くのは I-S3b3 からと注記した。
- 補正 10: 準拠テストの名前に PS-07b を足した。
- 補正 11: `PlaybackQueue` の重複の除去の path を `Podcast/Playback/Domain/PlaybackQueue.swift` にし、「`Podcast/Playback/` を変えない」の例外と書いた。
- 補正 12: 完了条件の `AudioCacheManager()` の行数と G08 の期待値を数え直した。`PreviewSupport` のキューは `PlaybackQueue<Episode>`。
- 着手前の前提点検の節を足した。

## 概要
I-S3b1 で新設した `Podcast/Playback/` を production の入口につなぐ。合成 root が `OfflineLibrary`・`PositionReporter`・`PlaybackCoordinator` を生成し（`AVPlayerEngine`・`MediaPlayerNowPlaying` は I-S3a で生成済み）、`PodcastViewModel` を Coordinator の薄い facade にする（3 段分割の ②。**決定境界は「入口の差し替え」1 つ**）。**共有仕様 §2・Q-01〜Q-32 の挙動は変えない**（特性テストで判定）。**変わる挙動は下の「変わる挙動」の表だけ**（準拠テストで判定）。旧公開プロパティは TP3 として computed で残し、旧実装の物理削除は I-S3b3。

正本は Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（冒頭の追記と §2 composition root・§3.1・§4・§6 S3b 行）と、I-S3b1 の order が固定した宣言（型・操作・手順）。検証モード（再設計しない）。新しい契約 ID を作らない。

2026-09-30 の前提点検（親 docs `research-reports/2026-09-30-wave3-order-premise-check/ios.md`）を受けて書き直した。I-S3b1 の書き直しで決まった形（公開 19 操作・通知 `notice`・`PlaybackState` の形・保存庫の操作）と、2026-10-01 の補正で決まった型（`Episode`・`QueueEntry`・`NowPlayingSnapshot`・`AudioFileStore`・`OfflineDownloads`。TA Spec §5.1）に合わせ、現行との差を「変わる挙動」に数え上げ直している。

## 前提・着手条件
- 依存: **I-S3b1 と I-T3 の ios PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（親で `git submodule status` の `ios` 行に `+` が無い）。I-S3b1・I-T3 の契約テストが green。
- コマンドの実行場所: 検査コマンドはすべて **`ios/`（submodule のルート）** で実行する。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator.swift`（rc=0）と `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift`（rc=0）で、場所と I-S3b1・I-T3 の成果を確かめる。
- 確定済み（再提案しない。親 docs 監査レポート §5）: SG-X1・SG-X4・SG-X3・SG-C16（位置の送信）、SG-C4（署名付き URL の取り直しと保持 URL へのフォールバック）、SG-C23（TP5 の削除）、SG-C27（ロック画面 port は App が 1 個作る）、SG-C39・C43（buffering 中の一時停止・総時間）、SG-C50（`setQueue` の重複 id）、SG-C59（リモートコマンドの登録と解除は Coordinator。I-S3b1 で実装済み）、SG-C60（公開 19 操作）、SG-C62（手動で開始前に再生不可なら通知だけ）。
- `docs/trial-log/player-auto-converge.md`・`docs/trial-log/transcript-sync-highlight.md` を読む。トランスクリプト自動追従のリセット（`.task(id:)` / `.onDisappear`）と `RequestRecordingSession` の直列化は既存どおり。AVPlayer を 2 系統持つ案は棄却済み（`mino-design-review-delegation.md`）。App が作った `AVPlayerEngine` の 1 個を Coordinator（の Session）が使い、VM 側の engine 消費を消す。

## 着手前の前提点検（投入の直前に数え直す。値が違えば order を直してから投入する）
2026-10-01 の値は revision `ef9e559`（I-S3b1・I-T3 の前）。行番号は I-T2a・I-T2b の後に動いているので数え直す。

| 項目 | 2026-10-01 の実測 | コマンド（`ios/` で） |
|---|---|---|
| 合成 root の入口 | `NewsListenAppApp.swift`（255 行）: `:185` `registerPlaybackLifecycle`、`:193` `flushPlaybackPosition()`、`:208` `playById`、`:163` `SettingsView(appState:)` | `grep -n 'registerPlaybackLifecycle\|flushPlaybackPosition\|playById\|SettingsView(' NewsListenApp/NewsListenApp/NewsListenAppApp.swift` |
| facade の旧い手順 | `Podcast/PodcastViewModel.swift`（698 行）: `download` `:190-217`、`removeDownload` `:221-228`、`downloadState(for:)` `:162`、`DownloadState` `:14-22`、`updateNowPlayingInfo` `:616-628`、位置同期 `:643-680` | `grep -n 'func download\|func removeDownload\|func downloadState\|enum DownloadState\|syncTimer' NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` |
| `Podcast` の memberwise init が `private(set) var` の 4 つ（`vocabulary`・`quiz`・`sourceArticles`・`sourceKind`）を引数に取れるか（TA Spec §11 の U4） | 取れる。`NewsListenAppTests/ModelTests.swift:858-866` が `Podcast(…, segments: nil, sourceKind: "featured")` で生成している（custom `init(from:)` は extension なので memberwise init が残る。`Models/Podcast.swift:115-121`） | `sed -n 855,870p NewsListenApp/NewsListenAppTests/ModelTests.swift` |
| `PodcastRowView` のバッジ | `:119-133`（`status` の文字列分岐。`accessibilityValue` は `podcast.errorMessage ?? ""` `:127`） | `sed -n 115,135p NewsListenApp/NewsListenApp/Podcast/PodcastRowView.swift` |
| `AudioCacheManager()` の生成 | 2026-10-01: `AppState.swift:537`・`Settings/SettingsViewModel.swift:73,80`・`Podcast/PodcastViewModel.swift:115` の 4 行。I-S3b1 の後は `Podcast/Playback/` に 0 行 | `grep -rn 'AudioCacheManager()' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v ':[0-9]*:[[:space:]]*//'` |
| G08 | `MediaPlayerNowPlaying(` が `NewsListenAppApp.swift` 1・`AppState.swift` 1・`Podcast/PodcastViewModel.swift` 1 | `GrepOracleTests.swift` の `testG08` |
| 既存テストの件数 | `PodcastViewModelTests` 72・`PodcastViewModelPortTests` 13・`SettingsViewModelTests` 36・`PlaybackQueueConformanceTests` 32 | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ。production の変更はこの 12 ファイルだけ。準拠テストの新規ファイルは可）
1. **`NewsListenAppApp.swift`**（合成 root）
   - App が `OfflineLibrary` を 1 個作る（`audioEngine`・`nowPlayingCenter` と同じ `private static let`。`OfflineLibrary(store: .live(cacheManager: AudioCacheManager()))`。`OfflineLibrary.init` は `nonisolated`。`AudioCacheManager()` を書くのはこの 1 箇所）。
   - `AppState` の生成に `clearOfflineLibrary: { try NewsListenAppApp.offlineLibrary.clearAll() }` を渡す（既存の `NewsListenAppApp.nowPlayingCenter` と同じく、`Self` ではなく型名で書く）（現行は `AppState.swift:537` の既定引数が別の `AudioCacheManager()` を作るので、主体離脱の全削除が保存庫を通らず `savedIds` が古いまま残る）。
   - `ContentView` は facade を `@StateObject` で 1 個だけ持つ。Coordinator・Reporter・facade の組み立ては、`StateObject(wrappedValue:)` の中から呼ぶ 1 つの関数にまとめる（`ContentView.init` は再描画のたびに走るので、init の本体で Coordinator を作らない）。`ContentView` の `appState` は `@EnvironmentObject` で `init` の中では読めないので、`appState` に依る依存（`defaultSpeed`・既存の `refreshListeningStreak:`）は、`NewsListenAppApp` の `ContentView(…)` の呼出側で closure にして渡す。`GrepOracleTests` の O-8（`testTT14_24`）は `appState.refreshListeningStreak(` の出現を 5 件、`registerPlaybackLifecycle(` を 1 件に固定しているので、この 2 つの出現数を変えない（完聴後の更新は既存の `refreshListeningStreak:` の引数をそのまま Reporter の `onCompletionRecorded` へ通す）。渡す依存: `engine` = `Self.audioEngine`、`nowPlayingCenter` = `Self.nowPlayingCenter`、`library` = `Self.offlineLibrary`、`fetchEpisode` / `updatePosition` / `markCompleted` / `downloadAudio` = `PlaybackGateway.live(apiClient:)` が返す closure（`Networking/Gateways/PlaybackGateway+Live.swift`。対象 10。`APIClient` の同名の呼出の応答を `toEpisode()` で `Episode` にする。TA Spec §5 冒頭の共通の決まり・I-36）、`isOnline` = `networkMonitor.isOnline`、`defaultSpeed` = `Float(appState.defaultPlaybackSpeed)`、`lockScreenSubtitle` = `DifficultyLabel.text(for:)`、`onCompletionRecorded` = `appState.refreshListeningStreak`、`onPositionSaved` = 何もしない closure（一覧の反映は下の `updatePosition` の closure が行う。`Episode` からは `Podcast` に戻せないため。TP6）、`updatePosition` の closure は「`apiClient.updatePlaybackPosition` → 応答の `Podcast` で facade の一覧の同じ id の要素を置き換える（facade は後から作るので、弱参照の箱を介す）→ `toEpisode()` を返す」、`downloads` = `OfflineDownloads(library: Self.offlineLibrary, fetchEpisode:, downloadAudio:)`（ログインごとに作り直す。`APIClient` と同じ寿命）、`beginBackgroundTask` = `UIApplication.shared.beginBackgroundTask` / `endBackgroundTask` を包んだ closure（`UIApplication` を書くのはこのファイルだけ）。
   - `:185` の `appState.registerPlaybackLifecycle(playerViewModel)` を `appState.registerPlaybackLifecycle(playerViewModel.playbackLifecycle)` へ（実体は Coordinator。TP4 の削除条件が成立）。
   - `:193` の `playerViewModel.flushPlaybackPosition()` を facade の command `playerViewModel.flushPosition()` へ（中身は `reporter.flush()`。I-30）。
   - `:208` は forwarder `playById(id)` を呼び続ける（呼出の付け替えは I-S3b3）。
   - `:163` の `SettingsView(appState: appState)` に `library: Self.offlineLibrary` を足す。
2. **`Podcast/PodcastViewModel.swift`**（facade 化）
   - `init` は `apiClient`・`coordinator`・`positionReporter`・`library`・`downloads`（`OfflineDownloads`）・`networkMonitor` を受ける（`positionReporter` は `flushPosition()` のためだけに private に持つ）。`engine:`・`nowPlaying:`・`cacheManager:`・`refreshListeningStreak:` の引数と、engine の事象の購読・ロック画面の更新・リモートコマンド・位置同期の Timer・`UIApplication` の利用を消す。`import UIKit` を外す。
   - **TP5 の削除**（SG-C23）: 旗 `isAudioLoaded` を消す。判定は Coordinator の `session` に置き換わっている。
   - **合成 root 用の読み取り専用プロパティ 1 つと command 1 つ**: `let playbackLifecycle: any PlaybackLifecycle`（Coordinator。操作は `stopForLogout()` だけの port）と `func flushPosition()`（`reporter.flush()` の中継）。`PositionReporter` は facade の外へ出さない（参照型の capsule を presentation の外へ渡さない。I-30・`architecture.md` §6）。View はこれ以外の形で Coordinator に触らない。
   - **状態の写し**（`isAdvancing` は写さず、`isFinished` の中で Coordinator の値を読む）: `@Published private(set) var session: PlaybackState`・`presentation: PlayerPresentation`・`notice: PlaybackNotice?` を、Coordinator の同名の `@Published` から `assign(to:)` で写す（facade は値を書かない）。Coordinator の `objectWillChange` を facade の `objectWillChange` へつなぐ（`nowPlaying()`・`upNext()` は関数なので、キューの変化で View が再描画される経路が要る）。`library.savedIds` と `downloads.downloadingIds` の変化も同じくつなぐ。
   - **Coordinator の 19 操作の中継**: `startEpisode(_:expandsPlayer:)`・`startEpisode(id:)`・`replayCurrent`・`retry`・`togglePlayPause`・`seek`・`setSpeed`・`addToQueue`・`playNext`・`removeFromQueue`・`moveUpNext`・`skipToNext`・`nowPlaying()`・`upNext()`・`presentation`・`dismissError`・`stopForLogout`・`minimizePlayer`・`expandPlayer`。facade は中継するだけで、判断を足さない。例外は次の 2 つ。
     - `dismissError()` は、自分の `listErrorMessage = nil` と Coordinator の `dismissError()` の両方を行う。
     - `startEpisode(id:)` の中継は、投げられた `ApiFailure` を `listErrorMessage = FailureMessages.message(for:context: .podcast)` に書く（現行 `playById` と同じ文言）。
     - `startEpisode(_:expandsPlayer:)`・`addToQueue`・`playNext` の中継は、View が渡す `Podcast`（TP6）を `toEpisode()` で `Episode` にして Coordinator へ渡す（facade の中で 1 行。判断は足さない）。
   - **TP3（旧公開プロパティ。computed で残す）**: owner: user／導入: I-S3b2／削除条件: I-S3b3 で View が `nowPlaying()`・`session` を直接読むようになった時。

     | 旧名 | 導き方 |
     |---|---|
     | `isPlaying` | `session` が `loading / playing / buffering` |
     | `isBuffering` | `session` が `buffering` |
     | `currentTime` | `session.position` |
     | `duration` | `session.duration` |
     | `playbackSpeed` | `session.speed`。無ければ既定速度 |
     | `currentPodcast` | `nowPlaying()` が `nil` でなければ Coordinator の `queue.current`（`Episode`）を表示用の `Podcast` に組み立てた値、`nil` なら `nil` |
     | `queue` | Coordinator の `queue`（`PlaybackQueue<Episode>`）の各要素を表示用の `Podcast` に組み立てた `PlaybackQueue<Podcast>`（同じ `currentIndex`） |
     | `errorMessage` | `notice` があればその文言、無ければ `listErrorMessage` |
     | `didFinishCurrentEpisode` | `isFinished`（下） |
     | `downloadedIds` | `library.savedIds` |

     表示用の `Podcast` の組み立ては、移行用の変換 `Episode.toDisplayPodcast()`（`Models/Podcast+Episode.swift` に足す。`Podcast` の memberwise init で、`status` は種別から `completed` / `processing` / `failed`、`errorMessage` は `reportedMessage`、`playbackPositionSeconds` は `serverPosition`（無ければ 0）、`type`・`articleIds` は空の値、`audioUrl` は `PlayableEpisode.audioUrl`（無ければ空）。View の 44 箇所が読む field（`displayTitle` の元の `title`・`japaneseIntroText`、`id`・`segments`・`vocabulary`・`quiz`・`difficulty`・`durationSeconds`・`createdAt`・`sourceArticles`・`sourceKind`）を `content` から写す）。owner: user／導入: I-S3b2／削除: I-S3b3（TP3 と同じ。TA Spec §8.3 の I-S3b3 の補正 8）。
   - **`isFinished: Bool`**（computed。I-S3b3 の後も残す読み取り専用の派生値。I-18）: `session.isEnded` かつ Coordinator の `isAdvancing` が false。オンラインで未キャッシュの次へ自動で進む途中（取り直しの待ち）に「聴き終わりました」が一瞬出るのを防ぐ。聴き終えた後に待機列へ足しても、表示は「聴き終わりました」のまま（現行と同じ）。
   - **公開する状態は全部 `private(set)`**（TA-D12）: `podcasts`・`isLoading`・`listErrorMessage`・`isOnline` と、写しの 3 つ。
   - **文言**: `@Published private(set) var listErrorMessage: String?` は、facade に残る操作（一覧読込 `:142,148,150`・`download` `:200,210,213`・`removeDownload` `:224`。2026-09-30 実測）の失敗だけを持つ。`download` の失敗の文言は現行と同じ: `DownloadFailure.api(f)` → `FailureMessages.message(for: f, context: .podcast)`、`.invalidSource` → "Invalid audio URL"、`.store(d)` → `d`（現行の `localizedDescription`）。再生由来の書込（`:267,271,290` play・`:344,346` playById・`:365` engine failed）は消える。理由 → 文言は `static func playbackErrorMessage(for reason: PlaybackErrorReason) -> String`（`offlineUncached` = "Offline and not cached"、`invalidSource` = "Invalid audio URL"、`engineFailed(d)` = `d ?? "Playback failed"`、`fetchFailed(f)` = `FailureMessages.message(for: f, context: .podcast)`。現行と同じ文言）。`notice` の文言は `.failure(理由)` がこの関数、`.loadWarning(説明文)` は説明文そのまま（SG-C42）。`shouldPresentErrorAlert`・`displayState` は合成後の `errorMessage` で判定し、alert は 1 つのまま。
   - **開始で一覧のエラーを消す**: `session` が `loading` になったら `listErrorMessage = nil`（現行の「再生開始で前回の失敗を消す」。issue #58）。
   - **forwarder（名前を残す。削除は I-S3b3）**: `playNow(p)` → `startEpisode(p.toEpisode())`、`playById(id)` → `startEpisode(id:)`、`replayCurrentEpisode()` → `replayCurrent()`、`stopPlayback()` → 使われなくなる（中身は空でよい）、`flushPlaybackPosition()` → `flushPosition()`、`handlePlaybackEnded(endedId:)` → Coordinator の `onEnded(endedId:)`、`previewMarkFinished()` → 空、`resolvePlaybackURL` → そのまま、`syncDownloadedState()` → `library.refresh(candidateIds: podcasts.map(\.id))`。
   - **facade に残る操作**: `loadPodcasts`（始めに、自分の `listErrorMessage` と Coordinator の `notice` の両方を消す = `dismissError()` と同じ。現行の `errorMessage = nil` は再生の失敗の表示も消している。終わりに `library.refresh(candidateIds:)`）・`download`・`removeDownload`・`downloadState(for:)`・`isPlayableWhileOffline`・`submitQuizAnswers`・`fetchSavedVocabulary`・`saveVocabulary`。`download(podcast:)` は `downloads.download(episodeId:)` の中継、`removeDownload(podcast:)` は `downloads.remove(episodeId:)` の中継、`downloadState(for:)` は `downloads.state(for:)` の中継（手順・二重実行の抑止・`downloadingIds` を facade に書かない。TA-R-PB-8・I-T3）。旧 `enum DownloadState`（`:14-22`）を消し、`Podcast/Playback/OfflineDownloads.swift` に `typealias DownloadState = OfflineDownloads.State` を足す（View の型名を変えない。I-T3 の完了条件 5）。
   - **位置の応答の反映**（TP6）: 合成 root の `updatePosition` の closure が、応答の `Podcast` で facade の `podcasts` の同じ id の要素を置き換える（facade は internal な `replacePodcast(_:)` を持つ。I-T4 で `EpisodeCatalog.applyPositionSaved` に替わる）。
3. **`Podcast/Playback/Domain/PlaybackQueue.swift`**（I-T2a で移動済み。「`Podcast/Playback/` を変えない」の例外）: `init` と `setQueue` に、id の重複を先勝ちで除く内部の gate を入れる（CI-T9。公開操作の名前と型は変えない）。`setQueue` の開始位置は、元の入力で clamp して id を決め、重複を除いた後のその id の位置を現在にする（SG-C50・共有仕様 Q-33）。
4. **`Podcast/PodcastRowView.swift:119-133`**: status の文字列分岐を消し、バッジの種類を引数 `badge: PodcastViewModel.RowBadge`（`none / generating / failed`。facade の入れ子の enum。TP6 の間だけ。I-T4 で `EpisodeBadge` に替わる）で受ける。種類は facade の `rowBadge(for: podcast)` が `podcast.toEpisode()` の種別から導く: `playable` はバッジなし、`generating` は「生成中」、`failed` は「失敗」（PS-07。TA-R-CT-2）。View は `Episode` を判別しない。「失敗」バッジの `accessibilityValue` は、現行どおり `podcast.errorMessage ?? ""`（= `FailedEpisode.reportedMessage ?? ""`）。
5. **`Podcast/PodcastView.swift`**: `:45` と `:135` の `errorMessage = nil` を `dismissError()` へ。`:90` の比較を `nowPlaying()?.episodeId == podcast.id` へ。行に `badge: viewModel.rowBadge(for: podcast)` を渡す。
6. **`Podcast/QueueSheet.swift:22`**: `currentPodcast != nil` と `queue.current` の合成を `nowPlaying()` へ。
7. **`DesignSystem/PreviewSupport.swift:151-168`**: `vm.currentPodcast = …` などの直書き 7 箇所（`:153-157`・`:165-166`）を、`PlaybackCoordinator.previewParts(session:queue:)`（I-S3b1）が返す Coordinator・Reporter・保存庫を facade の `init` に渡す形へ替える（`PreviewSupport` では保存庫も Reporter も作らない）。`playerViewModel()` は `session: .playing(episode: <podcasts[0].toEpisode() の PlayableEpisode>, position: 72, duration: 247, speed: 1.0)`、`finishedPlayerViewModel()` は `session: .ended(episode: 同じ, duration: 247)`。どちらも `queue` は `PlaybackQueue<Episode>(items: [podcasts[0].toEpisode()], currentIndex: 0)`。
8. **`Settings/SettingsViewModel.swift`**: `cacheManager: AudioCacheManager` を `library: OfflineLibrary` に替える（`usage()`・`clearAll()`）。**TP2 は型を変えて残す**: 2 つの `init`（`:73,80`）の既定引数を `library: OfflineLibrary = OfflineLibrary(store: .live(cacheManager: AudioCacheManager()))` にする。既定引数の物理削除は I-S3b3。
9. **`Settings/SettingsView.swift`**: `init(appState:)` に `library: OfflineLibrary` を足し、`:57` の `SettingsViewModel(appState:)` に渡す（起票時はこのファイルが対象に無く、App の保存庫を設定画面へ渡す経路が無かった）。
10. **`Networking/Gateways/PlaybackGateway+Live.swift`**（新規。adapter）: `enum PlaybackGateway`（adapter の名前空間。case を持たない）の static 関数 `live(apiClient:)` が `fetchEpisode`・`updatePosition`・`markCompleted`・`downloadAudio` の 4 つの closure を `APIClient` から組んで返す（戻り値は 4 つの closure を持つ名前つきタプル。応答は `toEpisode()`）。再生の port は I-S3b1・I-T3 の `init` が受ける closure の型そのもので、束の型を application に足さない（TA Spec §5.1 の port の表は「再生の gateway（closure）」。I-S3b1 の `Podcast/Playback/` を変えないため）。
11. **`Models/Podcast+Episode.swift`**（I-T2a の adapter）: 移行用の `Episode.toDisplayPodcast()` を足す（TP3。I-S3b3 で消す）。
12. **`Podcast/Playback/OfflineDownloads.swift`**（I-T3）: `typealias DownloadState = OfflineDownloads.State` の 1 行だけを足す（「`Podcast/Playback/` を変えない」の例外）。

**`Podcast/Playback/` と `Podcast/Platform/` は変えない**（例外は対象 3 の `Domain/PlaybackQueue.swift` と対象 12 の `typealias` 1 行）。Coordinator 側の不足が見つかったら、実装を止めて報告する。

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
| —（CI-T1e。SG-C43） | 開始の直後から総時間が出る。総時間が不明な間に先送りしても 0 へ戻らない。位置は `[0, 総時間]` に丸める | 最初の定期更新まで総時間 0。不明な間の先送りで 0 へ戻る。`seek(to:)` は丸めない | 準拠テスト（facade の `seek` で判定）。**注**: 画面の ±秒ボタンは View が `min(vm.duration, …)` を掛けている（`Podcast/AudioPlayerView.swift:225`）ので、「総時間が不明な間の先送りで 0 へ戻らない」が画面のボタンに届くのは I-S3b3（View の丸めを外す。TA-R-PB-5）から |
| —（CI-T5。SG-C4） | オンラインで未キャッシュのエピソードは、再生の直前に URL と再開位置を取り直す。開始（プレイヤーの切替を含む）は、その応答の後になる | 一覧を取得した時点の URL と位置でそのまま始める | 準拠テスト（gateway double の呼出と、double の `loadedURL` を観測）。既存 `testResolvePlaybackURL*` 3 件（`PodcastViewModelTests.swift:401,422,439`）は純関数の forwarder が残るので不変 |
| —（CI-T8。G12） | 位置を送った応答で、一覧の再開位置を更新する（巻き戻した位置は、現行どおり送る。SG-C67） | 応答を捨てる | 準拠テスト |
| PS-05（背景遷移。導出 I-9） | 背景遷移で、同じ位置は再送しない（`.inactive` と `.background` の 2 回が 1 回になる） | 2 回送る（`NewsListenAppApp.swift:193` が両方の遷移で `flushPlaybackPosition()` を呼ぶ） | 準拠テスト（facade の `flushPosition()` を 2 回呼んで送信 1 回） |
| PS-05（背景遷移。導出 I-9） | 背景遷移で、`ended`・`errored`・`idle` では送らない | `currentPodcast` があれば送る（`Podcast/PodcastViewModel.swift:659-680`） | 準拠テスト（3 状態それぞれで `flushPosition()` → 送信 0） |
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
- 準拠テストが green で、テスト名に **PS-01〜PS-08（05b・07b を含む）** の行 ID と `verifies: CI-T4/T5/T6/T7/T8/T9/T9b/T11` を持つ（PS-07b は共有仕様 §4.4 の保留の解除条件）。
- 変更した production が対象の 12 本だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 12 行。`git diff --name-only origin/main -- NewsListenApp/NewsListenApp/Podcast/Playback NewsListenApp/NewsListenApp/Podcast/Platform` が 2 行（`Domain/PlaybackQueue.swift`・`OfflineDownloads.swift`）。`git diff origin/main -- NewsListenApp/NewsListenApp/Podcast/Playback/OfflineDownloads.swift | grep -c '^+[^+]'` → 1（`typealias` の 1 行）。
- T-T7b: `grep -rn "currentPodcast\s*=[^=]" NewsListenApp/NewsListenApp --include='*.swift'` が 0 件（`==` の比較は一致しない。2026-09-30 実測: 現行の一致は `DesignSystem/PreviewSupport.swift:153,165` と `Podcast/PodcastViewModel.swift:280,693` の 4 件）。T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include='*.swift'` が `Networking/` 以外で 0 件。
- 依存方向: I-S3b1 の完了条件 4 の grep が 0 件のまま。`grep -n "^import \(AVFoundation\|MediaPlayer\|UIKit\)" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` が 0 件。`GrepOracleTests`（10。G08 の期待値だけ上のとおり改める）が green。
- TP5 が消えている: `grep -rnw "TP5\|isAudioLoaded" NewsListenApp/NewsListenApp --include='*.swift'` が 0 件（2026-09-30 実測: `PodcastViewModel.swift` に `TP5` 1 行・`isAudioLoaded` 12 行）。
- 主体離脱の登録先: `grep -n "registerPlaybackLifecycle" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` の引数が `playerViewModel.playbackLifecycle`。
- Reporter を外へ出さない: `grep -rn "positionReporter" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift\|^NewsListenApp/NewsListenApp/NewsListenAppApp.swift"` が 0 件。`grep -n "flushPosition()" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` が 1 行以上。facade の `positionReporter` が private（`grep -n "private let positionReporter" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` が 1 行）。
- ダウンロードの手順が facade に無い: `grep -n "downloadAudio\|fetchPodcast\|downloadingIds.insert\|enum DownloadState" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` が 0 件。
- 公開する状態: `grep -c "@Published var" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0。
- View が `Episode` を判別しない: `grep -rn "toEpisode()\|Episode.decode" NewsListenApp/NewsListenApp/Podcast/*View.swift NewsListenApp/NewsListenApp/Podcast/QueueSheet.swift` が 0 件。
- 保存庫が 1 個: `grep -rn "AudioCacheManager()" NewsListenApp/NewsListenApp --include='*.swift' | grep -v ":[0-9]*:[[:space:]]*//"` が 4 行（`NewsListenAppApp.swift` の生成 1 行、`Settings/SettingsViewModel.swift` の既定引数 2 行 = TP2、`AppState.swift` の `clearOfflineLibrary` の既定引数 1 行 = Preview とテスト用。I-S3b1 の Preview は「何もしない」`AudioFileStore` で 0 行。TA Spec §8.3 の I-S3b2 の補正 12）。`Podcast/PodcastViewModel.swift` には無い。`grep -n "clearOfflineLibrary" NewsListenApp/NewsListenApp/NewsListenAppApp.swift` が 1 行。
- TP3 の owner・導入・削除条件が、コード上のコメントか PR 説明にある。
- シミュレータの目視（UV3）を PR 説明に記す: (1) logout の後、ロック画面に前の主体の再生情報が残らない。(2) 自動で進んだ先が再生できないとき、止まった表示になる。(3) 一覧を 1 時間放置した後に再生できる。(4) **既定速度を 1.5 にして再生を始めると、実際に 1.5 倍で進む**（I-1 の確認。実機かシミュレータでしか確かめられない）。(5) 再生を始めてすぐに一時停止・再開ができる（事象の届く順序の確認）。(6) 画面をロックしたまま、オンラインで未キャッシュの次のエピソードへ自動で進む（I-16）。(7) **記録だけ行う確認**（SG-C70。I-S3c を決める材料）: ロック画面とコントロールセンターに出るボタン（15 秒戻し・30 秒送り）、イヤホンのリモコンの 2 回押しが何に割り当たるか、CarPlay があればその表示。挙動は変えない。

## 禁止事項 / scope 外
- `AudioPlayerView`・`MiniPlayerView`・`QueueSheet`（`:22` 以外）・`PodcastView`（`:45,90,135` 以外）の読み替え（TP3 の削除）はしない。forwarder・TP2・TP4 のコード・`didFinishCurrentEpisode`・`downloadedIds` の物理削除はしない（I-S3b3）。
- `Podcast/Playback/`・`Podcast/Platform/` を変えない（例外は対象 3・12）。facade の外へ `PositionReporter` を出さない。facade にダウンロードの手順を書かない。
- 「変わる挙動」以外を変えない（Q-*・再開位置の規則・古い終了通知の無視・トランスクリプト同期・表示形態の遷移）。`reorderUpNext` を rename しない。RO1〜RO7・SG-A7 を作らない。
- `skipToNext` を画面やロック画面につながない（I-S3c）。

## 特性テスト（baseline。着手前に green を記録する）
I-S3b1 完了時点の全件。とくに `PodcastViewModelTests`（72）・`PodcastViewModelPortTests`（13）・`SettingsViewModelTests`（36）・`AppStateAuthTests`・`PlaybackQueueConformanceTests`（32）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`（ios README の現行の形式）→ 全 green。`ArchitectureOracleTests` の許可リストを、本 slice が消した違反の分だけ減らす（TA-D5 の `Podcast/` と Preview の 8 行、TA-D6・D13 の `PodcastViewModel` の既定引数と `UIApplication`・`Timer`、TA-D8 の `PreviewSupport` 2 行、TA-V3 の TA-R-CT-1・2 の `PodcastRowView` 3 行。PR 説明に前後の行数）。
- 完了条件のコマンドを `ios/` で実行し、結果を PR 説明に貼る。commit は「Queue の重複除去」「Episode の切替（PS-07）」「facade への切替と TP3」「View 2 箇所・Preview・Settings への注入」「合成 root」「準拠テスト」の単位。

## 規模（見込み。2026-09-30 実測の基点: `PodcastViewModel.swift` 698・`NewsListenAppApp.swift` 255・`PlaybackQueue.swift` 143・`PodcastRowView.swift` 160・`PodcastView.swift` 151・`QueueSheet.swift` 82・`PreviewSupport.swift` 196・`SettingsViewModel.swift` 298、`PodcastViewModelTests.swift` 1,319・`SettingsViewModelTests.swift` 547）
- production ≈ 700 行（削除と追加の合計）: `PodcastViewModel.swift` は 698 行から facade ≈ 300 行へ（削除 ≈ 450・追加 ≈ 100）。`NewsListenAppApp.swift` ≈ 60・`PlaybackQueue.swift` ≈ 15・`PodcastRowView.swift` ≈ 25・`PodcastView.swift` 3・`QueueSheet.swift` 1・`PreviewSupport.swift` ≈ 20・`SettingsViewModel.swift` ≈ 10・`SettingsView.swift` ≈ 5。
- test ≈ 600 行: `PodcastViewModelTests.swift` の helper と Given ≈ 170、変わる挙動の Then ≈ 60、準拠テスト（新規ファイル）≈ 330、`SettingsViewModelTests.swift` の Given ≈ 40。
- 合計 ≈ 1,300 行だが分割しない。分割の基準 1,000 行は巻き戻しの範囲 = production に当てる。決定境界は「入口の差し替え」1 つで、これ以上分けると facade と旧 VM が併存する（AVPlayer 2 系統。棄却済み）。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記する。
- 親 docs へ返すもの: 共有仕様 §4.4 の PS-01〜PS-08 の iOS の保留（解除条件 = 本 slice の完了）を解除できる。`design/ios-design.md` §8（AVPlayer 設計）を Platform adapter の現状の記述へ、§11.3 の I-S3b2 行を完了へ。
