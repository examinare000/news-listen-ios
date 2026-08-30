# トランスクリプト同期ハイライトの main 再着地（transcript-sync-highlight）

## 2026-08-30 スタック迷子の検出と再着地

- **目的**: 「仕掛中」とされていたトランスクリプト同期ハイライトの実際の進捗を確定する。
  **前提**: PR #77（feature/transcript-sync-highlight）は GitHub 上 MERGED 表示。
  **やったこと**: `gh pr view 77 --json baseRefName,mergeCommit` と `git merge-base --is-ancestor 87f85ad origin/main` で実測。
  **結果**: PR #77 の base は `feature/global-mini-player`、PR #76 の base は `feature/global-playback-continuity` だった。base の PR #75 が先に main へマージされたためスタックが宙に浮き、**#76/#77 のどちらも main へ到達していなかった**（`is-ancestor` → false、`origin/main` に `TranscriptTiming.swift` / `MiniPlayerView.swift` が存在しない）。MERGED 表示だけを根拠にすると「実装済み」と誤認する典型例。

- **目的**: 再着地の安全性を事前に判定する。
  **前提**: main 側は PR #78（featured-categories）が後から入っている。
  **やったこと**: `git merge-tree $(git merge-base origin/main origin/feature/global-mini-player) origin/feature/global-mini-player origin/main` でドライラン。
  **結果**: コンフリクト 0。main 側の後続差分は Onboarding / Settings / Featured 系のみで、Podcast 配下と重ならないことを確認。

- **目的**: main ベースへ再着地させる。
  **やったこと**: `origin/main`（`c792fae`）起点で `feat/reland-mini-player-transcript-highlight` を作成し、`origin/feature/global-mini-player`（`f6e788f`）を `--no-ff` でマージ（`9e23355`）。
  **結果**: コンフリクトなし。`git merge-base --is-ancestor 87f85ad HEAD` → true。4 コミット（ミニプレイヤー 2・トランスクリプト 2）が 1 本で乗った。
  **粒度の判断**: 1ブランチ1目的の原則では分割が理想だが、`87f85ad` の `AudioPlayerView` 変更はミニプレイヤーの `PlayerSheetView` 前提の上に乗っており、切り離すと再実装になる。「落ちた #76/#77 スタックの再着地」を 1 目的として扱った。

## 検証

- **ユニットテスト**: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination "platform=iOS Simulator,id=14BBBBE4-70F0-47BF-9BFF-517D7F6B1AF7" -only-testing:NewsListenAppTests`
  → `** TEST SUCCEEDED **`、**Executed 492 tests, with 0 failures**（うち `TranscriptTimingTests` 13 件）。
  シミュレータ関連の XPC がサンドボックスで遮断されるため、この実行のみサンドボックス外で行った。

- **`simctl list devices` が空を返す件**: `xcode-select -p` が `/Library/Developer/CommandLineTools` を指すため。`DEVELOPER_DIR` の上書きで解消（memory `ios-xcodebuild-without-sudo` と同型）。同名シミュレータが重複しているため `name=` ではなく `id=<UDID>` 指定が確実。

## 未実施（人間の確認が必要・引き継ぎ事項）

PR #77 本文が「手動確認項目（未実施・レビュー時に確認要）」と自認していた項目は、**本セッションでも未実施のまま**である。理由: アプリはログインと実バックエンドを経由しないと segments 付きエピソードへ到達できず（モック起動用の launch argument や UI テスト経路が無い）、シミュレータ自動操作で検証できない。

1. 実エピソードでのハイライトと実音声のずれ幅測定、および `EstimatedTranscriptTiming.japaneseCharWeight`（現在 2.0）の調整。イントロ中に点灯するなら値を上げる（手順は `TranscriptTiming.swift` の doc comment に記載）。
2. 手動スクロール中に追従が止まり、約 3 秒で中央へ復帰すること。
3. 再生速度 0.75x / 1.5x での追従（`currentTime` 駆動のため理論上は速度非依存。実測で確認）。
4. `segments` 無しの旧エピソードでハイライトとタップシークが無効化されること。
5. 慣性スクロール（指を離した後の惰性）中に自動スクロールが割り込まないか。iOS 17 デプロイターゲットで `.onScrollPhaseChange` が使えず `DragGesture` で手動操作を検知しているため、指を離した後の惰性は検知できない**既知の穴**。

## 設計上の既知の限界

タイミングは**実時刻ではなく推定**である。バックエンドの `TranscriptSegment`（`backend/shared/models.py`）は `speaker` と `text` のみで時刻を持たない（ADR-059 の既知の限界）。本実装は総再生時間を日本語イントロ重み付き文字数按分で割り当てている。実時刻が提供されたら `TranscriptTimingProviding` の別実装へ差し替える設計になっている（UI は protocol にのみ依存）。バックエンド側の実時刻付与は本タスクのスコープ外。
