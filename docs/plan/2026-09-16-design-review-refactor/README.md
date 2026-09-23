# iOS リファクタ計画（2026-09-16 設計レビュー反映）— takt 委譲用の指示書

2026-09-16 の iOS 設計レビュー（`docs/research-reports/2026-09-16-code-design-review.md`）と user 承認済みの Implementation Spec（`docs/design/2026-09-16-implementation-spec-playback-domain-model.md`）、2026-09-23 の主体離脱の設計決定（親 docs `docs/adr/104-subject-departure-and-subject-scoped-assets.md`）を、takt の `sdd-governed` ワークフローへ slice 単位で委譲するための指示書（order）一式。正本は Spec と ADR-104 であり、本フォルダの各 order は該当 slice を takt の 1 タスクに切り出したもの。slice ID は親 docs の実行計画 `docs/plan/2026-09-16-design-review-refactor.md`（2026-09-23 再スライス版）の接頭辞付き ID **I-\*** を使う（`docs/design/ios-design.md` §11.3 と同一）。実装完了後、本フォルダは削除し、確定内容は親 docs の `design/ios-design.md`（§4〜§8 を target の内容へ書き換え、§11 を削除）へ移す（`agent-rules/30` の plan ライフサイクル）。

Spec §6 の `S0 spec`（共有仕様の改訂）は **news-listen-docs #133 で main 済み・完了**。本フォルダに order は作らない。

## slice と投入順

| 順 | order | 内容 | 依存 | 検証する行 ID（ios-design §11.3） | 切替方式 |
|---|---|---|---|---|---|
| — | （I-S0 spec） | 共有仕様の改訂 | なし | — | 完了済み（news-listen-docs #133） |
| 1 | [S1-failure-meaning.md](S1-failure-meaning.md)（完了） | `ApiFailure`・`validateResponse` の変換・`notFound.subject`・非 HTTP 応答・`FailureMessages`。10 消費者の置換 | なし | CI-T12 / T13 | 旧 `APIError` 互換 throw（TP1）を暫定保持（削除条件: `Networking/` 以外に参照 0） |
| 2 | [I-S2-session-boundary.md](I-S2-session-boundary.md) | `AuthSession` union・失効検知・`SubjectCleanup` の骨格・`PreferenceRegistry`・`NowPlayingCenter` port（clear の最小） | S1 | SL-01〜SL-05（音声キャッシュ部分は I-S5 まで `clearAll()`） | TP2（`SettingsViewModel` の既定引数）・TP4（`PodcastViewModel` が `PlaybackLifecycle` を暫定実装）を導入。削除条件はどちらも I-S3b2 で成立、物理削除は I-S3b3 |
| 3 | [I-S3a-audio-engine-doubles.md](I-S3a-audio-engine-doubles.md) | `AudioEngine` port と double を導入し、`PodcastViewModelTests` の AVFoundation 直結 17 関数を double 駆動へ移植。production の挙動変更なし | I-S2 | —（全件 green が I-S3b1 の入口条件） | 小ステップ |
| 4 | [I-S3b1-playback-domain.md](I-S3b1-playback-domain.md) | `Podcast/Playback/{Session,Coordinator,OfflineLibrary,PositionReporter}` と `Models/Episode.swift` のドメイン層新設。既存コードから呼ばない | I-S3a | RS-01〜RS-07（CI-T3）・PS-04（CI-T7a）。契約テスト CI-T1/T2/T4/T5/T6/T8/T10/T11 | ① 新規コードのみ |
| 5 | [I-S3b2-playback-entry.md](I-S3b2-playback-entry.md) | `Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}`・合成 root・facade 化・`startEpisode` 1 経路・`PlaybackQueue` dedupe・`Episode` 切替・View 2 箇所・Preview。共有仕様 §2・Q-* は挙動不変。変わる挙動は右列の行のみ | I-S3b1 | PS-01〜PS-03（CI-T6）・PS-04（CI-T7 / T-T7b）・PS-05 / PS-05b / PS-06（CI-T8。SG-X1 / SG-X4）・PS-07（CI-T11）・PS-08（CI-T4）・CI-T9 / T9b | ② 入口の差し替え。TP3（旧公開プロパティ 8 の computed）を導入。TP2 / TP4 の削除条件成立 |
| 6 | [I-S3b3-playback-cleanup.md](I-S3b3-playback-cleanup.md) | `PodcastViewModel` の縮小（TP3・`didFinishCurrentEpisode` / `downloadedIds`・forwarder 7・旧 engine 由来 6）・TP2 / TP4 の物理削除・View 読出の付け替え | I-S3b2 | —（参照 0 件の grep 8 本。契約テスト件数は減らさない） | ③ 削除のみ |
| 7 | [I-S4-rules-ci.md](I-S4-rules-ci.md) | `PasswordPolicy`（12〜20、ADR-101）・`AccountSettingsViewModel` 新設・`AdminUsersViewModel` の policy 参照・既定速度 Picker を 8 段へ（SG-X5）・`ci.yml` を `make test` 呼出へ | I-S3b3 | CI-T16 | 小ステップ |
| 8 | [I-S5-subject-cache.md](I-S5-subject-cache.md) | 主体別音声キャッシュ `Caches/NewsListenApp/audio/{user_id}/`・起動時の回収・平置きキャッシュの初回全削除（SG-A1）・ダウンロードジョブの主体固定・遷移 ④・logout の明示ヘッダ（ADR-104 決定 14・26） | **B-S5**（`user_id` の公開）＋ I-S4 | SL-06 / SL-07・SL-01 / SL-02 の音声キャッシュ部分（CI-T10 / T15） | 不可逆点（キャッシュ構造の変更。移行なし） |
| 保留 | （views） | `QuizSheetView` の採点 VM 化・構造整理のみ（View の `nowPlaying()` / `session` 直読み化は I-S3b3 で完了） | I-S3b3 | — | order 未作成（学習機能のサイクルまで。ios-design §11.3「保留 views」行と同一） |

- 依存の連鎖: **I-S2 → I-S3a → I-S3b1 → I-S3b2 → I-S3b3 → I-S4**（iOS 内は直列）。**I-S5 は B-S5 の merge 後**（クリティカルパス W-0 → B-S4 → B-S5 → I-S5。親 plan「クリティカルパス」）。
- 3 段分割の理由（親 plan 2026-09-23）: 旧 `S3b-playback.md` は一括切替で、入口条件が slice の外側でしか判定できず巻き戻しが 1,000 行超だった。① は特性テストに依存せず着手でき、② は「挙動不変（特性テスト）＋変更行（準拠テスト）」で判定でき、③ は数え上げられる。
- Selection Gate SG-X1〜X5 は 2026-09-16 に確定、SG-X3 は 2026-09-23 に ADR-104 で改訂（待たない＋主体識別）。iOS に効くのは SG-X1（I-S3b2）・SG-X4（I-S3b2 で pin）・SG-X5（I-S4）・SG-X3 revised（I-S2・I-S5）・SG-A1（I-S5）。
- 他モジュールとの契約: パスワード規則は ADR-101 の **12〜20**（Spec 本文の 8〜20 は採らない）。`user_id` は B-S5 が `/auth/me` と login 応答に載せる（ADR-104 決定 15）。logout の明示ヘッダ（決定 14）は新ヘッダを作らず、破棄前に捕捉したトークンで既存 `Authorization: Bearer` を付けて送る（2026-09-23 user 判断）。`user_id` 欠落・形式不正はキャッシュ無効＋回収は未認証と同じ（決定 16 を 3 platform 共通に）。`error_message` 4 値の文言写像（ADR-102）は iOS 次サイクル（RO-c）で scope 外。
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
- 前 slice の PR が main に merge されてから次を投入する（takt の worktree は main を基点に clone するため）。
- **投入前に、指示書を `analyze_order` の受入検査（全称命題の対象集合の数え上げ／条項どうしの矛盾／未決の選択）へ自分で通す。** 未決が 1 件でも残っていれば投入しない（親 docs `trial-log/order-acceptance-inspection-finds-design-defects.md`）。
- analyze_order は order を「承認済み指示書」として**検証モード**で受ける。generate_spec の `spec.md` / `plan.md` は Spec の該当 slice の契約（CI-T*）の抜粋で足り、新しい契約 ID を作らない。
- 各 order の「特性テスト（baseline）」が green でなければ着手しない。
- 検証コマンドは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:NewsListenAppTests`（`make test` は現行環境で不可。`docs/research-reports/2026-09-16-code-design-review/verification-run.md` §1 参照）。

## 完了後

- 各 slice の merge 後、`docs/trial-log/` に棄却・方針転換があれば追記（takt の record_trial_log が行う）。各 order の「記録」節にある親 docs への返却事項（共有仕様 §4.3 / §4.4 の保留解除・§6.3 iOS 行・ios-design §4 / §8 / §11.3）を router へ渡す。
- 全 slice 完了で本フォルダを削除し、親 docs `design/ios-design.md` §4〜§8 を target の内容へ書き換え、§11 を削除する。
