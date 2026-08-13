# 再生完了時のプレイヤー自動収束（player-auto-converge-on-finish）

## 2026-08-13T05:38:00Z 計画確定までの試行と棄却（adversarial-verifier 2回のREJECT・転記）

- **目的**: 完了時の収束アニメーションを、Listを巻き込まず・挿入transitionを殺さず実現する。
  **前提**: `PodcastView.swift:69` の `.animation(.spring(), value: viewModel.currentPodcast?.id)` が唯一のアニメーション駆動源。
  **やったこと**: アニメーションスコープを `AudioPlayerView` を包む `Group` へ移す案を検討。
  **結果（棄却）**: Groupへ移すと if 分岐の挿入（パネル出現の `.transition(.move(edge: .bottom))`）が不発になる典型パターンに落ちる。またList側のレイアウト変化（パネル縮小に伴う残り空間の再配分）を駆動するトランザクションが外側に無いため「パネルはspring・Listはsnap」に分離してしまう。→ 外側VStack上で `value` を2本立てにする案（`currentPodcast != nil` / `didFinishCurrentEpisode`）へ変更。

- **目的**: 完了処理中の状態遷移レースを解消する。
  **前提**: 当初案は「`handlePlaybackEnded()` 内の処理順序をUI収束→ネットワークへ入れ替えれば、レース構造自体が消える」という想定だった。
  **やったこと**: 順序入れ替えのみで verifier に提出。
  **結果（棄却/修正）**: 反証により、順序入れ替え後も終了通知〜`Task`実行までにMainActorジョブ1ホップの隙間が残り、その間に利用者が別エピソードへ切り替えるとレースが再発することが判明。「順序入れ替え後に `currentPodcast?.id` 同士を比較してもトートロジーで無意味」との指摘。→ `endedId`（終了した item 由来のID）を引数で閉じ込め、受け側で stale なら早期returnするガードを追加（issue #59 の `shouldProcessPlayerItemCallback` と同型）。

- **目的**: 順序入れ替えが既存テストへ与える影響を洗い出す。
  **前提**: 既存の `:106`付近（`testPlaybackEndedMarksCapturedPodcastBeforeAutoAdvanceAndRefreshesStreak`）・`:136`（`testCompletionFailureDoesNotBlockQueueAutoAdvance`）は `session.requests.first` 等でリクエスト**順序**を厳密に固定している。
  **やったこと**: 順序入れ替えの影響範囲を確認。
  **結果**: 順序入れ替えにより `stopPlayback()` が spawn する `/position` 同期Taskが `markCompleted` より先にenqueueされ得るため、これら順序依存アサーションがタイミング依存で落ちることが判明。→ 順序非依存（`contains`ベース）へ書き換え必須と結論。加えて `RequestRecordingSession.requests` への並行appendはデータ競合になり得るため直列化（actor化 or NSLock）が必要。

- **目的**: 完聴済みエピソード再タップ時の即完了ループを防ぐ。
  **前提**: サーバーの `playback_position_seconds` は完聴後も末尾のまま残る（backendの `markCompleted` は `completed_at` のみ書き込み、position はリセットしない）。
  **やったこと**: 「保存位置が末尾付近なら復元しない」ガードを検討。当初 `podcast.playbackPositionSeconds >= Double(podcast.durationSeconds) - 2` のみで判定する案。
  **結果（修正）**: `durationSeconds == 0`（メタデータ欠損）のケースで `isAtEnd` が常に `true` になり、レジューム機能が全面無効化される欠陥を反証で指摘された。→ `durationSeconds > 0` を前置ガードとして必須化。テストは抑制方向（末尾で復元しない）と復元方向（途中位置・duration=0で復元する）を対で書く方針に変更（一方向だけだとガードがレジュームを丸ごと殺しても green のまま通ってしまうため）。

## 実装中の試行記録

### 2026-08-13T05:38:00Z〜 TDD実装

- **目的**: `make test` を実行できる環境を整える。
  **前提**: `xcode-select -p` が `/Library/Developer/CommandLineTools` を指しており、`xcrun simctl` が見つからずビルド不能。
  **やったこと**: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` を明示指定して `xcodebuild`/`make test` を実行（既知の回避策、memory `ios-xcodebuild-without-sudo` と同型）。`-destination "platform=iOS Simulator,name=iPhone 16 Pro"` は「latest」解決に失敗したため、`id=<UDID>` 指定または `SIMULATOR` 環境変数で機種名を明示する方式に切り替えた。
  **結果**: `SIMULATOR="iPhone 17" make test` および `xcodebuild -destination "platform=iOS Simulator,id=..."` の両方で実行可能と確認。

- **目的**: Red（テストのみ追加した状態でのコンパイル失敗）を確認する。
  **前提**: VM側実装（`didFinishCurrentEpisode` / `replayCurrentEpisode()` / `handlePlaybackEnded(endedId:)`）は未実装。
  **やったこと**: 新規12件のテスト＋既存4件の修正（:83/:91 flag追記、:106/:136 順序非依存化）＋`RequestRecordingSession` 直列化＋`queuePodcast(_:)` デフォルト引数化を先に追加し、`xcodebuild test` を実行。
  **結果**: 期待通り `value of type 'PodcastViewModel' has no member 'didFinishCurrentEpisode'` 等、欠落しているAPIが原因のコンパイルエラーで失敗（Redとして正しい理由）。

- **目的**: `RequestRecordingSession.requests` の並行append対策（計画の指示）を実装する。
  **前提**: `data(for:)` は `async` メソッドであり、`session.requests.last` は同期プロパティとして既存の `refreshListeningStreak` クロージャ内で呼ばれている（actor化すると壊れる）。
  **やったこと**: 最初 `NSLock` で直列化 → ビルドは通ったが `instance method 'lock' is unavailable from asynchronous contexts; ... this is an error in the Swift 6 language mode` という警告が出た。
  **結果（修正）**: `OSAllocatedUnfairLock`（`import os`）へ差し替え、`withLock` クロージャ経由の同期アクセスに統一。警告消滅を確認。NSLock直呼びは今後同種のテストヘルパでも避ける。

- **目的**: VM実装（Green）。
  **やったこと**: `didFinishCurrentEpisode` 追加、`play(podcast:)` にガード通過後のflagクリア＋末尾ガード（`durationSeconds > 0` 前置）を追加、`handlePlaybackEnded(endedId:)` を順序入れ替え＋staleガード＋`beginBackgroundTask`で実装、`replayCurrentEpisode()` 追加、`#if DEBUG` の `previewMarkFinished()` シーム追加、`import UIKit` 追加。
  **結果**: 461件全テストgreen（新規12件+修正4件を含む）。

- **目的**: View実装（AudioPlayerView/PodcastView/PreviewSupport）。
  **やったこと**: 計画どおり、ルートVStack内で `playingContent`/`finishedContent` に分岐（`AudioPlayerView` 自体は差し替えない）、`.onChange(of: vm.didFinishCurrentEpisode)` でDisclosureGroupリセット+VoiceOver通知、PodcastViewの `.animation` を2本立てへ差し替え、`PreviewSupport` に `finishedPlayerViewModel()` を追加し `AudioPlayerView` へ "Player / Finished" プレビューを追加。`.animation` は AudioPlayerView 側には置かず PodcastView 側のみに置いた（計画どおり）。
  **結果**: `xcodebuild test`（アプリ全体のビルドを含む）green・461件全テストgreen。View側の主張自体はユニットテストでは担保されない（計画の検証節に明記のとおり、シミュレータ目視は本セッションのスコープ外）。

## 未実施（スコープ外・引き継ぎ事項）
- シミュレータ目視確認（計画の検証2）は本セッションでは未実施。次段階（review-ai-antipattern / adversarial-verifier 後、または人間レビュー時）に実施すること。

## fresh-context レビュー指摘への対応（2026-08-13）
- code-reviewer の指摘6件（major2/minor4）のうち5件を修正適用:
  1. [major] `pathSeenByRefresh` の `.last` 依存を排し「refresh時点で /completed 送信済み」の含有チェックへ（順序保証の本来の意味だけを固定）
  2. [minor] `testReplayCurrentEpisodeOverridesMidPositionRestore` 追加（`replayCurrentEpisode()` の `seek(to: 0)` を削るとRED）
  3. [minor] `onChange(of: didFinishCurrentEpisode)` を双方向リセットへ（finished中に語彙を展開→replayで持ち越すバグの芽を除去）
  4. [minor] `beginBackgroundTask` の `.invalid` ガード追加
  5. [minor] `isAtEnd` 固定2秒ウィンドウの前提（分単位尺のみ生成）をWHYコメント化
- [major] シミュレータ目視確認は未実施のまま人間レビューへハンドオフ（`make test` はUIテスト非実行のため）
- 参考指摘（auto-advance時のオフライン早期returnで旧stateが残る既存構造）はスコープ外・followup issue化候補
