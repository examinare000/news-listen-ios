# iOS リファクタ計画（2026-09-16 設計レビュー反映）— takt 委譲用の指示書

2026-09-16 の iOS 設計レビュー（`docs/research-reports/2026-09-16-code-design-review.md`）と user 承認済みの Implementation Spec（`docs/design/2026-09-16-implementation-spec-playback-domain-model.md`）を、takt の `sdd-governed` ワークフローへ slice 単位で委譲するための指示書（order）一式。正本は Spec であり、本フォルダの各 order は Spec の該当 slice を takt の 1 タスクに切り出したもの。実装完了後、本フォルダは削除し、確定内容は親 docs の `design/ios-design.md`（§4〜§8 を target の内容へ書き換え、§11 を削除）へ移す（`agent-rules/30` の plan ライフサイクル）。

Spec §0 の `S0 spec`（共有仕様 `docs/design/shared-playback-spec.md` の改訂: §2.11「advance 後の再生失敗は停止」・§2.7 操作名対応表・§6.3 iOS 欄の実装名改訂）は **news-listen-docs #133 で main 済み・完了**。本フォルダに order は作らない。

## slice と投入順

| 順 | order | 内容 | 依存 | Selection Gate | 切替方式 |
|---|---|---|---|---|---|
| — | （S0 spec） | 共有仕様の改訂 | なし | なし | 完了済み（news-listen-docs #133） |
| 1 | [S1-failure-meaning.md](S1-failure-meaning.md) | `ApiFailure`・`validateResponse` の変換・`notFound.subject`・非 HTTP 応答・`FailureMessages`。10 消費者の置換 | なし | なし | 旧 `APIError` 互換 throw（TP1）を暫定保持 |
| 2 | [S2-session-boundary.md](S2-session-boundary.md) | `AuthSession` union・失効検知・`SubjectCleanup`・`PreferenceRegistry`・`NowPlayingCenter` port（clear の最小） | S1 | SG-X3 確定: 待たない（iOS 現行どおり） | TP2（`SettingsViewModel` の既定引数）・TP4（`PodcastViewModel` が `PlaybackLifecycle` を暫定実装）を暫定保持 |
| 3 | [S3a-audio-engine-doubles.md](S3a-audio-engine-doubles.md) | `AudioEngine` port と double を導入し、`PodcastViewModelTests` の AVFoundation / `vm.player` / KVO 直結の 17 関数を double 駆動へ移植（68 中）。production の挙動変更なし | S2 | なし | 小ステップ（17 関数のみ移植・残り 51 は不変） |
| 4 | [S3b-playback.md](S3b-playback.md) | `Podcast/Playback/{Session,Coordinator,OfflineLibrary,PositionReporter}`・`Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}`・`PlaybackQueue` dedupe・`Episode` decode・facade 化・`startEpisode` 1 経路・署名 URL 再取得・速度初期化・advance 失敗の停止・INV-P1 | S3a（17 関数移植・68 green が入口条件） | SG-X1 確定: 完聴時に `duration` を明示送信（S3b で実装）・SG-X3 確定: 待たない・SG-X4 確定: 一時停止中は送らない（iOS 現行どおり） | **一括切替**（S3a の 68 green ＋特性テスト移植が入口条件） |
| 5 | [S4-rules-ci.md](S4-rules-ci.md) | `PasswordPolicy`（12〜20、ADR-101）・`AccountSettingsViewModel` 新設・`AdminUsersViewModel` の policy 参照・設定画面の既定速度 Picker を 8 段へ（SG-X5）・`ci.yml` を `make test` 呼出へ | S3b | SG-X5 確定: 8 段 | 小ステップ |
| 保留 | （S5 views） | `QueueSheet` / `PodcastView` / `MiniPlayerView` / `AudioPlayerView` を `nowPlaying()` / `session` 直読みへ、TP3 の削除、`QuizSheetView` の VM 化 | S4 | — | order 未作成 |

- 共有仕様 §6.7 の Selection Gate SG-X1〜X5 は 2026-09-16 に全て確定済み（確定値は §6.4〜§6.6 本文）。iOS に効くのは SG-X1（完聴時に `duration` を明示送信）・SG-X5（設定画面の Picker を 8 段へ）。SG-X3 / SG-X4 は iOS の現行どおり。
- 他モジュールとの契約: S4 のパスワード規則は `docs/adr/101-password-policy-cross-client-unification.md` の **12〜20 文字**（Spec 本文 §3.3 の「8〜20」は backend 決定で差し戻された旧値のため採らない）。`error_message` 4 値の文言写像（ADR-102）は iOS の次サイクル（RO-c）であり本計画の scope 外。
- `docs/trial-log/` の `player-auto-converge.md`・`transcript-sync-highlight.md` は S3b の再生・View 挙動に関係するため、S3b 着手前に読み棄却済み案を再試行しない。

## takt への投入手順（親リポ `news-listen` の作業ツリーで）

order はサブモジュール内の docs にあるが、takt のタスク単位は親リポ（`.takt/config.yaml` の `submodules: all`）。order 本文をタスク内容として渡す。

```bash
# 例: S1
takt add -w sdd-governed -b takt/refactor/ios-s1-failure-meaning \
  -t "$(cat ios/docs/plan/2026-09-16-design-review-refactor/S1-failure-meaning.md)"
takt run
```

- ブランチ名は `takt/refactor/ios-<slice>`。1 slice = 1 タスク = 1 PR（サブモジュール PR → 親の draft PR の順。`.takt/facets/knowledge/project-context.md`）。
- 前 slice の PR が main に merge されてから次を投入する（takt の worktree は main を基点に clone するため）。
- analyze_order は order を「承認済み指示書」として**検証モード**で受ける。generate_spec の `spec.md` / `plan.md` は Spec の該当 slice の契約（CI-T*）の抜粋で足り、新しい契約 ID を作らない。
- 各 order の「特性テスト（baseline）」が green でなければ着手しない（bootstrap_worktree のベースライン verify とは別に、slice 固有の baseline）。
- 検証コマンドは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:NewsListenAppTests`（509 tests。`make test` は現行環境で不可。`docs/research-reports/2026-09-16-code-design-review/verification-run.md` §1 参照）。

## 完了後

- 各 slice の merge 後、`docs/trial-log/` に棄却・方針転換があれば追記（takt の record_trial_log が行う）。
- 全 slice 完了で本フォルダを削除し、親 docs `design/ios-design.md` §4〜§8 を target の内容へ書き換え、§11 を削除する。
