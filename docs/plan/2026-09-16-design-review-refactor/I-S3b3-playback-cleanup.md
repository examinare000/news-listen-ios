## iOS リファクタ I-S3b3: 旧実装の削除（`PodcastViewModel` の縮小・TP2 / TP3 / TP4 の除去）

## 概要
I-S3b2 で入口を差し替えた後に残る暫定経路と旧公開 API を**削除だけ**する（3 段分割の ③）。削除の前提として、旧公開プロパティを読む View の読出箇所を `nowPlaying()` / `session` 直読みへ付け替える（読出の付け替えのみ。表示・挙動は変えない）。正本は Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§5 naming_decisions・§6 TP2 / TP3 / TP4 の削除条件）と `docs/design/ios-design.md` §11.2（TP3 の削除条件 = I-S3b3）。検証モード（再設計しない）。新しい契約 ID を作らない。

## 着手前に決める項目（`unresolved`。user 判断が出るまで投入しない — `agent-rules/96` 「適用 slice に未決を残さない」）
| ID | 論点 | 選択肢 | 代償 | 決定が無いと止まる工程 |
|---|---|---|---|---|
| U-3b3-1 | forwarder 削除後、**通知経路**（`NewsListenAppApp.swift:185`。id しか持たない）と **replay**（`MiniPlayerView.swift:67`・`AudioPlayerView.swift:281`。`Podcast` DTO を持たない）の呼出形。Coordinator の 15 操作（Spec §5 CP4）には id 指定・現在エピソードの再開始が無く、`startEpisode(_ podcast:)` は DTO を要求する | (a) facade に `startEpisode(id:)`（`fetchPodcast` → `startEpisode`）と `replayCurrent()`（`queue.current` を `startEpisode`）を薄い forwarder として残す（Spec §11.2「facade 固有の操作は無し」を 2 操作分改訂）/ (b) Coordinator に同 2 操作を足す（15 → 17。Spec §5 CP4 と web Spec の対応表を改訂）/ (c) `nowPlaying()` の payload に `Podcast` DTO を含め、View が `startEpisode(nowPlaying.podcast)` を呼ぶ（通知経路は別途 (a) か (b) が要る。Spec の leakage guard「DTO を再生中の意味で読まない」と要整合） | (a) facade に操作が残る / (b) Coordinator の契約が増える / (c) DTO 露出 | 表 C「呼出の付け替え」3 箇所と表 A「forwarder 7」のうち `playById / replayCurrentEpisode` の削除 |
| U-3b3-2 | `AudioPlayerView` が `vm.currentPodcast` から読む DTO 項目（`id` 3 箇所のほか、子 View へ渡す `Podcast` 本体: transcript segments・vocabulary・quiz・sourceArticles）を、TP3 削除後にどこから読むか | (a) `nowPlaying()` の payload が `PlayableEpisode`（Spec §3.2 の任意項目 segments / vocabulary / quiz / sourceArticles を含む）を持ち、View は `PlayableEpisode` を読む（子 View の引数型が `Podcast` → `PlayableEpisode` に変わる = View の構造変更に近い）/ (b) `nowPlaying()` が `Podcast` DTO も持つ（U-3b3-1 (c) と同じ） | (a) 子 View の型変更が本 slice に入り「読出の付け替えのみ」を超える / (b) DTO 露出 | 表 C の `AudioPlayerView` 12 箇所の付け替え |

## 前提・着手条件
- 依存: **I-S3b2 の submodule PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（`git -C <親> submodule status` で `ios` に `+` が無い）。準拠テスト PS-01〜PS-08 green、`PlaybackLifecycle` の登録先が Coordinator、`OfflineLibrary` が合成 root から注入済み = TP2 / TP4 の削除条件成立。
- 上の「着手前に決める項目」2 件が user 判断で確定し、本 order の表 A・C にその決定が書き込まれていること。
- 削除対象の集合は下表で閉じる。表に無いシンボルを削除しない。`QuizSheetView` の採点 VM 化・View の構造変更は本 slice の対象外（ios-design §11.3「保留 views」）。

## 対象（ios サブモジュールのみ）
**A. 削除するシンボル（`Podcast/PodcastViewModel.swift`）**
| 種別 | 対象 | 由来 |
|---|---|---|
| TP3 computed 8 | `isPlaying / currentTime / duration / playbackSpeed / isBuffering / errorMessage / currentPodcast / queue`。`errorMessage` は `session` 派生の合成部分を削除し、一覧読込（`loadPodcasts`）の失敗文言を保持する facade 所有の `@Published private(set) var errorMessage` として残す（View の再生エラー表示は `session` の `errored` を直読み） | Spec §6 TP3 |
| 派生 atom 2 | `didFinishCurrentEpisode`（→ `session == .ended`）、`downloadedIds`（→ `library.savedIds`） | Spec §5 naming_decisions |
| forwarder 7 | `playNow / playById / replayCurrentEpisode / stopPlayback / flushPlaybackPosition / previewMarkFinished / resolvePlaybackURL` | `startEpisode` 1 経路（Q2）・Coordinator / PositionReporter が所有 |
| forwarder 2（旧 engine 由来） | `handlePlaybackEnded / syncDownloadedState`（I-S3b2 で forwarder になった分。AVFoundation 型を持つ 4 関数は **I-S3a** で `AVPlayerEngine` 内部へ移動済み・旧名は使われていない） | Coordinator / Library が所有 |
| TP4 | `PodcastViewModel` の `PlaybackLifecycle` 準拠（`extension` または conformance 宣言） | I-S2 で導入。削除条件成立済み |

残す facade 操作: `podcasts / isLoading / errorMessage（一覧読込のみ） / downloadingIds / isOnline / presentation / loadPodcasts / download / removeDownload / downloadState(for:) / isPlayableWhileOffline` と Coordinator の 15 操作の中継（`startEpisode / retry / togglePlayPause / seek / setSpeed / addToQueue / playNext / removeFromQueue / moveUpNext / skipToNext / nowPlaying() / upNext() / presentation / dismissError / stopForLogout`）、`submitQuizAnswers / fetchSavedVocabulary / saveVocabulary`。

**B. 削除する暫定経路（他ファイル）**: TP2 = `Settings/SettingsViewModel.swift` の 2 つの `init`（I-S3b2 時点で `library: OfflineLibrary = OfflineLibrary(cacheManager: AudioCacheManager())`）の既定引数（注入必須にする）。

**C. 読出の付け替え（削除の前提。読む先を変えるだけ）**: 2026-09-23 実測の読出箇所（件数は `grep -o "\(vm\|viewModel\)\.<prop>\b"` の**出現数**。同一行の複数出現は複数に数える）= `Podcast/AudioPlayerView.swift`（`currentPodcast` 12・`currentTime` 5・`isPlaying` 3・`duration` 3・`didFinishCurrentEpisode` 2・`playbackSpeed` 1・`isBuffering` 1 = 27）、`Podcast/MiniPlayerView.swift`（`currentPodcast` 2・`isPlaying` 2・`duration` 2・`currentTime` 1・`isBuffering` 1・`didFinishCurrentEpisode` 1 = 9）、`Podcast/PodcastView.swift`（`errorMessage` 3・`isPlaying` 1・`queue` 2（`:39` に 2 出現）= 6。`currentPodcast`（`:90`）は I-S3b2 で `nowPlaying()` へ置換済み）、`Podcast/QueueSheet.swift`（`queue` 4。`currentPodcast`（`:22`）は I-S3b2 で置換済み）。`DesignSystem/PreviewSupport.swift` の `vm.currentPodcast = …` 等 7 箇所は**書込**で I-S3b2 の DEBUG ファクトリ化で消えているため、本 slice では 0 件を確認するだけ。合計 **46 箇所**。着手時に完了条件 2 の grep で再実測し、件数が増えていれば増分も対象に含める（増減で止めない）。
呼出の付け替え（呼出形は「着手前に決める項目」U-3b3-1 の決定に従う）: `NewsListenAppApp.swift:185`（`playById`）、`PodcastView.swift:102`（`playNow` → `startEpisode(podcast)`）、`MiniPlayerView.swift:67`・`AudioPlayerView.swift:281`（`replayCurrentEpisode`）。`NewsListenAppApp.swift:170` の `flushPlaybackPosition` は I-S3b2 で `PositionReporter.flush()` 済みであることを確認。

**D. テスト**: `PodcastViewModelTests` のうち削除 API を駆動する関数は、I-S3b1 の T-T*（Coordinator / Session / PositionReporter）と I-S3b2 の準拠テストが同じ契約を検証していることを 1 対 1 で照合したうえで削除し、照合できない関数は facade の残る操作へ書き換える（契約の検証件数を減らさない）。照合表を PR 説明に載せる。

## 完了条件（参照 0 件の grep。除外範囲を含む）
1. `grep -rn "\.\(playNow\|playById\|replayCurrentEpisode\|stopPlayback\|flushPlaybackPosition\|previewMarkFinished\|resolvePlaybackURL\|handlePlaybackEnded\|shouldProcessPlayerItemCallback\|shouldProcessPlayerCallback\|handlePlayerItemStatusChange\|handleTimeControlStatusChange\|syncDownloadedState\)(" NewsListenApp --include='*.swift'` → 0 件（production・テストとも。除外なし）。
2. `grep -rn "\(vm\|viewModel\|playerViewModel\)\.\(isPlaying\|currentTime\|duration\|playbackSpeed\|isBuffering\|currentPodcast\|queue\|didFinishCurrentEpisode\|downloadedIds\)\b" NewsListenApp/NewsListenApp/Podcast NewsListenApp/NewsListenApp/DesignSystem NewsListenApp/NewsListenApp/NewsListenAppApp.swift` → 0 件。**除外**: `Feed/ Starred/ Settings/ Auth/ Admin/ Learning/ Passkey/ Onboarding/ Sessions/`（他 VM の同名プロパティ）。`errorMessage` は上の pattern から外す（一覧読込の失敗文言として残るため。`PodcastView.swift` の 3 箇所のうち再生エラー由来の表示は `session` 直読みへ、一覧読込由来は `errorMessage` のまま。着手時に 3 箇所の由来を PR 説明で分類する）。
3. `grep -n "PlaybackLifecycle" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0 件（port 定義・`AppState`・`SubjectCleanup`・`PlaybackCoordinator` は残る）。
4. `grep -rn "= OfflineLibrary(\|= AudioCacheManager()" NewsListenApp/NewsListenApp --include='*.swift'` → 0 件（既定引数生成が無い）。`AudioCacheManager(` の生成は `NewsListenAppApp.swift` の 1 行のみ（テストの生成・doc コメントは除外）。
5. `grep -n "^import \(AVFoundation\|MediaPlayer\|UIKit\)" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0 件（I-S3b2 の回帰なし）。T-T7b / T-T13 の grep（I-S3b2 と同じ）→ 0 件。
6. `PodcastViewModel.swift` の `@Published` 宣言が `podcasts / isLoading / errorMessage / downloadingIds / isOnline / presentation` の 6 つ以下（`grep -c "^\s*@Published" …` ≤ 6）。
7. 既存テスト全件 green。conformance 32 件・準拠テスト PS-01〜PS-08・RS-01〜RS-07・T-T1〜T-T11 の件数が I-S3b2 完了時から減らない。
8. TP2 / TP3 / TP4 のコメント（owner・削除条件）がコードに残っていない: `grep -rnw "TP2\|TP3\|TP4" NewsListenApp/NewsListenApp --include='*.swift'` → 0 件（TP1 は S1 の管轄で対象外）。

## 禁止事項 / scope 外
- 表 A・B 以外のシンボルを削除しない。View の表示・レイアウト・アニメーション・`.task(id:)` / `.onDisappear` の追従リセット（`transcript-sync-highlight.md`）を変えない（読出の付け替えのみ）。
- `QuizSheetView` の VM 化、`AudioPlayerView` の分割、新しい状態・失敗理由の追加はしない。`reorderUpNext` を rename しない。
- 契約テストの削除で検証件数を減らさない（D の照合表なしに削除しない）。

## 特性テスト（baseline）
I-S3b2 完了時点の全件（`PodcastViewModelTests`・conformance 32・準拠テスト PS-*/RS-*・T-T1〜T-T11・`SettingsViewModelTests` 36・`AppStateAuthTests`）。UI は目視 UV3 の 3 項目を再確認（読出の付け替えで表示が変わっていないこと）。

## 検証
- `xcodebuild test -only-testing:NewsListenAppTests`（README のコマンド）→ 全 green、件数が baseline 以上。
- 完了条件 1〜6・8 の grep → すべて期待どおり。commit は「View 読出の付け替え」「forwarder 削除」「TP3 削除」「TP2 / TP4 削除」「テスト照合・整理」の単位。

## 規模の目安（巻き戻し範囲）
削除約 250 行（facade の TP3 / forwarder / TP4）＋ View 4 ファイルの読出 46 箇所＋テスト整理。1 PR で読める規模。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記。router へ返す: `docs/design/ios-design.md` §5（MVVM）・§8・§11.2「PodcastViewModel facade」を現状記述へ、§11.3 I-S3b3 行を完了へ。I-S4 の着手条件が成立したことを README に記す。
