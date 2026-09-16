# news-listen-ios Implementation Spec — 再生ドメインモデル・失効境界・カプセル化（design mode）

日付: 2026-09-16 ／ mode: design（read-only、実装は別フェーズ）／ owner: user ／ decision_maturity: **approved**（2026-09-16 user 承認。P9 事前ゲート revise 6 件反映版）
入力: `docs/research-reports/2026-09-16-code-design-review.md`（finding RF*・§8 人間判断 Q1〜Q10）と同ディレクトリの Function package（F-A*/G*/IV*/OB-C*/CI-*/LF*/SG-*）。
位置づけ: 親リポ `docs/design/ios-design.md` §5〜§8 の **target 版**。実装が進んだ節から ios-design.md を書き換える（本書は移行中の設計正本）。web の同種 Spec（`web/docs/design/2026-09-16-implementation-spec-domain-model.md`）と用語・capsule 構成・契約 ID の対応を保つ。

> 事前実装ゲート（`docs/research-reports/2026-09-16-code-design-review/spec-gate.md`、verdict revise）の修正 M1〜M6 を本版に反映: composition root 節（§2）、§8 逸脱 3 件の撤回（SG-S1 satisfied・role enum 化と読取側 id 検証を削除・`timeout` 削除）、§2.7 の書き方と CI-T9b、T-T7b の grep oracle 化と S3a/S3b 分割、TP4、公開操作の補完。

> 設計原則（本書の判断順）: actor の目的 → use case → その判断に必要な概念・不変条件 → 契約 → カプセル（公開操作と隠す技術）→ 依存方向 → 移行。pattern 名・class 数は成果にしない。1 実装しかない箇所に protocol を作らない（Boundary RO1〜RO7 を踏襲。port は品質根拠のある 4 つだけ）。


> **追記（2026-09-16・共有仕様 §6.7 の確定による上書き）**: 親 docs `shared-playback-spec.md` §6.7 の Selection Gate が user 判断で確定し、本書の次の記述を上書きする（本書は改訂せず、この追記と各 slice の order `docs/plan/2026-09-16-design-review-refactor/` を優先する）。
> - SG-X1: 完聴時にサーバーへ送る位置は **`duration` を明示的に 1 回送る**（§3.1 PositionReporter と CI-T8 の「完聴 → 位置 0 の順」を置換。順序は listenCompleted → `duration` → advance）。
> - SG-X3: 主体離脱で cleanup 完了を待たない（本書どおり）。SG-X4: 一時停止中は周期送信しない（本書どおり）。
> - SG-X5: 設定画面の既定速度 Picker（`SettingsView.swift:50` の 5 段）を `PlaybackConstants.speeds` 8 段へ揃える（S4 に追加）。
> - パスワード（SG-B2）: **12〜20 文字**（ADR-101。本書 §3.3・CI-T16 の「8〜20」を置換）。

## 0. Decision frame と function_plan

```yaml
decision_frame:
  mode: design
  requested_outcome: Implementation Spec（use case catalog・context 分割・model・契約・capsule・移行・検証計画）
  decision_owner: user
  mutation_authorized: false
  in_scope: [NewsListenApp/NewsListenApp の Podcast/ Networking/ AppState.swift Settings/（AccountSettings・SettingsViewModel の cache）の責務再配置, 契約と test obligation, 移行手順]
  out_of_scope: [backend 契約変更, web / android の実装, 意匠, Feed / Learning / Passkey / Push の model（gateway 呼出のみ・意味層の消費者としてだけ触る）]
  reversibility: reversible（slice 単位・特性テストで保護）
  public_contract_change_allowed: false   # backend API・共有再生仕様 §2 の意味論は不変。§2 への「advance 後の再生失敗」追記と §6.3 の実装名改訂は spec 先行（§6 参照）
  decision_maturity: {status: approved, owner: user, scope: [ios/], evidence_status: confirmed, approval_evidence: ["review §8（Q1〜Q10 satisfied）", "2026-09-16 user: Spec 承認（gate revise 反映版）"]}
function_plan:
  - {function: architecture, run_if: "context 分割・data authority・依存方向", status: completed, note: "§2・§5。SG-A1/A2/A3/A5/A6 の決定を target に反映"}
  - {function: completeness, run_if: "model の概念・状態・失敗", status: completed, note: "§3。G1〜G14 / IV1〜IV12 を target model で閉じる"}
  - {function: contract, run_if: "capsule の公開操作", status: completed, note: "§4。既存 CI-* を再利用し、target 固有は CI-T*。web Spec の CI-T 番号と主題を揃える"}
  - {function: boundary, run_if: "capsule の interface / implementation 分離", status: completed, note: "§5・§6。LF1〜LF16 の解消先を明示"}
  - {function: change_safety, run_if: "既存挙動の変更", status: completed, note: "§7。slice・特性テスト・temporary path"}
  - {function: discovery, status: not_applicable, not_applicable_reason: "用語は §1.3 の term ledger で確定（既存 Models・共有仕様・web Spec 由来）"}
```

## 1. Use Case catalog と用語

### 1.1 actor と目的

| actor | 目的（product value） |
|---|---|
| Listener（聴く人） | 移動中・オフラインでも英語ニュース音声を途切れず聴き、前回の続きから再開できる。ロック画面・イヤホンから操作できる |
| Learner（学ぶ人） | 語彙・クイズで理解を定着させ、ストリークで継続を可視化する（本書では境界のみ） |
| Account owner | 自分の認証手段・端末・設定を安全に管理し、ログアウトしたら端末に自分の痕跡を残さない |
| System（OS・Push） | バックグラウンド再生、割り込み、通知ディープリンク、クラッシュ通報 |

### 1.2 Use Case（UC）

| UC | actor | 内容 | 主要な判断（=ドメインルール） | context |
|---|---|---|---|---|
| UC-P1 エピソードを再生する | Listener | 一覧タップ／通知ディープリンク／「もう一度聴く」 | 再生元（cached / network / unavailable）、network なら再生直前の署名 URL 再取得（Q6）、再開位置（server 値。末尾 2 秒は先頭から）、キュー挿入規則（無ければ現在の次に挿入して jump。Q2）、Playable 判定 | Playback ← Catalog |
| UC-P2 再生を操作する | Listener | play / pause / seek / ±秒 / 速度 / ロック画面・リモコン | seek の clamp、速度の値域、セッション速度 vs 既定速度（Q4） | Playback / Platform |
| UC-P3 連続再生 | Listener | ended → 完聴記録 → 次へ or 停止 | 完聴記録は best-effort、次の再生失敗は**停止**（index は進めたまま error。Q3） | Playback |
| UC-P4 キューを編成する | Listener | 追加・次に再生・削除・並べ替え | 共有仕様 §2（Q-01〜Q-32）。IndexSet 複数移動はコアの iOS 拡張として明記 | Playback |
| UC-P5 オフライン保存 | Listener | 保存・削除・全削除・使用量 | 成功応答のみ保存、保存済み＝再生可能、有無の正本はファイル実体 | Playback（OfflineLibrary） |
| UC-P6 再生位置の同期 | Listener | 15 秒ごと・停止時・背景遷移時にサーバへ | 順序（完聴 → 位置）、同一エピソードの完聴 1 回、失敗は観測可能 | Playback（PositionReporter） |
| UC-A1 認証 | Account owner | ログイン・Passkey・起動時解決・**失効**・ログアウト | AuthSession の遷移（unauthorized と unavailable の区別。Q5）、主体が離れるときの消去（Q1） | Account |
| UC-A2 アカウント管理 | Account owner | 表示名・パスワード・Passkey・セッション | パスワード規則（8〜20、1 policy。Q9） | Account |
| UC-A3 設定 | Account owner | 既定難易度・既定速度・週目標（server 同期）／記事の開き方・時刻表記・効果音（local） | 主体依存値の一覧（logout で消す対象。Q1） | Preferences |
| UC-S1 通知ディープリンク | System | Push タップ → 該当エピソードを再生 | UC-P1 の挿入規則に従う（キューに載る。Q2） | Playback |
| UC-S2 OS 連携 | System | NowPlaying・RemoteCommand・AudioSession・割り込み・route change | logout でクリアできる（Q1）。port 背後（Q8） | Platform |
| UC-S3 クラッシュ通報 | System | MetricKit → POST /client-errors | 現状維持 | Platform |

### 1.3 term ledger（意味を分ける語。web Spec §1.3 と揃える）

| term | 意味 | 区別する別義 | 正本 |
|---|---|---|---|
| Episode | 聴く対象（backend の `Podcast` DTO をドメインで読んだもの） | DTO そのもの | Catalog `Episode`（§3.2） |
| 再生可能（Playable） | `status == "completed"` ∧ `audioUrl` 非空 ∧ `errorMessage == nil` | 生成中・失敗 | Catalog |
| 現在再生中 | `Queue.current`（spec §2.1 不変条件 4） | AVPlayer に load 済みの item | Playback Queue（Q2） |
| 完聴（listen completed） | ended 到達の事象 | 生成完了（`status "completed"`） | Playback（`ListenCompleted`）／Catalog（`GenerationStatus`） |
| 既定速度 | 新しい再生の初期速度（設定・永続・サーバ同期） | セッション速度（今回の再生・非永続） | Preferences ／ Playback（Q4） |
| 認証済み | `/auth/me` 成功で `user` を伴う状態 | Keychain にトークンが存在する状態 | Account `AuthSession` |
| 失効 | サーバが unauthorized を返した事象 | 通信断で確認できない（unavailable） | Account（Q5） |
| 保存済み（downloaded） | OfflineLibrary の `has(id)`（ファイル実体） | VM の `downloadedIds` ミラー | OfflineLibrary |
| 失敗の意味（ApiFailure） | network / unauthorized / forbidden / notFound(subject) / conflict / rateLimited(retryAfter) / server(status) / decoding / unknown(status) | HTTP status 数値 | Platform ApiGateway（Q7） |

## 2. Bounded context と依存方向（Architecture target）

```text
Views (SwiftUI)                         …… 画面。capsule の query を描き、command を呼ぶ。ルールを持たない
  ↓
ViewModels (@MainActor ObservableObject) …… 画面単位の派生値と配線。PodcastViewModel は Coordinator の薄い facade
  ↓
Composition root (NewsListenAppApp / AppState) …… adapter を生成し capsule を配線。AudioCacheManager 等は 1 インスタンス
  ↓ owns                                   ↑ implements
Playback/ Account/ Catalog/ Preferences/ (model・policy・coordinator)  ←  Platform/ (port の adapter: AVPlayer / MediaPlayer / FileManager / URLSession / Keychain / UserDefaults)
```

| context | purpose | 所有する概念（source of truth） | 置き場（target） |
|---|---|---|---|
| **Playback** | 聴き続ける | `PlaybackSession`（transport 状態 union）, `PlaybackQueue`（現在再生中・待機列。既存）, `PlaybackSource`（既存 `resolvePlaybackURL` の純関数部分）, `OfflineLibrary`, `PlaybackCoordinator`, `PositionReporter` | `Podcast/Playback/`（Session / Queue / OfflineLibrary / Coordinator / PositionReporter）、`Podcast/PodcastViewModel.swift`（facade） |
| **Catalog** | 聴く対象を選ぶ | `Episode`（Playable / Generating / Failed）decode、`GenerationStatus` | `Models/Episode.swift`（`Podcast` DTO は不変） |
| **Account** | 誰であるか | `AuthSession`（判別共用体）, `PasswordPolicy`（1 実装）, 失効・logout の主体データ消去 `SubjectCleanup` | `AppState.swift`（Session owner）、`Auth/PasswordPolicy.swift`、`Auth/SubjectCleanup.swift` |
| **Preferences** | 自分の使い方 | 設定レジストリ（key・scope・値域・主体依存か） | `AppState.swift` の `Keys` を `Settings/PreferenceRegistry.swift` へ |
| **Platform** | 技術境界 | `ApiGateway`（`APIClient` + `ApiFailure`）, `AudioEngine` port, `NowPlayingCenter` port, `FileStore`（既存 `FileManagerProtocol`）, `SessionStore`（既存 Keychain） | `Networking/`、`Podcast/Platform/`（AVPlayer / MediaPlayer adapter） |

**依存方向の禁止事項（prohibited_structures）**
- `Podcast/Playback/` は `AVFoundation` / `MediaPlayer` / `UIKit` / `SwiftUI` を import しない（port 経由のみ）。現状の LF1（AVFoundation 型の公開）・LF13（UIKit background task）・DV1 を解消。
- `Podcast/Playback/` は `APIClient` を import しない（Coordinator が gateway 関数をクロージャで受ける。現状 `PodcastViewModel:85` の直接保持を解消）。
- `DesignSystem/` は ViewModel の状態を書かない（`PreviewSupport.swift:152-166` は Coordinator の DEBUG ファクトリ経由に置換。LF11）。
- View は `@Published` を書かない（`PodcastView.swift:45,135` の `errorMessage = nil` は `dismissError()` command へ。LF2 / SG-A9）。
- ViewModel / View は `APIError.httpError(statusCode)` の数値を読まない（`ApiFailure` を読む。LF6）。

**port を置く根拠（abstraction gate）**: 4 つだけ。いずれも「1 実装だが品質根拠あり」。

| port | 根拠 | 既存の萌芽 |
|---|---|---|
| `AudioEngine`（load / play / pause / seek / rate / 事象 stream） | Session の状態遷移 13 本を AVPlayer 抜きで XCTest する（CI-T1）。現状はテストが AVFoundation 型を直接扱う（`PodcastViewModelTests.swift:743-778` 等） | `shouldProcessPlayerItemCallback` 等の純関数ガード |
| `NowPlayingCenter`（update / clear / remote command 登録） | logout でクリアする入口が必要（Q1、CI-T15）。シングルトン直参照ではテスト seam も外部制御点も無い（LF8） | `NowPlayingInfo.make` 純関数 |
| `FileStore` | 既存 `FileManagerProtocol`（`Networking/FileManagerProtocol.swift`）をそのまま | 既存 |
| `URLSessionProtocol` | 既存。`ApiGateway` は既存 `APIClient` の内部変更 | 既存 |

**Composition root（gate 指摘 M1）**: 現状 `AppState` は App 直下の `@StateObject`（`NewsListenAppApp.swift:19`）、`PodcastViewModel` は `ContentView` の `@StateObject`（`:104`、authenticated 時のみ生成）で、**AppState から再生側への参照は存在しない**。target では次の所有関係にする。

| 所有者 | 生成物 | 生存期間 | 参照方向 |
|---|---|---|---|
| `NewsListenAppApp`（App） | `AppState`、`OfflineLibrary`（1 インスタンス）、`NowPlayingCenter` adapter、`AudioEngine` adapter | プロセス | App → 全 adapter |
| `AppState` | `AuthSession`、`SubjectCleanup`、`PreferenceRegistry` | プロセス | `SubjectCleanup` は `PlaybackLifecycle` port（`stopForLogout()` のみ）と `OfflineLibrary.clearAll` / `NowPlayingCenter.clear` を **注入で**受ける。Coordinator 本体は参照しない |
| `ContentView`（authenticated 時） | `PlaybackCoordinator`（＝`PlaybackLifecycle` の実装）、`PodcastViewModel`（facade）、`PositionReporter` | ログインセッション | Coordinator 生成時に `AppState.registerPlaybackLifecycle(self)`、破棄時に解除（weak 保持）。未登録なら `SubjectCleanup` は再生停止を no-op として `CleanupIncomplete` に含めない（再生側が無い＝消すものが無い） |
| `SettingsView` | `SettingsViewModel` | 画面 | `OfflineLibrary` を App から environment 経由で受ける（既定引数生成を廃止） |

`AudioCacheManager` の protocol 化（RO7）・`BaseViewModel`（RO3）・再生ソース Strategy（RO2）・汎用 Repository（RO1）・stale guard 共通抽象（RO6）・HTTP 網羅 Error 階層（RO5）は作らない。`AudioSession` / `NotificationCenter`（割り込み・route change）は `AudioEngine` adapter の内部に閉じ、port にしない。

## 3. ドメインモデル（Completeness target）

### 3.1 Playback

**PlaybackSession（transport 状態の正本）** — 排他 union。既存 15 atom（isPlaying / currentTime / duration / playbackSpeed / isBuffering / errorMessage / didFinishCurrentEpisode …）は派生値。

| 状態 | 保持する値 | 遷移（コマンド／事象） |
|---|---|---|
| `idle` | — | `start(episode, source, resume, speed)` → `loading` |
| `loading` | episode, resumePosition, speed | engine `ready` → `paused`（resume 適用済み）→ 即 `play()` で `playing`／engine `failed` → `errored(engine_failed)` |
| `playing` | episode, position, duration, speed | `pause()` → `paused`／engine `buffering` → `buffering`／engine `ended` → `ended`／engine `failed` → `errored`／`timeupdate`（位置更新。保存は PositionReporter） |
| `buffering` | 同上 | engine `resumed` → `playing`／`pause()` → `paused`／engine `failed` → `errored` |
| `paused` | 同上 | `play()` → `playing`／`seek`／`start` |
| `ended` | episode, duration | Coordinator が `ListenCompleted` を通知し `advance` |
| `errored` | episode（取得前の失敗は `episodeRef: {id}`）, position, `reason: offline_uncached \| invalid_source \| engine_failed(description) \| fetch_failed(ApiFailure)` | `play()`（手動再試行）→ `loading`／`start` |

遷移表の分母（T-T1 用に固定）: idle→loading, loading→paused, loading→errored, paused→playing, paused→paused(seek), paused→loading(start), playing→paused, playing→buffering, buffering→playing, buffering→paused, playing→ended, playing→errored, buffering→errored, ended→loading(advance), errored→loading(retry), errored→loading(start) の **16 遷移**。表外（例: idle→playing、ended→playing、errored→paused）は禁止。IV2（error と paused の同居）・IV3（buffering ∧ error）は型で構築不能になる。

不変条件: `position ∈ [0, duration]`（seek / seekRelative とも clamp、CI-P19 / SG-C3）。速度は `PlaybackConstants` の許容値内。`start` 時のセッション速度は Preferences の既定速度で初期化し、以後はセッション内で保持（Q4、CI-P12 / G11）。`errored` からの `play()` は同じ source 解決をやり直す（オフライン → オンライン復帰で再試行が通る）。割り込み（電話）は `paused` への遷移として表し、`wasPlayingBeforeInterruption` は Coordinator の内部値。

**「現在再生中」の一本化（Q2 / SG-A1）**: `PlaybackQueue`（既存 struct、spec §2）が「順序と現在位置」の正本。`PlaybackSession` は「現在位置の decode 済み `PlayableEpisode`（再生に必要な payload）」の保持者。不変条件 **INV-P1**: `session` が `idle` でないとき `session.episode.id == queue.current?.id`。UI が「何が再生中か」を問う唯一の入口は Coordinator の `nowPlaying()` query（`Queue.current` から id、`session` から title / difficulty / duration / position / 状態を導出した view model）。`PodcastViewModel.currentPodcast` は `nowPlaying()` の派生 computed に置き換え（reader 19 箇所は型変更なしで読める形を保つ）。`QueueSheet.swift:22` の AND 合成と `PodcastView.swift:90` の比較は `nowPlaying()?.episodeId` へ。

**PlaybackQueue** — 共有仕様 §2 の状態モデルと公開操作を **そのまま**（`start / setQueue / add / playNext / jump / advance / remove / reorderUpNext`）。変更は 3 点のみ。(1) 内部 gate: `init` / `setQueue` で id 重複を dedupe（不変条件 1。CI-Q02 / SG-C1。公開操作は throw しない）。(2) `reorderUpNext(fromOffsets:toOffset:)` の IndexSet 複数移動は、spec §2.7 が「コア仕様の対象外（アダプタ責務）」とする範囲を **iOS 実装がコア型の内部で提供している**ものとして §2.7 の iOS 欄に記す（「コア仕様の拡張」とは書かない。gate M3。SG-C2）。単一要素は正本 `moveUpNext` と等価（CI-Q12）。複数要素の期待値は iOS 固有契約 CI-T9b として本書で固定する。別 adapter 型へ切り出す案は、呼出側が `QueueSheet.onMove` 1 箇所で切り出しても責務が移るだけで契約は増えないため採らない。名前は変えない（既存テスト 44 件・View の `onMove` 配線に影響するため。web は逆に `moveUpNext` に寄せた: 名前差は spec の対応表で吸収）。(3) `start` / `setQueue` は conformance が検証する操作なので **残す**（production 未使用でも削除しない）。

**PlaybackSource** — 既存 `resolvePlaybackURL` を `resolvePlaybackSource(hasCached:isOnline:) → cached | network | unavailable` の純関数（spec §6.1 と同名・同形）と、Coordinator 側の URL 解決に分ける。`unavailable` は `errored(offline_uncached)`。

**OfflineLibrary** — 既存 `AudioCacheManager` を包む「再生可能なエピソードの保存庫」。合成 root で **1 インスタンス**を生成し `PlaybackCoordinator` と `SettingsViewModel` に注入（現状の 2 既定引数生成を解消。RF11 / SG-A6）。

| 操作 | 事後条件 |
|---|---|
| `save(episode)` | gateway `downloadAudio` の成功データのみ格納（既存 CI-C01 系）。完了後 `has()` true |
| `has(id)` / `url(id)` | ファイル実体を正本とする。`downloadedIds` ミラーは廃止し `@Published private(set) var savedIds` を Library が publish（`clearAll` で即 空。IV10 / G7 を閉じる） |
| `remove(id)` / `clearAll()` / `usage()` | `clearAll` は logout（SubjectCleanup）からも呼ばれる（Q1） |
| id 検証 | 現状（書込側のみ）を維持。RF4 は §8.3 で「記録のみ」（backend の id 規則 U1 確認後に再判定） |

**PlaybackCoordinator（use case orchestration・非 React 相当の `@MainActor final class`）**

- `startEpisode(_ podcast: Podcast, expandsPlayer:)`（一覧タップ・通知・replay 共通）: `queue.jump(to:)` が false なら `queue.playNext` → `jump`（現状 `playNow` の規則を **全経路**に適用。`playById` もこの経路。Q2）→ `decodeEpisode` が Playable でなければ `errored(invalid_source)`（IV11 / G8）→ `source = resolvePlaybackSource(hasCached: library.has(id), isOnline)` → `cached` なら `library.url` ／ `network` なら **`fetchPodcast(id)` で再取得**し `audioUrl` を使う。取得失敗（`ApiFailure`）は保持 `audioUrl` でフォールバック（Q6 / ADR-009 / CI-P04）／ `unavailable` なら `errored(offline_uncached)` → `resume = resolveResume(serverPosition, duration)`（末尾 2 秒規則は既存のまま）→ `session.start(episode, url, resume, speed: prefs.defaultPlaybackSpeed)`。
- `onEnded(endedId)`: stale ガード（`endedId != queue.current?.id` なら無視。既存方式）→ `PositionReporter.listenCompleted(id)`（best-effort・background task は adapter 内）→ `queue.advance()` → `next` があれば `startEpisode(next, expandsPlayer: false)`。**失敗時は停止**: `queue.currentIndex` は進めたまま、`session = errored(reason)`、`nowPlaying()` は失敗エピソードを返し、手動 `play()` が `startEpisode(current)` を再実行（Q3 / CI-P13 / G1）。`next` が無ければ `session = ended` を保持（「聴き終わりました」表示は `ended` 状態から派生。`didFinishCurrentEpisode` atom は廃止）。
- `removeFromQueue(id)`: 現在再生中を消した場合は `queue.remove` 後に `session.stop()` して `queue.current`（次要素）を `idle` 扱いで表示（CI-P17。自動再生はしない）。
- `retry()`: `errored` のときだけ `startEpisode(queue.current)`。
- `stopForLogout()`: `session.stop()` → `nowPlaying.clear()` → `queue = PlaybackQueue()`（SubjectCleanup から呼ばれる。Q1）。
- 位置保存は **`PositionReporter`** が単独所有: Session の `positionChanged` を 15 秒 throttle でサーバへ、`pause`/`stop`/背景遷移で即時、完聴は `listenCompleted` → 位置 0 の順（CI-A13 相当）。応答の `Podcast` は捨てず `Catalog` へ渡してローカル値を更新（G12）。失敗は `@Published lastSyncFailure: ApiFailure?` として観測可能に（黙殺しない。SG-A8 の最小対応）。

### 3.2 Catalog

**Episode** — `Podcast` DTO の decode 結果（DTO 型と `CodingKeys` は不変。web Spec §3.2 と同じ判別）。

| 種別 | 条件 | 保持 |
|---|---|---|
| `PlayableEpisode` | `status == "completed"` ∧ `audioUrl != ""` ∧ `errorMessage == nil` | id, title(fallback: japaneseIntroText), audioUrl, durationSeconds, difficulty, createdAt, serverPosition, 任意: segments / vocabulary / quiz / sourceArticles / sourceKind |
| `GeneratingEpisode` | `status == "processing"` | id, title, difficulty, createdAt |
| `FailedEpisode` | `status ∈ {"failed","partial_failed"}` または矛盾組合せ（fail-closed） | id, title, errorMessage ?? "inconsistent" |
| 未知 `status` | `FailedEpisode`（fail-closed。U2 が確定するまでの既定） | — |

`PodcastRowView.swift:118-133` の文字列分岐は `Episode` 種別の switch へ。▶は `PlayableEpisode` にのみ付く。

### 3.3 Account

**AuthSession** — 判別共用体（G4 / G5 / IV6〜IV8 を閉じる。web Spec §3.3 と同形）。

| 状態 | 値 | 遷移 |
|---|---|---|
| `resolving` | — | `fetchMe` 成功 → `authenticated(user)`／`unauthorized` → `anonymous`／それ以外の `ApiFailure` → `unavailable(failure)`（**トークンは保持**。Q5 / RF3） |
| `authenticated` | `user: AuthUser` | `logout` → `anonymous`／任意の API 呼出が `unauthorized` → `anonymous`（**失効**。Q5 / RF2） |
| `anonymous` | — | login / passkey 成功 → `authenticated` |
| `unavailable` | `failure` | 再試行 → `resolving`（一時障害でログアウト表示しない） |

`authenticated → anonymous` の全遷移（logout・失効）の事後条件 = **SubjectCleanup**（Q1 / SG-A5）: (1) `sessionStore.token = nil`、(2) `OfflineLibrary.clearAll()`、(3) `PlaybackCoordinator.stopForLogout()`（session 停止・NowPlaying クリア・queue 空）、(4) 主体依存 UserDefaults の削除（§3.4 registry で `subjectScoped: true` の key: 実績既読・週目標・既定難易度・既定速度のローカルコピー。記事の開き方・時刻表記・効果音は端末設定として残す）、(5) `currentUser = nil`。消去失敗は `CleanupIncomplete` として観測可能に返し、認証状態の遷移自体は止めない（spec §6.3 のベストエフォート方針）。`ContentView` の破棄（`NewsListenAppApp.swift:65-70`）は従来どおり起きるが、消去は破棄に依存させない。

**失効の検知点**: `ApiGateway` が `unauthorized` を返した事象を 1 箇所（`AppState.handle(failure:)`）で受ける。各 VM は `ApiFailure.unauthorized` を文言化せず、遷移は AppState に委ねる。

**PasswordPolicy** — `Auth/PasswordPolicy.swift` に 1 実装。**8〜20 文字**（Q9、web SG7 と同値。文字種規則は現状 iOS に無いため追加しない）。`AccountSettingsView.swift:305-333` の `saveProfile` / `changePassword` は `AccountSettingsViewModel`（新設）へ移し、View は状態を描くだけ。`AdminUsersViewModel.swift:47` と `AdminUsersView.swift:28` の文言はこの policy から導出。backend 側の検証値は S4 着手前に確認（OB-A1）。

### 3.4 Preferences

設定レジストリ: 各設定を `{ key, scope: local | server, subjectScoped: Bool, codec, default }` で宣言（`AppState.swift:40-47` の `Keys`・`DSFeedback.swift:27-28`・`LearningEngagement.swift:147` を 1 箇所に）。

| 設定 | scope | subjectScoped | 値域 |
|---|---|---|---|
| defaultDifficulty | server（local copy） | true | 難易度コード一覧 |
| defaultPlaybackSpeed | server（local copy） | true | `PlaybackConstants` の速度一覧。**再生開始時に Session へ渡す**（Q4） |
| weeklyGoalEpisodes | server（local copy） | true | 3 / 5 / 7 / 10 |
| seenAchievementIds | local | true | `[String]`（既存 logout 削除を registry 経由に） |
| articleOpenMode / timeFormat | local | false | 列挙 |
| sfxEnabled / hapticsEnabled | local | false | Bool |

`SubjectCleanup` は `subjectScoped == true` の key だけを消す。`AppState` の `didSet → UserDefaults` 直書きは registry の `set` に置換。

### 3.5 Platform

**ApiGateway（既存 `APIClient` の内部変更。Q7 / SG-B1）**: `validateResponse` が `APIError` を `ApiFailure` へ変換する。`ApiFailure = network(URLError) | unauthorized | forbidden | notFound(subject: NotFoundSubject) | conflict | rateLimited(retryAfter: Int?) | validation | server(status) | decoding | unknown(status)`。`notFound.subject` は endpoint メソッドが付与（`streak / quota / quiz` = 機能未提供、`credential / session / star` = 冪等削除成功。既存 404 の 2 意味）。非 `HTTPURLResponse` は `network` として失敗（fail-open を閉じる。CI-A02）。`downloadAudio` はヘッダ非付与の方針を保ちつつ同じ `validateResponse` を通す（既存）。日本語文言は `Networking/FailureMessages.swift` の 1 関数 `message(for: ApiFailure, context:)` に集約し、`localizedDescription` の露出を消す。既存 `APIError` は S1 の間 **TP1** として `ApiFailure` から生成して throw する互換層に残し、10 消費者の置換完了で削除。

**AudioEngine / NowPlayingCenter**: `Podcast/Platform/AVPlayerEngine.swift`（AVPlayer・KVO・periodic observer・didPlayToEnd・AudioSession・割り込み・route change を内包し、`AsyncStream<EngineEvent>` を publish）と `Podcast/Platform/MediaPlayerNowPlaying.swift`（`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`）。`UIApplication.beginBackgroundTask` は PositionReporter の adapter 側に閉じる。

## 4. 契約（Contract target）

既存 Contract package の CI-*（`docs/research-reports/2026-09-16-code-design-review/contract-package.md`）を再利用し、target 固有の契約を CI-T* として追加する。番号と主題は web Spec の CI-T と揃える（T1 状態 union、T4 速度、T6 advance 失敗、T7 INV-P1、T8 位置、T9 Queue、T10 保存庫、T11 decode、T12 失敗の意味、T15 AuthSession、T17 Preferences）。テスト仕様 T-T* は Given-When-Then と oracle。

**失敗の表現**: `ApiGateway` は `throws ApiFailure`（Swift の typed throws は deployment target 17 で使えないため `Error` として throw し、消費者は `catch let f as ApiFailure` で受ける。`ApiFailure` 以外の Error が gateway から出ないことを CI-T12 が保証）。`PlaybackQueue` の公開操作は throw しない。

| CI | 対象 capsule | statement（要約） | 由来 | test（oracle は公開 API 経由） |
|---|---|---|---|---|
| CI-T1 | PlaybackSession | 状態は §3.1 の union のみ。16 遷移以外は起きない。`errored` は `paused` / `buffering` と区別できる | G2, IV2, IV3, OB-C3 | T-T1: 16 遷移を `AudioEngine` double の事象で駆動し `state` を観測（分母 16） |
| CI-T2 | PlaybackSession | engine `failed` → `errored(engine_failed)`。重複 `play()` は 1 状態に収束 | CI-P10, OB-C4 | T-T2 |
| CI-T3 | Coordinator | `start` 後の位置は server 値（末尾 2 秒以内 or duration 0 なら 0）。`ready` 後に再適用 | CI-P06 | T-T3（既存 `PodcastViewModelTests` の resume 系を特性テストとして流用） |
| CI-T4 | Coordinator / Session | セッション速度は `start` で既定速度に初期化、以後保持。既定速度は Preferences のみが書く | G11, CI-P12, Q4 | T-T4 |
| CI-T5 | Coordinator | `unavailable` → gateway 呼出なし、`errored(offline_uncached)`。`network` → `fetchPodcast` を 1 回呼び、その `audioUrl` で開始。取得失敗は保持 URL でフォールバック | CI-P02, CI-P04, Q6 | T-T5: gateway double の呼出回数と URL を観測（既存 `:483` を書き換え） |
| CI-T6 | Coordinator | advance 後の再生失敗: `queue.current` = 失敗エピソード（index は進む）、`errored(reason)`、`retry()` が同エピソードで `startEpisode` を再実行。15 秒 Timer は停止 | G1, IV1, CI-P13, Q3 | T-T6 |
| CI-T7 | Coordinator | INV-P1（`session.episode.id == queue.current?.id`）が全公開操作後に成立。`playById` 相当（`startEpisode` 通知経路）後も `queue.current` が同エピソード。「何が再生中か」の唯一の読出口は `nowPlaying()` | G3, IV4, IV5, CI-P05, CI-P08, Q2 | T-T7a: 全操作後の INV-P1 検査（unit）。T-T7b: `grep -rn "currentPodcast\s*=" NewsListenApp/NewsListenApp --include=*.swift` が `Podcast/Playback/` 以外で 0 件（T-T13 と同じ grep oracle。コンパイル境界は oracle にしない。gate M4） |
| CI-T8 | PositionReporter | 完聴 → 位置 0 の順。同一 episode の完聴通知は **クライアント側で** 1 セッション内 1 回に抑止（backend の冪等性 U3 には依存しない）。応答の位置は Catalog へ反映。失敗は `lastSyncFailure` に現れる | G12, CI-P23, CI-P24 | T-T8: gateway double の呼出列と `lastSyncFailure` |
| CI-T9 | PlaybackQueue | 公開操作は §2 どおり正規化し throw しない。`init` / `setQueue` は id を dedupe。単一要素 `reorderUpNext` は `moveUpNext` と等価。Q-01〜Q-32 不変 | CI-Q02, CI-Q12, SG-C1 | 既存 conformance 32 件（不変）＋ T-T9: 重複 id を含む `init` / `setQueue` の property test |
| CI-T9b | PlaybackQueue（iOS 固有） | 複数要素 `IndexSet` の `reorderUpNext` は SwiftUI `Array.move(fromOffsets:toOffset:)` と同じ結果（選択要素を元順序で一括取り出し、destination から選択済み要素数を差し引いた位置へ一括挿入）。`currentIndex` 不変。範囲外は no-op | CI-Q13, RF20, SG-C2 | T-T9b: 期待値表（upNext=[b,c,d,e]: {0,2}→4 = [c,e,b,d]、{1,3}→0 = [c,e,b,d]、{0,1}→2 = 無変更、範囲外 = 無変更）を `Array.move` の実行結果と突合 |
| CI-T10 | OfflineLibrary | `has` / `url` はファイル実体が正本。`clearAll` 後は `savedIds` が即 空 | G7, IV10, CI-C04 | T-T10: `FileStore` double で `clearAll` 後の `has` と `savedIds` |
| CI-T11 | Episode decode | DTO → 判別共用体。矛盾 DTO・未知 status は `FailedEpisode`。▶は Playable のみ | G8, G9, IV11 | T-T11（表駆動 status 4+未知 × audioUrl 2 × errorMessage 2 = 20） |
| CI-T12 | ApiGateway | 失敗は `ApiFailure` のみ（分母 = `APIEndpoint` の全 case。`Networking/APIEndpoint.swift` で数える）。`notFound.subject` は endpoint ごと。非 HTTPURLResponse は `network`。`rateLimited` は `retryAfter` を持つ | CI-A01, CI-A02, LF6, Q7 | T-T12（既存 `APIClientTests` 34 件を `ApiFailure` へ移植。`MockURLSession` に URLError / 非 HTTP 応答モードを追加） |
| CI-T13 | 消費者 | VM / View に `statusCode ==` / `httpError(` の数値比較が無い | RF10 | T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include=*.swift` が `Networking/` 以外で 0 件（CI で実行） |
| CI-T14 | AuthSession | 4 状態のみ。`fetchMe` の `unauthorized` 以外は `unavailable`（トークン保持）。実行中の任意 API の `unauthorized` で `anonymous` へ | G4, G5, IV6-IV8, CI-S03, Q5 | T-T14（`MockURLSession` の URLError モードで unavailable、401 で anonymous） |
| CI-T15 | SubjectCleanup | `authenticated → anonymous`（logout・失効の両方）の事後に `OfflineLibrary.usage() == 0`、`nowPlaying()` nil、`NowPlayingCenter.clear` 呼出 1 回、`subjectScoped` key が UserDefaults に無い。消去失敗は `CleanupIncomplete` | G6, IV9, CI-C05, CI-S05, Q1 | T-T15（`FileStore` / `NowPlayingCenter` double＋UserDefaults suite） |
| CI-T16 | PasswordPolicy | 8〜20 文字。`AccountSettingsViewModel` と `AdminUsersViewModel` が同じ policy を呼ぶ | RF9(a), Q9 | T-T16（境界値 7/8/20/21） |
| CI-T17 | PreferenceRegistry | registry 外 key・列挙外値は拒否／既定へ。`subjectScoped` の集合が §3.4 と一致 | OB-C7 相当, Q1 | T-T17 |
| CI-T18 | spec 追随 | spec §2.7 iOS 欄（IndexSet 複数移動）と §6.3 iOS 欄（実装名 `OfflineLibrary.clearAll`）、§2 追記「advance 後の再生失敗は停止」が実装と一致 | RF20, RF1, Q3 | T-T18: docs 側の改訂（spec §5 準拠規約: 本書を先に改訂） |

coverage（design 時点）: CI-T 19 件（T1〜T18 + T9b）すべてに test 仕様あり（実行は未）。既存 CI のうち target で `met` へ変わる見込み: Q02, Q13, P03, P04, P05, P08, P09, P13, P17, P19, P23, A02, C05, S03, S05（計 15 件）。**変えない**: A04（force unwrap。到達不能を維持）、C01（読取側 id 検証。RF4 記録のみ）、S06（token 鮮度。SG-A7 default）、P11（partial のまま。挙動不変）。

## 5. カプセルと公開操作（Boundary / code design）

```yaml
code_design:
  capsules:
    - {id: CP1, name: PlaybackSession, owns: [transport 状態 union（§3.1 の 7 状態）, 位置 clamp, セッション速度, AudioEngine port の駆動], hides: [AVPlayer / KVO / observer], emits: [stateChanged(PlaybackState), positionChanged(seconds), ended(episodeId)], note: "state は §3.1 の enum。EngineEvent は ready / buffering / resumed / ended / failed(description) / timeUpdate(seconds) / interrupted / interruptionEnded(shouldResume) の 8 種"}
    - {id: CP2, name: PlaybackQueue, owns: [QueueState と不変条件 1〜5（内部 dedupe）], hides: [配列操作], note: "共有仕様 §2 の公開操作をそのまま。名前は不変"}
    - {id: CP3, name: OfflineLibrary, owns: [保存庫の有無（ファイル実体）, savedIds publish, id 検証], hides: [FileManager, パス規約, 3 段の write], note: "既存 AudioCacheManager を包む。1 インスタンス"}
    - {id: CP4, name: PlaybackCoordinator, owns: [UC-P1/P3/P4/S1 の判断: source 選択・署名 URL 再取得・挿入規則・失敗方針・INV-P1・stopForLogout], hides: [gateway 関数, ports]}
    - {id: CP5, name: EpisodeDecoder, owns: [DTO → Episode 判別], hides: [status 文字列]}
    - {id: CP6, name: ApiGateway（APIClient）, owns: [request, ヘッダ, ApiFailure 正規化, notFound subject], hides: [URLSession, status 数値]}
    - {id: CP7, name: AuthSession + SubjectCleanup（AppState）, owns: [認証状態 union, 失効検知, 主体データ消去の順序], hides: [Keychain, fetchMe]}
    - {id: CP8, name: PreferenceRegistry, owns: [key・scope・subjectScoped・値域], hides: [UserDefaults]}
    - {id: CP9, name: PositionReporter, owns: [15 秒 throttle, 即時同期の契機, 完聴→位置 0 の順, 完聴 1 回, 失敗の観測], hides: [Timer, background task, gateway]}
    - {id: CP10, name: NowPlayingCenter port + adapter, owns: [ロック画面情報の更新・クリア, remote command 登録/解除], hides: [MPNowPlayingInfoCenter, MPRemoteCommandCenter]}
    - {id: CP11, name: PasswordPolicy, owns: [長さ規則 8〜20], hides: []}
  public_operations:
    - {capsule: CP1, ops: [start(episode, url, resume, speed), play, pause, seek, seekRelative, setSpeed, stop, state]}
    - {capsule: CP2, ops: [current, upNext, isEmpty, start, setQueue, add, playNext, jump, advance, remove, reorderUpNext]}
    - {capsule: CP5, ops: [decode(Podcast) → Episode, isPlayable]}
    - {capsule: CP3, ops: [save, has, url, remove, clearAll, usage, savedIds]}
    - {capsule: CP4, ops: [startEpisode, retry, togglePlayPause, seek, setSpeed, addToQueue, playNext, removeFromQueue, moveUpNext, skipToNext, nowPlaying(), upNext(), presentation, dismissError, stopForLogout]}
    - {capsule: CP6, ops: ["各 endpoint メソッド（既存名）→ throws ApiFailure"]}
    - {capsule: CP7, ops: [session, completeLogin, refreshAuth, logout, handle(failure:), retryResolve]}
    - {capsule: CP8, ops: [get(setting), set(setting, value), subjectScopedKeys]}
    - {capsule: CP9, ops: [attach(session), flush, listenCompleted(id), lastSyncFailure]}
    - {capsule: CP10, ops: [update(info), clear, registerCommands(handler), unregister]}
    - {capsule: CP11, ops: [validate(password) → Result]}
  branch_decisions:
    - {branch: "resolvePlaybackSource の 3 値", meaning: business decision table, decision: "Coordinator が全 3 値を扱う"}
    - {branch: "queue.jump の Bool", meaning: short input guard, decision: "Coordinator 内に留める"}
    - {branch: "currentPodcast != nil && queue.current", meaning: 2 正本の合成（LF3）, decision: "nowPlaying() に置換し View から消す"}
    - {branch: "statusCode == 404 の 6 箇所", meaning: business decision table（2 意味）, decision: "ApiFailure.notFound(subject) へ。subject は gateway が付与"}
    - {branch: "PodcastRowView の status 文字列", meaning: lifecycle state, decision: "Episode 種別の switch"}
    - {branch: "isAdmin の View 3 箇所", meaning: policy, decision: "変更なし（述語 1 箇所。RF9(c)〜(f) は §8.3 で記録のみ）"}
  naming_decisions:
    - {from: AudioCacheManager（公開面）, to: OfflineLibrary, reason: "技術（cache）ではなく目的（保存庫）。内部実装名は残す"}
    - {from: "downloadedIds / downloadState", to: "savedIds / Library.has", reason: "ミラーではなく正本を読む"}
    - {from: APIError, to: ApiFailure, reason: "意味を持つ値。TP1 で互換維持"}
    - {from: "didFinishCurrentEpisode", to: "session == .ended", reason: "合成 atom を状態に"}
    - {from: "playNow / playById / replayCurrentEpisode", to: "startEpisode（1 経路）", reason: "挿入規則を全経路に。Q2"}
  abstraction_decisions:
    - {subject: AudioEngine port, decision: adopt, rationale: "CI-T1 の 16 遷移を AVFoundation 抜きでテスト。1 実装"}
    - {subject: NowPlayingCenter port, decision: adopt, rationale: "logout クリアの外部制御点（Q1）。1 実装"}
    - {subject: "FileStore / URLSessionProtocol", decision: keep, rationale: "既存 seam"}
  rejected_overdesign:
    - {subject: AudioCacheManager の protocol 化, rationale: "RO7。CS2 fail の原因は port 不在ではなく file URL の公開。OfflineLibrary が URL を Coordinator にだけ渡す形で足りる"}
    - {subject: 共通 LoadableViewModel / BaseViewModel, rationale: "RO1 / RO3。一覧読込 9 箇所は change reason が異なる（Boundary D1）"}
    - {subject: 再生ソース Strategy, rationale: "RO2。3 分岐の純関数"}
    - {subject: stale guard 共通抽象, rationale: "RO6。3 方式は異なる正しさを守る"}
    - {subject: AVPlayer 鏡写しの AudioEngineProtocol, rationale: "RO4。port は Session が必要な 6 操作＋事象 stream に絞る"}
    - {subject: token provider 注入, rationale: "SG-A7 default。失効遷移で client 再生成"}
    - {subject: PlaybackQueue の rename（reorderUpNext → moveUpNext）, rationale: "既存テスト 44 件と onMove 配線への影響に対し、spec の対応表で名前差を吸収する方が安い。web と逆の判断を spec に明記"}
  dependency_direction: ["Views → ViewModels → Coordinator/AppState → Playback/Account/Catalog/Preferences ← Platform adapters", "Podcast/Playback ↛ AVFoundation/MediaPlayer/UIKit/SwiftUI", "Podcast/Playback ↛ APIClient（gateway 関数を注入）", "DesignSystem ↛ ViewModel 内部（DEBUG ファクトリ経由）"]
  change_scenarios:
    - {id: CS1, name: "replace AVPlayer → 別エンジン", expected: pass, evidence: "AudioEngine adapter の差替えで CP1/CP4 の契約テストが不変"}
    - {id: CS2, name: "replace FileManager → 別ストレージ", expected: pass, evidence: "OfflineLibrary の内部。公開 url は Coordinator のみが読む"}
    - {id: CS4/CS5/CS7, name: "change one business rule（パスワード / 404 意味 / 合格閾値）", expected: "pass（1 ファイル）。合格閾値は QuizSheetView の VM 化と同時（S4 以降）"}
    - {id: CS10/CS11/CS12, name: "authority / logout 消去 / 速度 2 概念", expected: pass, evidence: "本 Spec の target"}
```

**interface が露出してはならないもの（leakage guard）**: `AVPlayer` / `AVPlayerItem` / `CMTime`、`MPNowPlayingInfoCenter`、`UIApplication`、`HTTPURLResponse` / status 数値、`APIError`（TP1 期間を除く）、`localizedDescription` の英語文言、`Podcast` DTO を「再生中」の意味で読むこと（`nowPlaying()` を使う）、`@Published var` の外部書込（全 capsule で `private(set)`）。

## 6. 移行（Change Safety）— §8 の着手順に沿った slice

原則: slice ごとに **特性テスト（現行挙動の pin）→ RED（CI-T*）→ 実装 → 旧 path 削除条件の確認**。1 slice = 1 PR 目安。temporary path は owner・導入日・削除条件を持つ。共有仕様の改訂は spec §5 の規約どおり **実装より先**に行う（S0）。

| slice | 内容 | 特性テスト（baseline） | RED（T-T*） | temporary path |
|---|---|---|---|---|
| S0 spec | `docs/design/shared-playback-spec.md` の改訂（親リポ・別 PR）: §2 に「advance 後の再生失敗は停止・失敗エピソードを current に保持（3 platform 共通。Android は追随義務）」を追記、§2.7 に操作名の 3 者対応表（spec `moveUpNext(from,toOffset)` / web `moveUpNext` / iOS `reorderUpNext(fromOffsets:toOffset:)`）と iOS 欄（IndexSet 複数移動はコア仕様対象外を iOS 実装が内部提供・単一要素は等価）、§6.3 iOS 欄を `OfflineLibrary.clearAll()`（logout・失効の両方）へ。ADR-053 の追記 | conformance 32/32・17/17 | T-T18 | なし |
| S1 failure meaning（§8 順 1） | `ApiFailure`・`validateResponse` の変換・`notFound.subject`・非 HTTP 応答・`FailureMessages`。10 消費者の置換。`MockURLSession` に URLError / 非 HTTP モード | `APIClientTests`（34）・`AuthAPIClientTests`（8）・各 VM テスト（Feed 40 / Starred 15 / Settings 26 / Login 4 / Passkey 13 / Onboarding 5） | T-T12, T-T13 | **TP1** `APIError` 互換 throw（`ApiFailure` から生成）。owner: user、導入: S1、削除条件: `Networking/` 以外に `APIError` の参照が 0 |
| S2 session boundary（§8 順 2） | `AuthSession` union・`handle(failure:)` の失効検知・`refreshAuth` の失敗分類・`SubjectCleanup`（token / `OfflineLibrary.clearAll` / `stopForLogout` / `subjectScoped` key）・`PreferenceRegistry`・`NowPlayingCenter` port（clear を呼ぶ最小）。この時点では `PlaybackLifecycle` port（§2 composition root）を現行 `PodcastViewModel` が実装 | `AppStateAuthTests`（8）・`AppStatePreferencesTests`（3）・`AppStateDefaultsTests`（1）・`AudioCacheManagerTests`（13）・`LearningEngagementModelTests`（seenAchievementIds） | T-T14, T-T15, T-T17 | **TP2** `AudioCacheManager` の 2 インスタンスを合成 root の 1 つに寄せるまで `SettingsViewModel` 側は既定引数を残す。owner: user、導入: S2、削除条件: S3b で `OfflineLibrary` 注入完了。**TP4** 現行 `PodcastViewModel` による `PlaybackLifecycle` 実装（`stopPlayback()` + NowPlaying クリア + `queue` 初期化）。owner: user、導入: S2、削除条件: S3b で Coordinator が実装を引き継いだ時（port 名が同じため呼出側 `SubjectCleanup` は不変。gate M5） |
| S3a test double 移植（§8 順 3 の入口条件） | `AudioEngine` port と double を先に導入し、`PodcastViewModelTests` のうち AVFoundation / `vm.player` / KVO ハンドラを直接扱う **17 関数**（68 中。router 実測: 型リテラル・engine 結合 API・`vm.player` 参照）を double 駆動へ移植。残り 51 関数は不変。全 68 が green のまま | `PodcastViewModelTests`（68） | — | なし（S3b の入口条件: 17 関数の移植完了・68 green） |
| S3b playback（§8 順 3・**一括切替**） | `Podcast/Playback/{Session,Coordinator,OfflineLibrary,PositionReporter}`・`Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}`・`PlaybackQueue` の dedupe gate・`Episode` decode・`PodcastViewModel` を facade 化（`currentPodcast` は `nowPlaying()` 派生の computed、`downloadedIds` → `savedIds`、`didFinishCurrentEpisode` → `session == .ended`）・`startEpisode` 1 経路（playNow / playById / replay 統合）・署名 URL 再取得・速度初期化・advance 失敗の停止・`PreviewSupport` の DEBUG ファクトリ化・`PodcastView.swift:45,135` を `dismissError()` へ | S3a で移植済みの `PodcastViewModelTests`（68）を特性テストとして新 facade へ、`PlaybackQueueTests`（12）、`PlaybackQueueConformanceTests`（32）、`NowPlayingInfoTests`（13）、`AudioCacheManagerTests`（13）、`TranscriptTimingTests`（13。`currentTime` 駆動が不変であること） | T-T1〜T-T11 | **TP3** `PodcastViewModel` の旧公開プロパティ名（`isPlaying` / `currentTime` / `duration` / `playbackSpeed` / `isBuffering` / `errorMessage` / `currentPodcast` / `queue`）を computed で残す。owner: user、導入: S3b、削除条件: View 側が `nowPlaying()` / `session` を直接読むよう置換完了（S5 以降） |
| S4 rules & CI（§8 順 4） | `PasswordPolicy`（8〜20）・`AccountSettingsViewModel` 新設（`saveProfile` / `changePassword` を View から移す）・`AdminUsersViewModel` の policy 参照・`ci.yml` を `make test`（`scripts/test.sh` に `SIMULATOR` 動的選択と `CODE_SIGNING_*` を吸収）呼出へ | `AdminUsersViewModel` はテスト 0 → 特性テストを先に追加 | T-T16 | なし |
| S5 views（保留） | `QueueSheet` / `PodcastView` / `MiniPlayerView` / `AudioPlayerView` を `nowPlaying()` / `session` 直読みへ。TP3 の削除。`QuizSheetView` の採点ロジック VM 化（CS7） | — | — | — |

**S3b の scope 上の注意**: `AudioPlayerView.swift`（606 行）は `vm.currentPodcast` を 12 箇所で読む（`:94,95,143,156,161,250,265,275,294,470,547,562`）。TP3 の computed で型を保つため S3 では View を触らないが、`:547,562` の stale ガード（`vm.currentPodcast?.id == podcast.id`）は `nowPlaying()?.episodeId` と同値であることを T-T7a に含める。トランスクリプト同期（`currentTime` 駆動）は `session.position` の派生で不変。

**不可逆点**: なし（UI 内部構造のみ。backend 契約・Keychain の service 名・UserDefaults の key 名・キャッシュディレクトリ・共有仕様 §2 の意味論は不変。§2 への追記は既存行の変更ではない）。
**rollback**: slice 単位の revert。S3 は一括切替だが、上記の特性テスト移植が **すべて green になってから** 切替に入る（それ以前は revert 以外の回復手段がないため）。S0 の spec 改訂は iOS 実装より先に merge されるが、追記内容は web / Android の現行挙動を否定しない（advance 失敗時の挙動は両者とも未定義だった）。

## 7. Requirement → UC → model → contract → test の trace

| R | UC | model / capsule | CI | test | status（design） |
|---|---|---|---|---|---|
| R1 業務ルール単一所有 | UC-P1/P3, UC-A2 | CP4, CP5, CP11, FailureMessages | CI-T5/T6/T11/T16, CS4/CS5 | T-T5/6/11/16 | covered（クイズ閾値 CS7 は S5） |
| R2 再生の不正状態なし | UC-P1〜P6 | CP1, CP2, CP3, CP5 | CI-T1/T2/T3/T6/T9/T10/T11 | T-T1〜3, 6, 9〜11 | covered |
| R3 正本一意 | UC-P1/P2/P5/P6 | Queue.current + INV-P1, CP3 savedIds, CP8, CP9 | CI-T4/T7/T8/T10 | T-T4/7a/7b/8/10 | covered |
| R4 失敗の意味 | 全 UC | CP6 ApiFailure, errored(reason) | CI-T5/T12/T13 | T-T5/12/13 | covered |
| R5 失効・認可 | UC-A1 | AuthSession, handle(failure:) | CI-T14 | T-T14 | covered |
| R6 主体離脱で残留なし | UC-A1, UC-S2 | SubjectCleanup, CP10, CP8 subjectScoped | CI-T15, CI-T17 | T-T15/17 | covered（spec §6.3 は S0 で実装名へ改訂） |
| R7 本番経路のテスト | — | 既存 URLSession seam、AudioEngine / NowPlaying double、MockURLSession 拡張 | 各 T-T が実 APIClient / 実 PlaybackQueue を通す | UI テストは据置（UV1） | partial（UI 層は目視 UV3） |
| R8 CI ゲート | — | — | — | ci.yml → make test（S4） | covered（lint / カバレッジは Q9 で見送り） |
| R9 spec 準拠 | UC-P4 | CP2 dedupe gate、spec §2.7 iOS 欄 | CI-T9, CI-T18 | conformance 49 + T-T9 | covered |

**UC 側の coverage 分母**: UC 12 件のうち CI-T を持つのは UC-P1〜P6, UC-A1〜A3, UC-S1, UC-S2 の 11 件。**CI 対象外 1 件**: UC-S3（クラッシュ通報。現状維持で変更なし）。

## 8. 検証計画と decision

```yaml
verification_plan:
  per_slice: ["特性テスト green（baseline）", "T-T* RED → GREEN", "DEVELOPER_DIR=... xcodebuild test -only-testing:NewsListenAppTests（verification-run.md §1 の手順）", "S3b のみ: シミュレータ目視 UV3（logout 後のロック画面、auto-advance 失敗時の停止表示、一覧放置 1 時間後の再生）"]
  independent: ["slice ごとに code-review ロール 1 回（consolidated）", "S3b 完了時に adversarial-review で CI-T1〜T11 の oracle を検算"]
  unexecuted_now: [UV1 UI テスト, UV3 目視, UV4 T-T* 実装]
  pre_implementation_gate: {role: architecture, result: "revise → 本版で M1〜M6 反映", artifact: "docs/research-reports/2026-09-16-code-design-review/spec-gate.md"}
selection_gates:
  - {id: SG-S1, subject: "spec §2 への『advance 後の再生失敗は停止』追記の適用範囲", owner: user, status: satisfied, decision: "3 platform 共通（review §8 Q3 で「spec §2 に追記（3 platform 共通）」と決定済み。gate M2(a) で pending 化を撤回）。Android は未実装のため追随義務を spec に明記"}
  - {id: SG-S2, subject: "PlaybackQueue.reorderUpNext の名前を維持する（web と逆の判断）", owner: user, status: satisfied, decision: "維持。spec の対応表で吸収"}
  - {id: SG-S3, subject: "未知 status の fail-closed（FailedEpisode）", owner: user, status: satisfied, decision: "fail-closed。U2 が確定したら再判定"}
decision:
  status: pass
  artifact_readiness: ready
  engineering_status: planned
  release_status: not_applicable
  decision_maturity: {status: approved, owner: user, approval_evidence: ["review §8", "2026-09-16 user: Spec 承認・SG-S2 名前維持・SG-S3 fail-closed を含む"], baseline_version: "2026-09-16", change_control: "本書を更新して再承認"}
  next_phase: {name: "S0（親リポ shared-playback-spec.md の改訂 PR）→ S1（tdd-implementation ロール）", status: allowed, human_approvals_required: []}
  unknowns: ["OB-A1: backend のパスワード検証値", "U1: backend の podcast id 規則（読取側検証は安全側で入れる）", "U2: 未知 status の扱い", "U3: backend の完聴・位置更新の冪等性（CI-T8 の『1 回』はクライアント側抑止として実装し backend 依存を注記）"]
  residual_risks: ["S3b は一括切替のため、S3a（17 関数の double 移植・68 green）を入口条件にしないと回復手段が revert のみ", "TP1 の期間中は文言ラダーが二重化する", "R7 の UI 層は目視のまま（XCUITest は Q9 で見送り）", "spec 改訂（S0）は親リポの PR で、iOS の S3 より先に merge が必要"]
```
