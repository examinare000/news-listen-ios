# Completeness Package — ios 再生/認証/キャッシュ/モデル（review mode・read-only）

参照ルート（本書の `path:line` は以下からの相対）:
- prod = `/Users/rio/git/news-listen/ios/NewsListenApp/NewsListenApp/`
- test = `/Users/rio/git/news-listen/ios/NewsListenApp/NewsListenAppTests/`
- spec = `/Users/rio/git/news-listen/docs/design/shared-playback-spec.md`

```yaml
routing_context:
  origin: integrated
  mode: review
  requested_by: router
  requested_artifact: completeness-package
  return_to: router
  mutation_authorized: false
```

## 1. scope / discovery

```yaml
scope:
  actors: [listener, returning_user_on_shared_device, ios_client_module]
  use_cases:
    - S1: 再生セッションの維持（開始・一時停止・バッファ・終了・失敗・割り込み・route 変更・stale callback）
    - S2: 再生キューの維持（PlaybackQueue と ViewModel 再生状態の同期）
    - S3: 認証セッションの維持（authStatus × currentUser × token、失効、logout）
    - S4: オフラインキャッシュの維持（downloadedIds ミラーとファイル実体）
    - S5: Podcast モデルの意味（status × audio_url × error_message と再生可否）
  requirements: [R2, R3, R5, R6, R9, R10]
  contexts:
    - playback_session（prod `Podcast/PodcastViewModel.swift`）
    - playback_queue（prod `Podcast/PlaybackQueue.swift`、正本 spec §2）
    - auth_session（prod `AppState.swift` + `Networking/SessionStore.swift`）
    - offline_cache（prod `Networking/AudioCacheManager.swift`）
    - podcast_catalog（prod `Models/Podcast.swift`）
  in_scope:
    - 上記 5 context の概念・値制約・状態・遷移・失敗・writer/reader・authority
    - iOS 単一 platform（本 module は iOS のみをビルド対象とする）
  out_of_scope:
    - reason_backed: R1（業務ルール所在の網羅監査）・R4（失敗意味の契約化）は Contract/Boundary Function が canonical owner。本書は S1–S5 に接する範囲だけを element として持ち、条件の authoritative enforcement を二重に確定しない。
    - reason_backed: R7・R8（テスト経路・CI）は成果物 readiness の観点であり model completeness の dimension ではない。test obligation としてのみ接続する。
    - reason_backed: backend / web 実装。本書は iOS 側 writer/reader のみを監査し、クロスプラットフォーム決定は SG* へ隔離する。

discovery_readiness:
  status: verified_input
  evidence:
    status: confirmed
    sources:
      - "spec §2.1-2.10（キュー状態モデル・不変条件 1〜5・操作契約）"
      - "spec §6.1-6.3（オフライン再生元優先度・位置同期・logout 時キャッシュ削除）"
      - "prod `Podcast/PodcastViewModel.swift`（854 行・全文読了）"
      - "prod `Podcast/PlaybackQueue.swift`（143 行）、`AppState.swift`（366 行）、`Networking/AudioCacheManager.swift`（119 行）、`Networking/SessionStore.swift`（82 行）、`Models/Podcast.swift`（214 行）"
      - "verification-run.md V1: Executed 509 tests, 0 failures（HEAD c8c1ada）"
  reason: "用語・context・操作契約が spec §2/§6 と実コードの doc comment に明示されており、term ledger の新規作成なしに意味を固定できた。ただし用語衝突（ME1/ME2/ME3/ME5/ME66）は下記 model_elements で conflicting として保持する。"

audit_rubric:
  name: suite_defined_completeness_dimensions
  origin: suite_operationalization
  dimensions: [term_context, concept, constraint, state, transition, behavior, relationship, failure, time, writer, reader, authority]

domain_discovery:
  applicability: not_applicable
  not_applicable_reason: "spec §2/§6 が用語・操作・不変条件の正本を持ち、対象 5 context の境界は既存 module 境界と一致する。未確定なのは個々の語の owner であって語彙そのものではないため、Domain Discovery Package ではなく term_context dimension の conflicting element として扱う。"
  confirmation_method: "spec §2.1 の 2 フィールド定義と `Podcast/PlaybackQueue.swift:17-20` の宣言が一対一であることの再読"
  impact_if_unresolved: "なし（discovery を省いたことで見落とす語があれば ME5/ME61 の unknown として再浮上する）"
  evidence:
    - status: confirmed
      sources: ["spec §2.1", "prod `Podcast/PlaybackQueue.swift:16-20`"]

platform_context:
  required_platforms: [ios]
  rationale: "本 module は iOS 専用ターゲット。Windows / Linux / macOS の native filesystem 差は対象外。ただし web モジュールとの意味論差は platform 差ではなくクロスプラットフォーム決定として SG1–SG4 へ隔離する。"
  evidence:
    - status: confirmed
      sources: ["`/Users/rio/git/news-listen/ios/CLAUDE.md`（Swift / SwiftUI / Xcode プロジェクト）"]

platform_validation:
  required_platforms: [ios]
  note: "本 Function は static な意味監査であり、platform 別の writer/reader 差を生む filesystem / process 連携を持たない（唯一の filesystem writer は `Networking/AudioCacheManager.swift` で、`FileManagerProtocol` 越しの単一経路）。runtime 検証は verification-run.md V1 が担当。"
```

## 2. requirement catalog（在庫。R2/R3/R5/R6/R9 は router seed、R10 は本 Function の追加候補）

```yaml
requirements_in_scope:
  - id: R2
    statement: "再生セッションの不正状態（error と paused の判別不能、advance 後に current と queue が別エピソード、`@Published var` の外部書込）を公開経路から構築できない"
    kind: invariant
    quality_constraint_ids: [QL3, QL2]
    current_behavior_classification: unknown
    evidence: {status: confirmed, sources: ["p4-common-brief §4"]}
  - id: R3
    statement: "「現在再生中」「再生速度（既定/セッション）」「再生位置」「キャッシュ有無」の source of truth が一意で、writer が 1 owner を通る"
    kind: invariant
    quality_constraint_ids: [QL1, QL3]
    evidence: {status: confirmed, sources: ["p4-common-brief §4"]}
  - id: R5
    statement: "実行中のセッション失効（API 401）で未認証へ遷移し、認可判定は単一 policy を通る"
    kind: prohibition
    quality_constraint_ids: [QL4]
    evidence: {status: confirmed, sources: ["p4-common-brief §4"]}
  - id: R6
    statement: "logout・失効時に前利用者の主体データ（音声キャッシュ・NowPlaying 情報・UserDefaults の主体依存値）が端末に残らない"
    kind: prohibition
    quality_constraint_ids: [QL4]
    evidence: {status: contradiction, sources: ["spec §6.3（iOS 欄は `AudioCacheManager.removeAllDownloads()` をビルトインかつ logout 時自動呼出と記す）", "prod `Networking/AudioCacheManager.swift:27-118`（公開 API は cachedURL:45 / isCached:52 / cache:62 / remove:71 / cacheSize:80 / clearCache:90 の 6 つで removeAllDownloads は存在しない）", "prod `AppState.swift:282-302`（logout 本体にキャッシュ削除の呼出なし）"]}
  - id: R9
    statement: "`PlaybackQueue` は spec §2 不変条件 1〜5 と操作契約を満たし、名前差（`reorderUpNext` vs `moveUpNext`、IndexSet 複数移動）は契約として明示される"
    kind: invariant
    quality_constraint_ids: [QL1]
    evidence: {status: confirmed, sources: ["spec §2.1-2.10", "prod `Podcast/PlaybackQueue.swift:16-143`"]}

requirement_candidates:
  - id: R10
    statement: "Podcast の生成ステータス（status）・音声 URL（audio_url）・失敗詳細（error_message）の意味が単一 owner に所有され、矛盾する組合せを decode 経路から構築できない"
    kind: invariant
    quality_constraint_ids: [QL1, QL3]
    rationale_for_addition: "ブリーフ §指定 scope S5 は seed R1〜R9 のどれにも一対一で対応しない（R1 は業務ルール所在、R4 は API 失敗の意味であり、Podcast モデル内部の組合せ整合を含まない）。denominator に含めるため候補として明示し、採否は router が決める。"
    decision_maturity: {status: proposed, owner: router, scope: [S5], evidence_status: inferred, approval_evidence: [], baseline_version: "", change_control: ""}
    evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:69-73`（status の 4 値と error_message の条件を doc comment のみで規定）", "prod `Models/Podcast.swift:121-141`（decode に組合せ検証なし）"]}
```

## 3. model elements（ME1–ME76）

凡例: `target_status` は監査対象（iOS 実装）における状態。`missing` は要件上必要だが実装に存在しない意味要素。Evidence 省略形 `C`=confirmed / `I`=inferred / `X`=contradiction。

### 3.1 term_context

```yaml
- {id: ME1, dimension: term_context, name: "現在再生中エピソード", meaning_or_rule: "利用者が今聴いている 1 件。spec §2.1 不変条件 4 は `items[currentIndex]` を正本とする", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:42`（A: `currentPodcast`）", "prod `Podcast/PlaybackQueue.swift:31-34`（B: `current`）", "prod `Podcast/PodcastViewModel.swift:289-290`（C: `AVPlayer.currentItem`）", "spec §2.1 不変条件 4"]}}
- {id: ME2, dimension: term_context, name: "再生速度", meaning_or_rule: "既定速度（永続・設定）とセッション速度（非永続・再生開始時に既定から初期化）の 2 概念", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:63-66`（既定速度・UserDefaults 永続）", "prod `Podcast/PodcastViewModel.swift:50`（セッション速度・初期値 1.0 固定）", "prod `Podcast/PodcastViewModel.swift:575-579`（`setSpeed` は既定へ書き戻さない）", "prod `Podcast/PodcastViewModel.swift:298-300`（play 時に既定から初期化しない）"]}}
- {id: ME3, dimension: term_context, name: "ダウンロード済み", meaning_or_rule: "当該エピソードの音声がこの端末で再生可能な状態にあること", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:55`（ミラー `downloadedIds`）", "prod `Networking/AudioCacheManager.swift:52-55`（実体 `isCached`）", "prod `Podcast/PodcastViewModel.swift:181-184`（オフライン再生可否はミラー由来）", "prod `Podcast/PodcastViewModel.swift:238-249`（再生元解決は実体由来）"]}}
- {id: ME4, dimension: term_context, name: "認証済み", meaning_or_rule: "有効な session token を持ち、その token に対応する利用者が特定できている状態", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:95`（`authStatus`）", "prod `AppState.swift:98`（`currentUser`）", "prod `AppState.swift:121-122,137-142`（token は `SessionStore` 側）", "3 者を束ねる型は存在しない"]}}
- {id: ME5, dimension: term_context, name: "生成ステータス（status）", meaning_or_rule: "`processing` | `completed` | `failed` | `partial_failed` の 4 値", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:69-71`（4 値を doc comment で列挙し `let status: String` として保持、enum 化は ADR-021 / iOS#15 へ先送りと明記）", "prod `Models/Podcast.swift:133`（decode は任意文字列を受理）"]}}
- {id: ME66, dimension: term_context, name: "待機列の並べ替え操作名", meaning_or_rule: "spec §2.7 は `moveUpNext(from, toOffset)`（単一要素）を正本操作名とする", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["spec §2.7", "prod `Podcast/PlaybackQueue.swift:118-128`（`reorderUpNext(fromOffsets:toOffset:)`・IndexSet 版）", "prod `Podcast/PodcastViewModel.swift:548-550`（VM 側は `moveUpNext` 名で IndexSet を通す）"]}}
- {id: ME61, dimension: term_context, name: "主体データ（ユーザー固有データ）", meaning_or_rule: "logout 時に端末から消すべき、前利用者に帰属するデータの集合", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:279-302`（doc comment は「デバイストークン・祝福トラッカーなど同型リスクの情報」と例示するのみで集合の定義がない）", "spec §6.3（iOS 欄はキャッシュのみを列挙）"]}}
```

### 3.2 concept

```yaml
- {id: ME6, dimension: concept, name: "PlaybackSession（再生セッション）", meaning_or_rule: "1 エピソードの再生開始から終了/失敗までの一貫した単位。排他的な状態と、その状態でのみ許される操作を持つ", target_status: missing, concept_kind: entity,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:36-69`（15 個の独立 `@Published` atom に分解され、束ねる型が無い）", "排他 enum は `PlayerPresentation`（表示形態）と `DownloadState`（準備状態）のみで、いずれも再生セッションの状態ではない"]}}
- {id: ME7, dimension: concept, name: "PlaybackFailure（再生失敗）", meaning_or_rule: "区別すべき失敗種別（未キャッシュオフライン / URL 不正 / ストリーミング失敗 / 音声セッション設定失敗 / 一覧取得失敗）と、その失敗後 state・recovery", target_status: missing, concept_kind: value_object,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:40`（全種別が単一の `errorMessage: String?` へ潰れる）", "書込点 `:145,151,201,211,222,265,386,418,624` の 9 箇所が同じ atom を共有する"]}}
- {id: ME8, dimension: concept, name: "Playable（再生可否判定）", meaning_or_rule: "status・audio_url・キャッシュ有無・オンライン状態から「このエピソードを今再生できるか」を決める単一の判断", target_status: missing, concept_kind: policy,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:238-249`（URL 解決＝キャッシュ/オンラインのみ。status を読まない）", "prod `Podcast/PodcastViewModel.swift:181-184`（オフライン再生可否＝`downloadedIds` 由来の別判断）", "prod `Podcast/PodcastRowView.swift:119-120`（status 由来の表示判断が View にある）"]}}
- {id: ME9, dimension: concept, name: "PodcastStatus", meaning_or_rule: "生成ライフサイクルを表す閉じた値集合", target_status: missing, concept_kind: value_object,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:71`（`let status: String`）", "iOS 側に enum・parse・既定値処理が存在しない"]}}
- {id: ME10, dimension: concept, name: "AuthSession（認証セッション）", meaning_or_rule: "token・利用者・状態を同時に守る単位", target_status: missing, concept_kind: aggregate,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:95,98,121-122`（3 つの独立フィールド）", "prod `AppState.swift:151-157`（`completeLogin` が 3 者を順に代入するだけで不変条件を持たない）"]}}
- {id: ME11, dimension: concept, name: "CachedAudio（端末キャッシュ資産）", meaning_or_rule: "この端末が保持する音声ファイル集合。容量・全削除・個別削除の対象", target_status: conflicting, concept_kind: aggregate,
   evidence: {status: confirmed, sources: ["prod `Networking/AudioCacheManager.swift:27-118`（型は存在する）", "prod `Podcast/PodcastViewModel.swift:131`（既定引数で独立インスタンス生成）", "prod `Settings/SettingsViewModel.swift:69,76`（別の独立インスタンス生成）", "同一ディレクトリを 2 インスタンスが変更するが相互通知が無い"]}}
- {id: ME12, dimension: concept, name: "PlaybackQueue", meaning_or_rule: "spec §2.1 の 2 フィールド（items / currentIndex）を持つ純粋値オブジェクト", target_status: present, concept_kind: value_object,
   evidence: {status: confirmed, sources: ["prod `Podcast/PlaybackQueue.swift:16-20`（`struct` + `private(set)` の 2 フィールド）", "外部 I/O 参照なし（import は Foundation のみ・`:10`）", "test `PlaybackQueueConformanceTests.swift` Q-01〜Q-32 が 32/32 存在し V1 で green"]}}
```

### 3.3 constraint

```yaml
- {id: ME13, dimension: constraint, name: "再生中表明の裏付け", meaning_or_rule: "`isPlaying == true` ⟹ `player != nil` かつその item が再生可能", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:553-559`（`togglePlayPause` は guard 通過後 `isPlaying` を無条件 toggle）", "prod `Podcast/PodcastViewModel.swift:370`（`play` は `player?.play()` の成否に関わらず true 代入）", "`timeControlStatus` の反映先は `isBuffering` のみ（`:424-425`）で `isPlaying` を訂正しない"]}}
- {id: ME14, dimension: constraint, name: "現在エピソードとキューの一致", meaning_or_rule: "キュー再生中は `currentPodcast?.id == queue.current?.id`", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["両者を同時に更新する経路は `playNow`（`:516-521`）と `handlePlaybackEnded` 成功時（`:441-442`）のみ", "prod `Podcast/PodcastViewModel.swift:381-388`（`playById` は queue を更新しない）", "prod `Podcast/PodcastViewModel.swift:543-545`（`removeFromQueue` は VM 側を更新しない）"]}}
- {id: ME15, dimension: constraint, name: "失敗表明の保持", meaning_or_rule: "`errorMessage != nil` ⟺ 直近の操作が失敗しており、利用者が回復操作を要する", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:40`（`@Published var`・`private(set)` なし）", "prod `Podcast/PodcastView.swift:45`（アラート OK で nil 代入）", "prod `Podcast/PodcastView.swift:135`（sheet dismiss で nil 代入）"]}}
- {id: ME16, dimension: constraint, name: "認証状態の三者整合", meaning_or_rule: "`authStatus == .authenticated` ⟹ token != nil ∧ currentUser != nil。`.unauthenticated` ⟹ token == nil ∧ currentUser == nil", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:151-157`（`completeLogin` は token の有効性を検査しない）", "prod `Networking/SessionStore.swift:38-43`（空文字トークンは削除として扱われる）", "prod `AppState.swift:98`（`currentUser` は外部書込可能な `@Published var`）"]}}
- {id: ME17, dimension: constraint, name: "ミラーの健全性", meaning_or_rule: "`downloadedIds ⊆ { id | cacheManager.isCached(id) }`", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:157`（再同期は `syncDownloadedState` のみ）", "prod `Podcast/PodcastViewModel.swift:149`（その唯一の呼出は `loadPodcasts` 成功時）", "prod `Settings/SettingsViewModel.swift:184-186`（別インスタンスが全削除しても通知が無い）"]}}
- {id: ME18, dimension: constraint, name: "Podcast ID の安全形式", meaning_or_rule: "`[A-Za-z0-9_-]+` のみ許可し path traversal を防ぐ", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Networking/AudioCacheManager.swift:102-108`（`validateId`）", "書込経路は検証する: `cache` `:62-66`、`remove` `:71-76`", "読取経路は検証しない: `cachedURL` `:45-47`、`isCached` `:52-55`", "`resolvePlaybackURL`（prod `Podcast/PodcastViewModel.swift:238-249`）は検証なしの読取経路 2 本のみを通る"]}}
- {id: ME19, dimension: constraint, name: "キュー不変条件 1〜5", meaning_or_rule: "id 一意 / currentIndex 範囲 / 空⟹null / current 定義 / upNext 定義", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["spec §2.1", "prod `Podcast/PlaybackQueue.swift:21-28`（init で clamp）", "`:59-62`（add の重複排除）、`:65-76`（playNext の重複除去と再計算）、`:100-113`（remove の追従）", "test `PlaybackQueueConformanceTests.swift` Q-01〜Q-32 が V1 で green"]}}
- {id: ME20, dimension: constraint, name: "末尾判定閾値", meaning_or_rule: "`durationSeconds > 0` かつ `position >= duration - 2` なら復元しない", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:304-305`", "WHY コメント `:296-303`（固定 2 秒ウィンドウの前提を明記）", "test `PodcastViewModelTests.swift:1017,1028,1038`"]}}
- {id: ME62, dimension: constraint, name: "logout 後の許容残留集合", meaning_or_rule: "logout 完了後に端末へ残ってよいデータの明示集合（それ以外は消去必須）", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:282-302`（消去対象は token / currentUser / authStatus / `seen_achievement_ids` の 4 つで、許容残留の定義はどこにも無い）", "spec §6.3（キャッシュのみ規定）"]}}
- {id: ME71, dimension: constraint, name: "status 値域", meaning_or_rule: "status は 4 値のいずれか。未知値は明示的に扱う", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:133`（`decode(String.self, forKey: .status)` のみ）", "prod `Podcast/PodcastRowView.swift:120`（`switch podcast.status` で未知値は default へ落ちる）"]}}
- {id: ME73, dimension: relationship, name: "status × audio_url × error_message の同時整合", meaning_or_rule: "`failed` / `partial_failed` ⟹ error_message 非 nil。`completed` ⟹ audio_url 非空。`processing` ⟹ 再生不可", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:72-73`（条件を doc comment のみで規定）", "prod `Models/Podcast.swift:127,133-134`（decode は 3 フィールドを独立に読む）", "test `ModelTests.swift:64`（`testPodcastDecodesStatusAndErrorMessage` は正常組合せのみ検証）"]}}
```

### 3.4 state / transition

```yaml
- {id: ME21, dimension: state, name: "再生セッション状態", meaning_or_rule: "idle / loading / playing / paused / buffering / ended / error が相互排他に区別される", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:36-69`（15 atom の直積で表現）", "paused = `isPlaying == false`（`:553-559`）", "ended = `didFinishCurrentEpisode == true`（`:449`）", "error = `errorMessage != nil`（`:418`）で `player` も `didFinishCurrentEpisode` も触らない", "buffering = `isBuffering`（`:425`）は error 時にリセットされない"]}}
- {id: ME22, dimension: state, name: "AuthStatus", meaning_or_rule: "unknown（/auth/me 解決前）/ authenticated / unauthenticated", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:95-96`", "test `AppStateAuthTests.swift:17,34,49`"]}}
- {id: ME23, dimension: state, name: "PlayerPresentation", meaning_or_rule: "hidden / mini / expanded の排他表示形態", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PlayerPresentation.swift`", "writer は `Podcast/PodcastViewModel.swift:69`（初期値）, `:283`, `:286`, `:470`, `:476` の 5 点のみ", "test `PodcastViewModelTests.swift:816,825,836,849`"]}}
- {id: ME24, dimension: state, name: "DownloadState", meaning_or_rule: "notDownloaded / downloading / downloaded、downloading を優先", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:17-24`（enum 定義）", "`:168-180`（純粋関数で導出）", "test `PodcastViewModelTests.swift:403`"]}}
- {id: ME25, dimension: state, name: "onboardingCompleted", meaning_or_rule: "nil=未取得（判定保留）/ false=未完了 / true=完了", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:88-93`（3 値の意味を doc comment で定義）", "prod `AppState.swift:312-313`（取得失敗でも true）", "prod `AppState.swift:321`（保存失敗でも `defer` で true）", "結果として true は「完了」「取得失敗」「保存失敗」の 3 意味を持つ"]}}
- {id: ME67, dimension: state, name: "queue state（items / currentIndex）", meaning_or_rule: "spec §2.1 の 2 フィールドのみで状態が決まる", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PlaybackQueue.swift:17-20`", "spec §2.1"]}}
- {id: ME72, dimension: state, name: "生成ライフサイクル状態", meaning_or_rule: "processing → completed | failed | partial_failed", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:71`（文字列のまま保持し状態として扱わない）", "iOS 側に生成完了の検知契機が無い（ポーリング不在・手動 refresh のみ。ME74 参照）"]}}

- {id: ME26, dimension: transition, name: "playing → auto-advance", meaning_or_rule: "終了通知で次があれば playing、無ければ ended。次の再生に失敗した場合の遷移先", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:441-442`（`advance()` で currentIndex を進めてから `play`）", "prod `Podcast/PodcastViewModel.swift:264-266`（`play` は失敗時に errorMessage を立てて即 return し、`isPlaying` も `currentPodcast` も `presentation` も変更しない）", "失敗後の遷移先が定義されていない（IV1）"]}}
- {id: ME27, dimension: transition, name: "authenticated → unauthenticated（実行中失効）", meaning_or_rule: "任意の API 応答が 401 のとき未認証へ遷移しトークンを破棄する", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["401 の集中処理が存在しない（`Networking/APIClient.swift:536-546` は 429 のみ意味化し 401 は `httpError(statusCode:)` へ潰す）", "401 を読む唯一の消費者は prod `Auth/LoginViewModel.swift:59`（ログイン失敗文言）", "prod `AppState.swift:201-221` の `refreshAuth` は起動時のみ"]}}
- {id: ME28, dimension: transition, name: "任意状態 → logged out", meaning_or_rule: "logout で主体データを消去し未認証へ遷移する（キャッシュ削除は best-effort・UI は即時遷移）", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: contradiction, sources: ["spec §6.3（iOS: `AudioCacheManager.removeAllDownloads()` をビルトインかつ logout 時自動呼出と規定）", "prod `AppState.swift:282-302`（該当呼出なし）", "prod `Networking/AudioCacheManager.swift:27-118`（該当 API なし）"]}}
- {id: ME29, dimension: transition, name: "割り込み / route 変更", meaning_or_rule: "began で一時停止、ended かつ shouldResume かつ割り込み前再生中なら再開。旧デバイス喪失で一時停止", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:759-784`（interruption）", "prod `Podcast/PodcastViewModel.swift:787-794`（route change）", "両者とも `togglePlayPause()` を経由するが、同関数は `guard let player else { return }`（`:554`）で `player == nil` のとき `isPlaying` を訂正せず黙って戻る", "IV1 の状態（`isPlaying == true` かつ実質無音）に割り込みが入ると `wasPlayingBeforeInterruption` が true になり、ended で再開扱いになる"]}}
- {id: ME59, dimension: transition, name: "cache 全削除 → ミラー無効化", meaning_or_rule: "キャッシュ全削除は全 reader のミラーを無効化する", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Settings/SettingsViewModel.swift:184-191`（`clearCache` は自身の `cacheSizeBytes` だけ更新）", "prod `Podcast/PodcastViewModel.swift:55`（`downloadedIds` は無効化されない）", "両 VM は互いを知らない"]}}
- {id: ME68, dimension: transition, name: "キュー操作の遷移規則", meaning_or_rule: "start / setQueue / add / playNext / jump / advance / remove / moveUpNext の 8 操作と currentIndex の追従規則", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["spec §2.3-2.10", "prod `Podcast/PlaybackQueue.swift:47-128`", "test `PlaybackQueueConformanceTests.swift` Q-01〜Q-32（32/32・V1 green）"]}}
```

### 3.5 behavior / relationship

```yaml
- {id: ME30, dimension: behavior, name: "自動次再生の owner", meaning_or_rule: "終了検知・stale 判定・キュー前進・次再生・完聴記録を 1 箇所が所有する", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:435-474`（`handlePlaybackEnded`）", "同関数は前進（`:441`）と再生（`:442`）を所有するが、再生失敗の取消・補償は所有しない", "失敗の検知手段も持たない（`play` は失敗を戻り値で返さず `errorMessage` を立てるだけ・`:262,265-266`）"]}}
- {id: ME31, dimension: behavior, name: "再生可否決定の owner", meaning_or_rule: "「このエピソードを今再生できるか」を 1 箇所が決める", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:238-249`（URL 解決・ファイルシステム由来）", "prod `Podcast/PodcastViewModel.swift:181-184`（オフライン可否・ミラー由来）", "prod `Podcast/PodcastRowView.swift:119-120`（生成ステータス由来の表示判断が View）", "3 者が別々の入力で同じ問いに答える"]}}
- {id: ME32, dimension: behavior, name: "セッション失効ハンドリングの owner", meaning_or_rule: "実行中 401 を検知して未認証へ落とす責務の所在", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Networking/APIClient.swift:536-546`（status を意味化するのは 429 のみ）", "token 破棄は prod `AppState.swift:217`（起動時 refreshAuth の catch）と `:299`（logout）の 2 点のみ", "各 VM は 401 を汎用エラー文言として表示する"]}}
- {id: ME33, dimension: behavior, name: "logout 時の主体データ消去 owner", meaning_or_rule: "logout で消すべきデータの列挙と削除を 1 箇所が所有する", target_status: missing, concept_kind: not_applicable,
   evidence: {status: contradiction, sources: ["spec §6.3（`removeAllDownloads()` を owner と規定）", "prod `Networking/AudioCacheManager.swift:90-96`（`clearCache` は存在するが呼出元は prod `Settings/SettingsViewModel.swift:186` の利用者操作のみ）", "prod `AppState.swift:282-302`（logout は cacheManager を参照しない）", "`MPNowPlayingInfoCenter` のクリアは prod `Podcast/PodcastViewModel.swift:611`（`stopPlayback`）と `:733` のみで logout 経路に無い"]}}
- {id: ME69, dimension: behavior, name: "IndexSet 複数移動の責務所在", meaning_or_rule: "spec §2.7 は複数選択移動をプラットフォームアダプタの責務としコア仕様外と定める", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["spec §2.7（複数選択はアダプタ責務・コア仕様外）", "prod `Podcast/PlaybackQueue.swift:131-142`（コアモデル自身が IndexSet 複数移動を実装）", "prod `Podcast/PodcastViewModel.swift:548-550`（アダプタ層は素通し）"]}}
- {id: ME75, dimension: writer, name: "Podcast 値の唯一の writer", meaning_or_rule: "backend JSON の decode", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:121-141`", "memberwise init はテスト/プレビュー用途で維持されている旨を `:118-120` が明記"]}}

- {id: ME34, dimension: relationship, name: "再生セッション ↔ キューの整合範囲", meaning_or_rule: "同時に守るべき範囲（current の一致・前進の原子性）", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["queue writer 6 経路（prod `Podcast/PodcastViewModel.swift:441,517,519,527,536,544,549`）のうち VM 側 `currentPodcast` を同時更新するのは `:517-521` と `:441-442` のみ", "prod `Podcast/QueueSheet.swift:22`（View 側が `currentPodcast != nil` と `queue.current` の AND で不整合を吸収している＝整合が保証されていない証跡）"]}}
- {id: ME35, dimension: relationship, name: "downloadedIds ↔ ファイルシステム", meaning_or_rule: "ミラーと実体の同期契機・方向・失敗時の扱い", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["同期契機は prod `Podcast/PodcastViewModel.swift:149`（`loadPodcasts` 成功時）の 1 点のみ", "`download` `:209` と `removeDownload` `:220` は自分の操作結果だけを反映する", "外部インスタンスによる削除は伝播しない（ME59）"]}}
- {id: ME36, dimension: relationship, name: "認証 context ↔ 再生/キャッシュ context", meaning_or_rule: "logout・失効が再生セッションとキャッシュへ伝播する範囲", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:282-302`（logout は `PodcastViewModel` も `AudioCacheManager` も参照しない）", "prod `NewsListenAppApp.swift:104,117-122`（`PodcastViewModel` は ContentView 所有で全タブ共有・AppState から到達経路が無い）"]}}
- {id: ME37, dimension: relationship, name: "既定速度 ↔ セッション速度", meaning_or_rule: "再生開始時にセッション速度を既定速度から初期化する", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:63-66`", "prod `Podcast/PodcastViewModel.swift:50`（初期値 1.0 固定）", "prod `Podcast/PodcastViewModel.swift:262-300`（play 経路に既定速度の参照が無い）"]}}
- {id: ME74, dimension: time, name: "生成完了の検知契機", meaning_or_rule: "processing のエピソードが completed になったことを client が知る契機", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["周期タイマーは位置同期のみ（prod `Podcast/PodcastViewModel.swift:816-826`）", "更新は手動 `.refreshable`（prod `Podcast/PodcastView.swift:126` ほか）に依存"]}}
```

### 3.6 failure / time

```yaml
- {id: ME38, dimension: failure, name: "オフライン＋未キャッシュ", meaning_or_rule: "再生不可。UI はダウンロード待機を促す（spec §6.1 の `'unavailable'`）", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:264-266`（利用者起点の再生では errorMessage を立てて return し、状態は保たれる）", "同じコードが auto-advance 経路（`:442`）からも呼ばれ、そこでは前進済みキューと旧セッションの不整合を残す（IV1）", "文言は英語リテラル `\"Offline and not cached\"`（`:265`）で、原因の異なる URL 不正とも合流する（ME45）"]}}
- {id: ME39, dimension: failure, name: "ストリーミング失敗（AVPlayerItem .failed）", meaning_or_rule: "再生継続不能。失敗後 state と再試行手段", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:416-420`（errorMessage と `isPlaying = false` のみ）", "`player` を解放せず `isBuffering` も `didFinishCurrentEpisode` も触らないため paused と区別できない", "再試行の公開操作が無い（`replayCurrentEpisode` `:481-487` は先頭から再生し直す別意味の操作）", "test `PodcastViewModelTests.swift:683,692,701` は errorMessage と isPlaying だけを固定している"]}}
- {id: ME40, dimension: failure, name: "再生位置同期の失敗", meaning_or_rule: "サーバ同期の失敗を区別し、失敗後 state か再送方針を持つ", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:849-851`（本文がコメントのみの catch。全 production で唯一）", "verification-run.md §5（空 catch 0・コメントのみ catch 1 件＝この箇所）"]}}
- {id: ME41, dimension: failure, name: "完聴記録の失敗", meaning_or_rule: "best-effort（自動遷移を止めない）", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:462`（`try?`）", "WHY を `:461-463` が明記", "test `PodcastViewModelTests.swift:162`（`testCompletionFailureDoesNotBlockQueueAutoAdvance`）", "再送は意図的に持たない＝設計判断として present と判定"]}}
- {id: ME42, dimension: failure, name: "実行中のセッション失効（401）", meaning_or_rule: "区別すべき失敗。未認証への遷移と再ログイン導線", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Networking/APIClient.swift:544`（`APIError.httpError(statusCode:)` へ潰す）", "iOS 側に 401 の集中消費者が無い（ME27・ME32）"]}}
- {id: ME43, dimension: failure, name: "起動時 refreshAuth の失敗（通信失敗 vs 失効）", meaning_or_rule: "通信失敗ではトークンを保持し、失効でのみ破棄する", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: contradiction, sources: ["prod `AppState.swift:216-220`（catch が例外種別を問わず `sessionStore.token = nil`）", "doc comment `:200-201` は「未設定・トークン無し・失効はすべて未認証として扱い、トークンを破棄する」と書き通信失敗に言及しない", "test `AppStateAuthTests.swift:49` はトークン無しの場合のみ固定しており、通信失敗ケースは未検証"]}}
- {id: ME44, dimension: failure, name: "キャッシュ I/O 失敗", meaning_or_rule: "書込/削除/列挙の失敗を区別し利用者へ通知する", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["書込/削除は throws で伝播し errorMessage へ（prod `Podcast/PodcastViewModel.swift:211,222`）", "列挙失敗は握り潰す: prod `Networking/AudioCacheManager.swift:81`（`cacheSize` が 0 を返す）、`:91`（`clearCache` が黙って no-op）", "結果、`clearCache` の成功と「ディレクトリが読めない」が区別できない"]}}
- {id: ME45, dimension: failure, name: "audio_url の欠損・不正", meaning_or_rule: "再生元が得られないことを、オフライン起因と区別して扱う", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:127`（`audio_url` は必須だが空文字を許す）", "prod `Podcast/PodcastViewModel.swift:243-246`（オンラインでも `URL(string:)` が nil なら nil を返す）", "prod `Podcast/PodcastViewModel.swift:265`（呼び側は原因を問わず \"Offline and not cached\" を表示）", "download 経路だけは別文言を持つ（`:201` \"Invalid audio URL\"）＝同一原因に 2 文言"]}}
- {id: ME64, dimension: failure, name: "logout 時のキャッシュ削除失敗", meaning_or_rule: "spec §6.3 は best-effort とし、失敗しても UI は即時未認証へ遷移する", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["spec §6.3 末尾（両プラットフォーム共通方針）", "prod `AppState.swift:282-302`（削除処理自体が無いため失敗の扱いも存在しない）"]}}

- {id: ME46, dimension: time, name: "stale callback 判定", meaning_or_rule: "非同期に遅延到達したコールバックが新しい状態を上書きしない", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:357`（登録時点で `endedId` を閉じ込める）", "`:399-401`, `:407-409`（インスタンス同一性の純粋関数ガード）", "`:436`（`currentPodcast?.id != endedId` で早期 return）", "test `PodcastViewModelTests.swift:741,748,755,762,769,776,1049,1103`"]}}
- {id: ME47, dimension: time, name: "位置同期の周期と server-wins の反映順", meaning_or_rule: "15 秒周期 + 停止時 + background 遷移時に送信し、server-wins（spec §6.2）でローカルを調整する", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:816-826`（15 秒 Timer）、`:585`（stopPlayback）、`:832-834`（flush）", "prod `Podcast/PodcastViewModel.swift:848`（`_ = try await updatePlaybackPosition(...)` で応答 Podcast を破棄）", "破棄の結果、`podcasts` と `currentPodcast` の `playbackPositionSeconds` は取得時点の値のまま古くなる", "spec §6.2 は server-wins を規定するが、client 側にサーバ値を取り込む契機は次回 `loadPodcasts` のみ"]}}
- {id: ME48, dimension: time, name: "末尾 2 秒ウィンドウ", meaning_or_rule: "末尾付近の保存位置は「聴き終えた」記録として復元しない", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:296-305`（WHY を含む）", "test `PodcastViewModelTests.swift:1017,1028,1038`"]}}
- {id: ME60, dimension: time, name: "セッション有効期限と失効検知時刻", meaning_or_rule: "token の有効期限、失効検知の契機、再検証間隔", target_status: missing, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Networking/SessionStore.swift:19-23,33-45`（token は文字列のみで期限を持たない）", "検証契機は起動時 `refreshAuth`（prod `AppState.swift:201`）の 1 回のみ", "実行中の再検証・期限切れ予測が無い"]}}
```

### 3.7 writer / reader

```yaml
- {id: ME49, dimension: writer, name: "currentPodcast の writer", meaning_or_rule: "再生開始時のみ設定される", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["本番の唯一の代入は prod `Podcast/PodcastViewModel.swift:281`", "ただし宣言 `:42` は `@Published var`（`private(set)` なし）でモジュール内の任意コードが書込可能", "DEBUG 経路の実書込: prod `DesignSystem/PreviewSupport.swift:153,165`"]}}
- {id: ME50, dimension: writer, name: "queue の writer", meaning_or_rule: "ViewModel の公開操作を通してのみ変更される", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["宣言 prod `Podcast/PodcastViewModel.swift:59`（`private(set)`）", "変更点は `:441,517,519,527,536,544,549` の 7 点すべて VM 内", "`Podcast/PlaybackQueue.swift:18-19` も `private(set)` で mutating 経由のみ"]}}
- {id: ME51, dimension: writer, name: "errorMessage の writer", meaning_or_rule: "失敗を検知した層だけが設定し、利用者の確認で解除する", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["VM 内 9 点（prod `Podcast/PodcastViewModel.swift:145,151,201,211,222,265,386,418,624`）", "View 2 点（prod `Podcast/PodcastView.swift:45,135`）が nil を代入", "writer ごとに意味（失敗種別）が異なるが型は共通の `String?`"]}}
- {id: ME52, dimension: writer, name: "キャッシュ有無の writer", meaning_or_rule: "ファイルシステムが正本で、writer は 1 owner を通る", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["実体 writer 2 系統: prod `Podcast/PodcastViewModel.swift:207`（`cache`）/`:228`（`remove`）と prod `Settings/SettingsViewModel.swift:186`（`clearCache`）", "各々が別インスタンス（prod `Podcast/PodcastViewModel.swift:131` と prod `Settings/SettingsViewModel.swift:69,76` の既定引数）を持つ", "ミラー writer は prod `Podcast/PodcastViewModel.swift:157,209,220`"]}}
- {id: ME53, dimension: writer, name: "session token の writer", meaning_or_rule: "AppState の認証遷移を通してのみ書かれる", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `AppState.swift:152`（login）、`:217`（refreshAuth 失敗）、`:299`（logout）の 3 点のみ", "実体は prod `Networking/SessionStore.swift:36-45`（protocol 注入・`AppState.swift:345`）"]}}
- {id: ME54, dimension: writer, name: "currentUser の writer", meaning_or_rule: "認証遷移の owner だけが書く", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["AppState 内 4 点（prod `AppState.swift:153,208,218,300`）", "View からの直接代入 1 点: prod `Settings/AccountSettingsView.swift:308`（`appState.currentUser = updated`）", "宣言 prod `AppState.swift:98` は `@Published var`"]}}
- {id: ME65, dimension: reader, name: "次利用者による前利用者データの読取経路", meaning_or_rule: "logout 後に残ったデータを次の利用者が自分のものとして読む経路", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:157`（`syncDownloadedState` は端末上のファイル実在のみで判定し所有者を問わない）", "prod `AppState.swift:345-360`（init が UserDefaults の主体依存値をそのまま読み戻す）", "prod `Settings/SettingsViewModel.swift:179`（`cacheSize` が前利用者のファイル容量を表示する）"]}}
- {id: ME56, dimension: reader, name: "「再生中」の reader", meaning_or_rule: "同じ問いに対し全 reader が同じ根拠を使う", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastView.swift:90`（`currentPodcast?.id == podcast.id && isPlaying`）", "prod `Podcast/QueueSheet.swift:22`（`currentPodcast != nil` と `queue.current` の AND）", "2 つの reader が別の合成規則で同じ意味を再構成している"]}}
- {id: ME57, dimension: reader, name: "オフライン再生可否の reader", meaning_or_rule: "表示と実行が同じ根拠で判断する", target_status: conflicting, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["表示: prod `Podcast/PodcastView.swift:91` → `isPlayableWhileOffline`（prod `Podcast/PodcastViewModel.swift:181-184`、ミラー由来）", "実行: prod `Podcast/PodcastViewModel.swift:264` → `resolvePlaybackURL`（`:238-249`、ファイルシステム由来）"]}}
- {id: ME58, dimension: reader, name: "認証状態の reader", meaning_or_rule: "ルーティングと出し分けが `authStatus` を読む", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `NewsListenAppApp.swift:50`", "prod `AppState.swift:185-186`（`registerDeviceTokenIfPossible` の guard）"]}}
- {id: ME70, dimension: reader, name: "キューの reader", meaning_or_rule: "待機列と現在を表示する", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/QueueSheet.swift:22,29,34`", "prod `Podcast/PodcastView.swift:39`", "いずれも `queue` の公開アクセサのみを読み、独自解釈を持たない"]}}
- {id: ME76, dimension: reader, name: "status の reader", meaning_or_rule: "生成ステータスを解釈する経路", target_status: present, concept_kind: not_applicable,
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastRowView.swift:119-120`（`statusBadge` の `switch podcast.status`）が唯一", "再生経路（prod `Podcast/PodcastViewModel.swift:262-384`）は status を一切読まない"]}}
```

## 4. access paths（不正状態へ到達しうる公開経路のみ。writer/reader の全在庫は §3.7）

```yaml
- {id: AP1, matrix_element_id: ME49, kind: writer, actor_or_component: "AVPlayerItem 終了通知 → PodcastViewModel", entry_point: "prod `Podcast/PodcastViewModel.swift:358-367` → `:435` `handlePlaybackEnded(endedId:)`",
   operation_or_interpretation: "`queue.advance()`（`:441`）でキューを前進させた後 `play(podcast:expandsPlayer:)`（`:442`）を呼ぶ",
   model_element_ids: [ME14, ME26, ME30, ME38], validation_or_translation_route: "stale ガード `:436` のみ。再生成否の検査は無い",
   bypass_or_misinterpretation_risk: "`play` の早期 return（`:264-266`）が呼び側へ伝わらず、前進済みキューと旧セッションが併存する（IV1）",
   representation: "in-memory `@Published` 状態", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:435-474`"]}}
- {id: AP2, matrix_element_id: ME51, kind: writer, actor_or_component: "SwiftUI View（利用者のアラート操作）", entry_point: "prod `Podcast/PodcastView.swift:45`, `:135`",
   operation_or_interpretation: "`viewModel.errorMessage = nil`", model_element_ids: [ME7, ME15, ME21],
   validation_or_translation_route: "なし（`@Published var` への直接代入）", bypass_or_misinterpretation_risk: "失敗状態が paused と区別できなくなる（IV2）",
   representation: "in-memory", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:40`", "prod `Podcast/PodcastView.swift:45,135`"]}}
- {id: AP3, matrix_element_id: ME50, kind: writer, actor_or_component: "SwiftUI View（キューからの削除）", entry_point: "prod `Podcast/QueueSheet.swift:37-41` → `removeFromQueue(id:)` prod `Podcast/PodcastViewModel.swift:543-545`",
   operation_or_interpretation: "`queue.remove(id:)`（prod `Podcast/PlaybackQueue.swift:100-113`）", model_element_ids: [ME14, ME34],
   validation_or_translation_route: "なし。VM 側 `currentPodcast`・`player` は更新しない",
   bypass_or_misinterpretation_risk: "再生中エピソードを削除すると `queue.current` だけが次要素へ進む（IV4）。なお `QueueSheet` は `upNext` のみを削除対象に出すため、現時点の UI からは現在エピソードの削除に到達しない（内部 API としては到達可能）",
   representation: "in-memory", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Podcast/QueueSheet.swift:29,34,37-41`", "prod `Podcast/PlaybackQueue.swift:100-113`"]}}
- {id: AP4, matrix_element_id: ME49, kind: writer, actor_or_component: "プッシュ通知ディープリンク", entry_point: "prod `AppState.swift:193-195` → prod `NewsListenAppApp.swift:188` → `playById(_:)` prod `Podcast/PodcastViewModel.swift:381-388`",
   operation_or_interpretation: "取得したエピソードを `play` するがキューには触れない", model_element_ids: [ME1, ME14, ME34],
   validation_or_translation_route: "なし", bypass_or_misinterpretation_risk: "`currentPodcast` と `queue.current` が無関係になり、以後の `addToQueue`/`playNext` の「何も再生していない」判定（`:526`, `:535`）も誤る（IV5）",
   representation: "in-memory", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:381-388,525-526,534-535`"]}}
- {id: AP5, matrix_element_id: ME53, kind: writer, actor_or_component: "ログイン応答 → AppState", entry_point: "prod `AppState.swift:151-157` `completeLogin(_:)`",
   operation_or_interpretation: "`sessionStore.token = response.token` と `authStatus = .authenticated` を検査なしに代入", model_element_ids: [ME10, ME16],
   validation_or_translation_route: "なし。`KeychainSessionStore`（prod `Networking/SessionStore.swift:38-43`）は空文字を削除として解釈する",
   bypass_or_misinterpretation_risk: "空トークン応答で authenticated かつ token nil が成立し、回復経路が無い（IV6）",
   representation: "Keychain generic password", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `AppState.swift:151-157`", "prod `Networking/SessionStore.swift:36-45`"]}}
- {id: AP6, matrix_element_id: ME54, kind: writer, actor_or_component: "SwiftUI View（プロフィール保存）", entry_point: "prod `Settings/AccountSettingsView.swift:308`",
   operation_or_interpretation: "`appState.currentUser = updated`（View が API を直接呼び結果を代入）", model_element_ids: [ME4, ME10, ME16],
   validation_or_translation_route: "なし", bypass_or_misinterpretation_risk: "logout と競合すると `.unauthenticated` かつ `currentUser != nil` が残る（IV7）。`isAdmin` 判定（prod `Settings/SettingsView.swift:204` ほか）が旧値に基づく",
   representation: "in-memory", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Settings/AccountSettingsView.swift:305-333`", "prod `AppState.swift:98`"]}}
- {id: AP7, matrix_element_id: ME52, kind: writer, actor_or_component: "設定画面（キャッシュ全削除）", entry_point: "prod `Settings/SettingsViewModel.swift:184-191` `clearCache()`",
   operation_or_interpretation: "独立インスタンスの `AudioCacheManager.clearCache()`（prod `Networking/AudioCacheManager.swift:90-96`）でディレクトリを空にする", model_element_ids: [ME3, ME17, ME59],
   validation_or_translation_route: "なし。`PodcastViewModel.downloadedIds` への通知が無い",
   bypass_or_misinterpretation_risk: "一覧はオフライン再生可の表示のまま、実行時のみ失敗する（IV10）",
   representation: "FileManager（`Caches/NewsListenApp/audio-cache`）", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Settings/SettingsViewModel.swift:184-191`", "prod `Podcast/PodcastViewModel.swift:149,157`"]}}
- {id: AP8, matrix_element_id: ME18, kind: reader, actor_or_component: "再生元解決", entry_point: "prod `Podcast/PodcastViewModel.swift:238-249` `resolvePlaybackURL`",
   operation_or_interpretation: "`isCached(id)`（prod `Networking/AudioCacheManager.swift:52-55`）→ `cachedURL(for:)`（`:45-47`）", model_element_ids: [ME18],
   validation_or_translation_route: "なし（`validateId` は書込経路 `:63`, `:72` でのみ実行される）",
   bypass_or_misinterpretation_risk: "backend 由来 id が path 構成文字を含むと `appendingPathComponent` で cache ディレクトリ外を指しうる。id の出所は backend JSON（prod `Models/Podcast.swift:122`）のみで、現時点で不正 id の実例は未確認",
   representation: "file URL", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `Networking/AudioCacheManager.swift:45-55,102-108`"]}}
- {id: AP9, matrix_element_id: ME65, kind: reader, actor_or_component: "logout 後の次利用者", entry_point: "prod `Podcast/PodcastViewModel.swift:149` → `:157` `syncDownloadedState()`",
   operation_or_interpretation: "端末上のファイル実在のみで「自分のダウンロード済み」を決定する", model_element_ids: [ME61, ME62, ME65],
   validation_or_translation_route: "なし（所有者情報を持たない）", bypass_or_misinterpretation_risk: "前利用者の音声を次利用者が再生できる（IV9）",
   representation: "FileManager", platform: not_applicable, evidence: {status: confirmed, sources: ["prod `AppState.swift:282-302`", "prod `Podcast/PodcastViewModel.swift:149,157`"]}}
```

## 5. ownership（scope-local な authority）

```yaml
- {id: OW1, matrix_element_id: ME21, authority_type: state_authority, subject_element_ids: [ME6, ME21, ME26], owner: "PodcastViewModel（型としての単一 owner だが、状態は 15 atom に分散し遷移を許可する門が無い）", target_status: conflicting,
   transition_controls: {status: not_applicable, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "移行計画の有無を router/user に確認", impact_if_unresolved: "なし（移行中ではなく恒常構造）", evidence: []},
   evidence: {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:36-69`", "遷移を通さない直接代入が `isPlaying`(`:370`,`:419`,`:605`), `didFinishCurrentEpisode`(`:272`,`:449`,`:494`) などで可能"]}}
- {id: OW2, matrix_element_id: ME1, authority_type: source_of_truth, subject_element_ids: [ME1, ME14], owner: "未確定（VM `currentPodcast` と `queue.currentIndex` が併存）", target_status: conflicting,
   transition_controls: {status: unknown, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "spec §2.1 不変条件 4 を iOS に適用するかを user が決定（SG2）", impact_if_unresolved: "IV1・IV4・IV5 の不整合が仕様違反か許容差かを判定できない", evidence: []},
   evidence: {status: contradiction, sources: ["spec §2.1 不変条件 4（`current` = `items[currentIndex]`）", "prod `Podcast/PodcastView.swift:90` と prod `Podcast/MiniPlayerView.swift:24,44` は `currentPodcast` を正本として読む"]}}
- {id: OW3, matrix_element_id: ME3, authority_type: source_of_truth, subject_element_ids: [ME3, ME17], owner: "ファイルシステム（`AudioCacheManager` 経由）が正本、`downloadedIds` は派生", target_status: conflicting,
   transition_controls: {status: not_applicable, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "", impact_if_unresolved: "なし", evidence: []},
   evidence: {status: confirmed, sources: ["派生であるべき `downloadedIds` を表示判断（prod `Podcast/PodcastViewModel.swift:181-184`）が正本として使う", "`AudioCacheManager` 自体が 2 インスタンス（ME11）"]}}
- {id: OW4, matrix_element_id: ME2, authority_type: semantic_owner, subject_element_ids: [ME2, ME37], owner: "未確定（既定速度＝AppState、セッション速度＝PodcastViewModel で相互参照なし）", target_status: conflicting,
   transition_controls: {status: not_applicable, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "", impact_if_unresolved: "なし", evidence: []},
   evidence: {status: confirmed, sources: ["prod `AppState.swift:63-66`", "prod `Podcast/PodcastViewModel.swift:50,575-579`"]}}
- {id: OW5, matrix_element_id: ME22, authority_type: state_authority, subject_element_ids: [ME4, ME10, ME22, ME27], owner: "AppState（ただし `currentUser` は View からも書ける／失効遷移の門が無い）", target_status: conflicting,
   transition_controls: {status: not_applicable, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "", impact_if_unresolved: "なし", evidence: []},
   evidence: {status: confirmed, sources: ["prod `AppState.swift:95-98`", "prod `Settings/AccountSettingsView.swift:308`", "401 遷移の owner 不在（ME32）"]}}
- {id: OW6, matrix_element_id: ME61, authority_type: invariant_owner, subject_element_ids: [ME61, ME62, ME33], owner: "未確定（spec §6.3 は `AudioCacheManager` を owner と示すが該当 API が無く、`AppState.logout` も列挙を持たない）", target_status: conflicting,
   transition_controls: {status: not_applicable, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "", impact_if_unresolved: "なし", evidence: []},
   evidence: {status: contradiction, sources: ["spec §6.3", "prod `Networking/AudioCacheManager.swift:27-118`", "prod `AppState.swift:282-302`"]}}
- {id: OW7, matrix_element_id: ME67, authority_type: invariant_owner, subject_element_ids: [ME12, ME19, ME67, ME68], owner: "PlaybackQueue（値型・`private(set)`・mutating 経由のみ）", target_status: unique,
   transition_controls: {status: not_applicable, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "", impact_if_unresolved: "なし", evidence: []},
   evidence: {status: confirmed, sources: ["prod `Podcast/PlaybackQueue.swift:16-28`", "test `PlaybackQueueConformanceTests.swift`（Q-01〜Q-32・V1 green）"]}}
- {id: OW8, matrix_element_id: ME5, authority_type: semantic_owner, subject_element_ids: [ME5, ME9, ME71, ME72, ME73], owner: "backend（iOS は文字列を透過保持するのみ）", target_status: unknown,
   transition_controls: {status: unknown, transition_period: "", conflict_rule: "", reconciliation: "", removal_condition: "", owner: "", confirmation_method: "backend の PodcastResponse スキーマと ADR-021 を読み、iOS が値域検証を担うべきかを確認する（本 review の scope は iOS のみで backend を読んでいない）", impact_if_unresolved: "未知 status 値の扱い（fail-open か fail-closed か）を決められず、OB-C10 の契約方向が定まらない", evidence: []},
   evidence: {status: inferred, sources: ["prod `Models/Podcast.swift:69-71`（enum 変換を ADR-021 / iOS#15 へ先送りと明記）"]}}
```

## 6. 12 dimension screening（分母 = in-scope requirement 6 × 12 = 72 cell）

```yaml
dimension_applicability_profiles:
  - id: DAP1
    requirement_ids: [R6]
    dimensions: [time]
    disposition: not_applicable
    rationale: "spec §6.3 は logout を非同期ベストエフォートと定め、キャッシュ削除の完了を UI 遷移から切り離している。よって削除の期限・順序・history・基準 clock は R6 の合否（前利用者データが残らないこと）を分岐させない。"
    evidence: {status: confirmed, sources: ["spec §6.3 末尾「logout は非同期（ベストエフォート）。キャッシュ削除に失敗してもログアウト UI 状態は即座に未認証へ遷移」"]}
  - id: DAP2
    requirement_ids: [R9]
    dimensions: [failure, time]
    disposition: not_applicable
    rationale: "`PlaybackQueue` は外部 I/O も時刻も持たない純粋値オブジェクトで（import は Foundation のみ）、範囲外入力は例外ではなく no-op へ畳まれる（spec §2.5/§2.7/§2.8/§2.10）。区別すべき失敗も基準 clock も存在しない。"
    evidence: {status: confirmed, sources: ["spec §2.1 の WHY 純粋モデル", "spec §2.5, §2.7, §2.8, §2.10（no-op 規定）", "prod `Podcast/PlaybackQueue.swift:10`（import Foundation のみ）", "prod `Podcast/PlaybackQueue.swift:133`（範囲外は no-op）"]}
  - id: DAP3
    requirement_ids: [R10]
    dimensions: [transition]
    disposition: not_applicable
    rationale: "生成ライフサイクルの遷移を許可・実行するのは backend であり、iOS は `Podcast` を読み取り専用で decode する（唯一の writer は decode・ME75）。iOS 側に許可/禁止/条件付き遷移の判断が存在しないため、R10（組合せ整合）の合否を分岐させない。"
    evidence: {status: confirmed, sources: ["prod `Models/Podcast.swift:121-141`", "iOS に status を書き換える経路が無い"]}

requirement_model_matrix:
  - requirement_id: R2
    dimension_links:
      - {dimension: term_context, element_ids: [ME1], evidence: {status: confirmed, sources: ["§3.1"]}}
      - {dimension: concept, element_ids: [ME6, ME7], evidence: {status: confirmed, sources: ["§3.2"]}}
      - {dimension: constraint, element_ids: [ME13, ME14, ME15], evidence: {status: confirmed, sources: ["§3.3"]}}
      - {dimension: state, element_ids: [ME21], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: transition, element_ids: [ME26, ME29], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: behavior, element_ids: [ME30], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: relationship, element_ids: [ME34], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: failure, element_ids: [ME38, ME39, ME45], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: time, element_ids: [ME46], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: writer, element_ids: [ME49, ME50, ME51], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: reader, element_ids: [ME56], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: authority, element_ids: [OW1], evidence: {status: confirmed, sources: ["§5"]}}
    not_applicable_profile_ids: []
    present_cells: [time]
  - requirement_id: R3
    dimension_links:
      - {dimension: term_context, element_ids: [ME1, ME2, ME3], evidence: {status: confirmed, sources: ["§3.1"]}}
      - {dimension: concept, element_ids: [ME11], evidence: {status: confirmed, sources: ["§3.2"]}}
      - {dimension: constraint, element_ids: [ME17], evidence: {status: confirmed, sources: ["§3.3"]}}
      - {dimension: state, element_ids: [ME24], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: transition, element_ids: [ME59], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: behavior, element_ids: [ME31], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: relationship, element_ids: [ME35, ME37], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: failure, element_ids: [ME44], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: time, element_ids: [ME47], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: writer, element_ids: [ME49, ME52, ME54], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: reader, element_ids: [ME57], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: authority, element_ids: [OW2, OW3, OW4], evidence: {status: confirmed, sources: ["§5"]}}
    not_applicable_profile_ids: []
    present_cells: [state]
  - requirement_id: R5
    dimension_links:
      - {dimension: term_context, element_ids: [ME4], evidence: {status: confirmed, sources: ["§3.1"]}}
      - {dimension: concept, element_ids: [ME10], evidence: {status: confirmed, sources: ["§3.2"]}}
      - {dimension: constraint, element_ids: [ME16], evidence: {status: confirmed, sources: ["§3.3"]}}
      - {dimension: state, element_ids: [ME22], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: transition, element_ids: [ME27], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: behavior, element_ids: [ME32], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: relationship, element_ids: [ME36], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: failure, element_ids: [ME42, ME43], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: time, element_ids: [ME60], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: writer, element_ids: [ME53, ME54], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: reader, element_ids: [ME58], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: authority, element_ids: [OW5], evidence: {status: confirmed, sources: ["§5"]}}
    not_applicable_profile_ids: []
    present_cells: [state, reader]
  - requirement_id: R6
    dimension_links:
      - {dimension: term_context, element_ids: [ME61], evidence: {status: confirmed, sources: ["§3.1"]}}
      - {dimension: concept, element_ids: [ME11], evidence: {status: confirmed, sources: ["§3.2"]}}
      - {dimension: constraint, element_ids: [ME62], evidence: {status: confirmed, sources: ["§3.3"]}}
      - {dimension: state, element_ids: [ME22], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: transition, element_ids: [ME28], evidence: {status: contradiction, sources: ["§3.4"]}}
      - {dimension: behavior, element_ids: [ME33], evidence: {status: contradiction, sources: ["§3.5"]}}
      - {dimension: relationship, element_ids: [ME36], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: failure, element_ids: [ME64], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: writer, element_ids: [ME52, ME53], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: reader, element_ids: [ME65], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: authority, element_ids: [OW6], evidence: {status: contradiction, sources: ["§5"]}}
    not_applicable_profile_ids: [DAP1]
    present_cells: [state, reader]
  - requirement_id: R9
    dimension_links:
      - {dimension: term_context, element_ids: [ME66], evidence: {status: confirmed, sources: ["§3.1"]}}
      - {dimension: concept, element_ids: [ME12], evidence: {status: confirmed, sources: ["§3.2"]}}
      - {dimension: constraint, element_ids: [ME19], evidence: {status: confirmed, sources: ["§3.3"]}}
      - {dimension: state, element_ids: [ME67], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: transition, element_ids: [ME68], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: behavior, element_ids: [ME69], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: relationship, element_ids: [ME34], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: writer, element_ids: [ME50], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: reader, element_ids: [ME70], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: authority, element_ids: [OW7], evidence: {status: confirmed, sources: ["§5"]}}
    not_applicable_profile_ids: [DAP2]
    present_cells: [concept, constraint, state, transition, writer, reader, authority]
  - requirement_id: R10
    dimension_links:
      - {dimension: term_context, element_ids: [ME5], evidence: {status: confirmed, sources: ["§3.1"]}}
      - {dimension: concept, element_ids: [ME8, ME9], evidence: {status: confirmed, sources: ["§3.2"]}}
      - {dimension: constraint, element_ids: [ME71], evidence: {status: confirmed, sources: ["§3.3"]}}
      - {dimension: state, element_ids: [ME72], evidence: {status: confirmed, sources: ["§3.4"]}}
      - {dimension: behavior, element_ids: [ME31], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: relationship, element_ids: [ME73], evidence: {status: confirmed, sources: ["§3.3 末尾"]}}
      - {dimension: failure, element_ids: [ME45], evidence: {status: confirmed, sources: ["§3.6"]}}
      - {dimension: time, element_ids: [ME74], evidence: {status: confirmed, sources: ["§3.5 末尾"]}}
      - {dimension: writer, element_ids: [ME75], evidence: {status: confirmed, sources: ["§3.5"]}}
      - {dimension: reader, element_ids: [ME76], evidence: {status: confirmed, sources: ["§3.7"]}}
      - {dimension: authority, element_ids: [OW8], evidence: {status: inferred, sources: ["§5"]}}
    not_applicable_profile_ids: [DAP3]
    present_cells: [writer, reader]
```

**screening 集計（展開後 cell 数で計算）**

| requirement | 12 dim 中 applicable | N/A（profile） | present cell | present cell の内訳 |
|---|---:|---:|---:|---|
| R2 | 12 | 0 | 1 | time（ME46） |
| R3 | 12 | 0 | 1 | state（ME24） |
| R5 | 12 | 0 | 2 | state（ME22）, reader（ME58） |
| R6 | 11 | 1（DAP1: time） | 2 | state（ME22）, reader（ME65） |
| R9 | 10 | 2（DAP2: failure, time） | 7 | concept, constraint, state, transition, writer, reader, authority |
| R10 | 11 | 1（DAP3: transition） | 2 | writer（ME75）, reader（ME76） |
| **合計** | **68** | **4** | **15** | — |

## 7. 不正状態 IV*（構築可能な組合せと、構築できる公開経路）

| ID | 構築できる不正な組合せ | 公開経路（`path:line`） | scope | element |
|---|---|---|---|---|
| IV1 | `isPlaying == true` ∧ 音は鳴っていない ∧ `currentPodcast` は前のエピソード ∧ `queue.current` は次のエピソード ∧ `errorMessage != nil` ∧ `presentation` 不変 | 再生終了通知 `Podcast/PodcastViewModel.swift:358-367` → `handlePlaybackEnded(endedId:)` `:435` → `queue.advance()` `:441` → `play(podcast:expandsPlayer:false)` `:442` → 再生元解決失敗で早期 return `:264-266`。`handlePlaybackEnded()` 自体も internal で直接呼べる | S1+S2 | ME14, ME26, ME30, ME38 |
| IV2 | `errorMessage == nil` ∧ 直前の再生が失敗したまま（`isPlaying == false` ∧ `player != nil`） | `Podcast/PodcastView.swift:45`（アラート OK）/ `:135`（sheet dismiss）が `viewModel.errorMessage = nil`。宣言 `Podcast/PodcastViewModel.swift:40` は `@Published var` | S1 | ME7, ME15, ME21 |
| IV3 | `isBuffering == true` ∧ `isPlaying == false` ∧ `errorMessage != nil` | `handleTimeControlStatusChange(.waitingToPlayAtSpecifiedRate)` `Podcast/PodcastViewModel.swift:424-425` の後に `handlePlayerItemStatusChange(.failed,...)` `:416-419`（`isBuffering` を戻さない）。両者とも internal | S1 | ME21, ME39 |
| IV4 | `currentPodcast?.id != queue.current?.id` ∧ 音声は継続再生中 | `removeFromQueue(id:)` `Podcast/PodcastViewModel.swift:543-545` に再生中 id を渡す → `PlaybackQueue.remove` `Podcast/PlaybackQueue.swift:109-111` が次要素を current に昇格。VM 側は不変。現行 UI（`Podcast/QueueSheet.swift:37-41`）は `upNext` のみ削除対象に出すため到達はモジュール内 API 経由 | S2 | ME14, ME34 |
| IV5 | `currentPodcast != nil` ∧ `queue.currentIndex == nil`（または無関係な位置） | 通知ディープリンク `AppState.swift:193-195` → `NewsListenAppApp.swift:188` → `playById(_:)` `Podcast/PodcastViewModel.swift:381-388`（queue 非更新）。以後 `addToQueue` `:525-526` / `playNext` `:534-535` の「何も再生していない」判定が `currentPodcast == nil` なので false となり、`PlaybackQueue.playNext` `:65-75` は currentIndex nil のまま先頭へ挿入する | S1+S2 | ME1, ME14, ME34 |
| IV6 | `authStatus == .authenticated` ∧ `currentUser != nil` ∧ `sessionStore.token == nil` | `AppState.completeLogin(_:)` `AppState.swift:151-157` が応答 token を無検査で代入 → `KeychainSessionStore.token` setter `Networking/SessionStore.swift:38-43` が空文字を削除として扱う。以後 `apiClient` `AppState.swift:137-142` は sessionToken nil で生成され、回復経路が無い | S3 | ME10, ME16 |
| IV7 | `authStatus == .unauthenticated` ∧ `currentUser != nil` | `Settings/AccountSettingsView.swift:308` が `appState.currentUser = updated`（宣言 `AppState.swift:98` は `@Published var`）。logout `:282-302` と競合すると残留し、`isAdmin` 出し分け（`Settings/SettingsView.swift:204`）が旧値で動く | S3 | ME4, ME16, ME54 |
| IV8 | 有効なトークンが破棄され `.unauthenticated`（失効していないのに再ログインを要求される） | 機内モード等での起動 → `AppState.refreshAuth()` `AppState.swift:201-221` の catch `:216-220` が例外種別を問わず `sessionStore.token = nil` | S3 | ME43, ME53 |
| IV9 | logout 後に前利用者の音声キャッシュ・ロック画面 NowPlaying・UserDefaults 主体依存値が残存し、次利用者がそれを自分のものとして読む | `AppState.logout()` `AppState.swift:282-302` の消去対象は token `:299` / currentUser `:300` / authStatus `:301` / `seen_achievement_ids` `:298` のみ。次利用者は `Podcast/PodcastViewModel.swift:157` で前利用者のファイルを「ダウンロード済み」として読み、`AppState.swift:352-360` が前利用者の既定難易度・再生速度・週次目標・表示設定を読み戻す | S3+S4 | ME33, ME61, ME62, ME65 |
| IV10 | `downloadedIds` に含まれるがファイルが存在しない（表示は「オフライン再生可」、実行は失敗） | `Settings/SettingsViewModel.swift:184-191` の `clearCache()` が別インスタンスでディレクトリを空にする。`Podcast/PodcastViewModel.downloadedIds` の再同期契機は `:157` で、呼出は `:149` の `loadPodcasts` 成功時のみ | S4 | ME3, ME17, ME59 |
| IV11 | `status == "processing"` ∧ `audioUrl == ""` ∧ `errorMessage == nil`、あるいは `status == "failed"` ∧ `errorMessage == nil` 等の任意の矛盾組合せ | backend JSON → `Models/Podcast.swift:121-141`。`status` は任意文字列を受理（`:133`）、`error_message` は独立 Optional（`:134`）、`audio_url` は必須だが空文字を許す（`:127`）。再生経路は status を読まないため（reader は `Podcast/PodcastRowView.swift:119-120` のみ）、空 URL は `Podcast/PodcastViewModel.swift:243-246` で nil となり `:265` の "Offline and not cached" に合流する | S5 | ME45, ME71, ME73 |
| IV12 | `onboardingCompleted == true` が「完了」「取得失敗」「保存失敗」のいずれかを判別できない | `AppState.refreshOnboardingStatus()` `:307-315` の catch `:312-313`、`completeOnboarding()` `:320-324` の `defer` `:321` | S3 | ME25 |

## 8. destruction probes（思考実験。本番 data への破壊操作なし）

```yaml
- id: DP1
  requirement_ids: [R2, R3]
  writer_access_path_id: AP1
  entry_point: "prod `Podcast/PodcastViewModel.swift:435` `handlePlaybackEnded(endedId:)`"
  destructive_input_or_sequence:
    - "キュー = [A, B]、A を再生中（`currentPodcast` = A、`queue.currentIndex` = 0）"
    - "B は未キャッシュ。A の再生中にオフラインへ遷移（`NetworkMonitoring` が isOnline=false を publish）"
    - "A が末尾に達し `didPlayToEndTime` が発火"
  propagation:
    - "`:436` stale ガード通過（`currentPodcast?.id == endedId`）"
    - "`:441` `queue.advance()` が currentIndex を 1 へ進め B を返す"
    - "`:442` `play(podcast: B, expandsPlayer: false)` → `:264` `resolvePlaybackURL` が nil → `:265` errorMessage 設定 → `:266` return"
    - "`stopPlayback()`（`:280`）へ到達しないため、A の player・timeObserver・KVO・15 秒 Timer はすべて生存"
    - "`isPlaying` は true のまま（`:370` は前回の play で立てた値）、`didFinishCurrentEpisode` は false のまま"
    - "`:464-473` で A の `markCompleted` が送られ streak が更新される"
  business_impact:
    - "ミニプレイヤーは A を「再生中」と表示し続けるが音は出ない（`Podcast/PodcastView.swift:90` は `currentPodcast` と `isPlaying` の AND）"
    - "`QueueSheet` は B を「再生中」と表示する（`Podcast/QueueSheet.swift:22` は `queue.current`）＝同一画面群で 2 つの答え"
    - "利用者の回復操作が無い: `replayCurrentEpisode`（`:481-487`）は A を再生し直し、B は待機列から消えたまま（advance 済みのため `upNext` に戻らない）"
    - "15 秒 Timer（`:816-826`）が A の位置を送り続ける"
  expected_invariant: "advance に伴う再生が失敗したとき、キュー位置と再生セッションのどちらか一方だけが進むことはない（ME14）"
  observed_result: {status: constructed, evidence: ["prod `Podcast/PodcastViewModel.swift:435-474`", "prod `Podcast/PodcastViewModel.swift:262-270`", "既存テストに当該経路は無い（test `PodcastViewModelTests.swift:87,96,162` はいずれも next の再生成功を前提にする）"]}
  defense_assessment: {status: absent, mechanisms: [], evidence: ["`play` は失敗を戻り値で返さない（`func play(...) async` に戻り値なし・`:262`）ため、呼び側が検知する手段が構造上存在しない"]}
  gap: {kind: invalid_state, element_ids: [ME14, ME26, ME30, ME38]}
  obligations: {applicability: required, rationale: "advance の前進と再生成功が原子的でない", confirmation_method: "", impact_if_unresolved: "", contract_obligation_ids: [OB-C1, OB-C2], test_obligation_ids: [OB-T1, OB-T2]}

- id: DP2
  requirement_ids: [R2]
  writer_access_path_id: AP2
  entry_point: "prod `Podcast/PodcastView.swift:45`"
  destructive_input_or_sequence:
    - "ストリーミング失敗（`handlePlayerItemStatusChange(.failed, ...)` `:416-419`）で errorMessage が立ち isPlaying=false"
    - "利用者がアラートの OK を押す → `viewModel.errorMessage = nil`"
  propagation:
    - "残る観測可能な状態は `isPlaying == false` ∧ `player != nil` ∧ `currentPodcast != nil` ∧ `didFinishCurrentEpisode == false`"
    - "これは利用者が自分で一時停止した状態（`togglePlayPause` `:553-559`）と完全に同一"
  business_impact:
    - "UI は再生ボタンを出すが、押しても `player.rate = playbackSpeed`（`:557`）は失敗済み item を進められない"
    - "失敗の再試行導線が無く、利用者は一覧へ戻って再タップする以外に回復手段がない"
  expected_invariant: "失敗状態は利用者の確認操作では消えない、または確認で消すなら再試行可能な状態へ遷移する（ME15）"
  observed_result: {status: constructed, evidence: ["prod `Podcast/PodcastViewModel.swift:40,416-419,553-559`", "prod `Podcast/PodcastView.swift:45,135`"]}
  defense_assessment: {status: absent, mechanisms: [], evidence: ["`errorMessage` は `private(set)` を持たない唯一の失敗表現"]}
  gap: {kind: invalid_state, element_ids: [ME7, ME15, ME21, ME39]}
  obligations: {applicability: required, rationale: "失敗が排他状態ではなく解除可能な付帯情報として表現されている", confirmation_method: "", impact_if_unresolved: "", contract_obligation_ids: [OB-C3], test_obligation_ids: [OB-T3]}

- id: DP3
  requirement_ids: [R5]
  writer_access_path_id: AP5
  entry_point: "prod `AppState.swift:151` `completeLogin(_:)` / prod `AppState.swift:201` `refreshAuth()`"
  destructive_input_or_sequence:
    - "(a) ログイン応答の `token` が空文字 → `completeLogin` が authenticated を立てる一方 Keychain は削除される（`Networking/SessionStore.swift:39-42`）"
    - "(b) 認証済みで利用中にサーバ側セッションが失効 → 任意の API が 401 を返す"
    - "(c) 機内モードで起動 → `refreshAuth` の `fetchMe` が URLError を投げる"
  propagation:
    - "(a) 以後 `apiClient`（`:137-142`）は sessionToken nil、全 API が 401、`authStatus` は authenticated のまま"
    - "(b) 401 は `APIError.httpError(statusCode: 401)`（prod `Networking/APIClient.swift:544`）として各 VM の汎用エラー文言になり、`authStatus` は変わらない。再ログイン導線が出ない"
    - "(c) catch `:216-220` が有効トークンを破棄し `.unauthenticated` へ"
  business_impact:
    - "(a)(b) 利用者はエラーの連続に遭うが原因（再ログインが必要）を知らされない"
    - "(c) 通信が戻っても再ログインが必要。オフライン再生のためにダウンロードした利用者ほど不利益を受ける"
  expected_invariant: "認証状態・利用者・トークンは同時にのみ遷移し、失効（401）と通信失敗を区別する（ME16, ME27, ME43）"
  observed_result: {status: constructed, evidence: ["prod `AppState.swift:151-157,201-221`", "prod `Networking/APIClient.swift:536-546`", "test `AppStateAuthTests.swift:49` はトークン無しの場合のみを固定する"]}
  defense_assessment: {status: absent, mechanisms: [], evidence: ["401 の集中処理・token 形式検証・例外種別の判別がいずれも存在しない"]}
  gap: {kind: missing_transition, element_ids: [ME10, ME16, ME27, ME32, ME42, ME43]}
  obligations: {applicability: required, rationale: "認証集約と失効遷移が欠落", confirmation_method: "", impact_if_unresolved: "", contract_obligation_ids: [OB-C5, OB-C6, OB-C7], test_obligation_ids: [OB-T5, OB-T6, OB-T7]}

- id: DP4
  requirement_ids: [R6]
  writer_access_path_id: AP9
  entry_point: "prod `AppState.swift:282` `logout()`"
  destructive_input_or_sequence:
    - "利用者 U1 がエピソード 3 件をダウンロードし再生中に logout"
    - "同一端末で利用者 U2 がログインし Podcast タブを開く"
  propagation:
    - "`logout` は token / currentUser / authStatus / `seen_achievement_ids` のみを消す（`:298-301`）"
    - "`Caches/NewsListenApp/audio-cache` の 3 ファイルは残る（`AudioCacheManager` は logout 経路から参照されない）"
    - "`MPNowPlayingInfoCenter.nowPlayingInfo` は U1 のエピソードのまま（クリアは `stopPlayback` `:611` と `updateNowPlayingInfo` `:733` のみ）"
    - "`AppState` の UserDefaults 値（既定難易度 `:353` / 既定再生速度 `:354` / 週次目標 `:355-357` / 記事の開き方 `:359` / 時刻表記 `:360`）は U1 の値のまま"
    - "U2 の `loadPodcasts` → `syncDownloadedState()`（`:149,157`）が U1 のファイル id と U2 の一覧の交差を「U2 のダウンロード済み」として表示する"
  business_impact:
    - "共有端末で U1 の音声を U2 が再生できる（id が一致する共通エピソードの場合）"
    - "ロック画面に U1 が聴いていたエピソードのタイトルが残る"
    - "U2 の設定画面が U1 の既定値を表示し、U2 が変更するまでサーバ同期（`refreshPreferences` `:225-245`）が上書きするまでの間は U1 の値で生成が走りうる"
  expected_invariant: "logout 完了後、前利用者に帰属する端末データが残らない（R6 / spec §6.3）"
  observed_result: {status: constructed, evidence: ["prod `AppState.swift:282-302`", "prod `Networking/AudioCacheManager.swift:27-118`（`removeAllDownloads` 不在）", "test `AppStateAuthTests.swift:34` は token と user のみを検証する"]}
  defense_assessment: {status: absent, mechanisms: ["`seen_achievement_ids` の削除（`:298`）のみが同型リスクへの対処として存在する"], evidence: ["prod `AppState.swift:297-298` の WHY コメントが「デバイストークンと同型のアカウント境界リスク」を認識しつつ音声キャッシュを対象に含めていない"]}
  gap: {kind: missing_behavior, element_ids: [ME33, ME61, ME62, ME64, ME65]}
  obligations: {applicability: required, rationale: "spec §6.3 が規定する API 自体が存在しない（contradiction）", confirmation_method: "", impact_if_unresolved: "", contract_obligation_ids: [OB-C8], test_obligation_ids: [OB-T8]}

- id: DP5
  requirement_ids: [R3]
  writer_access_path_id: AP7
  entry_point: "prod `Settings/SettingsViewModel.swift:184` `clearCache()`"
  destructive_input_or_sequence:
    - "Podcast タブで 2 件ダウンロード（`downloadedIds` = {A, B}）"
    - "設定タブでキャッシュ全削除（別インスタンスがディレクトリを空にする）"
    - "Podcast タブへ戻る（`loadPodcasts` を再実行しない = タブ切替では再ロードしない）"
  propagation:
    - "`downloadedIds` は {A, B} のまま → 一覧は「ダウンロード済み」バッジとオフライン再生可の表示を続ける（`Podcast/PodcastView.swift:91`, `Podcast/PodcastViewModel.swift:181-184`）"
    - "オフラインで A をタップ → `resolvePlaybackURL`（`:238-249`）はファイル不在を見て nil → `:265` \"Offline and not cached\""
  business_impact:
    - "「ダウンロード済み」と表示されたものが再生できない。しかも文言は英語で、原因（キャッシュが消えた）を説明しない"
    - "再ダウンロード導線も塞がれる: `download(podcast:)` の guard `:192` が `downloadedIds.contains` で即 return するため、`loadPodcasts` が走るまで再取得できない"
  expected_invariant: "ミラーは実体の部分集合である（ME17）"
  observed_result: {status: constructed, evidence: ["prod `Podcast/PodcastViewModel.swift:149,157,181-184,192,238-249`", "prod `Settings/SettingsViewModel.swift:184-191`", "test `PodcastViewModelTests.swift:424`（`testSyncDownloadedState`）は同期が起きた後だけを固定する"]}
  defense_assessment: {status: absent, mechanisms: [], evidence: ["2 インスタンス間に通知・共有 owner が無い（ME11）"]}
  gap: {kind: authority_conflict, element_ids: [ME3, ME11, ME17, ME59]}
  obligations: {applicability: required, rationale: "同一 fact に 2 つの source of truth", confirmation_method: "", impact_if_unresolved: "", contract_obligation_ids: [OB-C9], test_obligation_ids: [OB-T9]}

- id: DP6
  requirement_ids: [R10]
  writer_access_path_id: AP8
  entry_point: "prod `Models/Podcast.swift:121` `init(from:)`"
  destructive_input_or_sequence:
    - "backend が `{\"status\":\"processing\", \"audio_url\":\"\", \"error_message\":null, ...}` を返す（生成中エピソードの一覧掲載）"
    - "利用者がその行をタップ"
  propagation:
    - "decode は成功する（`:127` audio_url は空文字可、`:133` status は任意文字列）"
    - "再生経路は status を読まないため（ME76）ガードが無く、`resolvePlaybackURL`（`:243-246`）で `URL(string: \"\")` が nil"
    - "`:265` が \"Offline and not cached\" を表示する（オンラインであるにもかかわらず）"
  business_impact:
    - "原因と無関係な英語メッセージが出て、利用者は「オフラインだから」と誤認する"
    - "同じ原因（URL が使えない）に対し download 経路は別文言（`:201` \"Invalid audio URL\"）を返す＝一貫しない"
  expected_invariant: "再生可否は status・audio_url・キャッシュ・オンライン状態から単一の判断（ME8）として導かれ、失敗理由が原因ごとに区別される"
  observed_result: {status: constructed, evidence: ["prod `Models/Podcast.swift:127,133-134`", "prod `Podcast/PodcastViewModel.swift:238-249,265`"]}
  defense_assessment: {status: absent, mechanisms: ["`Podcast/PodcastRowView.swift:119-120` の statusBadge は表示のみで、タップの可否を制御しない"], evidence: ["prod `Podcast/PodcastRowView.swift:63,119-120`"]}
  gap: {kind: missing_concept, element_ids: [ME8, ME9, ME45, ME71, ME73]}
  obligations: {applicability: required, rationale: "再生可否概念と status 値域が未定義", confirmation_method: "", impact_if_unresolved: "", contract_obligation_ids: [OB-C10, OB-C11], test_obligation_ids: [OB-T10, OB-T11]}

- id: DP7
  requirement_ids: [R6]
  writer_access_path_id: AP8
  entry_point: "prod `Networking/AudioCacheManager.swift:52` `isCached(_:)` / `:45` `cachedURL(for:)`"
  destructive_input_or_sequence:
    - "backend が `id` に path 構成文字（`../` 等）を含む Podcast を返す（または将来 id 形式が変わる）"
    - "`resolvePlaybackURL`（prod `Podcast/PodcastViewModel.swift:238-249`）が `isCached` → `cachedURL` を検証なしで呼ぶ"
  propagation:
    - "`appendingPathComponent(\"\\(id).mp3\")`（`:46`）が cache ディレクトリ外の path を生成しうる"
    - "書込（`cache` `:63`）と削除（`remove` `:72`）は `validateId` で守られているため、影響は読取（存在判定・URL 生成）に限定される"
  business_impact:
    - "端末上の別 path を音声として AVPlayer に渡す（読取のみ。書込・削除には至らない）"
  expected_invariant: "id の安全形式検証が全 access path で一様に適用される（ME18）"
  observed_result: {status: partially_observed, evidence: ["prod `Networking/AudioCacheManager.swift:45-55`（検証なし）", "`:62-66`, `:71-76`（検証あり）", "test `AudioCacheManagerTests.swift:158,175,188,204` は書込経路のみを検証する"]}
  defense_assessment: {status: unknown, mechanisms: ["id の唯一の供給元は backend JSON（ME75）であり、backend 側の id 生成規則が実質的な防御になっている可能性がある"], evidence: ["本 review は backend を読んでいないため、id 形式の保証を確認できていない"]}
  gap: {kind: missing_constraint, element_ids: [ME18]}
  obligations: {applicability: required, rationale: "同一制約が writer 経路のみに適用され reader 経路に適用されていない（非対称）", confirmation_method: "backend の podcast id 生成規則（UUID 等）を確認し、client 側検証が防御の二重化か唯一の防御かを判定する", impact_if_unresolved: "severity の確定（major か minor か）ができない", contract_obligation_ids: [OB-C12], test_obligation_ids: [OB-T12]}
```

## 9. gap G*

```yaml
- {id: G1, requirement_ids: [R2, R3, R9], element_ids: [ME14, ME26, ME30, ME34, ME38], kind: invalid_state, severity: blocker,
   impact: "auto-advance の取得失敗で、キュー位置・再生セッション・player・UI 表示が 4 つの異なる真実を持つ（IV1）。回復操作が無く、15 秒 Timer が旧エピソードの位置を送り続ける。",
   evidence: [{status: confirmed, sources: ["DP1", "prod `Podcast/PodcastViewModel.swift:435-474`", "prod `Podcast/PodcastViewModel.swift:262-270`"]}],
   contract_obligation_ids: [OB-C1, OB-C2], test_obligation_ids: [OB-T1, OB-T2]}
- {id: G2, requirement_ids: [R2], element_ids: [ME6, ME7, ME15, ME21, ME39], kind: missing_concept, severity: major,
   impact: "再生セッションに排他状態が無く、error / paused / buffering / ended が atom の組合せに潰れる（IV2・IV3）。失敗後の再試行契約が無い。",
   evidence: [{status: confirmed, sources: ["DP2", "prod `Podcast/PodcastViewModel.swift:36-69,416-425,553-559`"]}],
   contract_obligation_ids: [OB-C3, OB-C4], test_obligation_ids: [OB-T3, OB-T4]}
- {id: G3, requirement_ids: [R2, R3], element_ids: [ME1, ME14, ME34, ME49], kind: authority_conflict, severity: major,
   impact: "「現在再生中」に 3 系統（VM / queue / AVPlayer）があり、片側だけを更新する公開経路が 2 本ある（`playById` `:381-388`・`removeFromQueue` `:543-545`）。View は AND 合成で症状を隠している（`Podcast/QueueSheet.swift:22`）。",
   evidence: [{status: confirmed, sources: ["IV4", "IV5", "OW2", "spec §2.1 不変条件 4"]}],
   contract_obligation_ids: [OB-C2], test_obligation_ids: [OB-T2, OB-T13]}
- {id: G4, requirement_ids: [R5], element_ids: [ME10, ME16, ME27, ME32, ME42], kind: missing_transition, severity: blocker,
   impact: "実行中 401 で未認証へ遷移する経路が存在せず、token nil × authenticated（IV6）と unauthenticated × currentUser 非 nil（IV7）を公開経路から構築できる。認可判定（isAdmin）が失効済みの旧利用者情報に基づく可能性がある。",
   evidence: [{status: confirmed, sources: ["DP3", "prod `Networking/APIClient.swift:536-546`", "prod `AppState.swift:151-157,98`", "prod `Settings/AccountSettingsView.swift:308`"]}],
   contract_obligation_ids: [OB-C5, OB-C6], test_obligation_ids: [OB-T5, OB-T6]}
- {id: G5, requirement_ids: [R5], element_ids: [ME43, ME53, ME60], kind: missing_failure, severity: major,
   impact: "通信失敗と失効を区別せず有効トークンを破棄する（IV8）。オフライン起動のたびに強制ログアウトされうる。",
   evidence: [{status: contradiction, sources: ["prod `AppState.swift:216-220`", "同関数 doc comment `:199-201` は通信失敗に言及しない", "test `AppStateAuthTests.swift:49` は未検証領域"]}],
   contract_obligation_ids: [OB-C7], test_obligation_ids: [OB-T7]}
- {id: G6, requirement_ids: [R6], element_ids: [ME28, ME33, ME61, ME62, ME64, ME65], kind: missing_behavior, severity: blocker,
   impact: "spec §6.3 が iOS の実装として名指しする `AudioCacheManager.removeAllDownloads()` が存在せず、logout がキャッシュ・NowPlaying・UserDefaults 主体依存値を消さない（IV9）。共有端末で前利用者の音声とロック画面情報が残る。",
   evidence: [{status: contradiction, sources: ["spec §6.3", "prod `Networking/AudioCacheManager.swift:27-118`", "prod `AppState.swift:282-302`", "DP4"]}],
   contract_obligation_ids: [OB-C8], test_obligation_ids: [OB-T8]}
- {id: G7, requirement_ids: [R3], element_ids: [ME3, ME11, ME17, ME52, ME57, ME59], kind: authority_conflict, severity: major,
   impact: "キャッシュ有無に `downloadedIds` とファイルシステムの 2 正本があり、`AudioCacheManager` 自体も 2 インスタンス。表示と実行が別根拠で判断し、全削除後に「ダウンロード済みだが再生も再取得もできない」状態になる（IV10）。",
   evidence: [{status: confirmed, sources: ["DP5", "prod `Podcast/PodcastViewModel.swift:131,149,157,181-184,192`", "prod `Settings/SettingsViewModel.swift:69,76,184-191`"]}],
   contract_obligation_ids: [OB-C9], test_obligation_ids: [OB-T9]}
- {id: G8, requirement_ids: [R10], element_ids: [ME5, ME8, ME9, ME71, ME72, ME73, ME76], kind: missing_concept, severity: major,
   impact: "`status` が閉じた値集合として存在せず、status × audio_url × error_message の矛盾組合せを decode で構築できる（IV11）。再生可否判断が status を読まないため、生成中・失敗エピソードのタップが誤った失敗文言に合流する。",
   evidence: [{status: confirmed, sources: ["DP6", "prod `Models/Podcast.swift:69-73,121-141`", "prod `Podcast/PodcastRowView.swift:119-120`"]}],
   contract_obligation_ids: [OB-C10, OB-C11], test_obligation_ids: [OB-T10, OB-T11]}
- {id: G9, requirement_ids: [R2, R10], element_ids: [ME45, ME7], kind: missing_failure, severity: major,
   impact: "`audio_url` 欠損・不正がオフライン起因と同じ文言に合流し（`:265`）、download 経路だけ別文言（`:201`）を持つ。利用者も開発者も原因を切り分けられない。",
   evidence: [{status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:200-201,243-246,264-266`", "prod `Models/Podcast.swift:127`"]}],
   contract_obligation_ids: [OB-C11], test_obligation_ids: [OB-T11]}
- {id: G10, requirement_ids: [R6], element_ids: [ME18], kind: missing_constraint, severity: unknown,
   impact: "id の安全形式検証が書込経路（`:63`,`:72`）にのみあり、読取経路（`:45`,`:52`）に無い。severity は backend の id 生成規則を確認するまで確定しない（DP7 の confirmation_method 参照）。",
   evidence: [{status: confirmed, sources: ["DP7", "prod `Networking/AudioCacheManager.swift:45-55,62-76,102-108`"]}],
   contract_obligation_ids: [OB-C12], test_obligation_ids: [OB-T12]}
- {id: G11, requirement_ids: [R3], element_ids: [ME2, ME37], kind: missing_relationship, severity: minor,
   impact: "既定再生速度（`AppState.swift:63-66`・永続）とセッション速度（`Podcast/PodcastViewModel.swift:50`・初期値 1.0 固定）が接続されていない。設定した既定速度が再生に一切反映されない。",
   evidence: [{status: confirmed, sources: ["prod `AppState.swift:63-66`", "prod `Podcast/PodcastViewModel.swift:50,262-300,575-579`"]}],
   contract_obligation_ids: [OB-C13], test_obligation_ids: [OB-T14]}
- {id: G12, requirement_ids: [R3], element_ids: [ME40, ME47], kind: missing_failure, severity: minor,
   impact: "位置同期の応答を破棄し（`:848`）失敗も握り潰す（`:849-851`）ため、spec §6.2 の server-wins をローカルへ取り込む契機が次回 `loadPodcasts` しか無く、失敗の可視化も無い。",
   evidence: [{status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift:843-852`", "spec §6.2", "verification-run.md §5（コメントのみ catch は production 全体でこの 1 件）"]}],
   contract_obligation_ids: [OB-C14], test_obligation_ids: [OB-T15]}
- {id: G13, requirement_ids: [R9], element_ids: [ME66, ME69], kind: missing_relationship, severity: minor,
   impact: "spec §2.7 が「複数選択はアダプタ責務・コア仕様外」と定めるのに、コアモデル `PlaybackQueue` が IndexSet 複数移動を実装している（`:131-142`）。操作名も spec（`moveUpNext`）と実装（`reorderUpNext`）で異なる。Q-01〜Q-32 は単一要素移動しか固定していない可能性がある（期待値突合は本 Function の scope 外）。",
   evidence: [{status: confirmed, sources: ["spec §2.7", "prod `Podcast/PlaybackQueue.swift:118-142`", "prod `Podcast/PodcastViewModel.swift:548-550`", "verification-run.md UV4（conformance 期待値と正本の突合は未実施）"]}],
   contract_obligation_ids: [OB-C15], test_obligation_ids: [OB-T16]}
- {id: G14, requirement_ids: [R5], element_ids: [ME25], kind: missing_concept, severity: minor,
   impact: "`onboardingCompleted == true` が「完了」「取得失敗」「保存失敗」の 3 意味を持つ（IV12）。fail-open の WHY は記されているが、失敗を区別しないため再試行も計測もできない。",
   evidence: [{status: confirmed, sources: ["prod `AppState.swift:88-93,305-315,318-325`"]}],
   contract_obligation_ids: [OB-C16], test_obligation_ids: [OB-T17]}
```

## 10. contract obligation（OB-C*）と test obligation（OB-T*）

契約条件の authoritative enforcement は Contract Function が canonical owner。ここでは「どの条件が必要か」までを obligation として渡し、条件式の確定は行わない。

```yaml
contract_obligations:
  - {id: OB-C1, requirement_ids: [R2], model_element_ids: [ME26, ME30, ME38], required_contract_kind: postcondition,
     statement: "auto-advance の 1 サイクル（advance + 次の再生開始）は原子的である。次エピソードの再生開始に失敗した場合、キュー位置と再生セッションのどちらか一方だけが変化した状態で終わらない。",
     evidence: {status: confirmed, sources: ["DP1", "G1"]}}
  - {id: OB-C2, requirement_ids: [R2, R3, R9], model_element_ids: [ME1, ME14, ME34], required_contract_kind: invariant,
     statement: "キュー再生中は `currentPodcast?.id == queue.current?.id` が全公開操作の前後で成立する。成立しない運用（`playById` のキュー外再生）を認めるなら、その状態を明示的な別概念として型に持つ。",
     evidence: {status: confirmed, sources: ["spec §2.1 不変条件 4", "IV4", "IV5"]}}
  - {id: OB-C3, requirement_ids: [R2], model_element_ids: [ME7, ME15, ME21], required_contract_kind: invariant,
     statement: "再生セッションの状態は排他であり、失敗状態は外部からの nil 代入で解除できない。失敗の解除は「再試行」または「別エピソードの再生」という意味のある操作を通る。",
     evidence: {status: confirmed, sources: ["DP2", "G2"]}}
  - {id: OB-C4, requirement_ids: [R2], model_element_ids: [ME13, ME39], required_contract_kind: failure_guarantee,
     statement: "`isPlaying == true` は再生可能な player と item の存在を含意する。`.failed` 検知後は player を解放するか、再試行可能な失敗状態へ遷移し、`isBuffering` を偽へ戻す。",
     evidence: {status: confirmed, sources: ["IV3", "prod `Podcast/PodcastViewModel.swift:416-425`"]}}
  - {id: OB-C5, requirement_ids: [R5], model_element_ids: [ME10, ME16], required_contract_kind: invariant,
     statement: "authStatus・currentUser・token は 1 つの認証状態として同時にのみ遷移する。`.authenticated` は非空トークンと利用者の両方を含意し、`.unauthenticated` は両方の不在を含意する。",
     evidence: {status: confirmed, sources: ["IV6", "IV7", "DP3"]}}
  - {id: OB-C6, requirement_ids: [R5], model_element_ids: [ME27, ME32, ME42], required_contract_kind: prohibited_transition,
     statement: "API 応答 401 を受けた後も `.authenticated` に留まることを禁じる。401 は単一の失効ハンドラを通って未認証へ遷移し、トークンを破棄する。",
     evidence: {status: confirmed, sources: ["DP3", "G4"]}}
  - {id: OB-C7, requirement_ids: [R5], model_element_ids: [ME43], required_contract_kind: failure_guarantee,
     statement: "起動時の認証再確認では、失効（401/403）でのみトークンを破棄し、通信失敗ではトークンを保持したまま判定を保留する。",
     evidence: {status: contradiction, sources: ["prod `AppState.swift:216-220`", "G5"]}}
  - {id: OB-C8, requirement_ids: [R6], model_element_ids: [ME33, ME61, ME62, ME64], required_contract_kind: postcondition,
     statement: "logout 完了後、前利用者に帰属する端末データ（音声キャッシュ全体・NowPlaying 情報・主体依存の UserDefaults 値）が残らない。削除は best-effort で、失敗しても未認証への UI 遷移は即時に行う（spec §6.3）。消去対象の集合を明示的に列挙する。",
     evidence: {status: contradiction, sources: ["spec §6.3", "DP4", "G6"]}}
  - {id: OB-C9, requirement_ids: [R3], model_element_ids: [ME3, ME11, ME17], required_contract_kind: invariant,
     statement: "キャッシュ有無の正本は 1 つ（ファイルシステム）であり、表示用ミラーは常にその部分集合である。キャッシュを変更する全経路は同一の owner を通り、ミラー保持者へ無効化が伝播する。",
     evidence: {status: confirmed, sources: ["DP5", "G7"]}}
  - {id: OB-C10, requirement_ids: [R10], model_element_ids: [ME5, ME9, ME71, ME73], required_contract_kind: precondition,
     statement: "`Podcast` の decode 時点で status を閉じた値集合として解釈し、status・audio_url・error_message の矛盾組合せを構築不能にする（または未知値を明示的に扱う既定を決める）。fail-open か fail-closed かは OW8 の unknown 解消後に確定する。",
     evidence: {status: inferred, sources: ["DP6", "G8", "OW8"]}}
  - {id: OB-C11, requirement_ids: [R2, R10], model_element_ids: [ME8, ME45], required_contract_kind: precondition,
     statement: "「今このエピソードを再生できるか」を単一の判断が所有し、再生不可の理由（生成未完了 / URL 欠損 / 未キャッシュかつオフライン）を区別して返す。表示層とオフライン判定は同じ判断を読む。",
     evidence: {status: confirmed, sources: ["DP6", "G8", "G9"]}}
  - {id: OB-C12, requirement_ids: [R6], model_element_ids: [ME18], required_contract_kind: precondition,
     statement: "Podcast ID の安全形式検証を読取経路（存在判定・URL 生成）にも適用し、全 access path で一様にする。",
     evidence: {status: confirmed, sources: ["DP7", "G10"]}}
  - {id: OB-C13, requirement_ids: [R3], model_element_ids: [ME2, ME37], required_contract_kind: postcondition,
     statement: "再生開始時、セッション速度は既定速度から初期化される。セッション速度の変更は既定速度を書き換えない。",
     evidence: {status: confirmed, sources: ["G11", "p4-common-brief §7（web で確定済みの 2 概念）"]}}
  - {id: OB-C14, requirement_ids: [R3], model_element_ids: [ME40, ME47], required_contract_kind: failure_guarantee,
     statement: "再生位置同期の失敗を状態として表現し（少なくとも最終同期時刻または失敗フラグ）、成功応答のサーバ値をローカルへ反映する契機を定義する（spec §6.2 server-wins）。",
     evidence: {status: confirmed, sources: ["G12", "spec §6.2"]}}
  - {id: OB-C15, requirement_ids: [R9], model_element_ids: [ME66, ME69], required_contract_kind: invariant,
     statement: "コアモデルが持つのは spec §2.7 の単一要素 `moveUpNext(from, toOffset)` 意味論であり、IndexSet 複数移動はアダプタ層の契約として別に明示する。名前差（`reorderUpNext` / `moveUpNext`）を契約表に記載する。",
     evidence: {status: confirmed, sources: ["spec §2.7", "G13"]}}
  - {id: OB-C16, requirement_ids: [R5], model_element_ids: [ME25], required_contract_kind: postcondition,
     statement: "オンボーディング状態は「完了」「未完了」「判定保留（取得失敗）」を区別する。fail-open で先へ進める運用は維持しつつ、失敗を状態として残す。",
     evidence: {status: confirmed, sources: ["G14"]}}

test_obligations:
  - {id: OB-T1, requirement_ids: [R2], model_element_ids: [ME26, ME38], contract_obligation_ids: [OB-C1],
     scenario: "キュー [A, B]、A 再生中、B 未キャッシュ、オフライン。A の終了通知で `handlePlaybackEnded(endedId: A.id)` を実行する。",
     required_oracle: "実行後、`queue.currentIndex` と `currentPodcast` が同じエピソードを指し、`isPlaying == false` であること。既存テストなし（最も近い test `PodcastViewModelTests.swift:87`・`:96`・`:162` はいずれも次の再生成功を前提にする）。",
     evidence: {status: confirmed, sources: ["DP1"]}}
  - {id: OB-T2, requirement_ids: [R2, R3], model_element_ids: [ME14], contract_obligation_ids: [OB-C2],
     scenario: "auto-advance 失敗後、`replayCurrentEpisode()` と `togglePlayPause()` を呼ぶ。",
     required_oracle: "どちらの操作も、キュー位置と再生セッションを再び一致させるか、一致しない状態を作らないこと。既存テストなし。",
     evidence: {status: confirmed, sources: ["DP1"]}}
  - {id: OB-T3, requirement_ids: [R2], model_element_ids: [ME15, ME39], contract_obligation_ids: [OB-C3],
     scenario: "`handlePlayerItemStatusChange(.failed, errorDescription: nil)` の後に、View 相当の経路で失敗表示を解除する。",
     required_oracle: "解除後も「失敗して停止している」ことが paused と区別して観測できること。既存テスト test `PodcastViewModelTests.swift:683,692,701` は errorMessage と isPlaying のみを固定し、解除後は未検証。",
     evidence: {status: confirmed, sources: ["DP2"]}}
  - {id: OB-T4, requirement_ids: [R2], model_element_ids: [ME13, ME21], contract_obligation_ids: [OB-C4],
     scenario: "`handleTimeControlStatusChange(.waitingToPlayAtSpecifiedRate)` の直後に `handlePlayerItemStatusChange(.failed, ...)` を実行する。",
     required_oracle: "`isBuffering` が偽へ戻ること。既存テスト test `PodcastViewModelTests.swift:710,719,729` は buffering の単独遷移と stopPlayback 経由のみを固定する。",
     evidence: {status: confirmed, sources: ["IV3"]}}
  - {id: OB-T5, requirement_ids: [R5], model_element_ids: [ME16], contract_obligation_ids: [OB-C5],
     scenario: "`completeLogin` に空文字トークンの `LoginResponse` を渡す。",
     required_oracle: "`.authenticated` かつ token nil の状態が成立しないこと。既存テスト test `AppStateAuthTests.swift:17`（`testCompleteLoginStoresTokenAndUser`）は非空トークンのみ。",
     evidence: {status: confirmed, sources: ["IV6"]}}
  - {id: OB-T6, requirement_ids: [R5], model_element_ids: [ME27, ME42], contract_obligation_ids: [OB-C6],
     scenario: "認証済み状態で、任意の API（例: `fetchPodcasts`）が 401 を返すよう `URLSessionProtocol` double を構成して VM 操作を実行する。",
     required_oracle: "`authStatus` が `.unauthenticated` へ遷移しトークンが破棄されること。既存テストなし（`MockURLSession`（test `APIClientTests.swift:637`）は常に成功応答を返すため、まず失敗応答を返せる double が必要）。",
     evidence: {status: confirmed, sources: ["DP3", "p1-test-ci-sec.md §3"]}}
  - {id: OB-T7, requirement_ids: [R5], model_element_ids: [ME43], contract_obligation_ids: [OB-C7],
     scenario: "有効トークンを持つ状態で `fetchMe` が `URLError(.notConnectedToInternet)` を投げるよう double を構成し `refreshAuth()` を実行する。",
     required_oracle: "トークンが保持されること。既存テスト test `AppStateAuthTests.swift:49` はトークン無しの場合のみ。`MockURLSession` は URLError を再現できないため double の拡張が前提（R7 と連動）。",
     evidence: {status: confirmed, sources: ["G5", "p1-test-ci-sec.md §7"]}}
  - {id: OB-T8, requirement_ids: [R6], model_element_ids: [ME33, ME62], contract_obligation_ids: [OB-C8],
     scenario: "`MockFileManager`（test `AudioCacheManagerTests.swift:9`）で 2 件キャッシュ済みの状態を作り `AppState.logout()` を実行する。",
     required_oracle: "キャッシュディレクトリが空であること、および主体依存 UserDefaults 値が既定へ戻ること。既存テスト test `AppStateAuthTests.swift:34`（`testLogoutClearsTokenAndUser`）は token と user のみ。NowPlaying のクリアは実機/シミュレータ目視（verification-run.md UV3）へ回す。",
     evidence: {status: contradiction, sources: ["spec §6.3", "DP4"]}}
  - {id: OB-T9, requirement_ids: [R3], model_element_ids: [ME17, ME59], contract_obligation_ids: [OB-C9],
     scenario: "`downloadedIds` が非空の状態で、同じキャッシュディレクトリを別経路から全削除する。",
     required_oracle: "`downloadState(for:)` が `.notDownloaded` を返し、`download(podcast:)` の再取得 guard（`Podcast/PodcastViewModel.swift:192`）が塞がらないこと。既存テスト test `PodcastViewModelTests.swift:424`（`testSyncDownloadedState`）は同期後のみを固定する。",
     evidence: {status: confirmed, sources: ["DP5"]}}
  - {id: OB-T10, requirement_ids: [R10], model_element_ids: [ME71, ME73], contract_obligation_ids: [OB-C10],
     scenario: "`status: \"failed\"` かつ `error_message: null`、`status: \"completed\"` かつ `audio_url: \"\"`、未知 status 値の 3 JSON を decode する。",
     required_oracle: "各組合せに対して定義された扱い（拒否 / 既定値 / 明示的な未知扱い）になること。既存テスト test `ModelTests.swift:64`（`testPodcastDecodesStatusAndErrorMessage`）は整合する組合せのみ。",
     evidence: {status: confirmed, sources: ["DP6"]}}
  - {id: OB-T11, requirement_ids: [R2, R10], model_element_ids: [ME8, ME45], contract_obligation_ids: [OB-C11],
     scenario: "オンラインかつ未キャッシュで `audioUrl` が空文字のエピソードを `play(podcast:)` する。",
     required_oracle: "オフライン起因とは区別できる失敗が観測できること。既存テスト test `PodcastViewModelTests.swift:456`（`testPlayOfflineNoCachedSetsErrorMessage`）と `:483`（`testPlayOnlineNoCachedResolvesAudioURL`）はいずれも正常な URL を前提にする。",
     evidence: {status: confirmed, sources: ["DP6", "G9"]}}
  - {id: OB-T12, requirement_ids: [R6], model_element_ids: [ME18], contract_obligation_ids: [OB-C12],
     scenario: "`../` を含む id で `isCached(_:)` と `cachedURL(for:)` を呼ぶ。",
     required_oracle: "キャッシュディレクトリ外の path を生成しないこと。既存テスト test `AudioCacheManagerTests.swift:158,175,204` は `cache`/`remove`（書込）経路のみを検証し、test `:52`（`testCachedURLReturnsCorrectPath`）は正常 id のみ。",
     evidence: {status: confirmed, sources: ["DP7"]}}
  - {id: OB-T13, requirement_ids: [R3], model_element_ids: [ME14, ME34], contract_obligation_ids: [OB-C2],
     scenario: "`playById(_:)` でキュー外のエピソードを再生した直後に `addToQueue(_:)` と、終了通知による auto-advance を実行する。",
     required_oracle: "キュー外再生中であることが明示的に表現され、無関係なキュー先頭が自動再生されないこと。既存テストなし（`playById` を対象とするテストが test `PodcastViewModelTests.swift` に存在しない）。",
     evidence: {status: confirmed, sources: ["IV5"]}}
  - {id: OB-T14, requirement_ids: [R3], model_element_ids: [ME2, ME37], contract_obligation_ids: [OB-C13],
     scenario: "既定再生速度を 1.5 に設定した状態で `play(podcast:)` を実行する。",
     required_oracle: "セッション速度が 1.5 で開始されること。既存テスト test `PodcastViewModelTests.swift:292`・`:647` は `setSpeed` の反映のみを固定する。",
     evidence: {status: confirmed, sources: ["G11"]}}
  - {id: OB-T15, requirement_ids: [R3], model_element_ids: [ME40, ME47], contract_obligation_ids: [OB-C14],
     scenario: "`updatePlaybackPosition` が失敗する double で `flushPlaybackPosition()` を呼ぶ。",
     required_oracle: "失敗が観測可能な状態として残ること。既存テスト test `PodcastViewModelTests.swift:865`・`:890` は送信内容のみを固定し、失敗経路は未検証。",
     evidence: {status: confirmed, sources: ["G12"]}}
  - {id: OB-T16, requirement_ids: [R9], model_element_ids: [ME69], contract_obligation_ids: [OB-C15],
     scenario: "IndexSet 複数要素の `moveUpNext` と、spec §2.7 の単一要素アルゴリズム（前方移動・末尾移動を含む）を対照する。",
     required_oracle: "コア意味論が spec §2.7 の 6 ステップと一致し、複数移動がアダプタ契約として別に固定されること。既存 conformance（test `PlaybackQueueConformanceTests.swift` Q-01〜Q-32・V1 green）の期待値と正本の突合は verification-run.md UV4 として未実施のまま。",
     evidence: {status: confirmed, sources: ["spec §2.7", "G13", "verification-run.md §10"]}}
  - {id: OB-T17, requirement_ids: [R5], model_element_ids: [ME25], contract_obligation_ids: [OB-C16],
     scenario: "`fetchOnboardingStatus` が失敗する double で `refreshOnboardingStatus()` を実行する。",
     required_oracle: "「完了」と「取得失敗による既定」が区別できること。既存テストなし（`AppState` のオンボーディング経路を対象とするテストが存在しない）。",
     evidence: {status: confirmed, sources: ["G14"]}}
```

## 11. Selection Gate（web 確定決定と iOS 挙動の差。finding ではなくクロスプラットフォーム決定として隔離）

```yaml
- id: SG1
  subject: "自動次再生の取得失敗時の挙動"
  candidate_ids:
    - "SG1-a: web 決定に合わせる（停止し、失敗したエピソードを current に保持して error 状態。手動 play で再試行）"
    - "SG1-b: iOS 現行を仕様化する（キューは前進し、`currentPodcast` は前のエピソードを保持、`isPlaying` は真のまま）"
    - "SG1-c: 第三案として前進を取り消す（advance をロールバックし前エピソードで停止）"
  decision_condition: "共有仕様 §2 に auto-advance 失敗時の状態を追記できるか、および iOS で「失敗したエピソードを current に保持する」ことが `currentPodcast` の 3 系統問題（SG2）と両立するか"
  evidence_required: ["spec §2 への追記可否", "web 実装の該当挙動の確認"]
  evidence_acquisition: "router が web 側 package の該当決定と spec 改訂手続き（spec §5「本書を単一の更新点として先に行う」）を突合する"
  owner: user
  status: pending
  evidence: [{status: confirmed, sources: ["p4-common-brief §7（自動次再生の取得失敗は停止）", "DP1", "IV1"]}]
- id: SG2
  subject: "「現在再生中」の正本を iOS でも `queue.currentIndex` にするか"
  candidate_ids:
    - "SG2-a: spec §2.1 不変条件 4 に合わせ `currentPodcast` を派生値にする（`playById` はキュー開始として再定義）"
    - "SG2-b: iOS は VM 側を正本とし、キューを従属モデルとして仕様に例外を書く"
  decision_condition: "`playById`（通知ディープリンク）と `replayCurrentEpisode` をキュー操作として再定義できるか。ADR-045/ADR-053 の改訂が必要かどうか"
  evidence_required: ["spec §2.1 不変条件 4 の iOS 適用範囲", "通知ディープリンク要件（issue #80）の意図"]
  evidence_acquisition: "router が web package の同決定と ADR-045 を突合する"
  owner: user
  status: pending
  evidence: [{status: contradiction, sources: ["spec §2.1 不変条件 4", "prod `Podcast/PodcastViewModel.swift:42,381-388`", "OW2", "IV4", "IV5"]}]
- id: SG3
  subject: "再生速度 2 概念（既定 / セッション）の iOS 実装"
  candidate_ids:
    - "SG3-a: web 決定に合わせる（再生開始時にセッション速度を既定速度から初期化）"
    - "SG3-b: 現行維持（既定速度は設定画面とサーバ同期のみに使い、再生には反映しない）"
  decision_condition: "既定速度が再生に反映されないことが意図された仕様か、未接続の欠落か"
  evidence_required: ["`AppState.defaultPlaybackSpeed` 導入時の要件（ADR-022 / issue #164 周辺）"]
  evidence_acquisition: "router が該当 ADR と web package の決定を突合する"
  owner: user
  status: pending
  evidence: [{status: confirmed, sources: ["p4-common-brief §7（再生速度は 2 概念）", "G11"]}]
- id: SG4
  subject: "logout 時に消す主体データの範囲と、spec §6.3 の記述と実装の矛盾の解消方向"
  candidate_ids:
    - "SG4-a: spec に合わせて `AudioCacheManager.removeAllDownloads()` を新設し logout から呼ぶ（消去対象＝キャッシュ全体）"
    - "SG4-b: 消去対象をキャッシュ＋NowPlaying＋主体依存 UserDefaults へ拡張し spec §6.3 の iOS 欄を改訂する"
    - "SG4-c: spec §6.3 の iOS 欄を実装に合わせて撤回する（＝残留を許容する）"
  decision_condition: "共有端末利用を想定するか（想定するなら SG4-c は選べない）。spec §6.3 は既に想定すると明記している"
  evidence_required: ["共有端末要件の確定", "spec §6.3 の decision_maturity（approved か proposed か）"]
  evidence_acquisition: "router が spec §6.3 の制定経緯（ADR-027 / ADR-063）と web 側の実装状況を突合する"
  owner: user
  status: pending
  evidence: [{status: contradiction, sources: ["spec §6.3", "prod `Networking/AudioCacheManager.swift:27-118`", "prod `AppState.swift:282-302`", "DP4"]}]
- id: SG5
  subject: "`PlaybackQueue` が IndexSet 複数移動を持つこと（spec §2.7 はアダプタ責務と規定）"
  candidate_ids:
    - "SG5-a: コアは単一要素のみとし、IndexSet 展開を VM（アダプタ）へ移す"
    - "SG5-b: iOS コアの複数移動を spec §2.7 の iOS 欄として明文化する"
  decision_condition: "web 実装が複数移動を持たないか、および conformance テスト表（Q-01〜Q-32）を分割する必要があるか"
  evidence_required: ["web の reorderUpNext 実装範囲", "Q-01〜Q-32 の期待値（verification-run.md UV4 が未実施）"]
  evidence_acquisition: "router が web package と conformance 期待値突合の結果を待つ"
  owner: user
  status: pending
  evidence: [{status: confirmed, sources: ["spec §2.7", "G13"]}]
```

## 12. existing downstream links / unknowns

```yaml
existing_downstream_links:
  note: "入力に Contract Package / Boundary Package は含まれていないため、実在 contract ID・boundary ID への link は作らない。既存の検証成果物のみを記録する。"
  - {kind: conformance_test_suite, id_or_path: "test `PlaybackQueueConformanceTests.swift`（testQ01〜testQ32）", covers_model_element_ids: [ME12, ME19, ME67, ME68], status: "存在 32/32・V1 green。ただし期待値と spec §4 の突合は未実施（verification-run.md UV4）"}
  - {kind: unit_test_suite, id_or_path: "test `PodcastViewModelTests.swift`（68 件）", covers_model_element_ids: [ME20, ME23, ME24, ME46, ME48, ME41], status: "stale ガード・presentation・末尾ウィンドウ・完聴 best-effort は固定済み"}
  - {kind: unit_test_suite, id_or_path: "test `AppStateAuthTests.swift`（8 件）", covers_model_element_ids: [ME22, ME53], status: "login/logout/token 無しのみ。失効・通信失敗・キャッシュ消去は未検証"}
  - {kind: unit_test_suite, id_or_path: "test `AudioCacheManagerTests.swift`（13 件）", covers_model_element_ids: [ME18, ME44], status: "書込経路の id 検証のみ。読取経路は未検証"}

unknowns:
  - {id: U1, subject: "backend の podcast id 生成規則（ME18 / G10 の severity 確定に必要）", confirmation_method: "backend の Podcast モデル定義と id 採番コードを読む（本 review は iOS のみが scope）", impact_if_unresolved: "OB-C12 が防御の二重化なのか唯一の防御なのかを決められず、G10 の severity が unknown のまま", owner: router, evidence: [{status: unknown, sources: ["prod `Models/Podcast.swift:122`（id は backend JSON 由来という事実のみ確認）"]}]}
  - {id: U2, subject: "未知 status 値の扱い（fail-open か fail-closed か）", confirmation_method: "ADR-021 と backend の status 値集合を確認する", impact_if_unresolved: "OB-C10 の契約方向が定まらず、G8 の解消案を一つに絞れない", owner: user, evidence: [{status: inferred, sources: ["prod `Models/Podcast.swift:69-71`（enum 変換は ADR-021 / iOS#15 へ先送りと明記）", "OW8"]}]}
  - {id: U3, subject: "Q-01〜Q-32 の期待値が spec §4 の正本値と一致するか", confirmation_method: "verification-run.md UV4（Contract Function が読解予定）", impact_if_unresolved: "ME19 / ME68 を present と判定した根拠が「テストの存在と green」に留まり、正本適合の証拠にならない", owner: router, evidence: [{status: unknown, sources: ["verification-run.md §10 UV4"]}]}
  - {id: U4, subject: "`AudioPlayerView.swift:303-606` の内部状態が再生セッションの意味を再解釈していないか", confirmation_method: "同ファイルの `@State` 書込点の網羅読み（trial-log で XCTest による `@State` 観測は棄却済みのため、読解のみで判断する）", impact_if_unresolved: "ME21 / ME56 の reader 在庫に漏れが残る可能性がある", owner: router, evidence: [{status: unknown, sources: ["p1-domain.md §6 未確認 3"]}]}

requirement_candidates:
  - {id: R10, note: "§2 に記載。router が採否を決める。不採用なら coverage 分母を 60 cell（5 requirement × 12）へ、applicable を 57、present を 13 へ読み替える。"}
```

## 13. coverage / verdict / decision

```yaml
coverage:
  audit_screen_denominator: 72          # in-scope requirement 6 × suite-defined 12 dimension
  audit_screen_resolved_numerator: 72   # 全 cell が Evidence 付き element link か DAP1-3 の根拠付き N/A profile のどちらか一方を持つ
  applicable_model_denominator: 68      # N/A 4 cell（DAP1: R6 time / DAP2: R9 failure,time / DAP3: R10 transition）を除く
  present_model_numerator: 15           # target_status: present かつ Evidence が unknown/contradiction でない element へ接続した cell
  uncovered_cell_ids:                   # present に数えなかった 53 cell の内訳（dimension 単位）
    missing: 31    # R2: concept,constraint,state,transition,relationship,failure / R3: constraint,transition,relationship / R5: concept,constraint,transition,behavior,relationship,failure,time / R6: term_context,constraint,behavior,relationship,failure / R9: relationship / R10: term_context,concept,constraint,state,relationship,failure,time ほか
    conflicting: 20 # R2: term_context,behavior,writer,reader,authority / R3: term_context,concept,behavior,failure,time,writer,reader,authority / R5: term_context,writer,authority / R6: transition,authority / R9: term_context,behavior
    unknown_or_contradiction_evidence: 2 # R6 authority(OW6・contradiction) と R10 authority(OW8・inferred/unknown)
  note: "audit_screen_* は suite-defined rubric の screening 網羅であって対象 model の完全性ではない。applicable_model / present_model の 15/68 が対象 model の coverage を表す。"

subject_verdict: incomplete
subject_verdict_rationale: |
  判定に十分な Evidence（全対象ファイルの全文読了、spec §2/§6、V1 509/509 green）があり、missing・invalid construction・leakage・authority conflict を具体的な公開経路つきで特定できた。
  R9（PlaybackQueue）だけが 7/10 と高い coverage を持ち、他の 5 requirement は 1〜2 cell に留まる。
  blocker gap は G1（auto-advance 失敗の不正状態）・G4（実行中 401 の遷移欠落）・G6（logout の主体データ残留、spec との contradiction）の 3 件。

decision:
  status: pass
  artifact_readiness: ready
  engineering_status: not_started
  release_status: not_applicable
  decision_maturity:
    status: proposed
    owner: router
    scope: [S1, S2, S3, S4, S5]
    evidence_status: confirmed
    approval_evidence: []
    baseline_version: "HEAD c8c1ada"
    change_control: "本 package は read-only review の成果物であり、承認は router / user が行う"
  next_phase:
    name: "contract 抽出と修正計画（OB-C* / OB-T* の契約化）"
    status: blocked
    reasons:
      - "SG1・SG2・SG4 が pending であり、G1・G3・G6 の修正方向がクロスプラットフォーム決定に依存する"
      - "U2（未知 status の扱い）が未解決で OB-C10 の契約方向が定まらない"
      - "OB-T6・OB-T7 は `MockURLSession`（test `APIClientTests.swift:637`）が失敗応答・URLError を再現できないため、double の拡張が前提になる"
    human_approvals_required:
      - "SG1（auto-advance 失敗時の挙動）"
      - "SG2（現在再生中の正本）"
      - "SG4（logout 時の消去範囲と spec §6.3 矛盾の解消方向）"
  evidence:
    - {status: confirmed, sources: ["prod `Podcast/PodcastViewModel.swift`（854 行・全文）", "prod `Podcast/PlaybackQueue.swift`（143 行・全文）", "prod `AppState.swift`（366 行・全文）", "prod `Networking/AudioCacheManager.swift`（119 行・全文）", "prod `Networking/SessionStore.swift`（82 行・全文）", "prod `Models/Podcast.swift`（214 行・全文）", "spec §2.1-2.10 / §6.1-6.3", "verification-run.md V1（509/509 green・HEAD c8c1ada）"]}
  assumptions:
    - {statement: "R10 を in-scope requirement として数える", falsification: "router が S5 を R1 または R4 の一部として扱うと判断した場合", impact_if_false: "coverage 分母が 72→60、applicable が 68→57、present が 15→13 になる。gap G8/G9 の要件帰属が変わるだけで内容は変わらない"}
  unknowns: [U1, U2, U3, U4]
  contradictions:
    - {id: X1, subject: "spec §6.3 の iOS 欄が `AudioCacheManager.removeAllDownloads()` をビルトインかつ logout 時自動呼出と記すが、実装に該当 API も呼出も存在しない", sources: ["spec §6.3", "prod `Networking/AudioCacheManager.swift:27-118`", "prod `AppState.swift:282-302`"], isolated_to: "SG4"}
    - {id: X2, subject: "spec §2.1 不変条件 4 は `current` を `items[currentIndex]` と定めるが、iOS の主要 reader（prod `Podcast/PodcastView.swift:90`）は VM の `currentPodcast` を正本として読む", sources: ["spec §2.1", "prod `Podcast/PodcastView.swift:90`", "prod `Podcast/QueueSheet.swift:22`"], isolated_to: "SG2"}
    - {id: X3, subject: "spec §2.7 は複数選択移動をアダプタ責務・コア仕様外と定めるが、コアモデルが実装している", sources: ["spec §2.7", "prod `Podcast/PlaybackQueue.swift:131-142`"], isolated_to: "SG5"}
    - {id: X4, subject: "`refreshAuth` の doc comment は破棄条件を「未設定・トークン無し・失効」と記すが、実装は通信失敗でも破棄する", sources: ["prod `AppState.swift:199-201`", "prod `AppState.swift:216-220`"], isolated_to: "G5 / OB-C7"}
  failed_gates: []
  unexecuted_validation:
    - {id: UV-A, reason: "本 Function は read-only の意味監査であり、OB-T1〜OB-T17 は未実装の test obligation である（実行済みと表現しない）", required_runner: "xcodebuild test（DEVELOPER_DIR + UDID destination 指定）", planned_commands: ["OB-T* の実装後に既存 `-only-testing:NewsListenAppTests` 経路で実行"], owner: router, evidence: [{status: confirmed, sources: ["verification-run.md §1"]}]}
    - {id: UV-B, reason: "IV9 のうち NowPlaying 残留と auto-advance 失敗時の UI は XCTest で観測できず、実機/シミュレータ目視が必要", required_runner: "iOS Simulator 目視", planned_commands: [], owner: user, evidence: [{status: confirmed, sources: ["verification-run.md §10 UV3"]}]}
  platform_validation:
    required_platforms: [ios]
    executed: []
    unexecuted: []
    parity_result: not_applicable
    platform_specific_risks: []
    note: "本 module は iOS 単一 platform。Windows / Linux / macOS の parity 要件を持たないため not_applicable。"
  residual_risks:
    - "G1・G4・G6 は現行 HEAD で構築可能な不正状態であり、本 review では修正案を選ばない（手段の選択は SG1・SG4 と Contract Function が所有する）"
    - "`AudioPlayerView.swift`（606 行）の内部状態は未監査（U4）。ME21 / ME56 の reader 在庫に漏れが残りうる"
  human_approvals_required: ["SG1", "SG2", "SG3", "SG4", "SG5"]
```

