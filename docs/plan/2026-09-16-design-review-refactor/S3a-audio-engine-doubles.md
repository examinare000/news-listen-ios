## iOS リファクタ S3a: AudioEngine port と double への移植（S3b 入口条件）

## 概要
`PlaybackSession` の 16 遷移を AVFoundation 抜きで XCTest できるようにするため、`AudioEngine` port と test double を先に導入し、`PodcastViewModelTests` のうち AVFoundation 型・`vm.player`・KVO ハンドラを直接扱うテストを double 駆動へ移植する。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§2 port 表・§4 CI-T1 の根拠・§6 S3a 行）。本 slice は **production コードの挙動変更を行わない**（テストの土台を作るだけ）。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。

Spec §8 着手順 3 の入口条件。S2 の merge 後に着手する。

## 前提・着手条件
- 依存: S2 が merge 済み。
- 本 slice は `Podcast/Playback/` 配下の新規capsule（Session / Coordinator 等）を作らない。`AudioEngine` port と double、およびテストの移植のみを行う。
- `docs/trial-log/player-auto-converge.md` を必ず読む。stale ガード（`endedId` を引数で閉じ込める）・`RequestRecordingSession` の直列化（`OSAllocatedUnfairLock`）など、double 実装時に同種の並行性問題を再現しないための既知の落とし穴が記録されている。再提案しない。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`AudioEngine` port（新規、`Podcast/Playback/` または `Podcast/Platform/` の protocol 定義）**: Spec §2 の port 表どおり、load / play / pause / seek / rate / 事象 stream（`AsyncStream<EngineEvent>`）の 6 操作＋事象を持つ。`EngineEvent` は `ready / buffering / resumed / ended / failed(description) / timeUpdate(seconds) / interrupted / interruptionEnded(shouldResume)` の 8 種（Spec §5 CP1 note）。
2. **test double（`NewsListenAppTests/` 内、production からは参照されない）**: `AudioEngine` を実装し、テストから事象を注入できるようにする。
3. **17 関数の移植**: `NewsListenAppTests/PodcastViewModelTests.swift`（68 関数中）のうち、AVFoundation 型リテラル・engine 結合 API・`vm.player` 参照を直接扱う 17 関数を、double 駆動（`AudioEngine` double へ事象を注入し `vm` の派生値を観測する形）へ書き換える。対象関数は着手時に `grep -n "AVPlayer\|AVPlayerItem\|CMTime\|vm\.player" NewsListenAppTests/PodcastViewModelTests.swift` で実測し直し、Spec のレビュー実測値（17）と一致することを確認してから移植に入る。不一致なら実装を止めて報告する。
4. **残り 51 関数は不変**: 移植対象外の関数は書き換えない。production コード（`PodcastViewModel.swift`）は本 slice では変更しない。

## 契約（CI-T → T-T の表）
本 slice は新しい CI-T を持たない。S3b の CI-T1（PlaybackSession の 16 遷移）が double を通してテストできることの前提を整えるための土台であり、oracle は「68 関数が double 移植前後で green のまま」であること。

| 確認事項 | 由来 | 検証 |
|---|---|---|
| `AudioEngine` port が Session の状態遷移を AVPlayer 抜きでテストできる | Spec §2 port 表（AudioEngine の根拠） | 17 関数移植後、当該テストが `import AVFoundation` に依存せず実行できる |
| production の挙動が変わらない | Spec §6 S3a 行「production 未使用でも削除しない／挙動変更なし」 | `PodcastViewModel.swift` の diff が 0（本 slice ではテストのみ変更） |

## 特性テスト（baseline。着手前に green を確認）
`PodcastViewModelTests`（68）全件。移植は 17 関数のみだが、baseline は 68 全件の green を確認してから着手する。

## 手順（TDD 順序）
1. baseline: `PodcastViewModelTests`（68）と `xcodebuild test -only-testing:NewsListenAppTests` の green を記録する。
2. `grep -n "AVPlayer\|AVPlayerItem\|CMTime\|vm\.player"` で 17 関数の対象を実測し、Spec の想定と突合する。一致しなければ実装を止めて報告する（`NEEDS_DECISION` 相当。対象数が違えば移植範囲の判断が必要になるため）。
3. `AudioEngine` port と double を新規追加する（この時点では production から参照されない。コンパイルが通ることだけを確認）。
4. 17 関数を 1 つずつ double 駆動へ書き換える。1 関数ごとに `xcodebuild test -only-testing:NewsListenAppTests/PodcastViewModelTests` を実行し green を確認しながら進める（大きな一括書き換えをしない）。
5. 全 17 関数の移植完了後、68 全件 green を確認する。
6. 1 slice = 1 PR。テストのみの変更のため commit は「port 追加」「double 追加」「17 関数移植」の単位で分ける。

## 完了条件
- `xcodebuild test -only-testing:NewsListenAppTests/PodcastViewModelTests` が 68 件全 green。
- `PodcastViewModel.swift`（production）に diff が無い。
- 移植した 17 関数が `AudioEngine` double 経由で駆動され、AVFoundation 型（`AVPlayer` / `AVPlayerItem` / `CMTime`）・`vm.player` を直接参照しない。
- 残り 51 関数に変更が無い。
- この 68 green が S3b 着手の入口条件であることを PR 説明に明記する。

## 禁止事項 / scope 外
- `PlaybackSession` / `PlaybackCoordinator` / `OfflineLibrary` 等の新規 capsule 実装（S3b）は行わない。
- production コード（`PodcastViewModel.swift` 本体のロジック）を変更しない。
- 17 関数以外のテストを書き換えない（51 関数は不変のまま維持する）。
- AVPlayer 鏡写しの `AudioEngineProtocol`（RO4）は作らない。port は Session が必要な 6 操作＋事象 stream に絞る（Spec §5 rejected_overdesign）。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §2（port 表）・§5（CP1）・§6（S3a 行）
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（SG-A6/SG-A10/SG-B3, Q8）
- trial-log: `docs/trial-log/player-auto-converge.md`
- 検証: `docs/research-reports/2026-09-16-code-design-review/verification-run.md` §7（AVPlayer 参照 2 ファイル）
