## iOS リファクタ I-S3b3: 旧実装の削除（`PodcastViewModel` の縮小・TP2 / TP3 / TP4 の除去）

## 概要
I-S3b2 で入口を差し替えた後に残る暫定経路と旧公開 API を**削除だけ**する（3 段分割の ③）。削除の前提として、旧公開プロパティを読む View の読出箇所を `nowPlaying()` / `session` 直読みへ付け替える（読出の付け替えのみ。表示・挙動は変えない）。正本は Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§5 naming_decisions・§6 TP2 / TP3 / TP4 の削除条件）と `docs/design/ios-design.md` §11.2（TP3 の削除条件 = I-S3b3）。検証モード（再設計しない）。新しい契約 ID を作らない。

## 確定済みの判断（2026-09-23 夜 dig-me。旧 U-3b3-1 / U-3b3-2 / U-3b3-3 は閉じた。未決なし）
| ID | 決定 | 反映先 |
|---|---|---|
| SG-C10（旧 U-3b3-1） | 選択肢 (b)。`PlaybackCoordinator` に `startEpisode(id:)`（Catalog で `Episode` を解決してから既存 `startEpisode`）と `replayCurrent()` を追加し公開 **17 操作**（定義と契約テストは I-S3b1、facade の中継は I-S3b2）。facade は固有操作なしのまま。通知経路 `NewsListenAppApp.swift:185` と replay 2 箇所はこれを呼ぶ。ios-design §11.2・共有仕様 §6.8「id からの再生開始」行に反映済み | 表 A forwarder 7 の `playById / replayCurrentEpisode` 削除、表 C「呼出の付け替え」 |
| SG-C11（旧 U-3b3-2） | `nowPlaying()` の派生値 `NowPlaying` は Android と同型の **episodeId / displayTitle / japaneseIntroText / segments / vocabulary / quiz / difficulty**（型定義は I-S3b1）。子 View は `NowPlaying` を受け取り、**`Podcast` DTO を「再生中」の意味で View に出さない**（Spec §5 leakage guard）。transport 値（`isPlaying / currentTime / duration / playbackSpeed / isBuffering`・`ended`）は `session` 直読み。共有仕様 §6.8 nowPlaying 行に反映済み | 表 C の `AudioPlayerView` / `MiniPlayerView` の付け替え、完了条件 2b |
| SG-C14（旧 U-3b3-3） | `NowPlaying` は共通 7 ＋ iOS 固有 2 field（`sourceArticles: [PodcastSourceArticle]?` / `sourceKind: String?`。ADR-095 の出典・ライセンス表示用。Android に同機能は無いため共通 7 の「同型」は保つ）。定義は I-S3b1、`PodcastAttributionContent(nowPlaying:)` / `attributionSection(_ nowPlaying:)` への付け替えは本 slice | 表 C「子 View の引数型」の出典表示行、`ModelTests.swift:843` |

## 前提・着手条件
- 依存: **I-S3b2 の submodule PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（`git -C <親> submodule status` で `ios` に `+` が無い）。準拠テスト PS-01〜PS-08 green、`PlaybackLifecycle` の登録先が Coordinator、`OfflineLibrary` が合成 root から注入済み = TP2 / TP4 の削除条件成立。
- 着手前に決める項目は無い（SG-C10 / SG-C11 / SG-C14 で全て確定・書込済み）。I-S3b1 で `PlaybackCoordinator` が 17 操作と `NowPlaying`（共通 7 ＋ iOS 固有 2 field）を持ち、I-S3b2 の facade がそれを中継していること（`playById` / `replayCurrentEpisode` forwarder の内部が `startEpisode(id:)` / `replayCurrent()`）。
- 削除対象の集合は下表で閉じる。表に無いシンボルを削除しない。`QuizSheetView` の採点 VM 化・View の構造変更は本 slice の対象外（ios-design §11.3「保留 views」）。

## 対象（ios サブモジュールのみ）
**A. 削除するシンボル（`Podcast/PodcastViewModel.swift`）**
| 種別 | 対象 | 由来 |
|---|---|---|
| TP3 computed 8 | `isPlaying / currentTime / duration / playbackSpeed / isBuffering / errorMessage / currentPodcast / queue`。`errorMessage` は `session` 派生の合成部分を削除し、一覧読込（`loadPodcasts`）の失敗文言を保持する facade 所有の `@Published private(set) var errorMessage` として残す（View の再生エラー表示は `session` の `errored` を直読み） | Spec §6 TP3 |
| 派生 atom 2 | `didFinishCurrentEpisode`（→ `session == .ended`）、`downloadedIds`（→ `library.savedIds`） | Spec §5 naming_decisions |
| forwarder 7 | `playNow / playById / replayCurrentEpisode / stopPlayback / flushPlaybackPosition / previewMarkFinished / resolvePlaybackURL` | `startEpisode` 1 経路（Q2）・Coordinator / PositionReporter が所有（`playById` → `startEpisode(id:)`、`replayCurrentEpisode` → `replayCurrent()`。SG-C10） |
| forwarder 2（旧 engine 由来） | `handlePlaybackEnded / syncDownloadedState`（I-S3b2 で forwarder になった分。AVFoundation 型を持つ 4 関数は **I-S3a** で `AVPlayerEngine` 内部へ移動済み・旧名は使われていない） | Coordinator / Library が所有 |
| TP4 | `PodcastViewModel` の `PlaybackLifecycle` 準拠（`extension` または conformance 宣言） | I-S2 で導入。削除条件成立済み |

残す facade 操作: `podcasts / isLoading / errorMessage（一覧読込のみ） / downloadingIds / isOnline / presentation / loadPodcasts / download / removeDownload / downloadState(for:) / isPlayableWhileOffline` と Coordinator の **17 操作**の中継（`startEpisode(_:expandsPlayer:) / startEpisode(id:) / replayCurrent / retry / togglePlayPause / seek / setSpeed / addToQueue / playNext / removeFromQueue / moveUpNext / skipToNext / nowPlaying() / upNext() / presentation / dismissError / stopForLogout`。SG-C10）、`submitQuizAnswers / fetchSavedVocabulary / saveVocabulary`。`startEpisode(id:)` の中継は解決失敗時に現行 `playById` と同じ文言を facade の `errorMessage` へ書く（I-S3b2 で導入済み。本 slice では名前を forwarder から中継へ寄せるだけで挙動不変）。

**B. 削除する暫定経路（他ファイル）**: TP2 = `Settings/SettingsViewModel.swift` の 2 つの `init`（I-S3b2 時点で `library: OfflineLibrary = OfflineLibrary(cacheManager: AudioCacheManager())`）の既定引数（注入必須にする）。

**C. 読出の付け替え（削除の前提。読む先を変えるだけ）**: 2026-09-23 実測の読出箇所（件数は `grep -o "\(vm\|viewModel\)\.<prop>\b"` の**出現数**。同一行の複数出現は複数に数える）= `Podcast/AudioPlayerView.swift`（`currentPodcast` 12・`currentTime` 5・`isPlaying` 3・`duration` 3・`didFinishCurrentEpisode` 2・`playbackSpeed` 1・`isBuffering` 1 = 27）、`Podcast/MiniPlayerView.swift`（`currentPodcast` 2・`isPlaying` 2・`duration` 2・`currentTime` 1・`isBuffering` 1・`didFinishCurrentEpisode` 1 = 9）、`Podcast/PodcastView.swift`（`errorMessage` 3・`isPlaying` 1・`queue` 2（`:39` に 2 出現）= 6。`currentPodcast`（`:90`）は I-S3b2 で `nowPlaying()` へ置換済み）、`Podcast/QueueSheet.swift`（`queue` 4。`currentPodcast`（`:22`）は I-S3b2 で置換済み）。`DesignSystem/PreviewSupport.swift` の `vm.currentPodcast = …` 等 7 箇所は**書込**で I-S3b2 の DEBUG ファクトリ化で消えているため、本 slice では 0 件を確認するだけ。合計 **46 箇所**。着手時に完了条件 2 の grep で再実測し、件数が増えていれば増分も対象に含める（増減で止めない）。
呼出の付け替え（SG-C10。呼出形は facade が中継する Coordinator の 17 操作）: `NewsListenAppApp.swift:185` `await playerViewModel.playById(id)` → `await playerViewModel.startEpisode(id: id)`、`PodcastView.swift:102` `playNow(podcast)` → `startEpisode(podcast)`（`expandsPlayer` 既定 true）、`MiniPlayerView.swift:67`・`AudioPlayerView.swift:281` `replayCurrentEpisode()` → `replayCurrent()`。`NewsListenAppApp.swift:170` の `flushPlaybackPosition` は I-S3b2 で `PositionReporter.flush()` 済みであることを確認。

読出の付け替え先（SG-C11）: `currentPodcast?.displayTitle / ?.id / ?.japaneseIntroText / ?.segments / ?.vocabulary / ?.quiz` は `nowPlaying()` の `NowPlaying` の同名 field へ、`hasTranscript / hasVocabulary / hasQuiz` は `NowPlaying` 上の同名 computed（`Podcast` の既存規則をそのまま写す。空配列は「無し」）へ、`isPlaying / currentTime / duration / playbackSpeed / isBuffering / didFinishCurrentEpisode` は `session` 直読みへ、`queue`（`PodcastView.swift:39`・`QueueSheet.swift`）は `upNext()` / `nowPlaying()` へ。`AudioPlayerView.swift:94` の `.task(id: vm.currentPodcast?.id)` は `.task(id: vm.nowPlaying()?.episodeId)`（追従リセットの契機は不変）。

**子 View の引数型（`AudioPlayerView.swift` 内の private 関数と `QuizSheetView`。SG-C11「子 View は `NowPlaying` を受ける」の対象集合。これ以外の View の引数は変えない）**
| 現行 | 付け替え後 | 備考 |
|---|---|---|
| `transcriptSection(segments:)`（`:327`） | 不変 | 既に `[TranscriptSegment]` を受ける |
| `learningSections(_ podcast: Podcast)`（`:423`） | `learningSections(_ nowPlaying: NowPlaying)` | `vocabulary / quiz / hasVocabulary / hasQuiz` を読む |
| `loadSavedVocabulary(for podcast: Podcast)`（`:545`）・`save(_:for podcast: Podcast)`（`:555`） | 引数を `episodeId: String` に | `podcast.id` しか読まない。stale ガード `vm.currentPodcast?.id == podcast.id`（`:547,562`）は `vm.nowPlaying()?.episodeId == episodeId` |
| `@State quizPodcast: Podcast?`（`:58`）＋ `QuizSheetView(podcast:)`（`:89`・`QuizSheetView.swift:12-28`） | `@State quizTarget: NowPlaying?`（`NowPlaying: Identifiable` で `.sheet(item:)` はそのまま）＋ `QuizSheetView(nowPlaying:)`。`submit` closure は `nowPlaying.episodeId` | `QuizSheetView` が読むのは `quiz / hasQuiz`（`:28,34,62,69`）のみ。**採点 VM 化・構造整理はしない**（ios-design §11.3「保留 views」）。`QuizSheetView.swift:229` の preview 用 `quizPreviewPodcast` は `NowPlaying` の preview 値へ |
| `attributionSection(_ podcast: Podcast)`（`:503`）・`PodcastAttributionContent(podcast:)`（`:13-27`。読み手 `:250,294`） | `attributionSection(_ nowPlaying: NowPlaying)`・`PodcastAttributionContent(nowPlaying:)`（`NowPlaying` の iOS 固有 field `sourceArticles / sourceKind` から組む。SG-C14。`hasSourceArticles` / `showsCcBySaLicense` の fail-closed 規則は `Podcast` の既存規則をそのまま写す） | `ModelTests.swift:843` の `PodcastAttributionContent` テストも `init(nowPlaying:)` へ付け替え、件数（`ModelTests` 50）は減らさない |

`PodcastRowView(podcast:)`（一覧行。`vm.podcasts` = Catalog の DTO）と `NowPlayingInfo.make(podcast:)`（Platform adapter。`Podcast/Platform/` 側で Coordinator が渡す）は「再生中」の意味で DTO を読んでいないため対象外。

**D. テスト**: `PodcastViewModelTests` のうち削除 API を駆動する関数は、I-S3b1 の T-T*（Coordinator / Session / PositionReporter）と I-S3b2 の準拠テストが同じ契約を検証していることを 1 対 1 で照合したうえで削除し、照合できない関数は facade の残る操作へ書き換える（契約の検証件数を減らさない）。照合表を PR 説明に載せる。

## 完了条件（参照 0 件の grep。除外範囲を含む）
1. `grep -rn "\.\(playNow\|playById\|replayCurrentEpisode\|stopPlayback\|flushPlaybackPosition\|previewMarkFinished\|resolvePlaybackURL\|handlePlaybackEnded\|shouldProcessPlayerItemCallback\|shouldProcessPlayerCallback\|handlePlayerItemStatusChange\|handleTimeControlStatusChange\|syncDownloadedState\)(" NewsListenApp --include='*.swift'` → 0 件（production・テストとも。除外なし）。
2. `grep -rn "\(vm\|viewModel\|playerViewModel\)\.\(isPlaying\|currentTime\|duration\|playbackSpeed\|isBuffering\|currentPodcast\|queue\|didFinishCurrentEpisode\|downloadedIds\)\b" NewsListenApp/NewsListenApp/Podcast NewsListenApp/NewsListenApp/DesignSystem NewsListenApp/NewsListenApp/NewsListenAppApp.swift` → 0 件。**除外**: `Feed/ Starred/ Settings/ Auth/ Admin/ Learning/ Passkey/ Onboarding/ Sessions/`（他 VM の同名プロパティ）。`errorMessage` は上の pattern から外す（一覧読込の失敗文言として残るため。`PodcastView.swift` の 3 箇所のうち再生エラー由来の表示は `session` 直読みへ、一覧読込由来は `errorMessage` のまま。着手時に 3 箇所の由来を PR 説明で分類する）。
2b. **`Podcast` DTO を View に出さない（SG-C11）**: `grep -rn "currentPodcast\|: Podcast\b\|: Podcast?" NewsListenApp/NewsListenApp/Podcast/AudioPlayerView.swift NewsListenApp/NewsListenApp/Podcast/MiniPlayerView.swift NewsListenApp/NewsListenApp/Podcast/QuizSheetView.swift NewsListenApp/NewsListenApp/Podcast/QueueSheet.swift` → 0 件。ただし `QueueSheet.swift:67` の `let podcast: Podcast`（`upNext()` の行 = Catalog の DTO を一覧として並べる行 View）と `PodcastView.swift` / `PodcastRowView.swift`（一覧）は除外。`grep -rn "\.playById(\|\.replayCurrentEpisode(\|\.playNow(" NewsListenApp --include='*.swift'` → 0 件（完了条件 1 に含まれるが、SG-C10 の呼出形 `startEpisode(id:)` / `replayCurrent()` / `startEpisode(` が `NewsListenAppApp.swift:185`・`MiniPlayerView.swift:67`・`AudioPlayerView.swift:281`・`PodcastView.swift:102` の 4 箇所にあることを PR 説明に載せる）。
3. `grep -n "PlaybackLifecycle" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0 件（port 定義・`AppState`・`SubjectCleanup`・`PlaybackCoordinator` は残る）。
4. `grep -rn "= OfflineLibrary(\|= AudioCacheManager()" NewsListenApp/NewsListenApp --include='*.swift'` → 0 件（既定引数生成が無い）。`AudioCacheManager(` の生成は `NewsListenAppApp.swift` の 1 行のみ（テストの生成・doc コメントは除外）。
5. `grep -n "^import \(AVFoundation\|MediaPlayer\|UIKit\)" NewsListenApp/NewsListenApp/Podcast/PodcastViewModel.swift` → 0 件（I-S3b2 の回帰なし）。T-T7b / T-T13 の grep（I-S3b2 と同じ）→ 0 件。
6. `PodcastViewModel.swift` の `@Published` 宣言が `podcasts / isLoading / errorMessage / downloadingIds / isOnline / presentation` の 6 つ以下（`grep -c "^\s*@Published" …` ≤ 6）。
7. 既存テスト全件 green。conformance 32 件・準拠テスト PS-01〜PS-08・RS-01〜RS-07・T-T1〜T-T11 の件数が I-S3b2 完了時から減らない。
8. TP2 / TP3 / TP4 のコメント（owner・削除条件）がコードに残っていない: `grep -rnw "TP2\|TP3\|TP4" NewsListenApp/NewsListenApp --include='*.swift'` → 0 件（TP1 は S1 の管轄で対象外）。

## 禁止事項 / scope 外
- 表 A・B 以外のシンボルを削除しない。View の表示・レイアウト・アニメーション・`.task(id:)` / `.onDisappear` の追従リセット（`transcript-sync-highlight.md`）を変えない（読出の付け替えのみ）。
- `QuizSheetView` の VM 化、`AudioPlayerView` の分割、新しい状態・失敗理由の追加はしない。`reorderUpNext` を rename しない。Coordinator の公開操作を 17 より増やさない（本 slice は Coordinator / facade に操作を足さない。SG-C10 の 2 操作は I-S3b1 / I-S3b2 で入っている）。`NowPlaying` の field は共通 7 ＋ iOS 固有 2（SG-C14）を超えて足さない。
- 契約テストの削除で検証件数を減らさない（D の照合表なしに削除しない）。

## 特性テスト（baseline）
I-S3b2 完了時点の全件（`PodcastViewModelTests`・conformance 32・準拠テスト PS-*/RS-*・T-T1〜T-T11・`SettingsViewModelTests` 36・`AppStateAuthTests`）。UI は目視 UV3 の 3 項目を再確認（読出の付け替えで表示が変わっていないこと）。

## 検証
- `xcodebuild test -only-testing:NewsListenAppTests`（README のコマンド）→ 全 green、件数が baseline 以上。
- 完了条件 1〜6・8 の grep → すべて期待どおり。commit は「View 読出の付け替え」「forwarder 削除」「TP3 削除」「TP2 / TP4 削除」「テスト照合・整理」の単位。

## 規模の目安（巻き戻し範囲）
削除約 250 行（facade の TP3 / forwarder / TP4）＋ View 4 ファイルの読出 46 箇所＋子 View 引数型の付け替え（`AudioPlayerView` 内 private 4 関数・`QuizSheetView` の init・`PodcastAttributionContent` の init）＋テスト整理。1 PR で読める規模。

## 記録
- `docs/trial-log/` に棄却・方針転換を追記。router へ返す: `docs/design/ios-design.md` §5（MVVM）・§8・§11.2「PodcastViewModel facade」を現状記述へ、§11.3 I-S3b3 行を完了へ。I-S4 の着手条件が成立したことを README に記す。
