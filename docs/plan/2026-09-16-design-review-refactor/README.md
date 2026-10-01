# iOS リファクタ計画（2026-09-16 設計レビュー反映）— takt 委譲用の指示書

2026-09-16 の iOS 設計レビュー（`docs/research-reports/2026-09-16-code-design-review.md`）と user 承認済みの Implementation Spec（`docs/design/2026-09-16-implementation-spec-playback-domain-model.md`）、2026-09-23 の主体離脱の設計決定（親 docs `docs/adr/104-subject-departure-and-subject-scoped-assets.md`）、2026-09-30 の目標アーキテクチャ（親 docs `docs/adr/110-refactor-target-domain-centered-onion-cqrs.md` と iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`）を、takt の `sdd-governed` ワークフローへ slice 単位で委譲するための指示書（order）一式。正本は 2 つの Spec（構造・型の置き場・依存の向き・slice の全体は 2026-09-30 の Spec、状態遷移と契約は 2026-09-16 の Spec）と ADR-104・ADR-110 であり、本フォルダの各 order は該当 slice を takt の 1 タスクに切り出したもの。slice ID は親 docs の実行計画 `docs/plan/2026-09-16-design-review-refactor.md`（2026-09-23 再スライス版）の接頭辞付き ID **I-\*** を使う（`docs/design/ios-design.md` §11.3 と同一）。実装完了後、本フォルダは削除し、確定内容は親 docs の `design/ios-design.md`（§4〜§8 を target の内容へ書き換え、§11 を削除）へ移す（`agent-rules/30` の plan ライフサイクル）。

Spec §6 の `I-S0 spec`（旧 S0。共有仕様の改訂）は **news-listen-docs #133 で main 済み・完了**。本フォルダに order は作らない。

## 投入前の前提点検が必須（2026-10-01）

**どの order も、投入の直前に、その order の「着手前の前提点検」の節（引用する件数・行番号・型名・grep の結果と、数え直すコマンド）を `ios/` で実行し、値が order と合うことを確かめてから投入する。** 値が違えば、order を直してから投入する（実装者に読み替えさせない）。後の wave の order は、書いた時点（2026-10-01、revision `ef9e559`）から前の slice が実コードを変えているので、点検なしでは投入できない。あわせて `analyze_order` の受入検査（未決の選択が無い／全称命題の集合が列挙されている／完了条件・対象・禁止の相互矛盾が無い／依存で結ばれた order と対で突き合わせる）を自分で通す。

**2026-10-01 の改訂**: 目標アーキテクチャ（親 docs `adr/110-refactor-target-domain-centered-onion-cqrs.md`、`design/architecture.md`、iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`。以下「TA Spec」）に合わせ、補完 slice **I-T1〜I-T12**（12 本。枝番を数えて 15 本）の order を足し、未着手の I-S3b1・I-S3b2・I-S3b3・I-S4・I-S5 を TA Spec §8.3 のとおり補正した（各 order の冒頭の「2026-10-01 … による補正」の節に直した点を列挙）。I-S3c は保留のまま path だけを追随させた。実装と takt への投入は、親 docs plan「実装の停止と再開ゲート」の 3 条件が満たされるまで止めてある。

## slice と投入順（TA Spec §8.1 の順。同じ submodule なので 1 本ずつ投入する）

| 順 | order | 内容 | 依存（submodule PR が main ＋ 親ポインタが進んでいること） | 契約・検査 | 状態 |
|---|---|---|---|---|---|
| — | （I-S0 spec） | 共有仕様の改訂 | なし | — | 完了（news-listen-docs #133） |
| — | [S1-failure-meaning.md](S1-failure-meaning.md)（I-S1） | `ApiFailure`・`validateResponse` の変換・`notFound.subject`・`FailureMessages` | なし | CI-T12 / T13 | **完了**（ios PR #84。TP1 は slice 内で削除済み） |
| — | [I-S2-session-boundary.md](I-S2-session-boundary.md) | `AuthSession` union・失効検知・`SubjectCleanup` の骨格・`PreferenceRegistry`・`NowPlayingCenter` port | S1 | SL-01〜SL-05 | **完了**（ios PR #91） |
| — | [I-S3a-audio-engine-doubles.md](I-S3a-audio-engine-doubles.md) | `AudioEngine` port・double・Platform adapter 2 本・VM の port 経由化 | I-S2 | engine 結合テスト 17 関数 | **完了**（ios PR #95） |
| 1 | [I-T1-layer-manifest.md](I-T1-layer-manifest.md) | 層の所属表と依存の検査。現状の違反を許可リスト（TP10）に固定（test だけ） | なし（再開ゲート 1〜3） | TA-V1〜V5・V7・V9 | 未着手 |
| 2 | [I-T2a-domain-foundation.md](I-T2a-domain-foundation.md) | `Episode`・`EpisodeContent`・generic な `PlaybackQueue`・`ApiFailure` の置き場・`toEpisode()` | I-T1 | CI-T11（T-T11）・TA-R-CT-1・3〜5・TA-D2 | 未着手 |
| 3 | [I-T2b-nowplaying-port.md](I-T2b-nowplaying-port.md) | ロック画面の port を `NowPlayingSnapshot` に。port と adapter の補助の置き場 | I-T1（I-T2a と順不同） | TA-D11・G03 | 未着手 |
| 4 | [I-S3b1-playback-domain.md](I-S3b1-playback-domain.md) | 再生の domain と application を新規コードとして入れる（2026-10-01 補正） | I-S3a・I-T1・I-T2a・I-T2b | CI-T1・T1b〜T1f・T2〜T8・T10、RS-01〜RS-07、PS-04・PS-09〜PS-13、TA-V6（PB） | 未着手 |
| 5 | [I-T3-offline-downloads.md](I-T3-offline-downloads.md) | オフライン保存の use case `OfflineDownloads`（新規コードのみ） | I-S3b1 | TA-C-PB-20〜22・TA-Q-PB-4・TA-R-PB-8 | 未着手 |
| 6 | [I-S3b2-playback-entry.md](I-S3b2-playback-entry.md) | 入口の差し替え（facade 化。2026-10-01 補正） | I-S3b1・I-T3 | PS-01〜PS-08（05b・07b）・CI-T9 / T9b | 未着手 |
| 7 | [I-S3b3-playback-cleanup.md](I-S3b3-playback-cleanup.md) | 旧実装の削除・View の読出の付け替え（2026-10-01 補正） | I-S3b2 | 参照 0 件の grep・TA-D5（`Podcast/`） | 未着手 |
| 8 | [I-T4-catalog.md](I-T4-catalog.md) | 一覧を `EpisodeCatalog`・`EpisodeRow` へ（TP6 を消す） | I-S3b3 | TA-Q-CT-1・2・TA-C-CT-1・TA-R-CT-2 | 未着手 |
| 9 | [I-T5-account-domain.md](I-T5-account-domain.md) | `Subject`・`Role`・`SubjectKey`・`AuthSession` から DTO を外す | I-S3b3（I-T4 と並行可） | TA-R-AC-4・5・CI-T14（不変） | 未着手 |
| 10 | [I-S4-rules-ci.md](I-S4-rules-ci.md) | `PasswordPolicy`・`AccountProfile`・`AccountSettingsViewModel`・速度の Picker・CI（2026-10-01 補正） | I-S3b3・I-T5 | CI-T16・TA-R-AC-1・TA-R-PB-4 | 未着手 |
| 11 | [I-S5-subject-cache.md](I-S5-subject-cache.md) | 主体別の音声キャッシュ・起動時の回収・logout の送信（2026-10-01 補正） | I-S3b3・I-T3・I-T5 ＋ backend **B-S5a**（完了）と **B-S5b** の契約 | SL-06〜SL-10・CI-T10 / T15 | **B-S5b 待ち**（B-S5b が親 main に入るまで投入しない） |
| 12 | [I-T6-preferences.md](I-T6-preferences.md) | Preferences の値型と `PreferencesStore` | I-S4（I-S5 と並行可） | TA-C-PF-1〜3・TA-Q-PF-1・TA-R-PF-1〜6・CI-T17（不変） | 未着手 |
| 13 | [I-T7a-curation.md](I-T7a-curation.md) | Curation（Feed・Starred・残り回数） | I-T6 | TA-C-CU-1〜4・TA-Q-CU-1〜3・TA-R-CU-1〜5 | 未着手 |
| 14 | [I-T7b-sources-onboarding.md](I-T7b-sources-onboarding.md) | RSS ソースと Onboarding | I-T6（I-T7a と並行可） | TA-C-SO-1〜3・TA-Q-SO-1・2・TA-R-SO-1〜4 | 未着手 |
| 15 | [I-T7c-account-periphery.md](I-T7c-account-periphery.md) | Account の周辺（login・Sessions・Passkey・Admin） | I-S4・I-S5・I-T5 | TA-C-AC-1・5〜9・TA-Q-AC-2・TA-R-AC-5〜7 | **B-S5b 待ち**（I-S5 経由） |
| 16 | [I-T8-learning-domain.md](I-T8-learning-domain.md) | Learning の domain の型 | I-T2a・I-S3b3 | TA-R-LE-1〜4・TA-R-LV-1・TA-R-LC-1・TA-V7 | 未着手 |
| 17 | [I-T9-vocabulary-quiz.md](I-T9-vocabulary-quiz.md) | 語彙とクイズの application（TP7 を消す） | I-S3b3・I-T8 | TA-C-LV-1・2・TA-Q-LV-1・2・TA-C-LC-1・TA-R-LV-2・TA-R-LC-2 | 未着手 |
| 18 | [I-T10-engagement.md](I-T10-engagement.md) | 継続（ストリーク・ダッシュボード・既読）の application | I-T8・I-T6・I-T9（I-T9 は gateway のファイルと `LearningViewModel` の呼出先を共有するため。TA Spec §8.1 への返却事項） | TA-Q-LE-1〜3・TA-C-LE-1・TA-R-LE-1・2 | 未着手 |
| 19 | [I-T11-playback-transition.md](I-T11-playback-transition.md) | 再生の遷移の決定を domain の純関数へ（TP8 を消す） | I-S3b3（ほかと並行可） | TA-R-PB-1 | 未着手 |
| 20 | [I-T12-finishing.md](I-T12-finishing.md) | 仕上げ: `AppState` を Account だけに・Push・Observability・adapter の生成を合成 root だけに・許可リストを空に | I-T4〜I-T11 の全部 | TA-C-AC-3・TA-C-PU-1・2・TA-C-OB-1・TA-D3・D5・D13 が 0 | **B-S5b 待ち**（I-T7c 経由） |
| 保留 | [I-S3c-remote-next-track.md](I-S3c-remote-next-track.md) | リモートコマンド「次のトラック」 | I-S3b3 | CI-T7 の抜粋（T-T7h / T-T7i） | 保留（SG-C70。投入しない。2026-10-01 に path だけ追随） |
| 未起票 | （位置同期） | ADR-109 決定 7〜13 の iOS 側 | backend B-S7・I-S3b3・I-T5 | — | 保留（SG-C79。order 未作成。起票の方針は TA Spec §8.3 の末尾） |

- 依存の連鎖（クリティカルパス）: **I-T1 → I-T2a / I-T2b → I-S3b1 → I-T3 → I-S3b2 → I-S3b3 → I-T5 → I-S4 → I-T6 → …**、および **B-S5b → I-S5 → I-T7c → I-T12**。I-T12 は I-T4〜I-T11 の全部の後。
- 「並行可」は対象のファイルが重ならず順序を問わないという意味（TA Spec §8.1）。同じ submodule なので、投入は 1 本ずつ（前の PR が main に入り、親ポインタが進んでから次）。
- 一時経路（TA Spec §8.4。TP1〜TP5 は再生 Spec §6）: TP6（facade の一覧が DTO。I-S3b2 → I-T4）、TP7（学習の中継 3 本。既存 → I-T9）、TP8（`PlaybackSession` が遷移の決定を持つ。I-S3b1 → I-T11）、TP9（旧 VM が `PlaybackQueue<Podcast>`。I-T2a → I-S3b2）、TP10（依存の検査の許可リスト。I-T1 → I-T12）、TP11（既定引数の adapter の生成。既存 → I-S3b3（`SettingsViewModel`）・I-T12）。
- 判断待ち: 無い（TA Spec §10.3 の 1 = 難易度ラベルは SG-D8 で (a) 現状維持に確定）。投入を止めているのは backend B-S5b の契約（I-S5・I-T7c・I-T12）と、再開ゲート。

## 投入順と release トリガ（takt の実挙動 2026-09-23: submodule PR の merge 後、親ポインタ PR が main に入ってから次を release する）

上の表の「順」のとおり 1 本ずつ投入する。release トリガは「依存 slice の ios PR が main に merge 済み ＋ 親ポインタ PR が main に入っている（`git -C <親> submodule status` で `ios` に `+` が無い）」。他 module への依存は PR 番号ではなく「契約が main にあること」で書く（I-S5 ← backend B-S5a・B-S5b。親ポインタが backend の該当 main を指していること = `backend` に `+` が無い）。並行可の組（I-T2a ∥ I-T2b、I-T4 ∥ I-T5、I-S4 ∥ I-S5、I-T6 ∥ I-S5、I-T7a ∥ I-T7b、I-T11 ∥ ほか）も投入は直列で、後から merge する側が rebase する。

各 order の「前提・着手条件」は「依存 slice の submodule PR が main に merge 済み **かつ** 親リポのポインタが進んでいる」を必ず含む。

**`unresolved`: 無し**（2026-10-01。order は TA Spec と承認済みの決定どおりで、未決の選択を含まない。投入を止める外部条件は B-S5b と再開ゲート）

## 経緯の記録（2026-09-23〜2026-09-30）

以下は経緯の記録で、当時の値のまま残す。2026-10-01 の補正で置き換わった記述（I-S3b1 の新規 6 本 → 9 本と `Models/Episode.swift` の削除、`Episode.decode` → `toEpisode()`、alert の合成の置き場 → facade の `alertMessage`、facade の `positionReporter` の公開 → command `flushPosition()`、`downloadingIds` の持ち主 → `OfflineDownloads`、I-S5 の依存「B-S5」→ B-S5a と B-S5b）は、各 order の冒頭の「2026-10-01 … による補正」の節と本文が正しい。

**2026-09-30 夜に user が確定した点**（一問一答。親 docs 監査レポート §5 の SG-C64〜C79）: `partial_failed` は再生不可で、backend も生成側で失敗にする（SG-C64。order は変更なし）。engine を呼ぶ順序（SG-C66）・読み込み中の割り込み（SG-C71）・聴き終えた後の表示（SG-C72）・利用者の開始の優先（SG-C73）は、order の記載どおりで確認済み。巻き戻した位置も送る（SG-C67。I-S3b1・I-S3b2 を直した）。I-S3c は保留（SG-C70）。位置同期の新しい規則（記録時刻の比較・オフライン分の同期・再開時の確認。SG-C74〜C79・親 docs ADR-109）は、backend の B-S7 を先に入れ、iOS は I-S3b3 の後に別の slice を起こす。

**2026-09-24 の order 修正（独立評価の反証への対応。router 導出の小決定）**
- View が `session` を読む経路: Coordinator が `session: PlaybackState` / `presentation` / `queue` を `@Published private(set)` で公開（I-S3b1）→ facade が同名 `@Published private(set)` に転写し `objectWillChange` を接続（I-S3b2）→ View は facade の `session` を直読み（I-S3b3）。View は Coordinator を直接持たない。facade の「固有操作なし」は維持（状態の転写は操作に数えない）。
- Preview: I-S3b1 が `Podcast/Playback/PlaybackCoordinator+Preview.swift`（`#if DEBUG` の `previewParts(session:queue:)`。2026-09-30 に名前と戻り値を改めた）を持ち、I-S3b2 の `PreviewSupport` 置換は capsule を変更せずに済む（新規 6 本）。
- grep の除外範囲: I-S3b3 完了条件 4 は合成 root `NewsListenAppApp.swift` の生成 1 行を除外。I-S3b2 T-T7b は `currentPodcast\s*=[^=]`（`==` 比較を除外）。I-S3b3 完了条件 1 の旧 4 関数名は I-S3a が `AVPlayerEngine` 内でも捨てるため除外不要。
- `errorMessage`: facade 所有の失敗文言は「facade に残る操作（一覧読込・download・removeDownload）の失敗」（実測 `PodcastViewModel.swift:145-227`）。I-S3b2 は `listErrorMessage` に保持し TP3 `errorMessage` で `session` の `errored(reason)` と合成、I-S3b3 は合成を View に移し（alert 1 つ。優先順 = `errored(reason)` → `errorMessage`）`listErrorMessage` を `errorMessage` に改名。理由 → 文言は純関数 `PodcastViewModel.playbackErrorMessage(for:)`（現行文言と同値）。
- `presentation` の所有者は Coordinator（Spec §5 CP4 ops）。facade の `@Published presentation` は転写、`minimizePlayer()` / `expandPlayer()` は 17 操作の `presentation` 遷移の中継として残す。
- 規模: 各 order に production / test の見込み行数を実測基点（`PodcastViewModel.swift` 861 行ほか）で記載。1,000 行の分割基準は巻き戻し範囲 = production に適用（3 段分割の理由と同じ数え方）。

**2026-09-23 夜に確定した判断（旧 `unresolved` を閉じた。各 order の「確定済みの判断」表に転記済み）**
- SG-C10（旧 U-3b3-1）: `PlaybackCoordinator` に `startEpisode(id:)` / `replayCurrent()` を足し公開 17 操作（定義 I-S3b1・中継 I-S3b2・呼出付け替え I-S3b3）。facade は固有操作なし。
- SG-C11（旧 U-3b3-2）: `nowPlaying()` の `NowPlaying` は Android と同型の 7 field（episodeId / displayTitle / japaneseIntroText / segments / vocabulary / quiz / difficulty）。子 View は `NowPlaying` を受け、`Podcast` DTO を View に出さない。
- SG-C14（旧 U-3b3-3）: `NowPlaying` は共通 7 ＋ iOS 固有 2 field（`sourceArticles` / `sourceKind`。ADR-095 の出典・ライセンス表示用）。定義は I-S3b1、`PodcastAttributionContent(nowPlaying:)` への付け替えは I-S3b3。
- SG-C12（旧 U-5-1）: logout 時の `unregisterDeviceToken` client 呼出を削除し B-S5b の連鎖削除に任せる。
- SG-C13: `unavailable` 中の login 成功（`completeLogin`。password / passkey とも唯一の入口）も主体の確定に含め、起動時回収を 1 回走らせる（I-S5 の経路 (v)）。
- **2026-09-30 の前提点検（wave 1 完了後）**: I-S2 の成果に合わせて I-S3a の実測値（78 関数・集合 17）と行番号を直し、再生の停止の扱いを user 判断で確定した（親 docs 監査レポート §5 の SG-C21〜C28）: `AudioEngine` port は `stop` を含む 7 操作（C22）、停止は遷移表の外のリセットで分母 16 は不変・契約 CI-T1b（C24）、I-S3a の間は VM の旗が「読み込み済みか」を持つ = TP5（C23。削除は I-S3b2）、T-T15 の 2 本は engine double の状態を観測（C21・C26）、`MediaPlayerNowPlaying` は App が 1 個作り `AppState` にも渡す（C27）、リモートコマンドの解除は現行どおり VM の `deinit`（C28。後始末へ移すかは I-S3b1 / I-S3b2 で判断）。
- **2026-09-30 の I-S3a 実装時の裁定**: takt の run は実装を終えたが、order の字面では現行の挙動を再現できない 10 点が裁定待ちになり、完了ゲートで止まった。user が推奨案で確定した（親 docs 監査レポート §5 の SG-C29〜C38）。成果は run の worktree から手動でブランチ `task/ios-i-s3a-audio-engine-doubles` へ移して PR にした（ios PR #95。main に merge 済み）。経緯は親 docs `trial-log/i-s3a-order-defects-and-port-gaps.md`。
- **2026-09-30 の I-S3b1 着手前の裁定**: I-S3a で足した事象と戻り値を Session がどう扱うかを user 判断で確定した（親 docs 監査レポート §5 の SG-C39〜C44）: engine の `paused` 事象は `buffering` のときだけ `paused` へ（C39）、`outputDeviceLost` は Session が自分で `paused` へ（C40）、`load` の警告は状態を変えず `start` の結果として 1 回出す（C41）、文言は現行のまま・日本語化は別 slice（C42）、総時間は DTO で初期化し engine の値で置き換え・不明な間は上限で丸めない（C43）、割り込みは一時停止を Session・再開の判断を Coordinator（C44）。分母 16 は不変で、契約 CI-T1c〜T1e を I-S3b1 に、変わる挙動 2 行を I-S3b2 に足した。（この時点で「I-S3b1 の未決は無い」と書いたのは誤りだった。リモートコマンドの解除の契機（SG-C28）が保留のままで、次項の点検で見つかった。）
- **2026-09-30 の wave 3 前提点検と I-S3b1 の書き直し**: 読み取り専用のレビュー役が I-S3b1 を I-S3a の実装と照合し、投入不可と判定した（指摘 #1〜#27。親 docs `research-reports/2026-09-30-wave3-order-premise-check/ios.md`）。user 判断で確定したもの（親 docs 監査レポート §5）: 再生開始は `ready` を待たずに続けて行う（SG-C58）、リモートコマンドは `stopForLogout()` と破棄の両方で解除（SG-C59。SG-C28 の保留を解消）、公開 19 操作（SG-C60）、完聴の送信は順に始めて次の開始は待たない（SG-C61）、手動で開始前に再生不可なら通知だけ（SG-C62）、次へ送り（SG-C63）、取得前の失敗は遷移表の外の操作 `fail`（SG-C52）、総時間の正本（SG-C54）、`setQueue` の重複 id（SG-C50）。order を書く側が決定から導いた宣言は **I-1〜I-23**（監査レポート §5.0 と Spec 冒頭の追記）。主なもの: 開始で engine を呼ぶ順序は「読み込み → seek → 再生 → 速度」（`AVPlayer.play()` が速度を 1.0 に戻すことを実測。I-1）、engine の test double を実 adapter と同じ振る舞いにする（I-2）、Coordinator は閉じられる通知 `notice` を 1 つ持つ（I-6）、待ちが終わってから状態を変える（I-7）、位置の送信の規則（I-9）、保存庫の操作（I-10）。I-S3b2・I-S3b3 を追随させ、I-S3c を新設した。I-S3b1 は書き直しの後、別のレビュー役の再点検を受けた（判定は「条件つきで可」。Blocker なし、指摘 F1〜F21。記録は親 docs `research-reports/2026-09-30-wave3-order-premise-check/ios-recheck.md`）。指摘は同日に I-S3b1・I-S3b2・I-S3b3 へ反映した（I-21 読み込み中の割り込みでも一時停止する、I-22 読み込み中のシークを受ける、I-23 利用者の操作を自動より優先する、ほか）。
- Selection Gate SG-X1〜X5 は 2026-09-16 に確定、SG-X3 は 2026-09-23 に ADR-104 で改訂（待たない＋主体識別）。iOS に効くのは SG-X1（I-S3b2）・SG-X4（I-S3b2 で pin）・SG-X5（I-S4）・SG-X3 revised（I-S2・I-S5）・SG-A1（I-S5）。
- 他モジュールとの契約: パスワード規則は ADR-101 の **12〜20**（Spec 本文の 8〜20 は採らない）。`user_id` は B-S5a が `/auth/me` と login 応答に載せる（ADR-104 決定 15）。logout の明示ヘッダ（決定 14）は新ヘッダを作らず、破棄前に捕捉したトークンで既存 `Authorization: Bearer` を付けて送る（2026-09-23 user 判断）。`user_id` 欠落・形式不正はキャッシュ無効＋回収は未認証と同じ（決定 16 を 3 platform 共通に）。`error_message` の文言写像（ADR-102。値域は ADR-108 / SG-C64 で 3 値）は iOS 次サイクル（RO-c）で scope 外。
- `docs/trial-log/` の `player-auto-converge.md`・`transcript-sync-highlight.md`・`mino-design-review-delegation.md`（棄却した案）は I-S3b1〜I-S3b3 の着手前に読み、棄却済み案を再試行しない。

## takt への投入手順（親リポ `news-listen` の作業ツリーで）

order はサブモジュール内の docs にあるが、takt のタスク単位は親リポ（`.takt/config.yaml` の `submodules: all`）。order 本文をタスク内容として渡す。

```bash
# 例: I-S3b1
takt add -w sdd-governed -b takt/refactor/ios-s3b1-playback-domain \
  -t "$(cat ios/docs/plan/2026-09-16-design-review-refactor/I-S3b1-playback-domain.md)"
takt run
```

- ブランチ名は `takt/refactor/ios-<slice>`。1 slice = 1 タスク = 1 PR（サブモジュール PR → 親 PR。**draft は作らない**。`.takt/facets/knowledge/project-context.md`）。
- 前 slice の submodule PR が main に merge され、**親リポのポインタ PR も main に入ってから**次を投入する（takt の worktree は親 main から clone し、bootstrap が submodule と親の記録の一致を検査するため。上の「投入順と release トリガ」）。
- **投入前に、指示書の「着手前の前提点検」を実行して値を確かめ（冒頭「投入前の前提点検が必須」）、指示書を `analyze_order` の受入検査（全称命題の対象集合の数え上げ／条項どうしの矛盾／未決の選択／依存で結ばれた指示書の対の突き合わせ）へ自分で通す。** 未決が 1 件でも残っていれば投入しない（親 docs `trial-log/order-acceptance-inspection-finds-design-defects.md`）。
- analyze_order は order を「承認済み指示書」として**検証モード**で受ける。generate_spec の `spec.md` / `plan.md` は Spec の該当 slice の契約（CI-T*）の抜粋で足り、新しい契約 ID を作らない。
- 各 order の「特性テスト（baseline）」が green でなければ着手しない。
- 検証コマンドは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`（ios README「テスト」の現行の形式。`scripts/test.sh` が利用可能な iPhone シミュレータを選び `-only-testing:NewsListenAppTests` で走らせる。機種は `SIMULATOR='iPhone 16'` で指定できる）。2026-09-16 の `verification-run.md` §1 の「`make test` は不可」は、`DEVELOPER_DIR` を指定しない環境での記録。

## 完了後

- 各 slice の merge 後、`docs/trial-log/` に棄却・方針転換があれば追記（takt の record_trial_log が行う）。各 order の「記録」節にある親 docs への返却事項（共有仕様 §4.3 / §4.4 の保留解除・§6.3 iOS 行・ios-design §4 / §8 / §11.3）を router へ渡す。
- 親 docs へ今すぐ返す drift（2026-09-23 夜の切り直し）: `ios-design.md` §11.3 の I-S3a 行を「port＋adapter 2 本＋VM の port 経由化（挙動不変）・15 関数」へ、I-S3b2 行から `Podcast/Platform/{…}` を外す。Spec §6 S3a / S3b 行も同じ。→ **済み**（2026-09-30。`ios-design.md` §11.3 は反映済み。Spec §6 は I-* の表へ直し、関数数は 2026-09-30 再実測の 17。Spec は本文を直して改訂履歴に残す運用に変えた）。
- 親 docs へ返す drift（SG-C10 / C11 の反映後）: `ios-design.md` §11.2 の 17 操作の表記 `startEpisode(episode:…)` は Spec §3.1・I-S3b1 の `startEpisode(_:expandsPlayer:)` と同じ操作（ラベル違い。Spec の表記に揃える）。Spec §5 CP4 の ops 15 と §3.1 の `nowPlaying()` 記述（title / difficulty / duration / position / 状態）は SG-C10 / C11 で 17 操作・7 field に更新が要る。→ **済み**（2026-09-30。Spec §5 CP4 は SG-C60 を含めて 19 操作、§3.1 は共通 7 ＋ iOS 固有 2 field）。SG-C14 により `ios-design.md` §11.2・共有仕様 §6.8 の「7 field」を「共通 7 ＋ iOS 固有 2（`sourceArticles` / `sourceKind`。出典表示）」へ。
- 全 slice 完了で本フォルダを削除し、親 docs `design/ios-design.md` §4〜§8 を target の内容へ書き換え、§11 を削除する。
