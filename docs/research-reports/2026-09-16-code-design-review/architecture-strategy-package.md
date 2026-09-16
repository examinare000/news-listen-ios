# Architecture Strategy Package — ios モジュール（review mode / read-only）

```yaml
routing_context: {origin: integrated, mode: review, requested_by: router, requested_artifact: architecture-strategy-package, return_to: router, mutation_authorized: false}
```

対象 HEAD: `c8c1ada`。path は `ios/NewsListenApp/NewsListenApp/` 相対（docs は repo root 相対）。
本 package は **手段を選択しない**。未決は Selection Gate（SG-A*）へ隔離し、owner: user とする。

---

## 0. decision_frame

```yaml
decision_frame:
  question: "iOS 再生系の責務・data authority・依存方向を、共有再生仕様と web 確定決定へ整合させるための target / transition をどう定めるか"
  owner: user
  approvers: [user]
  decision_maturity: {status: proposed, owner: user, scope: [ios playback architecture], evidence_status: inferred, approval_evidence: [], baseline_version: "c8c1ada", change_control: "本 package は review 成果物であり baseline ではない"}
  actors:
    - id: A1
      purpose: "通勤・移動中に英語ニュース音声を連続再生し、オフラインでも中断なく聴く"
      evidence: [{status: inferred, source: "docs/design/shared-playback-spec.md:280-315", supports: "オフライン再生とキュー連続再生が共有仕様の一級要件"}]
    - id: A2
      purpose: "共有端末で logout 後に前利用者の音声・再生情報が残らない"
      evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:305-315", supports: "§6.3 共有端末対応として logout 時の完全削除を規定"}]
    - id: A3
      purpose: "開発者として iOS / web 双方の再生挙動を同一仕様で変更・検証できる"
      evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:37-128", supports: "§2 が両 platform の正本モデル"}]
  product_values:
    - id: V1
      statement: "キュー連続再生・オフライン再生が、端末をまたいでも同じ意味で動く"
      actor_ids: [A1, A3]
      success_signals: ["spec §2 Q-01〜Q-32 の conformance が両 platform で green", "auto-advance 失敗時の観測挙動が platform 間で一致"]
      owner: user
      evidence: [{status: confirmed, source: "verification-run.md §8（PlaybackQueueConformanceTests Q01-Q32 = 32/32 green）", supports: "キュー意味論は既に契約化済み"}]
    - id: V2
      statement: "共有端末で利用者が切り替わっても、前利用者の主体データが端末に残らない"
      actor_ids: [A2]
      success_signals: ["logout 後に音声キャッシュ 0 バイト", "logout 後にロック画面 NowPlaying が消える"]
      owner: user
      evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:312 と Networking/AudioCacheManager.swift:45-95 / AppState.swift:282-302", supports: "仕様は removeAllDownloads() 自動呼出を規定するが実装に該当 API も呼出も無い"}]
    - id: V3
      statement: "再生機能へ変更を入れるとき、影響範囲が 1 owner に閉じ、単体テストで先に検証できる"
      actor_ids: [A3]
      success_signals: ["1 論理変更が 1 型に閉じる", "外部 I/O なしで状態遷移を検証できる"]
      owner: user
      evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:1-854（854 行・@Published 15）", supports: "再生責務が単一型へ集中"}]
  in_scope: ["再生セッション・キュー・キャッシュ・ネットワーク・認証の data authority", "層間の依存方向", "logout / 失効時の主体データ消去範囲", "target / transition の候補提示"]
  out_of_scope: ["backend 実装", "web 実装の変更", "具体的なリファクタ手順の選択（SG へ隔離）", "UI 意匠"]
  horizon: "次の 1〜2 リリースサイクル（roadmap Evidence なし: unknown U-A5）"
  target_platforms: [ios]
  reversibility: costly
  constraints:
    - "共有再生仕様 §2 の不変条件 1〜5 と onMove 意味論（ADR-053）は must_preserve"
    - "V1 = 509/509 green を回帰させない（verification-run.md §1）"
    - "本 review は read-only。mutation は別 Function"
```

`candidate_means`（目的化を避けるため退避。いずれも未選択）: 「Redux 風 single store 化」「TCA 導入」「PodcastViewModel の分割」「PlaybackService 新設」「Repository パターン」「@Observable 移行」。

---

## 1. capabilities

```yaml
capabilities:
  - id: CAP1
    name: "キュー連続再生（再生セッション管理）"
    kind: business_capability
    classification: core
    classification_rationale: "本アプリの利用価値（移動中の連続リスニング）を直接成立させ、共有仕様が platform 横断の正本を定義している領域"
    actor_ids: [A1, A3]
    value_ids: [V1]
    differentiation: "キュー意味論（onMove 方式・advance 末尾停止・remove の currentIndex 追従）を web と共有し、同一の観測挙動を保証する点"
    unique_knowledge: "spec §2.3-2.10 の操作契約と不変条件 1〜5"
    expected_change: high
    failure_risk: high
    owner: user
    evidence:
      - {status: confirmed, source: "docs/design/shared-playback-spec.md:48-53,112-118", supports: "不変条件と advance 契約が明文化"}
      - {status: confirmed, source: "Podcast/PlaybackQueue.swift:1-143", supports: "値型・外部 I/O なしの純粋モデルとして実装済み"}
    domain_frame:
      domain_vision_status: applicable
      target_customer: "移動中に英語ニュースを聴く学習者（A1）"
      critical_problem: "端末やキュー操作で再生順が食い違うと学習の連続性が壊れる"
      unique_value: "platform 非依存の単一キュー意味論"
      success_signals: ["Q-01〜Q-32 が両 platform で green"]
      value_preservation_or_risk_statement: ""
    investment: {priority: now, level: high, build_buy_reuse: build, rationale: "共有仕様の正本が既にあり、実装差分の解消が価値へ直結", reevaluate_when: ["spec §2 の改訂", "web 側決定の変更"]}

  - id: CAP2
    name: "オフライン音声キャッシュ"
    kind: business_capability
    classification: supporting
    classification_rationale: "再生価値を支えるが差別化の源泉ではない。優先すべきは availability と、共有端末での confidentiality"
    actor_ids: [A1, A2]
    value_ids: [V1, V2]
    differentiation: ""
    unique_knowledge: ""
    expected_change: medium
    failure_risk: high
    owner: user
    evidence:
      - {status: confirmed, source: "Networking/AudioCacheManager.swift:45-95", supports: "cachedURL/isCached/cache/remove/cacheSize/clearCache の 6 操作"}
      - {status: confirmed, source: "docs/design/shared-playback-spec.md:284-296", supports: "resolvePlaybackSource の優先度が共有仕様"}
    domain_frame:
      domain_vision_status: not_applicable
      not_applicable_reason: "supporting capability。架空の unique value を作らない"
      value_preservation_or_risk_statement: "共有端末で前利用者の音声ファイルが残ると、その利用者の学習内容が第三者へ露出する（QL4 constraint）。仕様 §6.3 は完全削除を要求している"
    investment: {priority: now, level: medium, build_buy_reuse: build, rationale: "既存実装があり、欠けているのは logout 連携と instance 共有", reevaluate_when: ["共有端末運用を前提から外す決定"]}

  - id: CAP3
    name: "認証・セッション保持"
    kind: subdomain
    classification: supporting
    classification_rationale: "差別化ではないが、失効・logout の正しさが security constraint を成立させる"
    actor_ids: [A2]
    value_ids: [V2]
    expected_change: low
    failure_risk: high
    owner: user
    evidence:
      - {status: confirmed, source: "Networking/SessionStore.swift:13-45", supports: "protocol + Keychain 実装 + InMemory 実装"}
      - {status: confirmed, source: "AppState.swift:201-221", supports: "refreshAuth の catch が全例外で token 破棄・未認証化"}
    domain_frame:
      domain_vision_status: not_applicable
      not_applicable_reason: "supporting subdomain"
      value_preservation_or_risk_statement: "token 保持は Keychain に限定され平文ログ禁止（Networking/SessionStore.swift:24-26）。失効時に主体データが残る経路は QL4 違反"
    investment: {priority: next, level: medium, build_buy_reuse: build, rationale: "構造は妥当。争点は失効時の消去範囲（SG-A5）と instance 生成方式（SG-A7）", reevaluate_when: ["多要素認証の追加"]}

  - id: CAP4
    name: "HTTP クライアント / ネットワーク状態監視"
    kind: technical_capability
    classification: not_applicable
    classification_rationale: "技術要素であり core/supporting/generic の投資分類対象ではない。quality scenario・failure risk・運用コストで評価する"
    actor_ids: [A3]
    value_ids: [V1, V3]
    expected_change: medium
    failure_risk: medium
    owner: user
    evidence:
      - {status: confirmed, source: "Networking/APIClient.swift:20-27,536-540", supports: "APIError は httpError(statusCode) 中心、429 のみ意味化"}
      - {status: confirmed, source: "Networking/NetworkMonitoring.swift:33-66", supports: "NWPathMonitor を protocol 背後へ隔離済み"}
    investment: {priority: next, level: medium, build_buy_reuse: build, rationale: "seam は URLSession 層で確保済み。争点は失敗の意味化（Boundary Function 所管）と instance 生成", reevaluate_when: ["API の失敗契約変更"]}
```

---

## 2. quality_portfolio と scenario

```yaml
quality_portfolio:
  items:
    - id: QA1  # = QL1
      quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: maintainability, subcharacteristic: modifiability, standard_term: modifiability, display_name_ja: 変更容易性, source_terms_ja: [変更容易性]}
      priority: primary
      value_ids: [V1, V3]
      rationale: "再生仕様が両 platform で改訂され続ける前提（ADR-053 で正本変更済み）。1 論理変更の波及範囲がコスト支配要因"
      owner: user
      evidence: [{status: confirmed, source: "p4-common-brief.md §3（ユーザー確定 QL）", supports: "primary 指定"}]
      reevaluate_when: ["再生仕様が凍結される場合"]
    - id: QA2  # = QL2
      quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: maintainability, subcharacteristic: testability, standard_term: testability, display_name_ja: テスト容易性, source_terms_ja: [テスト容易性]}
      priority: primary
      value_ids: [V1, V3]
      rationale: "TDD が project rule（agent-rules/11-testing-strategy.md）。検証不能な構造は変更を止める"
      owner: user
      evidence: [{status: confirmed, source: "verification-run.md §1（509 tests green）", supports: "既存投資が大きく、維持価値が高い"}]
      reevaluate_when: []
    - id: QA3  # = QL3
      quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: reliability, subcharacteristic: fault_tolerance, standard_term: fault tolerance, display_name_ja: 耐障害性, source_terms_ja: [耐障害性]}
      priority: secondary
      value_ids: [V1]
      rationale: "移動中のネットワーク断が常態。ただし primary 2 品質と競合したときは譲る"
      owner: user
      evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:264-267", supports: "オフライン未キャッシュ経路が明示的に存在"}]
      reevaluate_when: []
    - id: QA4  # = QL4
      quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: security, subcharacteristic: confidentiality, standard_term: confidentiality, display_name_ja: 機密性, source_terms_ja: [機密性]}
      priority: constraint
      value_ids: [V2]
      rationale: "must-hold。他品質との trade-off で落とさない（supporting capability でも必要品質は維持する）"
      owner: user
      evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:305-315", supports: "共有端末対応が仕様要件"}]
      reevaluate_when: ["共有端末運用を前提から外す user 決定"]
    - id: QA5
      quality: {reference_model: "ISO/IEC 25010:2023", level: characteristic, characteristic: performance_efficiency, subcharacteristic: not_applicable, standard_term: performance efficiency, display_name_ja: 性能効率性, source_terms_ja: [性能]}
      priority: intentionally_not_optimized
      value_ids: []
      rationale: "計測 Evidence が無い。数値目標を作らず、劣化が観測されたときに再評価する"
      owner: user
      evidence: [{status: unknown, source: "計測なし", supports: "verification-run.md に性能計測の記録が無い"}]
      reevaluate_when: ["体感遅延の報告", "起動/再生開始時間の計測導入"]
```

### trade-off（同時最大化しない宣言）

| ID | trade-off | 影響 quality | 判断状態 |
|---|---|---|---|
| TD-A1 | オフライン再生の**可用性**（キャッシュを端末に持ち続ける）と、共有端末の**機密性**（logout で消す）は直接競合する。仕様 §6.3 は機密性側を選び「logout 時に完全削除」としている | QA3 ↓ / QA4 ↑ | spec は決定済み（`docs/design/shared-playback-spec.md:305-315`）だが iOS 実装は未追随 → SG-A5 |
| TD-A2 | `try?` による best-effort（`Podcast/PodcastViewModel.swift:462`、`AppState.swift:292,294`）は**耐障害性**を上げるが、production にログ API が 1 つも無い（verification-run.md §7）ため**観測可能性**を 0 にしている。失敗が起きても誰も気づけない | QA3 ↑ / QA1・運用 ↓ | 未決（SG-A8 で観測方針を選択） |
| TD-A3 | `PodcastViewModel` 単一型への集約は**局所的な変更容易性**（配線が 1 箇所）を上げるが、854 行・15 atom で**テスト容易性**と**変更影響範囲**を下げる | QA1 ↓ / QA2 ↓ | 未決（SG-A6） |
| TD-A4 | `AppState.swift:312-314` の fail-open（onboarding 取得失敗→完了扱い）は journey の行き止まりを避ける**可用性**優先。WHY が `:306` に記録済み | QA3 ↑ / 正確性 ↓ | 既決（コメントに WHY あり）。QA4 には触れないため constraint 違反なし |

### quality_scenario

```yaml
quality_scenarios:
  - id: QS1
    quality_item_id: QA1
    stimulus: "spec §2 の操作契約が 1 つ改訂される（例: advance の末尾挙動）"
    artifact: "PlaybackQueue と PodcastViewModel の呼出側"
    environment: "通常開発"
    expected_response: "変更が PlaybackQueue 内に閉じ、VM 側は呼出名の変更を伴わない"
    oracle: "変更差分が触るファイル数と、Q-01〜Q-32 の再 green"
    owner: user
    evidence: [{status: inferred, source: "Podcast/PlaybackQueue.swift:1-143 は外部 I/O を持たない", supports: "閉じ込めは概ね成立"}]
    measurement_plan: "代表変更の change simulation（VAL1）"
  - id: QS2
    quality_item_id: QA1
    stimulus: "「現在再生中」の判定規則を 1 箇所変更する"
    artifact: "currentPodcast / queue.currentIndex / AVPlayer.currentItem の 3 系統"
    environment: "通常開発"
    expected_response: "1 owner の変更で全 reader の意味が変わる"
    oracle: "reader の参照先が単一 owner へ解決するか"
    owner: user
    evidence: [{status: confirmed, source: "p1-domain.md §5 の 3 系統表と Podcast/PodcastViewModel.swift:281,441,517-519", supports: "現状は 3 系統・同期は 2 経路のみ"}]
    measurement_plan: "VAL2 の依存 trace"
  - id: QS3
    quality_item_id: QA2
    stimulus: "auto-advance 先の再生が失敗する（オフライン + 未キャッシュ）"
    artifact: "handlePlaybackEnded → play の経路"
    environment: "XCTest（実 APIClient + URLSession double）"
    expected_response: "外部 I/O なしで、失敗後の観測状態（current / queue / error）を一意に検証できる"
    oracle: "単体テストで状態を pin できるか"
    owner: user
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:435-465 と :262-267", supports: "advance 済み・currentPodcast 据置の中間状態が構築可能"}]
    measurement_plan: "VAL3 failure injection"
  - id: QS4
    quality_item_id: QA3
    stimulus: "再生位置のサーバ同期が失敗する"
    artifact: "syncPlaybackPositionIfNeeded"
    environment: "実機・電波不良"
    expected_response: "再生は継続し、失敗が観測可能な形（状態またはログ）で残る"
    oracle: "失敗時に観測可能な痕跡が 1 つ以上あるか"
    owner: user
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:844-851（catch 本文がコメントのみ・本 repo で唯一）", supports: "痕跡ゼロ"}]
    measurement_plan: "VAL3"
  - id: QS5
    quality_item_id: QA4
    stimulus: "共有端末で利用者 X が logout し、利用者 Y がログインする"
    artifact: "AudioCacheManager のファイル群 / MPNowPlayingInfoCenter / UserDefaults"
    environment: "実機"
    expected_response: "X の音声ファイル・ロック画面情報・主体依存 UserDefaults が残らない"
    oracle: "logout 後の cacheSize() == 0、NowPlaying 非表示"
    owner: user
    evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:312 vs AppState.swift:282-302（キャッシュ削除呼出なし）", supports: "仕様と実装が競合"}]
    measurement_plan: "VAL4 security review + 実機観測（UV3）"
  - id: QS6
    quality_item_id: QA4
    stimulus: "実行中にサーバ側でセッションが失効する（401）"
    artifact: "AppState.refreshAuth / 各 VM の API 呼出"
    environment: "実機"
    expected_response: "未認証へ遷移し、主体データの消去範囲が logout と同一"
    oracle: "失効経路と logout 経路が同じ消去 owner を通るか"
    owner: user
    evidence: [{status: confirmed, source: "AppState.swift:216-220（refreshAuth の catch）と :282-302（logout）で消去内容が異なる", supports: "2 経路で消去範囲が非対称"}]
    measurement_plan: "VAL4"
  - id: QS7
    quality_item_id: QA1
    stimulus: "設定画面でキャッシュ全削除を実行する"
    artifact: "SettingsViewModel.clearCache と PodcastViewModel.downloadedIds"
    environment: "実機"
    expected_response: "ダウンロード済み表示が即座に整合する"
    oracle: "clearCache 後の downloadedIds が空"
    owner: user
    evidence: [{status: confirmed, source: "Settings/SettingsViewModel.swift:184-192 と Podcast/PodcastViewModel.swift:55,158", supports: "別インスタンス経由で削除され、downloadedIds は無効化されない"}]
    measurement_plan: "VAL1"
  - id: QS8
    quality_item_id: QA1
    stimulus: "設定で既定速度を 1.5 に変更し、その後エピソードを再生する"
    artifact: "AppState.defaultPlaybackSpeed / PodcastViewModel.playbackSpeed"
    environment: "実機"
    expected_response: "web 決定（既定速度→セッション速度の初期化）と同じ観測挙動になる"
    oracle: "再生開始時の rate が既定速度と一致するか"
    owner: user
    evidence: [{status: confirmed, source: "AppState.swift:63-65 と Podcast/PodcastViewModel.swift:50,291,575-578（両者に接続コードなし）", supports: "2 正本が完全分離"}]
    measurement_plan: "VAL1"
```

---

## 3. data authority 表（fact ごとの writer / reader / 一意性 / 候補 owner）

すべての `path:line` は本レビューで再読済み（§10 の範囲検査参照）。

### (a) 現在再生中のエピソード

| 項目 | 内容 |
|---|---|
| writer | 系統 A: `Podcast/PodcastViewModel.swift:281`（`currentPodcast = podcast`・本番唯一）／DEBUG `DesignSystem/PreviewSupport.swift:152,164`（`@Published var` を外部代入）。系統 B: `Podcast/PlaybackQueue.swift:49,55,71,81,90,95,105,107,110`（`currentIndex`）を VM の `Podcast/PodcastViewModel.swift:441,517,518,519,527,536,544,549` が駆動。系統 C: `Podcast/PodcastViewModel.swift:290-291`（`AVPlayer` 再生成） |
| reader | `Podcast/PodcastViewModel.swift:436,437,475,482,526,535`、`Podcast/PodcastView.swift:90`、`Podcast/QueueSheet.swift:22`、`Podcast/MiniPlayerView.swift:24,44`、`Podcast/AudioPlayerView.swift:94,95,143,156,161` |
| 一意か | **否**。3 系統が併存し、同期するのは `playNow`（`:517-521`）と `handlePlaybackEnded`（`:441-442`）の 2 経路のみ。`playById`（`:381-388`）と `replayCurrentEpisode`（`:481-487`）は B を更新しない |
| 候補 owner | (i) `PlaybackQueue.currentIndex`（spec §2.1 不変条件 4 = `docs/design/shared-playback-spec.md:53`、web 決定と同じ）。`currentPodcast` は derived。(ii) `PodcastViewModel.currentPodcast` を正本にし queue を待機列専用へ縮退。(iii) 現状 2 正本のまま同期契約を明文化し、非同期経路（playById/replay/remove）に reconciliation を規定 |
| 選択条件 | SG-A1 |

### (b) 再生速度（セッション速度 / 既定速度）

| 項目 | 内容 |
|---|---|
| writer（セッション） | `Podcast/PodcastViewModel.swift:50`（宣言・`@Published var` で外部書込可）、`:575-578`（`setSpeed`）、DEBUG `DesignSystem/PreviewSupport.swift:152-157` 系 |
| reader（セッション） | `Podcast/PodcastViewModel.swift:291`（`player?.rate = playbackSpeed`）, `:577`、`Podcast/AudioPlayerView.swift:237` |
| writer（既定） | `AppState.swift:63-65`（didSet→UserDefaults）, `:233`（サーバ preferences 反映）, `:353`（起動時復元）、`Settings/SettingsView.swift:390` 系の Picker 束縛 |
| reader（既定） | `Settings/SettingsView.swift:390`、`Settings/SettingsViewModel.swift`（速度同期 request id `:61`） |
| 一意か | **否**。既定とセッションが別型に住み、**接続コードが 1 行も無い**（`Podcast/PodcastViewModel.swift:262-291` に `AppState` 参照なし）。web 決定は「セッション速度は再生開始時に既定から初期化」 |
| 候補 owner | (i) 既定 = `AppState`、セッション = 再生 owner とし、`play()` 開始時に既定を読んで初期化（web 決定と同形）。(ii) 既定・セッションを 1 つの playback settings owner へ集約。(iii) 現状維持（2 概念が非連動であることを仕様として明記） |
| 選択条件 | SG-A2 |

### (c) 再生位置（local / server）

| 項目 | 内容 |
|---|---|
| writer（local） | `Podcast/PodcastViewModel.swift:319`（periodic observer）, `:569`（`seek`）, `:606`（`stopPlayback` で 0）。宣言 `:46` は `@Published var`（外部書込可） |
| reader（local） | `Podcast/PodcastViewModel.swift:681,687,740,749,845`、`Podcast/AudioPlayerView.swift:110,170,177,204,225`、`Podcast/MiniPlayerView.swift:89` |
| writer（server） | `Podcast/PodcastViewModel.swift:848`（`updatePlaybackPosition`）。呼出は 15 秒周期 Timer・`stopPlayback` 経路・`flushPlaybackPosition` の 3 点 |
| reader（server） | `Models/Podcast.swift` の `playbackPosition` → `Podcast/PodcastViewModel.swift:305-307`（再開位置復元） |
| 一意か | **否**。server は spec §6.2 の server-wins（`docs/design/shared-playback-spec.md:302`）が正本だが、`:848` が戻り値を `_ =` で破棄するためローカルの `podcasts` / `currentPodcast` は stale のまま。失敗時は `:849-851` の catch がコメントのみで痕跡なし |
| 候補 owner | (i) server を正本とし、同期応答で local model を更新（spec §6.2 と同形）。(ii) local を writer、server を replica とし、復帰時のみ resolveResumePosition で調停。(iii) 現状維持＋失敗の観測手段だけ追加 |
| 選択条件 | SG-A3（消去範囲の SG-A5 とは独立） |

### (d) キャッシュ有無

| 項目 | 内容 |
|---|---|
| writer（正本＝ファイルシステム） | `Networking/AudioCacheManager.swift:62-66`（`cache`）, `:71-76`（`remove`）, `:90-95`（`clearCache`） |
| writer（ミラー） | `Podcast/PodcastViewModel.swift:158`（`syncDownloadedState`）, `:209`（成功時 insert）, `:220`（失敗時 remove）。宣言 `:55` は `private(set)` |
| reader | `Podcast/PodcastViewModel.swift:164`（`downloadState`）, `:192`、`Podcast/PodcastView.swift:91`、`Settings/SettingsViewModel.swift:179,191` |
| 一意か | **否**。正本は FS だが `AudioCacheManager` の**インスタンスが 2 つ独立生成**される: `Podcast/PodcastViewModel.swift:122`（既定引数。`NewsListenAppApp.swift:118` の生成で既定が採用される）と `Settings/SettingsViewModel.swift:69,76`（両 init の既定引数。`Settings/SettingsView.swift:57` が `init(appState:)` を使用）。同一ディレクトリを指すため FS 上は整合するが、ミラー `downloadedIds` は `SettingsViewModel.clearCache`（`:184-192`）で無効化されない |
| 候補 owner | (i) `AudioCacheManager` を単一インスタンスとして合成 root（`NewsListenAppApp.swift:19` 近傍）から両 VM へ注入。(ii) キャッシュ状態の owner を 1 つの型へ集約し、VM はそれを購読。(iii) 現状維持＋`clearCache` 後の再同期を呼出側の契約として明記 |
| 選択条件 | SG-A6 |

### (e) ネットワーク状態

| 項目 | 内容 |
|---|---|
| writer | `Networking/NetworkMonitoring.swift:62`（`NWPathMonitor` の pathUpdateHandler。唯一の本番 writer） |
| reader（ミラー経由） | `Podcast/PodcastViewModel.swift:61,130,134`、`Feed/FeedViewModel.swift:37,82,85`、`Starred/StarredViewModel.swift:22,49,52`、View 側 `Podcast/PodcastView.swift:26,92` ほか |
| reader（直読） | `Podcast/PodcastViewModel.swift:264`（`networkMonitor.isOnline` を `resolvePlaybackURL` へ直接渡す） |
| 一意か | **概ね一意**（writer 1・protocol 背後に隔離済み）。ただし同一 VM 内で「表示は `@Published isOnline` ミラー、再生判定は monitor 直読」と参照元が分かれ、Combine の `receive(on: .main)`（`:134-136`）による遅延ぶん 2 値が乖離し得る |
| 候補 owner | (i) VM 内の参照を直読へ統一（表示も monitor 由来の単一値へ）。(ii) ミラーへ統一し `resolvePlaybackURL` はミラーを受け取る。(iii) 現状維持（乖離は 1 run loop 未満と仮定し、仮定を明記） |
| 選択条件 | SG-A4 |

### (f) 認証状態・トークン

| 項目 | 内容 |
|---|---|
| writer（authStatus / currentUser） | `AppState.swift:153-154`（completeLogin）, `:207-208`（refreshAuth 成功）, `:218-219`（catch）, `:300-301`（logout）／**層またぎ** `Settings/AccountSettingsView.swift:308`（View が `appState.currentUser` を直接代入） |
| reader | `AppState.swift:145`、`NewsListenAppApp.swift:50`、`Settings/AccountSettingsView.swift:50,71,81`、`Settings/SettingsView.swift:204`、`Admin/AdminUsersView.swift:52` |
| writer（token） | `AppState.swift:152`, `:217`（401 相当で破棄）, `:299`／実体 `Networking/SessionStore.swift:36-45`（Keychain） |
| reader（token） | `AppState.swift:141`, `:202` |
| 一意か | token は**一意**（protocol 注入 `AppState.swift:121,345`、Keychain 単一 account `Networking/SessionStore.swift:29`）。authStatus / currentUser は**否**（View からの直接代入が 1 経路） |
| 候補 owner | (i) `AppState` を唯一の writer とし `currentUser` を `private(set)` + 更新 intent メソッド化。(ii) 認証を専用 owner へ切り出し `AppState` は購読側。(iii) 現状維持＋View 直書き経路を規約で禁止 |
| 選択条件 | SG-A9（`AccountSettingsView` の API 直呼びは Boundary Function 所管。OB-A2） |

### (g) APIClient インスタンス

| 項目 | 内容 |
|---|---|
| 生成点 | `AppState.swift:137-142`（computed。アクセスのたびに `APIClient(baseURL:apiKey:sessionToken:)` を新規生成し、その瞬間の `sessionStore.token` を **let でスナップショット**）。テスト注入は `:132` の `apiClientOverride` |
| 保持点 | `Podcast/PodcastViewModel.swift:119`（init で受領・保持）。`NewsListenAppApp.swift:118-121` が起動時に 1 度だけ渡す |
| 取得点 | `Settings/SettingsViewModel.swift:42`（`appState?.apiClient ?? apiClientOverride` を毎回 computed 取得） |
| 一意か | **否**（instance は多数・生成規則は 1 つ）。結果として**トークン鮮度が保持側で固定される**: 起動時に注入された `PodcastViewModel.apiClient` は、以後 token が更新・破棄されても古い token を持ち続ける。`SettingsViewModel` は毎回取り直すため鮮度が異なる |
| 影響 | QA4: logout / 失効後も `PodcastViewModel` 経由の API 呼出が旧 token を送出しうる（`Podcast/PodcastViewModel.swift:462,848` は `try?` / silent catch のため失敗しても観測されない） |
| 候補 owner | (i) token を都度解決する client（factory または token provider 注入）へ変更し、保持型は「client の取得手段」を持つ。(ii) 認証イベントで保持側の client を差し替える。(iii) 現状維持＋旧 token 送出が無害である根拠（サーバ側失効）を確認して仮定として記録 |
| 選択条件 | SG-A7 |

---

## 4. 依存方向: 現状と違反

```text
現状（実線 = 実依存、★ = 逆流・層またぎ）

  NewsListenAppApp (composition root)
        │ :19 AppState()        :118 PodcastViewModel(apiClient:...)
        ▼
     AppState ──────────► SessionStore(protocol) ──► Keychain
        │ :137-142 computed APIClient
        ▼
   PodcastViewModel ──► APIClient ──► URLSession(seam)
        │  ├──► AudioCacheManager ──► FileManagerProtocol(seam)
        │  ├──► NetworkMonitoring(protocol) ──► NWPathMonitor
        │  └──► PlaybackQueue（純粋値型・外部 I/O なし）
        │
        ★ :13 import SwiftUI / :14 import UIKit（:456,459 beginBackgroundTask）
        ★ :11,12 AVFoundation / MediaPlayer を public 面へ露出（:95 player, :399/:407/:416/:424 の引数型）
        ★ シングルトン直参照: MPRemoteCommandCenter.shared()/MPNowPlayingInfoCenter.default()/AVAudioSession.sharedInstance()/NotificationCenter.default
        ▲
        ★ View → VM 直接書込: PodcastView.swift:45,135（errorMessage = nil）
        ★ View → AppState 直接書込: AccountSettingsView.swift:308
        ★ DesignSystem/PreviewSupport.swift:152,164 が VM の @Published を外部代入（#if DEBUG だが production target）
```

| ID | 違反 | Evidence | 影響 quality |
|---|---|---|---|
| DV1 | ViewModel が UIKit / SwiftUI に依存 | `Podcast/PodcastViewModel.swift:13,14`（用途は `:456,459` の `UIApplication.shared.beginBackgroundTask`） | QA2（UI framework なしで VM をテストできない）／QA1 |
| DV2 | ViewModel の公開面に AVFoundation 型が露出 | `Podcast/PodcastViewModel.swift:11,12` と `:399,407,416,424` の引数型 | QA1（再生実装を差し替えると公開面が動く）。ただし View 側の AVFoundation 参照は 0 で、実利用者はテストのみ |
| DV3 | DesignSystem が PodcastViewModel の内部状態へ書込む | `DesignSystem/PreviewSupport.swift:152,164` が `PodcastViewModel(apiClient:)` を生成し `@Published` を直接代入 | QA1（下位層 DesignSystem が上位 VM の内部に結合）／QA2 |
| DV4 | View が VM / AppState の状態を直接書込む | `Podcast/PodcastView.swift:45,135`、`Settings/AccountSettingsView.swift:308` | QA1／QA4（認証状態の writer が 2 層に分散） |
| DV5 | シングルトン直参照でテスト seam が無い | `Podcast/PodcastViewModel.swift` の MPRemoteCommandCenter / MPNowPlayingInfoCenter / AVAudioSession / NotificationCenter 直呼び | QA2（ロック画面連携・割り込み処理が単体検証不能・UV3 の実機観測に依存） |
| DV6 | 業務ルールが View 層に存在 | `Settings/AccountSettingsView.swift:317`（パスワード最小長 8）と `Admin/AdminUsersViewModel.swift:47`（同値・別 owner）、`Podcast/QuizSheetView.swift` の採点 | QA1（R1 相当。Boundary/Domain Function と重複するため詳細は OB-A2） |
| DV7 | production target にテスト用実装が同居 | `Networking/SessionStore.swift:19-22`（`InMemorySessionStore`、DEBUG ガードなし） | QA4（token を平文保持する実装が出荷物に含まれる。到達経路は `AppState.swift:345` の既定引数が Keychain のため現状は未使用） |

**target の依存方向は本 package では選択しない**。候補は SG-A6（分割単位）・SG-A10（AV / Remote 境界の seam 化）に隔離し、選択されるまで「候補」として扱う。

---

## 5. current findings（技術負債 5 因子）

```yaml
current_findings:
  - id: F-A1
    quality_scenario_ids: [QS2]
    levels: [system, journey, future_change]
    observed_symptom: "「現在再生中」が currentPodcast / queue.currentIndex / AVPlayer.currentItem の 3 系統に分かれ、playById(:381-388) と replayCurrentEpisode(:481-487) と removeFromQueue(:543-545) で系統間が乖離する"
    violated_quality_or_target: "QA1（R3: source of truth 一意性）。spec 不変条件 4（docs/design/shared-playback-spec.md:53）が定める current の定義と、VM 側 current の定義が別物"
    wrong_responsibility_or_authority: "再生セッションの状態権威が VM（currentPodcast）とキューモデル（currentIndex）に二重に置かれている"
    structural_cause: "キュー機能（issue #81）を、既存の currentPodcast 中心の再生実装へ後付けしたため、正本の移譲ではなく並置になった"
    product_or_delivery_impact: "キュー操作後に UI が示すエピソードと次に再生されるエピソードが食い違い得る。QueueSheet.swift:22 が AND 条件で UI 側に吸収しており、規則が View へ漏れている"
    owner: {status: unknown, value: "", resolution_or_reason: "コード所有者の記録が repo に無い。user へ確認が必要", evidence: []}
    evidence:
      - {status: confirmed, source: "Podcast/PodcastViewModel.swift:281,441,517-519 / Podcast/PlaybackQueue.swift:31-34", supports: "2 系統の writer が別"}
      - {status: confirmed, source: "docs/design/shared-playback-spec.md:53", supports: "spec の current 定義は currentIndex 由来"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: high, impact: "core capability CAP1 の中心概念", rationale: "V1 の成功条件に直結", evidence: [{status: confirmed, source: "CAP1"}]}
        - {kind: expected_change, rating: high, impact: "spec 改訂のたびに両系統へ波及", rationale: "ADR-053 で既に 1 度正本が変わっている", evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:37-128"}]}
        - {kind: debt_impact, rating: high, impact: "新しい再生導線を足すたびに『どちらを更新するか』の判断が必要になり、判断漏れが QS2 の失敗として現れる。実際 playById は queue を更新していない", rationale: "3 経路中 2 経路が非同期", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:381-388,481-487"}]}
        - {kind: failure_risk, rating: medium, impact: "UI 不整合。データ破壊や情報漏洩は伴わない", rationale: "QueueSheet.swift:22 が表示面を防御", evidence: [{status: inferred, source: "Podcast/QueueSheet.swift:22"}]}
        - {kind: remediation_cost, rating: high, impact: "currentPodcast の reader が 6 ファイル・20 箇所以上に分布し、正本移譲は広域変更になる", rationale: "p1-domain.md §1 の reader 一覧", evidence: [{status: inferred, source: "p1-domain.md §1"}]}
      comparison_rationale: "criticality と expected_change が high で debt_impact も high だが remediation_cost が high。web 決定（現在再生中 = currentIndex）との整合が先に決まらないと手戻りするため、単独で now とせず SG-A1 の決定待ちにする"
      owner: {status: unknown, value: "", resolution_or_reason: "user 決定待ち（SG-A1）", evidence: []}
    priority: unknown

  - id: F-A2
    quality_scenario_ids: [QS5, QS6]
    levels: [system, journey, organization]
    observed_symptom: "logout（AppState.swift:282-302）で音声キャッシュ・NowPlaying 情報・再生セッションのいずれも消去されない。仕様 §6.3 が指定する AudioCacheManager.removeAllDownloads() は存在しない（Networking/AudioCacheManager.swift の公開 API は :45,:52,:62,:71,:80,:90 の 6 つ）"
    violated_quality_or_target: "QA4（constraint・must-hold）。R6"
    wrong_responsibility_or_authority: "『主体データの消去』の owner が不在。AppState が token と一部 UserDefaults（:298）だけを消し、キャッシュ・NowPlaying の owner は誰も呼ばれない"
    structural_cause: "logout 処理が『自分が知っている状態を消す』形で書かれており、主体データ保持者を列挙する境界（消去参加者の登録点）が無い。新しい主体データが増えても logout は自動的に無知になる"
    product_or_delivery_impact: "共有端末で前利用者の音声ファイルとロック画面情報が残る。V2 が未達で、仕様書は達成済みと読める（ドキュメントと実装の contradiction）"
    owner: {status: unknown, value: "", resolution_or_reason: "user 確認が必要（消去範囲の決定は SG-A5）", evidence: []}
    evidence:
      - {status: contradiction, source: "docs/design/shared-playback-spec.md:312 vs AppState.swift:282-302", supports: "仕様が規定する呼出が実装に無い"}
      - {status: confirmed, source: "Networking/AudioCacheManager.swift:45-95", supports: "removeAllDownloads は未実装（clearCache は存在）"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: high, impact: "supporting capability だが security constraint に該当", rationale: "QA4 は落とさない品質", evidence: [{status: confirmed, source: "QA4"}]}
        - {kind: expected_change, rating: low, impact: "logout 経路の変更頻度は低い", rationale: "AppState.logout の履歴的安定", evidence: [{status: inferred, source: "AppState.swift:282-302 のコメントが issue #80 / ADR-086 に言及"}]}
        - {kind: debt_impact, rating: high, impact: "主体データが増えるたびに消去漏れが再発する構造。実際 ADR-086 で祝福トラッカーだけが個別に追加されている（:296-298）", rationale: "列挙型の消去で拡張点が無い", evidence: [{status: confirmed, source: "AppState.swift:296-298"}]}
        - {kind: failure_risk, rating: high, impact: "第三者へ前利用者の学習音声が露出。ロック画面にタイトルが残る", rationale: "共有端末前提が仕様に明記", evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:305"}]}
        - {kind: remediation_cost, rating: low, impact: "clearCache() は既存。呼出点の追加と NowPlaying クリアで足りる可能性が高い", rationale: "既存 API で大半を賄える", evidence: [{status: inferred, source: "Networking/AudioCacheManager.swift:90-95 / Podcast/PodcastViewModel.swift:611 付近の NowPlaying 更新"}]}
      comparison_rationale: "failure_risk high かつ remediation_cost low、さらに仕様と実装の contradiction を伴うため、5 因子の比較では最上位候補。ただし『どこまで消すか』（キャッシュ全体か主体分のみか、失効時も同様か）は QA3 との trade-off（TD-A1）を含む user 決定であり、priority 確定は SG-A5 に従属する"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A5 の owner: user", evidence: []}
    priority: unknown

  - id: F-A3
    quality_scenario_ids: [QS3]
    levels: [local, system, journey]
    observed_symptom: "再生セッションが 15 個の独立 @Published atom で表現され、error と paused が同じ atom 組合せになりうる（:416-420 は errorMessage と isPlaying=false のみ更新し player を解放せず didFinish も触らない）。auto-advance 失敗時は queue.currentIndex（:441）だけが進み currentPodcast（:281 未実行）は前のままの中間状態になる"
    violated_quality_or_target: "QA3 / QA2（R2: 不正状態を公開経路から構築できないこと）"
    wrong_responsibility_or_authority: "再生セッションの遷移権威が『個々の atom の書き手』へ分散し、遷移規則の owner が居ない"
    structural_cause: "状態が排他 enum ではなく独立変数の集合で表現されている。排他型は PlayerPresentation と DownloadState の 2 つだけで、再生セッション自体には無い"
    product_or_delivery_impact: "auto-advance が失敗すると『停止でも次進行でもない』状態になり、利用者の再試行導線（replayCurrentEpisode:481-487）は前エピソードを再生する。web の確定決定（失敗時は停止し失敗エピソードを current に保持）と観測挙動が一致しない"
    owner: {status: unknown, value: "", resolution_or_reason: "user 確認が必要（SG-A3 / SG-A6）", evidence: []}
    evidence:
      - {status: confirmed, source: "Podcast/PodcastViewModel.swift:36-69", supports: "@Published 15 atom・排他 enum 不在"}
      - {status: confirmed, source: "Podcast/PodcastViewModel.swift:435-465 と :262-267", supports: "advance 後 play 失敗で中間状態が生じる"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: high, impact: "CAP1 core の失敗経路", rationale: "移動中のオフラインは常態", evidence: [{status: confirmed, source: "QS3"}]}
        - {kind: expected_change, rating: high, impact: "再生状態の追加（例: sleep timer）のたびに atom が増える", rationale: "現状 15 atom への増加履歴", evidence: [{status: inferred, source: "Podcast/PodcastViewModel.swift:36-69 の issue 番号コメント"}]}
        - {kind: debt_impact, rating: high, impact: "テストが『ありえない組合せ』を検証できず、production で初めて中間状態が観測される。UV3 が未実行のまま残っている", rationale: "verification-run.md §10 UV3", evidence: [{status: confirmed, source: "verification-run.md §10"}]}
        - {kind: failure_risk, rating: medium, impact: "再生が止まり利用者が手動復帰を要する。データ損失なし", rationale: "journey の中断", evidence: [{status: inferred, source: "Podcast/PodcastViewModel.swift:441-442"}]}
        - {kind: remediation_cost, rating: medium, impact: "状態表現の変更は VM 内に閉じるが、View 側 reader（AudioPlayerView 等）の条件式が追随する", rationale: "reader は同一モジュール内", evidence: [{status: inferred, source: "p1-domain.md §1"}]}
      comparison_rationale: "F-A1 と同じ core capability の負債だが、こちらは失敗経路の観測挙動が web 決定と食い違う点で cross-platform 整合の論点を含む。remediation_cost は F-A1 より低いが、SG-A3（失敗時方針）の決定前に状態表現を確定すると手戻りする"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A3 決定後に再評価", evidence: []}
    priority: unknown

  - id: F-A4
    quality_scenario_ids: [QS8]
    levels: [system, journey]
    observed_symptom: "既定速度（AppState.swift:63-65）とセッション速度（Podcast/PodcastViewModel.swift:50,575-578）が接続されておらず、設定変更が次の再生に反映されない"
    violated_quality_or_target: "QA1（R3）。web 確定決定『セッション速度は再生開始時に既定から初期化』との不一致"
    wrong_responsibility_or_authority: "2 概念の関係を定義する owner が不在。どちらも自分だけを正本とみなしている"
    structural_cause: "設定ドメイン（AppState）と再生ドメイン（PodcastViewModel）が合成 root（NewsListenAppApp.swift:118）で APIClient しか受け渡していないため、設定値を再生側へ伝える経路が構造的に無い"
    product_or_delivery_impact: "設定画面で速度を変えても再生が 1.0 で始まる。web と観測挙動が異なる"
    owner: {status: unknown, value: "", resolution_or_reason: "SG-A2", evidence: []}
    evidence:
      - {status: confirmed, source: "AppState.swift:63-65,233,353 / Podcast/PodcastViewModel.swift:50,291,575-578", supports: "両者に相互参照が無い"}
      - {status: confirmed, source: "NewsListenAppApp.swift:113-122", supports: "VM へ渡るのは apiClient と closure のみ"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: medium, impact: "利用者の体感に直結するが再生自体は成立する", rationale: "機能不全ではなく設定無効", evidence: [{status: inferred, source: "QS8"}]}
        - {kind: expected_change, rating: medium, impact: "preferences 項目が増えると同型の断絶が再発", rationale: "difficulty / weeklyGoal も AppState 側のみ", evidence: [{status: confirmed, source: "AppState.swift:229-238"}]}
        - {kind: debt_impact, rating: medium, impact: "設定と再生の断絶が『設定が効かない』バグとして個別報告され、都度その場配線で塞がれるおそれ", rationale: "配線点が無いため回避策が局所化しやすい", evidence: [{status: inferred, source: "NewsListenAppApp.swift:113-122"}]}
        - {kind: failure_risk, rating: low, impact: "安全性・データ影響なし", rationale: "表示・体感のみ", evidence: [{status: inferred, source: "QS8"}]}
        - {kind: remediation_cost, rating: low, impact: "再生開始時に既定を読む配線を 1 箇所追加するだけで観測挙動は揃う", rationale: "play() は :262 の 1 入口", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:262-291"}]}
      comparison_rationale: "criticality medium・cost low で費用対効果は良いが、『既定をどう伝えるか（注入 / 購読 / 引数）』は SG-A2 の選択に依存する。F-A2 より failure_risk が低いため後位"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A2", evidence: []}
    priority: unknown

  - id: F-A5
    quality_scenario_ids: [QS4]
    levels: [local, system]
    observed_symptom: "updatePlaybackPosition の戻り値を破棄（Podcast/PodcastViewModel.swift:848 の `_ =`）し、失敗は catch 本文がコメントのみ（:849-851、本 repo で唯一の『本文コメントのみ catch』）"
    violated_quality_or_target: "QA3（TD-A2 の観測可能性側）／QA1（R3: server 正本との整合）"
    wrong_responsibility_or_authority: "server が正本（spec §6.2 server-wins）であるにもかかわらず、同期結果を local へ反映する責務の所在が無い"
    structural_cause: "同期を『投げっぱなしの副作用』として実装したため、結果を受け取る側が設計されていない"
    product_or_delivery_impact: "同期失敗が誰にも観測されず、ローカル表示位置が server と乖離したまま進む。production にログ API が 0 のため事後調査も不能"
    owner: {status: unknown, value: "", resolution_or_reason: "SG-A8（観測方針）", evidence: []}
    evidence:
      - {status: confirmed, source: "Podcast/PodcastViewModel.swift:844-851", supports: "戻り値破棄と無痕跡 catch"}
      - {status: confirmed, source: "verification-run.md §7（production のログ API 0）", supports: "観測手段が存在しない"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: medium, impact: "複数端末での再開位置整合に関わる", rationale: "spec §6.2 が server-wins を規定", evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:302"}]}
        - {kind: expected_change, rating: low, impact: "同期経路の変更頻度は低い", rationale: "issue #50 以降安定", evidence: [{status: inferred, source: "Podcast/PodcastViewModel.swift:838-843 のコメント"}]}
        - {kind: debt_impact, rating: medium, impact: "障害時に『再開位置がおかしい』の原因切り分けが不能。再現待ちのコストが継続的に発生する", rationale: "痕跡が残らない", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:849-851"}]}
        - {kind: failure_risk, rating: low, impact: "再生位置のずれのみ", rationale: "データ破壊・漏洩なし", evidence: [{status: inferred, source: "QS4"}]}
        - {kind: remediation_cost, rating: low, impact: "戻り値の反映と観測追加で局所的", rationale: "1 メソッド内", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:844-851"}]}
      comparison_rationale: "単独では low〜medium。ただし SG-A8（観測方針）が決まれば同型の try? 22 件（verification-run.md §5）へ一括で効くため、方針決定とセットで扱うと費用対効果が上がる"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A8", evidence: []}
    priority: unknown

  - id: F-A6
    quality_scenario_ids: [QS7]
    levels: [system]
    observed_symptom: "AudioCacheManager が 2 箇所で独立生成され（Podcast/PodcastViewModel.swift:122 の既定引数、Settings/SettingsViewModel.swift:69,76 の既定引数）、SettingsViewModel.clearCache(:184-192) は PodcastViewModel.downloadedIds(:55) を無効化しない"
    violated_quality_or_target: "QA1（R3: キャッシュ有無の authority）"
    wrong_responsibility_or_authority: "キャッシュ状態の owner は FS だが、状態変化の通知責務がどこにも無い。ミラー保持者（VM）が自分で再同期する契約も明示されていない"
    structural_cause: "既定引数による暗黙生成を合成 root の代わりに使っているため、依存の共有関係がコード上に現れない"
    product_or_delivery_impact: "設定でキャッシュを全削除した直後、Podcast 一覧が『ダウンロード済み』を表示し続け、タップすると未キャッシュとして扱われる"
    owner: {status: unknown, value: "", resolution_or_reason: "SG-A6", evidence: []}
    evidence:
      - {status: confirmed, source: "Podcast/PodcastViewModel.swift:122 / Settings/SettingsViewModel.swift:69,76", supports: "既定引数で別インスタンス"}
      - {status: confirmed, source: "NewsListenAppApp.swift:118-121 / Settings/SettingsView.swift:57", supports: "本番経路が既定引数を採用している"}
      - {status: confirmed, source: "Settings/SettingsViewModel.swift:184-192 / Podcast/PodcastViewModel.swift:158", supports: "再同期は loadPodcasts 経路のみ"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: medium, impact: "CAP2 supporting。誤表示だが再生自体は fallback する", rationale: "resolvePlaybackURL が isCached を都度問い合わせる（:264）", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:264"}]}
        - {kind: expected_change, rating: low, impact: "キャッシュ操作の追加は稀", rationale: "LRU 等はスコープ外と明記", evidence: [{status: confirmed, source: "Settings/SettingsViewModel.swift:175"}]}
        - {kind: debt_impact, rating: medium, impact: "logout 時の一括削除（F-A2 の是正）を実装する際、どのインスタンスから消すかという同じ問いが再発する", rationale: "F-A2 と構造原因を共有", evidence: [{status: inferred, source: "F-A2"}]}
        - {kind: failure_risk, rating: low, impact: "UI 不整合のみ", rationale: "FS は整合している", evidence: [{status: confirmed, source: "Networking/AudioCacheManager.swift:45-46（同一 cacheDirectory 規則）"}]}
        - {kind: remediation_cost, rating: low, impact: "合成 root での 1 インスタンス注入に変更するだけで両 VM が同一 owner を共有する", rationale: "init 引数は既に存在", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:122 / Settings/SettingsViewModel.swift:69,76"}]}
      comparison_rationale: "単独では low だが F-A2（QA4 constraint）の前提条件になるため、F-A2 の実施方針が決まれば同時に扱うのが合理的。単独着手は価値が小さい"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A6", evidence: []}
    priority: unknown

  - id: F-A7
    quality_scenario_ids: [QS3]
    levels: [local, system]
    observed_symptom: "同一 VM 内でネットワーク状態の参照元が分かれる（表示は @Published ミラー :61,:130,:134、再生判定は monitor 直読 :264）"
    violated_quality_or_target: "QA1（R3）"
    wrong_responsibility_or_authority: "ミラーと直読のどちらが VM 内の権威かが未定義"
    structural_cause: "オフラインバナー（issue #54）の購読と、再生可否判定の純関数化が別時期に導入され統合されていない"
    product_or_delivery_impact: "Combine の main queue ホップぶん 2 値が乖離し、『オンライン表示なのに再生不可』が理論上起こりうる（未観測）"
    owner: {status: unknown, value: "", resolution_or_reason: "SG-A4", evidence: []}
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:61,130,134,264", supports: "2 参照元"}]
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: low, impact: "稀な遷移タイミングのみ", rationale: "1 run loop 未満の窓", evidence: [{status: inferred, source: "Networking/NetworkMonitoring.swift:60-64"}]}
        - {kind: expected_change, rating: low, impact: "監視実装の変更は稀", rationale: "protocol 化済み", evidence: [{status: confirmed, source: "Networking/NetworkMonitoring.swift:33"}]}
        - {kind: debt_impact, rating: low, impact: "読み手が『どちらを見るべきか』を毎回判断する小さな認知コスト", rationale: "同一ファイル内で参照元が 2 つ", evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:61,264"}]}
        - {kind: failure_risk, rating: low, impact: "未観測", rationale: "実機観測 UV3 未実行", evidence: [{status: unknown, source: "verification-run.md §10"}]}
        - {kind: remediation_cost, rating: low, impact: "参照を 1 つへ寄せるだけ", rationale: "局所", evidence: [{status: inferred, source: "Podcast/PodcastViewModel.swift:264"}]}
      comparison_rationale: "全因子 low。他 finding の作業に付随して解消できる範囲で、単独では do-minimum 候補"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A4", evidence: []}
    priority: unknown

  - id: F-A8
    quality_scenario_ids: [QS6]
    levels: [system, journey]
    observed_symptom: "AppState.apiClient が computed で毎回新規生成し token をスナップショットする（AppState.swift:137-142 と APIClient の let sessionToken）。起動時に PodcastViewModel へ注入された client（NewsListenAppApp.swift:118-121）は以後 token 更新・破棄を反映しない"
    violated_quality_or_target: "QA4（R5: 失効後の主体データアクセス）／QA1（R3: token 権威）"
    wrong_responsibility_or_authority: "token の権威は SessionStore だが、client が値をコピーして保持するため実効的な権威が複製される"
    structural_cause: "APIClient が token を構築時定数として受け取る設計で、token 供給者への参照（provider）を持たない"
    product_or_delivery_impact: "logout / 失効後も長寿命 VM からの API 呼出が旧 token を送出しうる。送出側は try?（:462）と silent catch（:849-851）のため失敗しても観測されない"
    owner: {status: unknown, value: "", resolution_or_reason: "SG-A7", evidence: []}
    evidence:
      - {status: confirmed, source: "AppState.swift:137-142", supports: "computed 生成と token スナップショット"}
      - {status: confirmed, source: "NewsListenAppApp.swift:113-122 / Podcast/PodcastViewModel.swift:119", supports: "VM は起動時の 1 インスタンスを保持し続ける"}
      - {status: unknown, source: "サーバ側の token 失効挙動", supports: "旧 token がサーバで拒否されるなら実害は限定される。未確認（U-A2）"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: high, impact: "QA4 constraint に触れる", rationale: "認可境界の問題", evidence: [{status: confirmed, source: "QA4"}]}
        - {kind: expected_change, rating: low, impact: "生成規則の変更は稀", rationale: "computed 1 箇所", evidence: [{status: confirmed, source: "AppState.swift:137-142"}]}
        - {kind: debt_impact, rating: medium, impact: "『どの client が新しい token を持つか』が呼出側ごとに異なり（SettingsViewModel は都度取得、PodcastViewModel は保持）、認証系の変更のたびに全保持者を点検する必要が生じる", rationale: "取得方式が 2 種混在", evidence: [{status: confirmed, source: "Settings/SettingsViewModel.swift:42 vs Podcast/PodcastViewModel.swift:119"}]}
        - {kind: failure_risk, rating: unknown, impact: "サーバが失効 token を拒否するかが未確認のため、実害の大きさを確定できない", rationale: "backend 挙動の Evidence 不足", evidence: [{status: unknown, source: "本 review は ios scope"}]}
        - {kind: remediation_cost, rating: medium, impact: "APIClient の token 受領方式を変えると全生成点と 35 の @testable テストへ波及しうる", rationale: "生成点は 1 だが利用は広い", evidence: [{status: inferred, source: "verification-run.md §3"}]}
      comparison_rationale: "criticality high だが failure_risk が unknown（サーバ側挙動 U-A2）。unknown を high と決めつけて順位を確定しない。U-A2 の解消を先行させる"
      owner: {status: unknown, value: "", resolution_or_reason: "U-A2 解消後に user 判断", evidence: []}
    priority: unknown

  - id: F-A9
    quality_scenario_ids: [QS1, QS3]
    levels: [local, system, future_change]
    observed_symptom: "PodcastViewModel が 854 行で、再生制御・キュー・ダウンロード・NowPlaying・Remote Command・割り込み・位置同期・完聴記録を 1 型に持ち、UIKit / AVFoundation / MediaPlayer / NotificationCenter を直接参照する"
    violated_quality_or_target: "QA1 / QA2（DV1・DV2・DV5）"
    wrong_responsibility_or_authority: "複数の変更理由（再生エンジン・OS 連携・キュー意味論・ダウンロード）が 1 owner に同居"
    structural_cause: "MVVM の VM を『画面の全状態と全副作用の置き場』として運用しており、再生ドメインの独立した owner が無い"
    product_or_delivery_impact: "再生周りの変更が常に同一ファイルの競合になり、ロック画面連携・割り込み処理は単体検証できず実機観測（UV3 未実行）に依存する"
    owner: {status: unknown, value: "", resolution_or_reason: "SG-A6 / SG-A10", evidence: []}
    evidence:
      - {status: confirmed, source: "Podcast/PodcastViewModel.swift:11-14（import）, :36-69（@Published 15）", supports: "責務集中と framework 直参照"}
      - {status: confirmed, source: "verification-run.md §3（854 行で最大ファイル）", supports: "規模"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: high, impact: "CAP1 core の実装本体", rationale: "再生変更は必ずここを通る", evidence: [{status: confirmed, source: "CAP1"}]}
        - {kind: expected_change, rating: high, impact: "spec 改訂・OS 連携追加のたびに変更", rationale: "issue 番号コメントが多数", evidence: [{status: inferred, source: "Podcast/PodcastViewModel.swift:36-69"}]}
        - {kind: debt_impact, rating: high, impact: "F-A1・F-A3・F-A4・F-A5・F-A7 のすべてがこの型の内部に居る。個別是正を重ねるほど型が肥大し、分割コストが上がる", rationale: "他 finding の共通宿主", evidence: [{status: inferred, source: "F-A1,F-A3,F-A4,F-A5,F-A7"}]}
        - {kind: failure_risk, rating: medium, impact: "検証不能領域（DV5）に回帰が潜る", rationale: "UV3 未実行", evidence: [{status: confirmed, source: "verification-run.md §10"}]}
        - {kind: remediation_cost, rating: high, impact: "分割は 509 テストの参照面へ波及し、DEBUG の PreviewSupport（DV3）も追随する", rationale: "テスト結合が強い", evidence: [{status: confirmed, source: "DesignSystem/PreviewSupport.swift:152,164"}]}
      comparison_rationale: "debt_impact が最も広い（他 5 finding の宿主）が remediation_cost も最大。分割単位を先に決めないと部分最適の分割で終わるため、SG-A6 を最優先の決定対象として扱う"
      owner: {status: unknown, value: "", resolution_or_reason: "SG-A6", evidence: []}
    priority: unknown

  - id: F-A10
    quality_scenario_ids: [QS6]
    levels: [organization, system]
    observed_symptom: "InMemorySessionStore（token を平文プロパティで保持）が production target に `#if DEBUG` ガードなしで含まれる"
    violated_quality_or_target: "QA4"
    wrong_responsibility_or_authority: "テスト double が production の配布物へ同居し、境界が target 分離で表現されていない"
    structural_cause: "テスト用実装を本番ファイル内に併置する慣行（NetworkMonitoring.swift:70 の StubNetworkMonitor も同様）"
    product_or_delivery_impact: "現状は到達経路が無い（AppState.swift:345 の既定は KeychainSessionStore）が、将来の誤配線が静かに token を平文化しうる"
    owner: {status: unknown, value: "", resolution_or_reason: "user 判断", evidence: []}
    evidence:
      - {status: confirmed, source: "Networking/SessionStore.swift:19-22", supports: "DEBUG ガードなし"}
      - {status: confirmed, source: "AppState.swift:345", supports: "本番既定は Keychain で現状未到達"}
    priority_assessment:
      factors:
        - {kind: business_criticality, rating: medium, impact: "現状未到達だが QA4 の防御層", rationale: "潜在的な誤配線リスク", evidence: [{status: confirmed, source: "AppState.swift:345"}]}
        - {kind: expected_change, rating: low, impact: "SessionStore の変更は稀", rationale: "protocol 2 実装のみ", evidence: [{status: confirmed, source: "Networking/SessionStore.swift:13-27"}]}
        - {kind: debt_impact, rating: low, impact: "同型の double 併置が他にもあり（StubNetworkMonitor）、規約が無いため増え続ける", rationale: "慣行の問題", evidence: [{status: confirmed, source: "Networking/NetworkMonitoring.swift:70"}]}
        - {kind: failure_risk, rating: low, impact: "到達経路が現状無い", rationale: "既定引数が Keychain", evidence: [{status: confirmed, source: "AppState.swift:345"}]}
        - {kind: remediation_cost, rating: low, impact: "テストターゲットへの移動または DEBUG ガードのみ", rationale: "局所", evidence: [{status: inferred, source: "Networking/SessionStore.swift:19-22"}]}
      comparison_rationale: "failure_risk low・cost low。do-minimum で処理できる最小の負債であり、上位 finding の作業に合流させる候補"
      owner: {status: unknown, value: "", resolution_or_reason: "user 判断", evidence: []}
    priority: unknown
```

---

## 6. options（候補。選択しない）

```yaml
options:
  - id: O0
    kind: do_nothing
    summary: "現状構造を維持し、web との差分を『iOS 仕様』として仕様書側へ追記する"
    owner: user
    addresses_finding_ids: []
    improves_quality_scenario_ids: []
    degrades_quality_scenario_ids: [QS2, QS5, QS8]
    scope: [docs]
    system_effects: {local: [], system: ["2 正本が固定化"], journey: ["QS5 が未達のまま"], organization: ["共有仕様が platform 別条項を持つ"], future_change: ["spec 改訂のたび両 platform で別判断"]}
    costs: ["ドキュメント更新のみ"]
    risks: ["QA4 constraint 違反が仕様として追認される（F-A2）。constraint を落とす決定は user のみが可能"]
    reversibility: reversible
    evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:305-315", supports: "現仕様は共通挙動を要求しており、追記は仕様の後退になる"}]
    assumption_ids: []
    unknown_ids: [U-A1]
    validation_ids: [VAL4]
  - id: O1
    kind: do_minimum
    summary: "QA4 constraint に限定して是正: logout / 失効時の主体データ消去（F-A2）と、その前提となる AudioCacheManager の単一インスタンス化（F-A6）だけを行う"
    owner: user
    addresses_finding_ids: [F-A2, F-A6]
    improves_quality_scenario_ids: [QS5, QS6, QS7]
    degrades_quality_scenario_ids: [QS3]
    scope: [AppState, AudioCacheManager, PodcastViewModel, SettingsViewModel, 合成 root]
    system_effects: {local: ["消去呼出の追加"], system: ["キャッシュ owner が 1 インスタンスへ"], journey: ["logout 後にオフライン再生資産を失う（TD-A1 の機密性優先）"], organization: ["仕様 §6.3 と実装が一致"], future_change: ["主体データ追加時の消去漏れは構造的には残る"]}
    costs: ["build: 小", "migration: 既存キャッシュは初回 logout 時に消える", "operation: なし"]
    risks: ["利用者がダウンロード済み音声を失う体験変化（QA3 低下）", "消去範囲の解釈違い（SG-A5 未決なら実装できない）"]
    reversibility: reversible
    evidence: [{status: confirmed, source: "Networking/AudioCacheManager.swift:90-95", supports: "clearCache が既存で流用可能"}]
    assumption_ids: [P-A1]
    unknown_ids: []
    validation_ids: [VAL4, VAL1]
  - id: O2
    kind: incremental
    summary: "『現在再生中』の正本を 1 つへ寄せ、派生値化する（F-A1）。web 決定に合わせるか否かは SG-A1"
    owner: user
    addresses_finding_ids: [F-A1, F-A3]
    improves_quality_scenario_ids: [QS2, QS3]
    degrades_quality_scenario_ids: []
    scope: [PodcastViewModel, PlaybackQueue, QueueSheet, PodcastView, MiniPlayerView, AudioPlayerView]
    system_effects: {local: ["currentPodcast が computed 化される候補"], system: ["非同期経路 playById / replay / remove の扱いを契約で規定"], journey: ["キュー操作後の表示と次再生が一致"], organization: ["spec 不変条件 4 と実装が一致"], future_change: ["再生導線追加時の判断点が 1 つ"]}
    costs: ["build: 中〜大（reader 20 箇所超）", "learning: 既存テストの前提更新"]
    risks: ["509 テストの広域修正", "playById の意味（キューに載せるか）が未決定だと再度手戻り"]
    reversibility: costly
    evidence: [{status: confirmed, source: "p1-domain.md §5 / docs/design/shared-playback-spec.md:53", supports: "3 系統と spec 定義"}]
    assumption_ids: []
    unknown_ids: [U-A3]
    validation_ids: [VAL1, VAL2]
  - id: O3
    kind: incremental
    summary: "再生セッション状態を排他型で表現し、auto-advance 失敗時の観測挙動を確定させる（F-A3）"
    owner: user
    addresses_finding_ids: [F-A3]
    improves_quality_scenario_ids: [QS3]
    degrades_quality_scenario_ids: []
    scope: [PodcastViewModel, AudioPlayerView, MiniPlayerView]
    system_effects: {local: ["atom 群の一部が enum へ集約"], system: ["error と paused が判別可能に"], journey: ["失敗時の利用者導線が一意"], organization: ["web と挙動を揃えるか否かの決定が必要"], future_change: ["状態追加が enum case 追加になる"]}
    costs: ["build: 中", "learning: View 条件式の更新"]
    risks: ["SG-A3 未決のまま実装すると web と別挙動を固定化する"]
    reversibility: costly
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:416-420,435-465", supports: "現状の判別不能性"}]
    assumption_ids: []
    unknown_ids: []
    validation_ids: [VAL3]
  - id: O4
    kind: incremental
    summary: "PodcastViewModel を責務単位へ分割し、OS 連携（Remote Command / NowPlaying / AudioSession / 割り込み）を port 背後へ隔離する（F-A9・DV1・DV2・DV5）"
    owner: user
    addresses_finding_ids: [F-A9, F-A5, F-A7]
    improves_quality_scenario_ids: [QS1, QS3, QS4]
    degrades_quality_scenario_ids: []
    scope: [Podcast モジュール全体, DesignSystem/PreviewSupport, NewsListenAppTests]
    system_effects: {local: ["型が複数へ分割"], system: ["OS 連携が seam 化され単体検証可能に"], journey: ["変化なし（挙動保存が前提）"], organization: ["レビュー単位が小さくなる"], future_change: ["再生エンジン差し替えが局所化"]}
    costs: ["build: 大", "migration: テスト参照面の更新", "learning: 新境界の習得"]
    risks: ["挙動保存を証明できない分割は回帰を招く", "分割単位を誤ると型が増えるだけで変更容易性が上がらない"]
    reversibility: costly
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:11-14,36-69", supports: "責務集中の実測"}]
    assumption_ids: [P-A2]
    unknown_ids: []
    validation_ids: [VAL1, VAL2, VAL3]
  - id: O5
    kind: incremental
    summary: "設定（既定速度ほか preferences）と再生セッションの接続経路を合成 root で定義する（F-A4）"
    owner: user
    addresses_finding_ids: [F-A4]
    improves_quality_scenario_ids: [QS8]
    degrades_quality_scenario_ids: []
    scope: [NewsListenAppApp, AppState, PodcastViewModel]
    system_effects: {local: ["play() 開始時に既定を参照"], system: ["設定→再生の一方向依存が明示"], journey: ["設定が効く"], organization: ["preferences 追加時の配線点が 1 つ"], future_change: ["同型の断絶が再発しない"]}
    costs: ["build: 小"]
    risks: ["VM が AppState へ直接依存すると逆に結合が増える（値注入 vs 参照注入の選択が必要）"]
    reversibility: reversible
    evidence: [{status: confirmed, source: "NewsListenAppApp.swift:113-122", supports: "現在 VM へ渡るのは apiClient と closure のみ"}]
    assumption_ids: []
    unknown_ids: []
    validation_ids: [VAL1]
```

---

## 7. Selection Gate（すべて owner: user・status: pending）

```yaml
selection_gates:
  - id: SG-A1
    subject: "『現在再生中』の正本を PlaybackQueue.currentIndex にするか（web 決定との整合）"
    candidate_ids: [O2, O0]
    decision_condition: "(i) currentIndex を正本にし currentPodcast を派生値化 / (ii) currentPodcast を正本にし queue を待機列専用へ縮退 / (iii) 2 正本を維持し同期契約を明文化。判断軸は『spec 不変条件 4 と web 実装に iOS を合わせるか』と『reader 20 箇所超の改修コストを今払うか』"
    evidence_required: ["web 側の実装が実際に currentIndex 正本であることの確認", "playById（一覧に無いエピソードのディープリンク）をキューへ載せるかの意味決定"]
    evidence_acquisition: ["web モジュールの対応 package / 実装の確認（OB-A1）", "user へ playById の期待挙動を確認"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:53 / Podcast/PodcastViewModel.swift:281,381-388", supports: "spec と実装の定義差"}]
  - id: SG-A2
    subject: "既定速度（AppState）とセッション速度（PodcastViewModel）の接続方法"
    candidate_ids: [O5, O0]
    decision_condition: "(i) 再生開始時に既定値を値として受け取り初期化（web 決定と同形・VM は AppState に依存しない） / (ii) VM が設定 owner を購読（変更が即時反映されるが結合が増える） / (iii) 非連動を仕様として明記。判断軸は『再生中に設定を変えたとき、その再生に反映すべきか』"
    evidence_required: ["再生中の設定変更に関する期待挙動", "web の初期化タイミングの実装"]
    evidence_acquisition: ["user へ確認", "OB-A1"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "AppState.swift:63-65 / Podcast/PodcastViewModel.swift:50,575-578", supports: "接続コード不在"}]
  - id: SG-A3
    subject: "auto-advance 先の再生失敗時の方針（停止 vs スキップ vs 現状の中間状態）"
    candidate_ids: [O3, O0]
    decision_condition: "(i) 停止（失敗エピソードを current に保持し error 状態。手動 play で再試行＝web 確定決定） / (ii) スキップ（次の再生可能エピソードへ進む。オフライン時に大量スキップの危険） / (iii) 現状維持。判断軸は『オフライン時に未キャッシュが連続する状況で、利用者が何を期待するか』"
    evidence_required: ["オフライン混在キューでの利用実態", "web 決定の適用範囲が iOS にも及ぶかの user 判断"]
    evidence_acquisition: ["user へ確認", "実機観測 UV3"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:435-465,262-267", supports: "現状は停止でもスキップでもない"}]
  - id: SG-A5
    subject: "logout / 失効時に消去する主体データの範囲（音声キャッシュ・NowPlaying・UserDefaults・再生セッション）"
    candidate_ids: [O1, O0]
    decision_condition: "(i) 仕様 §6.3 どおり音声キャッシュ全削除 + NowPlaying クリア + 再生停止 + 主体依存 UserDefaults 削除（QA4 優先・TD-A1 で QA3 を明示的に劣化させる） / (ii) キャッシュは残し NowPlaying と再生セッションのみ消す（共有端末前提を緩める） / (iii) logout と 401 失効で範囲を変える。判断軸は『共有端末前提を維持するか』と『UserDefaults のどのキーが主体依存か』"
    evidence_required: ["共有端末前提の有効性", "UserDefaults 5 キー（AppState.swift:40-47 付近）と AchievementCelebrationTracker 以外の主体依存値の棚卸し", "失効（AppState.swift:216-220）と logout（:282-302）を同一経路にするか"]
    evidence_acquisition: ["user へ確認", "Domain Function による主体依存値の棚卸し（OB-A3）"]
    owner: user
    status: pending
    evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:312 vs AppState.swift:282-302", supports: "仕様と実装の不一致"}]
  - id: SG-A6
    subject: "PodcastViewModel（854 行）の分割単位と AudioCacheManager インスタンスの共有方法"
    candidate_ids: [O4, O1, O0]
    decision_condition: "分割単位の候補: (i) 再生エンジン制御 / キュー操作 / ダウンロード / OS 連携（NowPlaying・Remote・割り込み）/ 位置同期 の 5 責務 / (ii) 『再生セッション owner』と『カタログ + ダウンロード owner』の 2 分割 / (iii) 分割せず OS 連携のみ port 化。インスタンス共有の候補: (a) 合成 root（NewsListenAppApp.swift:19 近傍）で 1 つ生成し両 VM へ注入 / (b) キャッシュ状態 owner 型を新設し VM は購読 / (c) 既定引数のまま契約で再同期を規定。判断軸は『どの変更理由で別々に変わるか』と『既存 509 テストの参照面をどれだけ動かせるか』"
    evidence_required: ["直近の再生関連変更が同時に触ったファイル群（変更理由の実測）", "テスト参照面の影響見積り"]
    evidence_acquisition: ["git log での変更共起分析（read-only）", "VAL1 change simulation"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:36-69,122 / Settings/SettingsViewModel.swift:69,76", supports: "責務集中と 2 インスタンス"}]
  - id: SG-A7
    subject: "APIClient インスタンスと token 鮮度の扱い"
    candidate_ids: [O0]
    decision_condition: "(i) token provider を注入し呼出時に解決（鮮度保証。生成点 1・利用面広く波及） / (ii) 認証イベントで保持側 client を差し替え（局所だが漏れやすい） / (iii) 現状維持（サーバ側で失効 token が拒否される前提を仮定として明記）。判断軸は U-A2（サーバが失効 token をどう扱うか）"
    evidence_required: ["backend の token 失効時レスポンス", "長寿命 VM からの API 呼出が失効後に発生する経路の棚卸し"]
    evidence_acquisition: ["backend 仕様/実装の確認（本 review の scope 外・OB-A4）"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "AppState.swift:137-142 / NewsListenAppApp.swift:113-122", supports: "スナップショット保持"}]
  - id: SG-A4
    subject: "VM 内のネットワーク状態参照を直読へ寄せるかミラーへ寄せるか"
    candidate_ids: [O4, O0]
    decision_condition: "(i) 直読へ統一 / (ii) ミラーへ統一 / (iii) 現状維持し乖離窓が無害であることを仮定として明記。判断軸は『表示と判定が同一時刻の値であるべきか』"
    evidence_required: ["乖離が実機で観測されるか"]
    evidence_acquisition: ["UV3 実機観測", "VAL3 failure injection"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:61,130,134,264", supports: "2 参照元"}]
  - id: SG-A8
    subject: "best-effort 失敗（try? 22 件・silent catch 1 件）の観測方針"
    candidate_ids: [O4, O0]
    decision_condition: "(i) production へ構造化ログ/計測を導入し失敗を観測可能にする（現状ログ API 0） / (ii) 状態へ反映して UI で表現する（AppState.swift:240 の preferencesSyncFailed と同型） / (iii) 現状維持（観測不能を受容）。判断軸は TD-A2（耐障害性と観測可能性の trade-off）と、ログに秘匿情報を出さない制約"
    evidence_required: ["運用時に必要な調査能力の水準", "ログ出力先の方針（端末内 / 送信）と QA4 への影響"]
    evidence_acquisition: ["user へ確認", "agent-rules/12-security-guidelines.md の再確認"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "verification-run.md §5,§7 / Podcast/PodcastViewModel.swift:849-851", supports: "痕跡ゼロの失敗経路"}]
  - id: SG-A9
    subject: "View からの状態直接書込（PodcastView.swift:45,135 / AccountSettingsView.swift:308）の扱い"
    candidate_ids: [O4, O0]
    decision_condition: "(i) writer を owner 型へ集約し View は intent を呼ぶ / (ii) errorMessage の dismiss だけ例外扱いとして規約化 / (iii) 現状維持。判断軸は『@Published var の外部書込を R2 の禁止対象に含めるか』"
    evidence_required: ["R2 の解釈（Contract Function 所管）"]
    evidence_acquisition: ["OB-A2（Boundary / Contract package の ID 参照）"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "Podcast/PodcastView.swift:45,135 / Settings/AccountSettingsView.swift:308", supports: "View からの直接代入"}]
  - id: SG-A10
    subject: "OS 連携（MPRemoteCommandCenter / MPNowPlayingInfoCenter / AVAudioSession / NotificationCenter / UIApplication）を port 背後へ隔離するか"
    candidate_ids: [O4, O0]
    decision_condition: "(i) 全てを protocol 背後へ隔離し単体検証可能にする / (ii) NowPlaying のみ隔離（logout 時クリアに必要な最小） / (iii) 現状維持し UI テストで担保する。判断軸は『UV3 の実機観測を恒常的な検証手段として受け入れるか』"
    evidence_required: ["UI テスト導入方針（現状 XCUITest はテンプレートのみ・CI 除外）"]
    evidence_acquisition: ["CI 方針の user 決定（R8 関連・Test Function 所管 OB-A5）"]
    owner: user
    status: pending
    evidence: [{status: confirmed, source: "verification-run.md §8,§9", supports: "UI テスト未整備・CI は unit のみ"}]
```

---

## 8. web 確定決定と iOS 現状の差分（finding ではなく SG として扱う）

| # | web 確定決定（ブリーフ §7） | iOS 現状（Evidence） | 差分の性質 | 隔離先 |
|---|---|---|---|---|
| D1 | 「現在再生中」の正本 = Queue の `currentIndex`。VM の `currentPodcast` 相当は派生値 | `currentPodcast`（`Podcast/PodcastViewModel.swift:281`）と `queue.currentIndex`（`Podcast/PlaybackQueue.swift:31-34`）が並立。同期は 2 経路のみ | 正本の所在が異なる（構造差） | SG-A1 |
| D2 | 再生速度は 2 概念（既定＝永続 / セッション＝非永続、再生開始時に既定から初期化） | 2 概念は存在するが**初期化の接続が無い**（`AppState.swift:63-65` ↔ `Podcast/PodcastViewModel.swift:50,291`） | 概念は一致・接続が欠落（観測挙動差） | SG-A2 |
| D3 | 自動次再生の取得失敗は**停止**（失敗エピソードを current に保持し error、手動 play で再試行） | 停止でもスキップでもない中間状態（`:441` で index 前進・`:281` 未実行・`:264-267` で errorMessage） | 失敗時挙動が未定義（観測挙動差） | SG-A3 |
| D4 | 失効時は主体データ（web: `shell-*`/`api-*` とキャッシュ）を消す | logout でも失効でも音声キャッシュ・NowPlaying を消さない。仕様 §6.3 は iOS にも削除を要求（`docs/design/shared-playback-spec.md:312`） | 仕様と実装の contradiction かつ platform 間差（QA4 constraint） | SG-A5 |
| D5 | （参考）`moveUpNext` の正本は iOS onMove 方式（ADR-053） | iOS は `reorderUpNext(fromOffsets:toOffset:)`（`Podcast/PlaybackQueue.swift:118-128`）で IndexSet 複数移動まで担う。spec はアダプタ責務としスコープ外と規定（`docs/design/shared-playback-spec.md:37-128` 内 §2.7） | 名前差と責務配置差。挙動は conformance で green | 契約明示は Contract Function 所管（OB-A2） |

差分 D1〜D4 は iOS 単独で決められない（web との整合が価値 V1 の一部）。よって finding ではなく Selection Gate として user 決定へ送る。

---

## 9. ADR / target / transition / validation

```yaml
adr:
  title: "iOS 再生系の data authority と依存方向の target 選定"
  lifecycle_status: unknown
  decision_maturity: {status: proposed, owner: user, scope: [ios playback], evidence_status: inferred, approval_evidence: [], baseline_version: "c8c1ada", change_control: "SG-A1/A2/A3/A5/A6 の satisfied をもって approved 化"}
  context: "共有再生仕様 §2/§6 と web 確定決定に対し、iOS は現在再生中・再生速度・失敗時挙動・logout 消去範囲の 4 点で整合していない。加えて再生責務が 854 行の単一 VM に集中している"
  decision: "未決。本 package は候補（O0〜O5）と Selection Gate のみを確定する"
  value_and_quality_rationale: ["V1 は platform 間の観測挙動一致に依存する", "V2 は QA4 constraint であり trade-off で落とさない"]
  options_considered: [O0, O1, O2, O3, O4, O5]
  tradeoff_decisions: [TD-A1, TD-A2, TD-A3, TD-A4]
  counterevidence:
    - "PlaybackQueue は既に spec §2 の純粋モデルとして分離済みで、conformance 32/32 green。『再生系全体が壊れている』という強い主張は成立しない"
    - "URLSession 層の seam と protocol 化された NetworkMonitoring / SessionStore / FileManagerProtocol は rule 11 の本番経路同一性に適合しており、境界設計が全面的に弱いわけではない"
  assumption_ids: [P-A1, P-A2]
  unknown_ids: [U-A1, U-A2, U-A3, U-A4, U-A5]
  consequences: ["SG が pending の間、O1〜O5 のいずれも着手不可（不可逆でないが手戻りコストが大きい）"]
  owner: user
  approvers: [user]
  reevaluate_when: ["web 側の決定変更", "共有端末前提の変更"]

target_architecture:
  decisions:
    - id: T-A1
      kind: data_authority
      statement: "【conditional】再生中エピソードの source of truth を 1 つに定める。候補は PlaybackQueue.currentIndex（spec 不変条件 4 準拠）または PodcastViewModel.currentPodcast"
      owner: user
      option_id: O2
      affected_capability_ids: [CAP1]
      quality_scenario_ids: [QS2, QS3]
      source_of_truth: "未選択（SG-A1）"
      state_or_transition_authority: "未選択（SG-A1）"
      boundary_artifact_refs: ["OB-A2 で参照予定の Boundary/Contract package ID（未作成のため ID を捏造しない）"]
      rationale: "2 正本のままでは QS2 が構造的に満たせない"
      evidence: [{status: confirmed, source: "p1-domain.md §5", supports: "3 系統"}]
      assumption_ids: []
      unknown_ids: [U-A3]
      selection_gate_ids: [SG-A1]
    - id: T-A2
      kind: data_authority
      statement: "【conditional】既定速度と セッション速度の関係（初期化の向きと時点）を定める"
      owner: user
      option_id: O5
      affected_capability_ids: [CAP1]
      quality_scenario_ids: [QS8]
      source_of_truth: "既定 = AppState（確定）／セッション = 未選択（SG-A2）"
      state_or_transition_authority: "未選択（SG-A2）"
      boundary_artifact_refs: []
      rationale: "2 概念の関係が未定義なため設定が無効化している"
      evidence: [{status: confirmed, source: "AppState.swift:63-65 / Podcast/PodcastViewModel.swift:50", supports: "接続不在"}]
      assumption_ids: []
      unknown_ids: []
      selection_gate_ids: [SG-A2]
    - id: T-A3
      kind: security
      statement: "【conditional】主体データ消去の owner と範囲を定め、logout と失効の両経路が同一 owner を通る"
      owner: user
      option_id: O1
      affected_capability_ids: [CAP2, CAP3]
      quality_scenario_ids: [QS5, QS6]
      source_of_truth: "消去対象の列挙 owner は未選択（SG-A5）"
      state_or_transition_authority: "AppState が認証遷移の authority である点は確定（AppState.swift:153-154,207-208,216-220,300-301）。消去参加者の登録方式は未選択"
      boundary_artifact_refs: []
      rationale: "QA4 constraint。仕様 §6.3 との contradiction を解消する"
      evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:312 vs AppState.swift:282-302", supports: "未実装"}]
      assumption_ids: [P-A1]
      unknown_ids: [U-A4]
      selection_gate_ids: [SG-A5]
    - id: T-A4
      kind: responsibility
      statement: "【conditional】再生責務の分割単位と OS 連携 port の有無を定める"
      owner: user
      option_id: O4
      affected_capability_ids: [CAP1]
      quality_scenario_ids: [QS1, QS3, QS4]
      source_of_truth: "not_applicable（責務分割であり data authority ではない）"
      state_or_transition_authority: "T-A1 の決定に従属"
      boundary_artifact_refs: []
      rationale: "他 5 finding の共通宿主であり、分割単位の先決が手戻りを防ぐ"
      evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:36-69", supports: "責務集中"}]
      assumption_ids: [P-A2]
      unknown_ids: []
      selection_gate_ids: [SG-A6, SG-A10]

transition_architecture:
  phases:
    - id: TP1
      name: "QA4 constraint の是正（SG-A5 満了後にのみ着手可）"
      owner: user
      from_state: "logout で token と一部 UserDefaults のみ消去"
      to_state: "SG-A5 で選ばれた範囲の主体データを logout / 失効の同一経路で消去"
      target_decision_ids: [T-A3]
      changes: ["AudioCacheManager を合成 root で 1 インスタンス化", "消去 owner の新設または AppState への集約", "NowPlaying / 再生セッションの停止呼出"]
      deploy_order:
        - {order: 1, artifact: runtime, change: "AudioCacheManager の単一インスタンス注入（挙動不変）", preconditions: ["SG-A6 のインスタンス共有選択肢 (a)/(b)/(c) のいずれかが決定"]}
        - {order: 2, artifact: operation, change: "消去 owner の導入と logout からの呼出", preconditions: ["SG-A5 satisfied"]}
        - {order: 3, artifact: operation, change: "失効経路（AppState.swift:216-220）を同一 owner へ接続", preconditions: ["order 2 完了"]}
      compatibility: ["既存キャッシュファイル形式は不変（Networking/AudioCacheManager.swift:45-46 の命名規則を変えない）"]
      migration: {backfill: ["not_applicable: 過去データの変換は不要。初回 logout 時に削除されるのみ"], dual_read_write: [], reconciliation: [], conflict_rule: "not_applicable（単一 writer）"}
      observation_window: "unknown（観測手段が無い。SG-A8 の決定に依存）"
      exit_criteria: ["logout 後に cacheSize() == 0 を単体テストで確認", "失効経路でも同一の消去が起きることを単体テストで確認", "UV3 実機観測でロック画面 NowPlaying が消える"]
      irreversible_point: {exists: true, description: "利用者端末上の音声キャッシュ削除は取り消せない（再ダウンロードが必要）", approval: {status: required, owner: user, evidence: []}}
      abort_conditions: ["exit_criteria のいずれかが満たせない", "SG-A5 が rejected へ変わる"]
      rollback_or_forward_recovery: {strategy: forward_recovery, steps: ["削除済みキャッシュは戻せないため、rollback ではなく再ダウンロード導線で回復する", "コードは revert 可能（atomic commit 単位）"], owner: user}
      temporary_paths: []
      old_path_removal: {artifacts: ["AppState.swift:298 の個別 UserDefaults 削除（消去 owner へ集約後）"], owner: user, deadline: "TP1 exit 時", usage_metric: "unknown（観測手段なし・SG-A8 依存）", removal_condition: "消去 owner が同キーを扱うことをテストで確認済み"}
      validation_ids: [VAL4, VAL1]
      evidence: [{status: inferred, source: "O1", supports: "do-minimum として独立実施可能"}]
    - id: TP2
      name: "cross-platform 整合（SG-A1/A2/A3 満了後）"
      owner: user
      from_state: "現在再生中 2 正本・速度未接続・失敗時中間状態"
      to_state: "SG-A1/A2/A3 の選択に従った単一正本・接続済み速度・確定した失敗時挙動"
      target_decision_ids: [T-A1, T-A2]
      changes: ["正本移譲と派生値化", "既定速度の初期化配線", "失敗時の状態遷移確定"]
      deploy_order:
        - {order: 1, artifact: schema, change: "正本を表す型/プロパティの導入（旧 atom は派生値として併存）", preconditions: ["SG-A1 satisfied"]}
        - {order: 2, artifact: consumer, change: "reader を新正本へ順次切替", preconditions: ["order 1 完了", "各切替が単体テスト green"]}
        - {order: 3, artifact: producer, change: "旧 writer 経路の削除", preconditions: ["全 reader 切替完了"]}
      compatibility: ["観測挙動は Q-01〜Q-32 と既存 509 テストで保護する"]
      migration: {backfill: [], dual_read_write: ["order 1〜2 の間、currentPodcast と currentIndex が併存する"], reconciliation: ["派生値を computed にして writer を 1 本化することで不一致を構造的に排除する"], conflict_rule: "併存期間中は新正本を優先し、旧 atom への直接代入を禁止する"}
      observation_window: "order 2 の各切替コミット後にテスト実行"
      exit_criteria: ["旧 writer 経路が 0", "Q-01〜Q-32 green", "QS2/QS8 の oracle を満たすテストが存在"]
      irreversible_point: {exists: false, description: "コード変更のみで利用者データへ不可逆影響なし", approval: {status: not_required, owner: user, evidence: []}}
      abort_conditions: ["509 テストの green を回復できない", "web 側決定が変更された"]
      rollback_or_forward_recovery: {strategy: rollback, steps: ["atomic commit 単位で revert"], owner: user}
      temporary_paths:
        - {artifact: "dual-write（currentPodcast と currentIndex の併存）", owner: user, introduced_at: "TP2 order 1（実施日は未着手のため unknown）", purpose: "reader を段階的に切り替えるため", metric_or_log: "旧 atom への writer 参照数（静的 grep で数える。実行時 metric は SG-A8 未決のため不可）", removal_condition: "旧 atom の writer 参照が 0", removal_phase: TP2}
      old_path_removal: {artifacts: ["currentPodcast への直接代入経路（Podcast/PodcastViewModel.swift:281 相当）", "DesignSystem/PreviewSupport.swift:152,164 の外部代入"], owner: user, deadline: "TP2 order 3", usage_metric: "静的参照数", removal_condition: "参照 0 かつテスト green"}
      validation_ids: [VAL1, VAL2, VAL3]
      evidence: [{status: inferred, source: "O2, O3, O5", supports: "段階移行が可能"}]
    - id: TP3
      name: "責務分割と OS 連携 seam 化（SG-A6/A10 満了後）"
      owner: user
      from_state: "854 行 VM が OS API を直接参照"
      to_state: "SG-A6 で選ばれた単位へ分割し、SG-A10 の範囲で OS 連携を port 背後へ"
      target_decision_ids: [T-A4]
      changes: ["責務単位の型抽出", "OS 連携 protocol の導入とテスト double"]
      deploy_order:
        - {order: 1, artifact: runtime, change: "OS 連携 port の導入（実装は既存呼出をそのまま移設）", preconditions: ["SG-A10 satisfied", "TP2 完了（正本が動くと分割単位が変わるため）"]}
        - {order: 2, artifact: producer, change: "責務単位の型抽出と合成 root での配線", preconditions: ["order 1 完了"]}
      compatibility: ["公開 API 名は段階的に維持し、テスト参照面の一括変更を避ける"]
      migration: {backfill: [], dual_read_write: [], reconciliation: [], conflict_rule: "not_applicable（状態の複製を作らない前提。作る場合は TP2 と同じ conflict rule を適用）"}
      observation_window: "各抽出コミット後のテスト実行"
      exit_criteria: ["DV1/DV2/DV5 が解消または意図的残置として記録", "509 テスト green", "OS 連携が単体検証可能"]
      irreversible_point: {exists: false, description: "コード変更のみ", approval: {status: not_required, owner: user, evidence: []}}
      abort_conditions: ["分割後にテストの意味が失われる", "型が増えるだけで QS1 が改善しない"]
      rollback_or_forward_recovery: {strategy: rollback, steps: ["atomic commit 単位で revert"], owner: user}
      temporary_paths:
        - {artifact: "old-path（旧 VM の公開 API を薄い委譲として残す）", owner: user, introduced_at: "TP3 order 2（未着手・unknown）", purpose: "テスト参照面の一括変更を避ける", metric_or_log: "委譲メソッドの参照数（静的）", removal_condition: "全呼出が新型へ移行", removal_phase: TP3}
      old_path_removal: {artifacts: ["旧 VM の委譲メソッド"], owner: user, deadline: "TP3 exit 時", usage_metric: "静的参照数", removal_condition: "参照 0"}
      validation_ids: [VAL1, VAL2, VAL3]
      evidence: [{status: inferred, source: "O4", supports: "段階移行が可能"}]

validation:
  items:
    - id: VAL1
      quality_scenario_ids: [QS1, QS7, QS8]
      target_decision_ids: [T-A1, T-A2, T-A3]
      transition_phase_ids: [TP1, TP2, TP3]
      kind: change_simulation
      oracle: "代表変更（spec §2.9 advance の末尾挙動変更／既定速度の反映）を入れたとき、変更が触るファイル数と再 green までの手順数"
      owner: user
      execution_conditions: ["DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer", "シミュレータ UDID 指定（verification-run.md §1 の手順）"]
      required_platforms: [macos]
      status: planned
      executed_at: ""
      result: ""
      evidence: []
      counterevidence: []
    - id: VAL2
      quality_scenario_ids: [QS2]
      target_decision_ids: [T-A1]
      transition_phase_ids: [TP2, TP3]
      kind: contract_dependency_test
      oracle: "PlaybackQueueConformanceTests Q-01〜Q-32 が green を維持し、かつ currentPodcast 相当の reader が新正本へ解決する"
      owner: user
      execution_conditions: ["同上"]
      required_platforms: [macos]
      status: planned
      executed_at: ""
      result: ""
      evidence: [{status: confirmed, source: "verification-run.md §8", supports: "Q-01〜Q-32 が既存で 32/32"}]
      counterevidence: []
    - id: VAL3
      quality_scenario_ids: [QS3, QS4]
      target_decision_ids: [T-A1, T-A4]
      transition_phase_ids: [TP2, TP3]
      kind: failure_injection
      oracle: "オフライン + 未キャッシュで auto-advance を起こしたときの (current, queue.currentIndex, error, isPlaying) の組が SG-A3 の選択と一致する"
      owner: user
      execution_conditions: ["StubNetworkMonitor と FileManager double で外部 I/O なしに再現（Networking/NetworkMonitoring.swift:70 の既存 stub を利用）"]
      required_platforms: [macos]
      status: planned
      executed_at: ""
      result: ""
      evidence: []
      counterevidence: []
    - id: VAL4
      quality_scenario_ids: [QS5, QS6]
      target_decision_ids: [T-A3]
      transition_phase_ids: [TP1]
      kind: security_review
      oracle: "logout / 失効の両経路後に、SG-A5 で定めた消去対象がいずれも残存しない（単体テスト + 実機観測）"
      owner: user
      execution_conditions: ["SG-A5 satisfied", "実機または simulator での UV3 観測"]
      required_platforms: [macos]
      status: planned
      executed_at: ""
      result: ""
      evidence: []
      counterevidence: []

architecture_traces:
  - {id: AT1, value_ids: [V1], quality_scenario_ids: [QS2], current_finding_ids: [F-A1], option_id: O2, target_decision_ids: [T-A1], transition_phase_ids: [TP2], validation_ids: [VAL1, VAL2], status: partial, evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:53"}], gaps: ["SG-A1 pending のため target が未選択"]}
  - {id: AT2, value_ids: [V2], quality_scenario_ids: [QS5, QS6], current_finding_ids: [F-A2, F-A6], option_id: O1, target_decision_ids: [T-A3], transition_phase_ids: [TP1], validation_ids: [VAL4], status: contradictory, evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:312 vs AppState.swift:282-302"}], gaps: ["仕様が達成済みと読める記述のまま。SG-A5 で範囲確定後に仕様側の記述も点検が必要（OB-A6）"]}
  - {id: AT3, value_ids: [V1], quality_scenario_ids: [QS3], current_finding_ids: [F-A3], option_id: O3, target_decision_ids: [T-A1], transition_phase_ids: [TP2], validation_ids: [VAL3], status: partial, evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:435-465"}], gaps: ["SG-A3 pending"]}
  - {id: AT4, value_ids: [V1], quality_scenario_ids: [QS8], current_finding_ids: [F-A4], option_id: O5, target_decision_ids: [T-A2], transition_phase_ids: [TP2], validation_ids: [VAL1], status: partial, evidence: [{status: confirmed, source: "AppState.swift:63-65"}], gaps: ["SG-A2 pending"]}
  - {id: AT5, value_ids: [V3], quality_scenario_ids: [QS1, QS4], current_finding_ids: [F-A9, F-A5, F-A7], option_id: O4, target_decision_ids: [T-A4], transition_phase_ids: [TP3], validation_ids: [VAL1, VAL3], status: partial, evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:11-14,36-69"}], gaps: ["SG-A6 / SG-A8 / SG-A10 pending"]}
  - {id: AT6, value_ids: [V2], quality_scenario_ids: [QS6], current_finding_ids: [F-A8, F-A10], option_id: O0, target_decision_ids: [], transition_phase_ids: [], validation_ids: [VAL4], status: missing, evidence: [{status: unknown, source: "backend の失効挙動が未確認（U-A2）"}], gaps: ["target 未定義。U-A2 解消が前提"]}
```

### premises / unknowns

```yaml
premises:
  - {id: P-A1, statement: "共有端末での利用が実在する前提（仕様 §6.3 の根拠）", evidence_status: inferred, falsification: "user が『個人端末のみ』と明言する", impact_if_false: "F-A2 の priority が大きく下がり TD-A1 の判断が逆転する"}
  - {id: P-A2, statement: "再生責務の分割は既存 509 テストの green を保ったまま段階的に行える", evidence_status: assumption, falsification: "テストが内部実装へ密結合していて分割時に大量書換が必要と判明する", impact_if_false: "O4 の remediation_cost が跳ね上がり do-minimum が優位になる"}

unknowns:
  - {id: U-A1, subject: "共有仕様と異なる iOS 挙動を仕様側へ追記して良いか（O0 の可否）", confirmation_method: "user 決定", impact_if_unresolved: "O0 を候補として比較できない", owner: user}
  - {id: U-A2, subject: "backend が失効 token をどう扱うか（F-A8 の failure_risk）", confirmation_method: "backend 実装/仕様の確認（ios scope 外）", impact_if_unresolved: "F-A8 の priority を確定できない", owner: user}
  - {id: U-A3, subject: "playById（ディープリンク再生）をキューへ載せるべきか", confirmation_method: "user へ期待挙動を確認", impact_if_unresolved: "T-A1 を選んでも playById の扱いが再度論点になる", owner: user}
  - {id: U-A4, subject: "UserDefaults のどのキーが主体依存か（AppState の 5 キー + AchievementCelebrationTracker 以外）", confirmation_method: "Domain Function による棚卸し（OB-A3）", impact_if_unresolved: "SG-A5 の消去範囲を確定できない", owner: user}
  - {id: U-A5, subject: "次の 1〜2 サイクルの roadmap（expected_change の裏付け）", confirmation_method: "user へ確認", impact_if_unresolved: "capability の expected_change が inferred 止まりで投資優先度が弱い根拠になる", owner: user}
```

### obligations（他 Function / orchestrator への依頼）

| ID | 依頼先 | 内容 |
|---|---|---|
| OB-A1 | orchestrator（web 側成果物の参照） | web 実装で「現在再生中 = currentIndex」「セッション速度の初期化時点」が実際にどう実装されているかの確認。SG-A1 / SG-A2 の Evidence |
| OB-A2 | Boundary / Contract Function | `AccountSettingsView.swift:305-333` の View 内 API 直呼び、`QuizSheetView` の採点ロジック、パスワード最小長 8 の 2 実装（`Settings/AccountSettingsView.swift:317` / `Admin/AdminUsersViewModel.swift:47`）、`reorderUpNext` の契約明示（D5）。本 package は consumer operation contract を重複定義しない |
| OB-A3 | Domain Function | 主体依存 UserDefaults キーの棚卸し（U-A4）。SG-A5 の前提 |
| OB-A4 | orchestrator | backend の token 失効挙動（U-A2）。ios scope 外 |
| OB-A5 | Test Function | CI の lint / 独立 build / UI テスト方針（R8）と、SG-A10 の検証手段の前提 |
| OB-A6 | orchestrator | SG-A5 決定後、`docs/design/shared-playback-spec.md:312` の記述（実装済みと読める）を実態へ合わせる必要がある（本 review は read-only のため未実施） |

---

## 10. verdict と decision

```yaml
subject_verdict: incomplete
subject_verdict_rationale: >
  対象（iOS の現行アーキテクチャ）には Evidence 付きの欠陥が特定できる。最も強いのは
  docs/design/shared-playback-spec.md:312 と AppState.swift:282-302 の contradiction（QA4 constraint 未達）、
  次いで「現在再生中」の 2 正本（Podcast/PodcastViewModel.swift:281 と Podcast/PlaybackQueue.swift:31-34）と
  既定速度/セッション速度の断絶（AppState.swift:63-65 ↔ Podcast/PodcastViewModel.swift:50）。
  これらは選択肢の問題ではなく現状の欠落であるため conditional ではなく incomplete とする。
  一方、是正**手段**は未選択であり、SG-A1〜SG-A10 として候補・選択条件・Evidence 取得方法付きで隔離してある。
  なお PlaybackQueue の純粋モデル分離（conformance 32/32 green）と URLSession / SessionStore / NetworkMonitoring /
  FileManagerProtocol の seam は健全であり、全面的な破綻ではない。

ai_restatement:
  statement: "iOS 再生系について、data authority の一意性・依存方向の逆流・logout 時の主体データ残留を Evidence 付きで特定し、是正手段は選択せず Selection Gate へ隔離した"
  comparison_basis: ["p4-common-brief.md §3 QL", "p4-common-brief.md §4 R1-R9（R2/R3/R6 を中心に）", "p4-common-brief.md §6 出力契約", "p4-common-brief.md §7 web 確定決定", "docs/design/shared-playback-spec.md §2/§6"]
  proposed_status: matched
  differences:
    - "brief §5 の `setSpeed` 行番号 576 は再読で 575 が正（Podcast/PodcastViewModel.swift:575）。同様に PreviewSupport の VM 生成は 152,164（p1-domain.md は 153,165 と記載）"
    - "brief R6 の『removeAllDownloads が無い』を confirmed として追認（Networking/AudioCacheManager.swift の公開 API 6 件を再読）"
  reviewed_by: {kind: unresolved, identity: "", review_status: unresolved, evidence: []}

decision:
  status: awaiting_approval
  artifact_readiness: ready
  engineering_status: not_started
  release_status: not_applicable
  decision_maturity: {status: proposed, owner: user, scope: [ios playback architecture review], evidence_status: inferred, approval_evidence: [], baseline_version: "c8c1ada", change_control: "SG-A* の user 決定を待つ"}
  next_phase:
    name: "Selection Gate の user 決定（SG-A5 → SG-A1 → SG-A2/A3 → SG-A6 の順を推奨）"
    status: awaiting_approval
    reasons: ["QA4 constraint に関わる SG-A5 が最も failure_risk が高く remediation_cost が低い", "SG-A1 の決定が SG-A6 の分割単位を規定する"]
    human_approvals_required: ["SG-A1", "SG-A2", "SG-A3", "SG-A5", "SG-A6", "SG-A7"]
  evidence: ["本 package 内の全 path:line は HEAD c8c1ada で再読済み（§11 の範囲検査）"]
  assumptions: [P-A1, P-A2]
  unknowns:
    - {id: U-A1, subject: "共有仕様と異なる iOS 挙動の追記可否", confirmation_method: "user 決定", impact_if_unresolved: "O0 を比較できない", owner: user, evidence: []}
    - {id: U-A2, subject: "backend の失効 token 挙動", confirmation_method: "backend 確認（OB-A4）", impact_if_unresolved: "F-A8 の priority 未確定", owner: user, evidence: []}
    - {id: U-A3, subject: "playById のキュー投入可否", confirmation_method: "user 決定", impact_if_unresolved: "T-A1 選択後に再論点化", owner: user, evidence: []}
    - {id: U-A4, subject: "主体依存 UserDefaults キーの全体", confirmation_method: "Domain Function 棚卸し（OB-A3）", impact_if_unresolved: "SG-A5 の範囲未確定", owner: user, evidence: []}
    - {id: U-A5, subject: "roadmap（expected_change の裏付け）", confirmation_method: "user 確認", impact_if_unresolved: "投資優先度の根拠が inferred 止まり", owner: user, evidence: []}
  contradictions:
    - "docs/design/shared-playback-spec.md:312（iOS は logout 時に removeAllDownloads() を自動呼出）vs Networking/AudioCacheManager.swift（該当 API 無し）・AppState.swift:282-302（呼出無し）"
  failed_gates: []
  unexecuted_validation:
    - {id: UV1, reason: "UI テストは未整備（テンプレートのみ・CI 除外）", required_runner: "xcodebuild test -only-testing:NewsListenAppUITests", planned_commands: [], owner: user, evidence: [{status: confirmed, source: "verification-run.md §8,§9"}]}
    - {id: UV3, reason: "実機/simulator 目視（logout 後 NowPlaying 残留、auto-advance 失敗時 UI）が本 review では未実施（read-only・design mode）", required_runner: "iOS Simulator または実機", planned_commands: [], owner: user, evidence: [{status: confirmed, source: "verification-run.md §10"}]}
    - {id: UV-A1, reason: "VAL1〜VAL4 は design mode の planned。oracle・owner・実行条件は揃うが未実行", required_runner: "xcodebuild test（verification-run.md §1 の手順）", planned_commands: [], owner: user, evidence: []}
  platform_validation:
    required_platforms: [macos]
    executed: []
    unexecuted:
      - {platform: macos, evidence_layer: application_runtime, reason: "本 Function は read-only review。テスト実行は T1 が実施済み（509/509 green・verification-run.md §1）であり、本 package 由来の新規 validation は未実行"}
```

---

## 11. `path:line` 範囲検査（`N ≤ wc -l`）

検査コマンドと結果は本ファイル生成後に 1 コマンドで実行し、下に追記する。

実行コマンド（cwd = `/Users/rio/git/news-listen/ios/NewsListenApp/NewsListenApp`、1 コマンド）:

```sh
grep -oE '[A-Za-z0-9_/.-]+\.(swift|md):[0-9]+(,[0-9]+)*(-[0-9]+)?' "$PKG" \
| awk -F: '{f=$1;n=$2;gsub(/-/," ",n);split(n,a,",");for(i in a){split(a[i],b," ");for(j in b) print f":"b[j]}}' \
| sort -u | while IFS=: read f n; do p="$f"; \
    [ -f "$p" ] || p=$(find . -name "$(basename $f)" -not -path "./build/*" | head -1); \
    [ -f "$p" ] || p="/Users/rio/git/news-listen/docs/design/$(basename $f)"; \
    [ -f "$p" ] || p="<scratchpad>/$(basename $f)"; \
    if [ ! -f "$p" ]; then echo "MISSING_FILE $f:$n"; \
    else m=$(wc -l < "$p"); [ "$n" -gt "$m" ] && echo "OUT_OF_RANGE $f:$n > $m"; fi; done
```

結果: **参照 `file:N` 244 件（個別行へ展開・重複除去後は 180 件のユニーク対）、`MISSING_FILE` 0 件、`OUT_OF_RANGE` 0 件**（全参照が `N ≤ wc -l` を満たす）。
対象 wc -l（主要ファイル）: `Podcast/PodcastViewModel.swift` 854 / `Podcast/PlaybackQueue.swift` 143 / `AppState.swift` 366 /
`Networking/APIClient.swift` 547 / `Networking/AudioCacheManager.swift` 119 / `Networking/SessionStore.swift` 82 /
`Networking/NetworkMonitoring.swift` 82 / `Settings/SettingsViewModel.swift` 286 / `Settings/SettingsView.swift` 557 /
`Settings/AccountSettingsView.swift` 333 / `Podcast/AudioPlayerView.swift` 606 / `Podcast/PodcastView.swift` 151 /
`Podcast/QueueSheet.swift` 82 / `DesignSystem/PreviewSupport.swift` 196 / `NewsListenAppApp.swift` 232 /
`docs/design/shared-playback-spec.md` 327。

注: 本 package 内の行番号は、Explorer 報告（p1-domain.md）の値をそのまま転記せず、すべて本 review で
`grep -n` / `awk` により**単一ファイル単位で再取得**した。再取得の過程で判明した差分は
`ai_restatement.differences`（§10）に記録した。
