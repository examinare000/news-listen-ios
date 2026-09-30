# iOS リファクタ計画（2026-09-16 設計レビュー反映）— takt 委譲用の指示書

2026-09-16 の iOS 設計レビュー（`docs/research-reports/2026-09-16-code-design-review.md`）と user 承認済みの Implementation Spec（`docs/design/2026-09-16-implementation-spec-playback-domain-model.md`）、2026-09-23 の主体離脱の設計決定（親 docs `docs/adr/104-subject-departure-and-subject-scoped-assets.md`）を、takt の `sdd-governed` ワークフローへ slice 単位で委譲するための指示書（order）一式。正本は Spec と ADR-104 であり、本フォルダの各 order は該当 slice を takt の 1 タスクに切り出したもの。slice ID は親 docs の実行計画 `docs/plan/2026-09-16-design-review-refactor.md`（2026-09-23 再スライス版）の接頭辞付き ID **I-\*** を使う（`docs/design/ios-design.md` §11.3 と同一）。実装完了後、本フォルダは削除し、確定内容は親 docs の `design/ios-design.md`（§4〜§8 を target の内容へ書き換え、§11 を削除）へ移す（`agent-rules/30` の plan ライフサイクル）。

Spec §6 の `I-S0 spec`（旧 S0。共有仕様の改訂）は **news-listen-docs #133 で main 済み・完了**。本フォルダに order は作らない。

## slice と投入順

| 順 | order | 内容 | 依存 | 検証する行 ID（ios-design §11.3） | 切替方式 |
|---|---|---|---|---|---|
| — | （I-S0 spec） | 共有仕様の改訂 | なし | — | 完了済み（news-listen-docs #133） |
| 1 | [S1-failure-meaning.md](S1-failure-meaning.md)（I-S1。完了。ios PR #84） | `ApiFailure`・`validateResponse` の変換・`notFound.subject`・非 HTTP 応答・`FailureMessages`。10 消費者の置換 | なし | CI-T12 / T13 | 旧 `APIError` 互換 throw（TP1）は本 slice の中で削除済み（削除条件「`Networking/` 以外に参照 0」が成立。2026-09-30 実測: production の `APIError` は 0 件） |
| 2 | [I-S2-session-boundary.md](I-S2-session-boundary.md)（完了。ios PR #91） | `AuthSession` union・失効検知・`SubjectCleanup` の骨格・`PreferenceRegistry`・`NowPlayingCenter` port（clear の最小） | S1 | SL-01〜SL-05（音声キャッシュ部分は I-S5 まで `clearAll()`） | TP2（`SettingsViewModel` の既定引数）・TP4（`PodcastViewModel` が `PlaybackLifecycle` を暫定実装）を導入。削除条件はどちらも I-S3b2 で成立、物理削除は I-S3b3 |
| 3 | [I-S3a-audio-engine-doubles.md](I-S3a-audio-engine-doubles.md)（完了。ios PR #95） | `AudioEngine` port（`Podcast/Playback/AudioEngine.swift`）と double、**Platform adapter 2 本（`Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}`）**を導入し、現行 `PodcastViewModel` を port 経由化（挙動不変・公開面不変）。engine 結合テスト **17 関数**（2026-09-30 再実測。78 関数中。11 は double 駆動、6 は `AVPlayerEngineTests` へ）を移植 | I-S2 | —（全件 green が I-S3b1 の入口条件） | 挙動不変（特性テスト＋公開面 grep）。**2026-09-23 夜に切り直し**: adapter を I-S3b2 から前倒し（下記「切り直しの理由」） |
| 4 | [I-S3b1-playback-domain.md](I-S3b1-playback-domain.md) | `Podcast/Playback/{Session,Coordinator,OfflineLibrary,PositionReporter}`・`Models/Episode.swift`・DEBUG ファクトリ `PlaybackCoordinator+Preview.swift`（新規 6 本）のドメイン層新設。Coordinator は公開 **19 操作**（SG-C10 の `startEpisode(id:)` / `replayCurrent()`、SG-C60 の `minimizePlayer` / `expandPlayer` を含む）と `NowPlaying`（Android と同型の 7 field ＋ iOS 固有 2。SG-C11 / C14）を持ち、`session`（`PlaybackState`）/ `presentation` / `queue` / `notice` / `isAdvancing` を `@Published private(set)` で read-only 公開する（操作に数えない）。engine の test double を実 adapter と同じ振る舞いに直す。既存コードから呼ばない。**2026-09-30 に全面的に書き直した**（型・操作・手順・状態 × 事象の表を order が固定） | I-S3a | RS-01〜RS-07（CI-T3）・PS-04（CI-T7a）。契約テスト CI-T1 / T1b〜T1f / T2 / T3 / T4 / T5 / T6 / T7 / T8 / T10 / T11 | ① 新規コードのみ |
| 5 | [I-S3b2-playback-entry.md](I-S3b2-playback-entry.md) | 合成 root（`OfflineLibrary`・Coordinator・PositionReporter。主体離脱の全削除も保存庫を通す）・facade 化（Coordinator の `session` / `presentation` / `notice` を同名 `@Published` に写す。View は Coordinator を持たない）・`startEpisode` 1 経路・`PlaybackQueue` dedupe・`Episode` 切替・View 2 箇所・Preview（I-S3b1 の DEBUG ファクトリ経由）・`SettingsViewModel` / `SettingsView` へ `OfflineLibrary` 注入（production 9 本）。共有仕様 §2・Q-* は挙動不変。変わる挙動は order の表の 14 行だけ（2026-09-30 に数え上げ直した）。**決定境界は「入口の差し替え」1 つ**（adapter は I-S3a） | I-S3b1 | PS-01〜PS-03（CI-T6）・PS-04（CI-T7 / T-T7b）・PS-05 / PS-05b / PS-06（CI-T8。SG-X1 / SG-X4）・PS-07（CI-T11）・PS-08（CI-T4）・CI-T9 / T9b | ② 入口の差し替え。TP3（旧公開プロパティ 8 の computed）を導入。TP2（型を `OfflineLibrary` に変えて既定引数のまま）/ TP4 の削除条件成立 |
| 6 | [I-S3b3-playback-cleanup.md](I-S3b3-playback-cleanup.md) | `PodcastViewModel` の縮小（TP3・`didFinishCurrentEpisode` / `downloadedIds`・forwarder 7・旧 engine 由来 2）・TP2 / TP4 の物理削除・View 読出の付け替え（44 箇所（2026-09-24 再実測: `PodcastView` の `errorMessage` 3 のうち 2 は書込で I-S3b2 が置換済み）。呼出形は SG-C10、子 View は `NowPlaying` を受け `Podcast` DTO を出さない = SG-C11、transport は facade が写した `session` を直読み）。エラー alert は 1 つのまま View で合成（facade が写した `notice` → facade の `errorMessage`） | I-S3b2。未決なし（U-3b3-3 は SG-C14 で確定） | —（参照 0 件の grep 9 本。契約テスト件数は減らさない） | ③ 削除のみ |
| 保留 | [I-S3c-remote-next-track.md](I-S3c-remote-next-track.md)（2026-09-30 新設・同日に保留。SG-C70） | リモートコマンド「次のトラック」を Coordinator の `skipToNext` につなぐ。待機列が空の間は無効にする（SG-C63）。`NowPlayingCenter` は 6 操作、`RemoteCommand` は 8 種になる | I-S3b3 | —（CI-T7 の抜粋 T-T7h / T-T7i。共有仕様 §2.12） | 小ステップ。I-S4・I-S5 と変更ファイルは重ならない |
| 7 | [I-S4-rules-ci.md](I-S4-rules-ci.md) | `PasswordPolicy`（12〜20、ADR-101）・`AccountSettingsViewModel` 新設・`AdminUsersViewModel` の policy 参照・既定速度 Picker を 8 段へ（SG-X5）・`ci.yml` を `make test` 呼出へ | I-S3b3 | CI-T16 | 小ステップ。**I-S5 と並行可** |
| 8 | [I-S5-subject-cache.md](I-S5-subject-cache.md) | 主体別音声キャッシュ `Caches/NewsListenApp/audio/{user_id}/`・起動時の回収（SG-B3 の 4 経路）・平置きキャッシュの初回全削除（SG-A1）・`user_id` 欠落時はキャッシュ無効（SG-B6）・ダウンロードジョブの主体固定・遷移 ④・logout の明示ヘッダ（ADR-104 決定 14・26）・logout 時の `unregisterDeviceToken` 呼出削除（SG-C12）・`unavailable` 中の login 成功も確定契機（SG-C13） | **backend main の `user_id` 契約**（B-S5a の成果）＋ I-S3b3。未決なし | SL-06 / SL-07・SL-01 / SL-02 の音声キャッシュ部分（CI-T10 / T15） | 不可逆点（キャッシュ構造の変更。移行なし）。**I-S4 と並行可** |
| 保留 | （views） | `QuizSheetView` の採点 VM 化・構造整理のみ（View の `nowPlaying()` / `session` 直読み化は I-S3b3 で完了） | I-S3b3 | — | order 未作成（学習機能のサイクルまで。ios-design §11.3「保留 views」行と同一） |

- 依存の連鎖: **I-S2 → I-S3a → I-S3b1 → I-S3b2 → I-S3b3 → {I-S4 ∥ I-S5}**（I-S3c は保留）。I-S5 はさらに **backend main に `user_id` 契約があること**（B-S5a の成果。クリティカルパスは B-S5a → I-S5 で、B-S5a は依存を持たない。親 plan「クリティカルパス」）。
- 3 段分割の理由（親 plan 2026-09-23）: 旧 `S3b-playback.md` は一括切替で、入口条件が slice の外側でしか判定できず巻き戻しが 1,000 行超だった。① は特性テストに依存せず着手でき、② は「挙動不変（特性テスト）＋変更行（準拠テスト）」で判定でき、③ は数え上げられる。
- **切り直しの理由（2026-09-23 夜の点検）**: 起票時の I-S3a は「`PodcastViewModel.swift` の diff 0」と「AVFoundation 直結テストを double 駆動へ」を同時に要求していたが、対象 15 関数（再実測。Spec の 17 はコメント行の一致 2 件を含む数）のうち 14 は VM の公開 API を AVFoundation 型で駆動しており、VM が port を消費しない限り double で駆動できない（条項の相互矛盾）。Platform adapter 2 本と VM の port 経由化（挙動不変）を I-S3a へ前倒しし、I-S3b2 は facade 化 1 境界に絞った。これに伴い親 docs `ios-design.md` §11.3 の I-S3a / I-S3b2 行と Spec §6 S3a / S3b 行の adapter 所属、I-S2 本文の「`update` / `registerCommands` の port 化は I-S3b2」が本 README と食い違う（router へ返す。I-S2 は投入済みのため本文は直さない）。**2026-09-30 追記**: `ios-design.md` §11.3 は反映済み。Spec §6 は同日に I-* の表へ直した（関数数は 2026-09-30 再実測の 17）。

## 投入順と release トリガ（takt の実挙動 2026-09-23: submodule PR の merge 後、親ポインタ PR が main に入ってから次を release する）

| 順 | order | 依存 | release トリガ（submodule PR が main ＋ 親ポインタが進む） | 並行可能な組 |
|---|---|---|---|---|
| 1 | I-S2（完了。ios PR #91・2026-09-28） | S1（完了） | — | — |
| 2 | I-S3a（完了。ios PR #95・2026-09-30） | I-S2 | I-S2 の ios PR merge → 親ポインタ PR merge（`git -C <親> submodule status` で `ios` に `+` 無し） | — |
| 3 | I-S3b1 | I-S3a | I-S3a の ios PR → 親ポインタ | — |
| 4 | I-S3b2 | I-S3b1 | I-S3b1 の ios PR → 親ポインタ | — |
| 5 | I-S3b3 | I-S3b2（SG-C10 / C11 / C14 は確定済み。未決なし） | I-S3b2 の ios PR → 親ポインタ | — |
| 保留 | I-S3c（投入しない。SG-C70） | I-S3b3 | I-S3b3 の ios PR → 親ポインタ | I-S4・I-S5 と変更ファイルは重ならない（I-S3c = `Podcast/Platform/{NowPlayingCenter,MediaPlayerNowPlaying}`・`Podcast/Playback/PlaybackCoordinator(+Preview)`）。同じ submodule なので投入は直列が無難 |
| 6a | I-S4 | I-S3b3 | I-S3b3 の ios PR → 親ポインタ | I-S5 と並行（変更ファイルが重ならない: I-S4 = `Auth/PasswordPolicy`・`Settings/AccountSettingsViewModel`・`Settings/AccountSettingsView`・`Settings/SettingsView`・`Admin/*`・`ci.yml`・`scripts/test.sh`、I-S5 = `Models/AuthModels`・`Networking/AudioCacheManager`・`Podcast/Playback/OfflineLibrary`・`Auth/SubjectCleanup`・`AppState`・`Settings/SettingsViewModel`。後から merge する側が rebase する） |
| 6b | I-S5 | I-S3b3 ＋ backend main の `user_id` 契約（B-S5a）。未決なし（U-5-1 は SG-C12 で確定） | I-S3b3 の ios PR → 親ポインタ、**かつ** B-S5a の backend PR → 親ポインタ（`backend` に `+` 無し） | 同上 |

各 order の「前提・着手条件」は「依存 slice の submodule PR が main に merge 済み **かつ** 親リポのポインタが進んでいる（`git -C <親> submodule status` で `+` が無い）」を必ず含む。他 module への依存（I-S5 ← B-S5a）は PR 番号ではなく「契約が main にあること」で書く。

**`unresolved`: 無し**（2026-09-30。order は承認済みの定義どおりで、未決の選択を含まない）

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
- **投入前に、指示書を `analyze_order` の受入検査（全称命題の対象集合の数え上げ／条項どうしの矛盾／未決の選択）へ自分で通す。** 未決が 1 件でも残っていれば投入しない（親 docs `trial-log/order-acceptance-inspection-finds-design-defects.md`）。
- analyze_order は order を「承認済み指示書」として**検証モード**で受ける。generate_spec の `spec.md` / `plan.md` は Spec の該当 slice の契約（CI-T*）の抜粋で足り、新しい契約 ID を作らない。
- 各 order の「特性テスト（baseline）」が green でなければ着手しない。
- 検証コマンドは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:NewsListenAppTests`（`make test` は現行環境で不可。`docs/research-reports/2026-09-16-code-design-review/verification-run.md` §1 参照）。

## 完了後

- 各 slice の merge 後、`docs/trial-log/` に棄却・方針転換があれば追記（takt の record_trial_log が行う）。各 order の「記録」節にある親 docs への返却事項（共有仕様 §4.3 / §4.4 の保留解除・§6.3 iOS 行・ios-design §4 / §8 / §11.3）を router へ渡す。
- 親 docs へ今すぐ返す drift（2026-09-23 夜の切り直し）: `ios-design.md` §11.3 の I-S3a 行を「port＋adapter 2 本＋VM の port 経由化（挙動不変）・15 関数」へ、I-S3b2 行から `Podcast/Platform/{…}` を外す。Spec §6 S3a / S3b 行も同じ。→ **済み**（2026-09-30。`ios-design.md` §11.3 は反映済み。Spec §6 は I-* の表へ直し、関数数は 2026-09-30 再実測の 17。Spec は本文を直して改訂履歴に残す運用に変えた）。
- 親 docs へ返す drift（SG-C10 / C11 の反映後）: `ios-design.md` §11.2 の 17 操作の表記 `startEpisode(episode:…)` は Spec §3.1・I-S3b1 の `startEpisode(_:expandsPlayer:)` と同じ操作（ラベル違い。Spec の表記に揃える）。Spec §5 CP4 の ops 15 と §3.1 の `nowPlaying()` 記述（title / difficulty / duration / position / 状態）は SG-C10 / C11 で 17 操作・7 field に更新が要る。→ **済み**（2026-09-30。Spec §5 CP4 は SG-C60 を含めて 19 操作、§3.1 は共通 7 ＋ iOS 固有 2 field）。SG-C14 により `ios-design.md` §11.2・共有仕様 §6.8 の「7 field」を「共通 7 ＋ iOS 固有 2（`sourceArticles` / `sourceKind`。出典表示）」へ。
- 全 slice 完了で本フォルダを削除し、親 docs `design/ios-design.md` §4〜§8 を target の内容へ書き換え、§11 を削除する。
