# news-listen-ios コード設計レビュー（mino 設計 Skill 群・review mode）

日付: 2026-09-16 ／ 対象: `ios/`（news-listen-ios submodule、HEAD `c8c1ada`。作業ツリーは `DesignSystem/DSFeedback.swift`・`NewsListenAppTests/LearningEngagementModelTests.swift` 変更中・`.takt/` 未追跡で dirty。レビューは HEAD の内容を対象とし dirty 差分には触れない）／ mode: review（read-only）
成果物種別: `reproducible_development_result.mode_artifact.kind = review_result`
決定の成熟度: **approved**（2026-09-16 §8 dig-me セッション Q1〜Q10 でユーザーが Selection Gate と着手順を確定）

> 読み方: §1〜§3 が Core（問題定義・前提・要件）、§4 が finding 一覧（優先品質順）、§5 が専門 Function package（lossless 付録）、§6 が追跡表と検証結果、§7 が canonical decision、§8 が人間判断。
> 外部知識源: `mcp__shelf__consult` は本セッションで接続失敗（timeout）のため未使用。設計原則の根拠は各 Skill の references と実コード、共有再生仕様のみ。
> 先行例: web モジュールの同日レビュー（`web/docs/research-reports/2026-09-16-code-design-review.md`）。R 番号と QL 番号は web と対応させているが、内容は iOS の実コードから独立に導出した。

---

## 0. Decision frame

```yaml
decision_frame:
  mode: review
  requested_outcome: Review Result（finding・Function package・traceability・subject verdict・canonical decision）
  decision_owner: user
  routing_origin: integrated
  mutation_authorized: false   # 本文書と付録の新規作成のみ。ソース・設定・git は不変
  in_scope: [NewsListenApp/NewsListenApp/**（Podcast/ Networking/ AppState.swift Settings/ Feed/ Starred/ Learning/ Admin/ Auth/ Passkey/ Sessions/ Onboarding/ Push/ Observability/ Models/ Utilities/ DesignSystem/）, NewsListenAppTests/, .github/workflows/ci.yml, Makefile, scripts/test.sh]
  out_of_scope: [backend 契約の妥当性, web / android, UI 意匠（15-frontend-design・ios-design-system）, 修正実装, NewsListenAppUITests の中身（テンプレートのみ）]
  reversibility: reversible
  public_contract_change_allowed: false   # backend API・共有再生仕様 §2 は不変
  destructive_change_allowed: false
  host_platform: macos
  target_platforms: [ios-simulator（Xcode 26.6 / iPhone 17）]
  decision_maturity: {status: proposed, owner: user, scope: [ios/], evidence_status: confirmed, approval_evidence: [], baseline_version: "", change_control: ""}
```

```yaml
method_provenance:
  source_derived_principles: [技術より先に actor/purpose/rule を確認, consumer が知る契約と内部技術の分離, code/test/scenario による検証]
  suite_operationalization: [canonical decision, Selection Gate, Requirement Catalog, 12 dimension screening, quality vocabulary]
  repository_policy: [agent-rules/11・12, ios/CLAUDE.md（TDD・Keychain・ログ禁止）, docs/design/shared-playback-spec.md の Q-*/RT-* 行 ID, ADR-053]
```

## 1. Problem Frame と前提監査（Core）

### 1.1 Problem Frame

```yaml
problem_frame:
  actor: ios モジュールを変更する開発者（人間・AI エージェント）
  context: SwiftUI + MVVM。AppState（認証・設定）と PodcastViewModel（一覧・DL・AVPlayer・キュー・NowPlaying・位置同期を 1 クラスで保持、854 行）を ContentView が所有し全タブで共有する
  desired_state: 再生・認証の変更が 1 owner の変更で済み、再生セッションの状態が排他的に読め、失敗の意味が VM/View に流れ、logout/失効時の主体データ消去が仕様どおりに保証される
  observed_barrier: 「現在再生中」が 3 系統（currentPodcast / queue.current / AVPlayer.currentItem）、既定速度とセッション速度が未接続、再生状態が 15 atom で error/paused/ended が判別不能、APIError.httpError(statusCode) の数値分岐が 10 箇所、logout が音声キャッシュを消さず共有仕様 §6.3 と矛盾、PodcastViewModel が 9 責務
  impact: 再生領域の変更ごとに 3 系統の同期を人手で保つ（playById / replay / remove で既に乖離が構築可能）、auto-advance 失敗が「停止でも次進行でもない中間状態」に落ちる、共有端末で前利用者の音声とロック画面情報が残る、単体テストは 509 件 green だが「何が再生中か」「失効時に何が消えるか」を検証する oracle が無い
problem_readiness: ready
```

技術語を除いても問題が説明できる（「今何を聴いているかの正本が複数」「止まった理由が区別できない」「ログアウトしても前の人の音声が残る」）。candidate_means（PodcastViewModel の分割・状態 enum 化・AudioCacheManager の共有・401 集中処理 等）は手段として §7 の Selection Gate に退避し、本レビューでは確定しない。

### 1.2 前提台帳

| ID | 前提 | Evidence | 反証条件 | 誤り時の影響 | status |
|---|---|---|---|---|---|
| P1 | 再生 ViewModel は 1 インスタンスを ContentView が所有し、全タブで共有する | `NewsListenAppApp.swift:104,117-122` | PodcastView 等が別インスタンスを生成 | R3 の「現在再生中」の系統数が増える | confirmed |
| P2 | `PlaybackQueue` は共有再生仕様 §2 に準拠し、conformance Q-01〜Q-32 が全 green | `NewsListenAppTests/PlaybackQueueConformanceTests.swift`（32 件）、V1 = 509/509 | いずれかの Q-* が red、または期待値が正本と異なる | R9 が finding に昇格 | confirmed（存在と green）／ inferred（期待値の正本一致は Contract package が読解） |
| P3 | セッショントークンは Keychain のみに保存され、ログ API へ出る経路は無い | `Networking/SessionStore.swift:27-82`、production の print/os_log/Logger 出現 0（verification-run §7） | UserDefaults 保存やログ出力の発見 | QL4 constraint 違反 | confirmed |
| P4 | logout は音声キャッシュを消さない。共有再生仕様 §6.3 の「iOS: `AudioCacheManager.removeAllDownloads()` を logout 時に自動呼び出し」に該当する API・呼出は存在しない | `AppState.swift:282-302`、`AudioCacheManager.swift` の公開 API（`clearCache:90` のみ。呼出は `SettingsViewModel.swift:186` のみ） | 別経路での消去の発見 | R6 の contradiction が解消 | confirmed（**仕様と実装の contradiction**） |
| P5 | 実行中の API 401 を検知してログアウト相当へ遷移する経路は無い | `APIClient.swift:534-546`（429 のみ意味化）、401 の扱いは `LoginViewModel.swift:59` と `AppState.swift:216-220`（起動時 refreshAuth の全例外）のみ | 共通ハンドラの発見 | R5 finding が誤り | confirmed |
| P6 | `AppState.defaultPlaybackSpeed`（設定・UserDefaults・サーバ同期）と `PodcastViewModel.playbackSpeed`（セッション）は接続されていない | `AppState.swift:63-64,233`、`PodcastViewModel.swift:50,576`、`playbackSpeed` の全参照に AppState 無し（p1-domain §1） | 接続コードの発見 | R3 の速度 fact が一意側に変わる | confirmed |
| P7 | テストの seam は URLSession 層で、VM テストは実 APIClient を通る（rule 11 :70-75 に良好） | `APIClient.swift:12-17,57,71`、構築点 10 ファイル（p1-test-ci-sec §3）、URLProtocol スタブ 0 | APIClient 丸ごと mock の発見 | R7 の評価が下がる | confirmed |
| P8 | CI は `xcodebuild test` と gitleaks のみで、lint・独立 build・UI テスト・カバレッジは無い | `.github/workflows/ci.yml:16-64` | 別 workflow の発見 | R8 finding 撤回 | confirmed |
| P9 | `BACKEND` 側の月次 quota・admin 認可・パスワード検証値は本レビューで確認しない | out_of_scope | — | R1 のパスワード規則統一値が確定しない（unknown U1） | assumption |

### 1.3 因果鎖（既存負債）

```yaml
causal_chain:
  applicability: required
  reason: 新規能力ではなく既存構造の負債
  symptom: 「現在再生中」3 系統の手動同期、error/paused/ended の判別不能、status 数値分岐の散在、logout 後のキャッシュ残留、VM 内の 9 責務
  violated_goal_or_quality: [QL1 modifiability, QL2 testability, QL3 fault tolerance, QL4 confidentiality]
  violated_rule_or_invariant: [R1, R2, R3, R4, R5, R6, R7, R8, R9]
  incorrect_owner_or_source: 再生セッションの状態 owner が VM の atom 群、キュー正本と VM の currentPodcast が別 owner、認可・パスワード規則の owner が View、キャッシュ有無の owner が VM ミラーとファイル実体の 2 つ
  structural_cause: Model 層（Models/・Podcast/PlaybackQueue）に「意味」の層（再生セッション状態機械・失敗の意味・主体境界の policy）が無く、ViewModel が transport（APIError.statusCode）・AVFoundation・UIKit・シングルトンを直接扱う。View も VM の @Published へ直接書き込める
```

## 2. Context Packet

```yaml
context_packet:
  actors: [開発者（人間/AI）, エンドユーザー（学習者・Listener）, 管理者]
  problem: 上記 Problem Frame
  purposes: [変更容易性, テスト容易性, 再生/認証の失敗経路での安全性, 共有端末での機密性]
  success_conditions: [finding が path:line 付き, 追跡表に分母/分子, 独立評価済み, decision schema 完全, web 決定との差分が SG として明示]
  context:
    time_or_state: [2026-09-16, HEAD c8c1ada（dirty 2 ファイル・.takt/ 未追跡）, Xcode 26.6, iOS 17 deployment target（trial-log transcript-sync-highlight）]
    business_background: [副業有償化は 2026-09-09 に見送り・news-listen は休止中（ユーザー memory）。本レビューは再開時の起点。利用者は本人＋少数の知人（web §8.1 Q1。iOS でも同じかは P7 で確認）]
    technical_background: [SwiftUI + MVVM, AppState/PodcastViewModel を ContentView が所有, APIClient は @MainActor で URLSessionProtocol 注入, Keychain セッショントークン + Bearer, AVPlayer + MPNowPlayingInfo + MPRemoteCommand, FileManager 音声キャッシュ, APNs Push]
  terminology:
    - {term: 再生キュー, meaning: spec §2.1 の QueueState（items + currentIndex）, alternative_meanings: [], evidence: [docs/design/shared-playback-spec.md §2, Podcast/PlaybackQueue.swift:14-19]}
    - {term: 現在再生中, meaning: queue.current（spec §2.1 不変条件 4）, alternative_meanings: [PodcastViewModel.currentPodcast, AVPlayer.currentItem], evidence: [Podcast/PodcastViewModel.swift:42,281, PlaybackQueue.swift:31-34, PodcastViewModel.swift:289-290]}
    - {term: 再生速度, meaning: 既定速度（AppState.defaultPlaybackSpeed・永続・サーバ同期）とセッション速度（PodcastViewModel.playbackSpeed・非永続）の 2 概念, alternative_meanings: [AVPlayer.rate], evidence: [AppState.swift:63-64, PodcastViewModel.swift:50,576]}
    - {term: 完了（completed）, meaning: 生成完了（Podcast.status == "completed"）, alternative_meanings: [完聴（markCompleted・didFinishCurrentEpisode）], evidence: [Models/Podcast.swift:70, PodcastViewModel.swift:65,462]}
    - {term: ダウンロード済み, meaning: cacheManager.isCached(id) が true（ファイル実体）, alternative_meanings: [downloadedIds に含まれる（VM ミラー）], evidence: [AudioCacheManager.swift:52, PodcastViewModel.swift:55,158]}
    - {term: 認証済み, meaning: /auth/me 成功で currentUser を伴う authStatus == .authenticated, alternative_meanings: [Keychain にトークンが存在する状態], evidence: [AppState.swift:196-222]}
    - {term: 失敗の意味, meaning: network / unauthorized / forbidden / not_found(subject) / conflict / rate_limited(retryAfter) / server, alternative_meanings: [APIError.httpError(statusCode) の数値], evidence: [Networking/APIClient.swift:20-40]}
  rules:
    - {id: R1, statement: 業務ルール（パスワード規則・404 の意味・admin 判定・quota 解釈・featured grouping・再開位置閾値）は Model/policy 層に単一所有, kind: policy, owner: user, evidence_status: inferred}
    - {id: R2, statement: 再生セッションの不正状態を公開経路から構築できない, kind: invariant, owner: user, evidence_status: inferred}
    - {id: R3, statement: 現在再生中 / 速度 / 位置 / キャッシュ有無 / ネットワーク状態 / 認証状態の source of truth が一意, kind: invariant, owner: user, evidence_status: inferred}
    - {id: R4, statement: 消費者は失敗の意味を受け取り transport 値（status 数値・英語 localizedDescription）に依存しない, kind: policy, owner: user, evidence_status: inferred}
    - {id: R5, statement: 実行中のセッション失効（401）で未認証へ遷移し、認可判定は単一 policy を通る, kind: prohibition, owner: user, evidence_status: inferred}
    - {id: R6, statement: logout・失効時に前利用者の主体データ（音声キャッシュ・NowPlaying・主体依存 UserDefaults）が端末に残らない, kind: prohibition, owner: user, evidence_status: confirmed（shared-playback-spec §6.3 「共有端末対応」・rule 12）}
    - {id: R7, statement: テストは production 経路を通り契約に対応付く, kind: policy, owner: user, evidence_status: confirmed（agent-rules/11 :70-75）}
    - {id: R8, statement: CI と make test が同一経路で lint / 独立 build / UI テストのゲート方針が明文化される, kind: policy, owner: user, evidence_status: inferred}
    - {id: R9, statement: PlaybackQueue は spec §2 不変条件 1〜5 と Q-01〜Q-32 を満たし、名前差（reorderUpNext vs moveUpNext、IndexSet 複数移動）は契約として明示される, kind: invariant, owner: user, evidence_status: confirmed（spec §5 準拠規約）}
  quality_lens:
    definitions:
      - {id: QL1, quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: maintainability, subcharacteristic: modifiability, standard_term: modifiability, display_name_ja: 変更容易性, source_terms_ja: [変更容易性]}, evidence: [ユーザー選択 2026-09-16（P0）]}
      - {id: QL2, quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: maintainability, subcharacteristic: testability, standard_term: testability, display_name_ja: テスト容易性, source_terms_ja: [テスト容易性]}, evidence: [ユーザー選択 2026-09-16（P0）]}
      - {id: QL3, quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: reliability, subcharacteristic: fault tolerance, standard_term: fault tolerance, display_name_ja: 障害許容性, source_terms_ja: [信頼性]}, evidence: [再生/認証/オフラインの失敗経路]}
      - {id: QL4, quality: {reference_model: "ISO/IEC 25010:2023", level: subcharacteristic, characteristic: security, subcharacteristic: confidentiality, standard_term: confidentiality, display_name_ja: 機密性, source_terms_ja: [セキュリティ]}, evidence: [agent-rules/12, ios/CLAUDE.md:12, shared-playback-spec §6.3]}
    primary_ids: [QL1, QL2]
    secondary_ids: [QL3]
    constraint_ids: [QL4]
    intentionally_not_optimized_ids: [performance（Explorer 報告に性能問題の Evidence なし）]
    tradeoff_decisions:
      - {id: TD1, statement: オフライン可用性（音声キャッシュ保持）と共有端末の機密性（logout 時消去）のトレードオフ。web では Q2「端末共有なし」で失効時は音声を残す判断, affected_quality_ids: [QL3, QL4], decision_maturity: {status: unknown, owner: user}, evidence: [shared-playback-spec §6.3, AppState.swift:282-302]}
      - {id: TD2, statement: best-effort（try? による黙殺）で再生継続を優先する耐障害性と、失敗の観測可能性のトレードオフ, affected_quality_ids: [QL3, QL2], decision_maturity: {status: unknown, owner: user}, evidence: [PodcastViewModel.swift:462,849-851, AppState.swift:292,294,312-314]}
  change_boundary:
    must_preserve: [spec Q-*/RT-* の観測挙動, Keychain によるトークン保管, X-API-Key/Bearer のヘッダ規約, backend API 契約]
    may_change: [Podcast/・Networking/・AppState の責務配置, ViewModel の分割, テスト戦略, CI ゲート, 文言の所在]
    must_not_change: [backend 契約, 共有再生仕様 §2 の意味論（変更は spec 先行・ADR）]
    out_of_scope: [web, android, 意匠]
  evidence:
    confirmed: [P1, P2（存在・green）, P3, P4, P5, P6, P7, P8, R6, R7, R9]
    inferred: [P2（期待値一致）, R1-R5, R8]
    assumptions: [P9]
    unknowns: [U1]   # §7 に canonical record
    contradictions: [C1: shared-playback-spec §6.3 の iOS logout 記述 vs 実装（P4）]
```

### 2.1 AI 復唱

```yaml
ai_restatement:
  statement: >
    ios モジュールの変更容易性・テスト容易性を主眼に、再生セッションの状態と正本、失敗の意味、認証・失効・logout の主体境界、
    共有再生仕様 §2 への準拠、テストの本番経路同一性を R1〜R9 の要件に正規化し、Architecture / Completeness / Contract / Boundary の
    4 Function で監査して finding と obligation を返す。修正手段は選択せず Selection Gate に隔離する。
    web で確定した 4 決定（正本 = Queue.currentIndex、速度 2 概念、auto-advance 失敗は停止、失効時の主体データ消去）と iOS の現状が
    異なる点は finding ではなく Selection Gate として P7 でユーザーに問う。
  comparison_basis: [指示書 prompt-ios.md, ランブック, AskUserQuestion 回答（ios/docs 配下・maintainability primary）, R1-R9, change_boundary]
  proposed_status: matched
  differences:
    - "§4 は primary=maintainability を宣言しつつ §4.1 に QL4 constraint 違反（R6 の contradiction）を先頭配置する。理由: constraint は must-hold で primary の最適化に先行するため"
    - "web の R5（admin gate の unknown 描画）は iOS では実行中 401 の未処理へ主題を移した。iOS の admin 出し分けは isAdmin 述語 1 箇所で backend が認可するため"
    - "R9（共有仕様 conformance）を追加した。web では P2 前提として扱ったが、iOS では reorderUpNext の名前差と IndexSet 複数移動という契約差分があるため要件化した"
  reviewed_by: {kind: independent_evaluator, identity: "adversarial-verifier (T5)", review_status: accepted, evidence: ["§7.1", "2026-09-16-code-design-review/t5-adversarial.md"]}   # scope・依頼一致は accepted。finding 個別の判定は §7.1
```

## 3. Requirement Catalog と rejection criteria

| ID | actor | trigger / context | expected_result | prohibited_results | 現行分類 | QL | acceptance（観測方法） |
|---|---|---|---|---|---|---|---|
| R1 | 開発者 | 業務ルール（パスワード最小長・404 の意味・admin 判定・quota 無制限解釈・featured grouping・再開位置閾値）を変更 | 1 箇所の Model/policy 変更で全 UI に反映 | 同一ルールの複数実装、View 内の業務判断 | intentional-change | QL1 | 同一ルールの実装箇所数 = 1（per-file 内訳） |
| R2 | Listener | 再生 error / ended / pause / auto-advance 失敗 / interruption | UI が状態を排他的に区別できる | error と paused の判別不能、advance 後の current 乖離、View から @Published 直接書込 | intentional-change | QL3/QL2 | 状態型が排他 union、不正状態を構築するテストが失敗する |
| R3 | 開発者 | 現在再生中 / 速度 / 位置 / キャッシュ有無 / ネットワーク / 認証状態を読む・書く | writer/reader が単一 owner を通る | 3 系統の手動同期、ミラーの失効、未接続の 2 正本 | intentional-change | QL1/QL3 | owner 表で writer が 1 |
| R4 | VM/View 実装者 | API 失敗を表示・分岐 | 失敗の意味（network / unauthorized / not_found(subject) / conflict / rate_limited / server）を受け取る | `httpError(statusCode)` の数値比較、英語 `localizedDescription` の露出 | intentional-change | QL1/QL3 | VM/View に status 数値比較が無い、文言が日本語 policy から出る |
| R5 | Account owner | 実行中に API が 401 を返す／admin 画面を開く | 未認証へ遷移しトークン破棄、認可は単一 policy | 401 が errorMessage だけで終わる、admin 判定の View 直書き | intentional-change | QL4 | 401 → authStatus 遷移のテスト |
| R6 | 共有端末の次利用者 | logout・失効後に端末を使う | 前利用者の音声キャッシュ・NowPlaying・主体依存 UserDefaults が無い | 音声ファイル残留、ロック画面に前利用者のエピソード | must-preserve（仕様）/ **contradictory**（実装が仕様に反し、テストは green） | QL4 | logout 後の cacheSize == 0、NowPlayingInfo == nil のテスト |
| R7 | 開発者 | テストを緑にする | production 経路（実 APIClient・実 decode・実 status 検証）を通り契約 CI* に対応付く | テスト 0 の VM、テンプレート空テスト、double が実物より寛容（URLError 非再現） | partial（seam は良好） | QL2 | contract coverage 分母/分子、テスト 0 の型の数 |
| R8 | 開発者 | PR を出す | CI と `make test` が同一経路、lint / build / UI テストの方針が明文 | 二重化した実行スクリプト、UI テストが常時未実行 | intentional-change | QL2 | ci.yml と scripts/test.sh の差分 0 または片方が他方を呼ぶ |
| R9 | 開発者 | PlaybackQueue を変更 | spec §2 不変条件 1〜5 と Q-01〜Q-32 が green、名前差・IndexSet 複数移動が契約に明記 | spec と実装の名前・責務の無記録な乖離 | must-preserve | QL1 | conformance 32/32 green、契約表に名前対応 |

```yaml
rejection_criteria:   # 本レビュー成果物自体の拒否条件（decision_maturity: proposed）
  - {id: RC1, requirement_ids: [R1-R9], condition: finding に path:line Evidence が無い／Explorer 報告の未確認転記, gate: verification}
  - {id: RC2, requirement_ids: [R2, R7], condition: trial-log 棄却済み案（@State の XCTest 観測・順序入替のみのレース解消・durationSeconds 前置ガード削除・green 未実測）を提案に含める, gate: core}
  - {id: RC3, requirement_ids: [], condition: subject_verdict と artifact_readiness の混同, gate: verification}
  - {id: RC4, requirement_ids: [R7, R9], condition: T*（既存テスト）の coverage 分母・分子を数えていない, gate: contract}
  - {id: RC5, requirement_ids: [], condition: AI 復唱 matched を自己証明にする（独立評価未実施）, gate: core}
  - {id: RC6, requirement_ids: [R1-R3], condition: pattern 名・class 数を根拠にする／将来用抽象を推奨, gate: boundary}
  - {id: RC7, requirement_ids: [], condition: スコープ外（backend 契約・意匠・web/android）を finding にする、または web 決定との差分を SG ではなく finding にする, gate: core}
```

---
## 4. Findings（優先品質順。severity は proposed、§7.1 の独立評価で確定）

凡例: gate = core/requirements/architecture/completeness/contract/boundary/verification、参照 ID は §5 の各 package 内で解決する（F-A*=Architecture finding、SG-A*=Architecture の Selection Gate、G*/IV*/OB-C*/OB-T*/SG1〜5=Completeness、CI-*=Contract item、LF*/CS*/RO*=Boundary）。
実測値の出典は `2026-09-16-code-design-review/verification-run.md`。行番号は HEAD `c8c1ada`。**web 決定との差分（正本・速度・失敗方針・失効時消去）は finding ではなく §7 の Selection Gate に置き、ここでは iOS 単独で成立する欠陥だけを finding にする。**

### 4.1 Constraint（QL4 confidentiality）違反と仕様矛盾

| ID | severity | gate | finding | Evidence（path:line） | 違反 R | 参照 | required_action（obligation。手段選択は SG） |
|---|---|---|---|---|---|---|---|
| RF1 | major（初版 blocker。§8 Q1 で降格: 現状は端末共有なし。契約は維持） | completeness/contract/architecture | 共有再生仕様 §6.3 は「iOS: `AudioCacheManager.removeAllDownloads()`（ビルトイン。logout 時に自動呼び出し）」と記すが、該当 API は存在せず（公開 API は `cachedURL/isCached/cache/remove/cacheSize/clearCache` の 6 つ）、`logout()` は音声キャッシュ・`MPNowPlayingInfoCenter` の情報・再生セッションを消さない。消すのはトークン・currentUser・実績既読 ID のみ。logout で `ContentView` が破棄され `PodcastViewModel` は deinit するが、deinit は observer 解除のみで NowPlaying をクリアしない。既存テスト（`AppStateAuthTests.swift:34,87`）は token/currentUser のみ検証し green | `docs/design/shared-playback-spec.md:312`, `AppState.swift:282-302`, `Networking/AudioCacheManager.swift:45,52,62,71,80,90`, `Podcast/PodcastViewModel.swift:796-810`（deinit）, `:611,733`（NowPlaying 更新点）, `NewsListenAppApp.swift:65-70`（ContentView は authenticated 時のみ） | R6 | F-A2, G6, IV9, CI-C05, CI-S05, LF8, CS11, OB-C8, OB-T8, SG-A5 / SG4, D4, X1 | logout（と失効）の事後条件として「主体データが残らない」を契約化（OB-C8）。消去範囲（キャッシュ全体 / NowPlaying / 主体依存 UserDefaults / 再生セッション）は SG-A5。仕様 §6.3 の iOS 欄は決定後に実態へ改訂（OB-A6） |
| RF2 | **major** | completeness/contract | 実行中の API 401（セッション失効）を未認証へ遷移させる経路が無い。`validateResponse` は 429 のみ意味化し、401 は `httpError(401)` として各 VM の `catch` で `errorMessage` になるだけ。トークン破棄は起動時 `refreshAuth()` と明示 logout の 2 経路のみ。結果、`authStatus == .authenticated` ∧ token 失効の状態が続き、`isAdmin` 判定（`AuthModels.swift:24`）は失効済みの旧 `currentUser` に基づく | `Networking/APIClient.swift:534-546`, `AppState.swift:196-222`, `:282-302`, 401 の扱い全出現 `Auth/LoginViewModel.swift:59` のみ | R5 | G4, IV6, IV7, OB-C5, OB-C6, OB-T5, OB-T6 | 401 を「セッション失効」の意味として 1 箇所で受け、`authStatus` 遷移＋主体データ消去（RF1 と同一経路）を契約化。手段（APIClient のフック / AppState の監視）は SG |
| RF3 | major | completeness/contract | `refreshAuth()` の `catch` が通信断・5xx・decode 失敗を含む**全例外**で有効トークンを破棄し未認証化する。doc comment（`:200`）は「未設定・トークン無し・失効」のみを挙げ、通信失敗に言及しない（コメントと実装の contradiction）。オフライン起動のたびに再ログインを要求しうる。既存テスト `AppStateAuthTests.swift:49` は前提不成立経路のみ | `AppState.swift:200,216-220`, `NewsListenAppTests/AppStateAuthTests.swift:49` | R5, R4 | G5, IV8, CI-S03, OB-C7, OB-T7, X4, SG-C5 | 失敗を unauthorized / unavailable に分類し、前者のみ破棄する契約（CI-S03）。`MockURLSession`（`APIClientTests.swift:637-659`）が URLError を再現できないため double 拡張が前提（RF12） |
| RF4 | minor（severity は backend の id 生成規則に依存 = unknown U1） | contract | `AudioCacheManager` の id 安全形式検証（`validateId`）が書込経路（`cache:62`, `remove:71`）にのみあり、読取経路（`cachedURL:45`, `isCached:52`）に無い。id が backend 由来の UUID なら実害なし | `Networking/AudioCacheManager.swift:45-55,62-76,102-108` | R6 | G10, CI-C01, OB-C12, U1 | backend の id 規則を確認（U1）。任意文字列なら読取側にも検証 |

### 4.2 Primary（QL1 modifiability / QL2 testability）

| ID | severity | gate | finding | Evidence | 違反 R | 参照 | required_action |
|---|---|---|---|---|---|---|---|
| RF5 | major | architecture/completeness | 「現在再生中」の source of truth が 3 系統: (A) `PodcastViewModel.currentPodcast`（`PodcastViewModel` 内の writer は `:281` のみ。DEBUG の `PreviewSupport.swift:153,165` は RF13）、(B) `queue.current`（`PlaybackQueue.currentIndex`）、(C) `AVPlayer.currentItem`。A↔B の同期は `playNow:516-522` と `handlePlaybackEnded:441-442` の 2 経路だけで、`playById:381-388`（通知ディープリンク経由）は B に触れず、`replayCurrentEpisode:481-487` は B 不変、`removeFromQueue:543-545` で再生中を消すと B だけ次要素へ進む。`addToQueue/playNext` の「何も再生していない」判定は B ではなく A（`:526,535`）。`QueueSheet.swift:22` は `currentPodcast != nil && queue.current` の AND で不一致を UI 側で吸収。spec §2.1 不変条件 4 は current を `items[currentIndex]` と定義 | `Podcast/PodcastViewModel.swift:42,281,381-388,481-487,516-540,543-545`, `Podcast/PlaybackQueue.swift:31-34`, `Podcast/QueueSheet.swift:22`, `Podcast/PodcastView.swift:90`, `docs/design/shared-playback-spec.md:53` | R3, R2 | F-A1, G3, IV4, IV5, CI-P05, CI-P08, CI-P17, LF3, LF4, CS10, OB-C2, OB-T2, OB-T13, SG-A1 / SG2, D1, X2 | 正本を 1 つ選ぶ（SG-A1。web は Queue.currentIndex を選択済み）。`playById` をキュー操作として再定義するか（U-A3）は user 判断 |
| RF6 | major | completeness/contract | 再生セッションに排他的な状態型が無く 15 個の `@Published` atom（うち 9 個が `var` で外部書込可）。`.failed`（`:416-420`）は `errorMessage` と `isPlaying=false` のみで `player` を解放せず `isBuffering` も戻さない → error / paused / buffering が同じ atom 組合せに潰れる（IV2, IV3）。ended は「`isPlaying=false` ∧ `didFinishCurrentEpisode`」の合成でしか読めない。View が `errorMessage = nil` を直接代入（`PodcastView.swift:45,135`）。失敗後の再試行契約が無い | `Podcast/PodcastViewModel.swift:36-69,416-425,553-561`, `Podcast/PodcastView.swift:45,135` | R2 | F-A3, G2, IV2, IV3, CI-P03, CI-P19, LF2, OB-C3, OB-C4, OB-T3, OB-T4, SG-A9, SG-C3 | 排他 union（idle/loading/playing/paused/buffering/ended/error(reason)）と遷移表を契約化し、atom を派生値に。`seek` の clamp 有無（CI-P19）も契約に含める |
| RF7 | major（QL3 兼） | completeness/contract | auto-advance の再生失敗が「停止でも次進行でもない中間状態」に落ちる: `handlePlaybackEnded` が `queue.advance()`（`:441`）で index を進めた後 `play()` がオフライン未キャッシュで早期 return（`:264-267`）すると、`currentIndex` は次、`currentPodcast` は前、`isPlaying` は真のまま、15 秒 Timer は前エピソードの位置を送り続ける。回復操作は「もう一度聴く」（前エピソード再生）のみ。trial-log player-auto-converge.md:63 が「既存構造・followup 候補」として記録済みの穴 | `Podcast/PodcastViewModel.swift:435-465,262-270,816-826`, `ios/docs/trial-log/player-auto-converge.md:63` | R2, R3 | G1, IV1, CI-P13, OB-C1, OB-T1, SG-A3 / SG1, D3 | 失敗時の収束先（停止して失敗エピソードを current に保持 ＝ web 決定 / advance のロールバック / スキップ）を SG で決めて契約化 |
| RF8 | major（QL3 兼） | contract/verification | **再生直前の署名 URL 再取得が実装されていない**。ADR-009・設計書 §8 手順 3・`play()` の doc comment（`:254`）は「オンライン+未キャッシュなら `GET /podcasts/{id}` で再取得」と定めるが、`play()` は `resolvePlaybackURL` が返す一覧保持の `podcast.audioUrl` を直接 `AVPlayerItem` に渡す（`fetchPodcast` の呼出は `downloadAudio:199` と `playById:383` のみ）。署名 URL は 1 時間で失効するため、一覧取得から時間が経った再生は失敗する。既存テスト `PodcastViewModelTests.swift:483`（`testPlayOnlineNoCachedResolvesAudioURL`）の assert は `:507` の `currentPodcast?.id == "p1"` 1 本だけで、再取得の有無を観測しない＝**契約を検証しない非識別テスト**（独立評価 N7 で「違反側を pin」から訂正。ADR-009 準拠に変えても green のまま） | `Podcast/PodcastViewModel.swift:238-249,254,262-290`, `:199,383`, `docs/adr/009-*.md:22`, `docs/design/ios-design.md:374`, `NewsListenAppTests/PodcastViewModelTests.swift:483` | R2, R7 | CI-P04（unmet。test は非識別）, SG-C4, OB-N5, spec §6.1 | ADR-009 の契約（再生直前の再取得、失敗時の fallback）を CI として確定し、`:483` のテストに再取得の観測（`fetchPodcast` 呼出）を追加する。実装差か ADR の撤回かは user 判断（ADR 改訂を伴う） |
| RF9 | major | boundary/requirements | 業務ルールの owner が View / 複数 VM に散在: (a) パスワード最小長 8 が `AccountSettingsView.swift:317`（View）と `AdminUsersViewModel.swift:47` の 2 実装（文言別・生リテラル）; (b) `AccountSettingsView.swift:305-333` が View 内で `appState.apiClient` を直接叩き `appState.currentUser = updated`（`:308`）を代入; (c) `QuizSheetView.swift:180-204` の採点送信・50% 閾値・404 解釈が View; (d) `SettingsView.swift:296` `quota.limit == 0`＝無制限の解釈（Model コメント `GenerationQuota.swift:17-18` と二重）; (e) featured grouping＋空カテゴリ除外が `SettingsViewModel.swift:47-53` と `OnboardingSourcesViewModel.swift:30-36` で逐語重複; (f) admin ロール文字列 `"admin"/"user"` が **3 ファイル 7 出現**（`AuthModels.swift:15,24`、`AdminUsersView.swift:31,32`、`AdminUsersViewModel.swift:23,61,84`。独立評価 N5 で 4→3 に訂正。述語 `isAdmin` 自体は 1 箇所）。(a) は `AdminUsersView.swift:28` の UI 文言「8文字以上」を含めると実質 3 箇所 | 上記各 path:line、`Models/AuthModels.swift:24`, `Admin/AdminUsersViewModel.swift:23,84`, `Admin/AdminUsersView.swift:32` | R1 | LF9, LF12, CS4, CS7, D4/D5（Boundary §8）, SG-B2, OB-A2, OB-B3 | 各ルールの owner を Model/policy に一意化。パスワード規則は web SG7 で 8〜20 文字と決定済み → iOS も同値にするかは P7 で確認 |
| RF10 | major | boundary/contract | API 失敗の意味が transport 値のまま消費者に渡る: `APIError.httpError(statusCode)` の数値比較が **10 箇所 / 10 ファイル**（404 ×6 で意味は「機能未提供」3 と「冪等削除成功」3 の 2 種、409 ×2、401 ×1、400 ×1 が View 内）。`APIError.errorDescription` は 429 以外が英語（"Invalid URL" / "HTTP Error N" / "Decoding error"、`APIClient.swift:33-36`）で、VM 側の英語リテラル（`PodcastViewModel.swift:265` "Offline and not cached"、`:418` "Playback failed"）と共に `localizedDescription` 経由でそのままアラートへ（`PodcastView.swift:44` 等）。`audio_url` 欠損とオフラインが同じ文言に合流（`:265`） | `Networking/APIClient.swift:20-40`, 分岐 10 箇所（`AppState.swift:263` / `Settings/SettingsViewModel.swift:163` / `Settings/AccountSettingsView.swift:327` / `Passkey/PasskeyCredentialsViewModel.swift:52` / `Auth/LoginViewModel.swift:59` / `Passkey/PasskeyRegistrationViewModel.swift:70` / `Starred/StarredViewModel.swift:108` / `Sessions/SessionsViewModel.swift:57` / `Podcast/QuizSheetView.swift:199` / `Onboarding/OnboardingSourcesViewModel.swift:66`。独立評価で一致）、文言露出 `Podcast/PodcastViewModel.swift:151,201,211,222,265,386,418,624` | R4 | CI-P03, CI-P09, G9, OB-C11, LF5, LF6, LF12, LF15, CS5, RO5, SG-B1, OB-N2 | 失敗を意味（network / unauthorized / forbidden / not_found(subject) / conflict / rate_limited / server）の判別共用体へ変換する層を Networking に置き、日本語文言の owner を 1 箇所に |
| RF11 | major | architecture/completeness | キャッシュ有無の正本が 2 つ（`downloadedIds` ミラー vs ファイル実体）で、`AudioCacheManager` 自体も 2 インスタンス（`PodcastViewModel.swift:122` と `SettingsViewModel.swift:69,76` の既定引数）。`SettingsViewModel.clearCache()`（`:184-192`）はファイルを消すが `downloadedIds` を無効化する経路が無く（再同期は `loadPodcasts:149` のみ）、全削除後に「ダウンロード済み表示だが再生も再取得もできない」状態（IV10）。オフライン再生可否も `resolvePlaybackURL`（実体）と `isPlayableWhileOffline`（ミラー）で別根拠 | `Podcast/PodcastViewModel.swift:55,122,149,157-158,181-184,238-249`, `Settings/SettingsViewModel.swift:69,76,184-192` | R3 | F-A6, G7, IV10, LF10, CS2, RO7, OB-C9, OB-T9, SG-A6, OB-B6 | インスタンス共有（合成 root で 1 つ注入 / 状態 owner 型）と「有無の正本」を SG-A6 で決め、再同期契約を書く |
| RF12 | major | verification | テストの seam は URLSession 層で production 経路を通る（良好・P7）が、**double の限界**: `MockURLSession`（`APIClientTests.swift:637-659`）は任意の statusCode を返せる（`AuthAPIClientTests.swift:59-65` が 401 を検証済み。独立評価 N6 で初版の「常に成功を返す」を撤回）が、`URLError`（通信断）と非 `HTTPURLResponse` は再現できないため、RF3（失敗分類）と CI-A02 の契約テストは double 拡張が前提。RF2（401 遷移）はこの制約を受けない。テスト参照 0 の production 型 8（`Admin/AdminUsersViewModel.swift` / `Sessions/SessionsViewModel.swift` / `Learning/LearningViewModel.swift` / `Learning/VocabularyTestViewModel.swift` / `Passkey/PasskeyCredentialsViewModel.swift` / `Podcast/PlayerPresentation.swift` / `Podcast/PlaybackConstants.swift` / `Networking/SessionStore.swift:27` の `KeychainSessionStore`。`grep -rl <型名> NewsListenAppTests/` = 0）。Xcode テンプレートの空テスト（`NewsListenAppTests/NewsListenAppTests.swift:20,30`、`NewsListenAppUITests/NewsListenAppUITests.swift:26,37`、`NewsListenAppUITests/NewsListenAppUITestsLaunchTests.swift:21`。常時 green の非識別テスト）。`MockFileManager` が 2 ファイルで重複定義。契約 coverage は §6.1（Contract package） | `NewsListenAppTests/APIClientTests.swift:637`, `NewsListenAppTests.swift:20,30`, `NewsListenAppUITests/*`, `AudioCacheManagerTests.swift:9` vs `PodcastViewModelTests.swift:1121` | R7 | CI-A02, CI-S03, LF13, LF16, OB-T7, OB-N3, OB-B5, verification-run §8 | 失敗応答・URLError を返せる double を 1 つ共有化。テスト 0 の VM は契約 CI 確定後に T* から RED |
| RF13 | major | boundary/architecture | `PodcastViewModel`（854 行・15 `@Published`）が一覧取得・DL 管理・URL 解決・AVPlayer 制御・キュー・NowPlaying・RemoteCommand・AudioSession・割り込み・位置同期・完聴記録・語彙保存を 1 型で持ち、`UIKit`（`beginBackgroundTask:456,459`）・`AVFoundation`・`MediaPlayer`・`NotificationCenter`・`AVAudioSession.sharedInstance()` を直接参照。public 面に AVFoundation 型（`player:95`, `AVPlayerItem.Status:416`, `AVPlayer.TimeControlStatus:424`）が露出し、実利用者はテストのみ。`DesignSystem/PreviewSupport.swift:152-166` が VM の `@Published` を直接代入（DesignSystem → Podcast 層の逆依存、DEBUG 内） | `Podcast/PodcastViewModel.swift:11-14,95,399-425,456-460,611-726,733-753`, `DesignSystem/PreviewSupport.swift:152,164` | R1, R2 | F-A9, DV1-DV7, LF1, LF8, LF11, LF13, CS1, RO4, SG-A6, SG-A10, SG-B3 | 分割単位（再生セッション / キュー / DL / OS 連携 / 位置同期）と OS 連携の port 化範囲は SG-A6 / SG-A10。RF1 の NowPlaying クリアには最小限 NowPlaying の seam が要る |
| RF14 | minor | boundary | ViewModel 間の重複: 一覧読み込み＋エラー文言の同型が 9 VM、失敗表現が 3 系統（`errorMessage` / `loadFailed` / 両方）、online 購読定型が 3 VM で逐語重複、stale-request guard が 3 方式（request ID ×3 in SettingsViewModel / endedId 一致 / `Task.isCancelled`）。`StarredViewModel` が `FeedViewModel.offlineMessage` を static 借用 | `Feed/FeedViewModel.swift:82-85,100-121`, `Starred/StarredViewModel.swift:49-52,66-82,67,101`, `Podcast/PodcastViewModel.swift:130-136`, `Settings/SettingsViewModel.swift:58-62,203-272` | R1 | D1〜D6（Boundary §8。意味同一は D2/D5 のみ）, RO1, RO3, RO6 | 共有する場合も BaseViewModel 継承ではなく純粋ヘルパ（`ListDisplayState` と同型）に留める（Boundary RO 参照） |

### 4.3 Secondary（QL3 fault tolerance）と記録

| ID | severity | gate | finding | Evidence | 違反 R | 参照 | required_action |
|---|---|---|---|---|---|---|---|
| RF15 | minor | completeness | 既定速度（`AppState.defaultPlaybackSpeed`・UserDefaults・サーバ同期）とセッション速度（`PodcastViewModel.playbackSpeed`・初期値 1.0 固定）が**未接続**。設定画面で保存した既定速度は再生に一切反映されない。ADR-022 / 設計書は保存先を定めるが「再生に適用する」とは書いていない（意図か欠落か unknown → SG） | `AppState.swift:63-66,233`, `Podcast/PodcastViewModel.swift:50,291,575-579` | R3 | F-A4, G11, OB-C13, OB-T14, SG-A2 / SG3, D2 | 接続方法（開始時に値で初期化 = web 決定 / 購読 / 非連動を仕様化）は SG |
| RF16 | minor | contract | 位置同期の `updatePlaybackPosition` 戻り値を `_ =` で破棄し、失敗は production 唯一の「本文コメントのみ catch」で黙殺（`:849-851`）。spec §6.2 の server-wins をローカルへ取り込む契機が次回 `loadPodcasts` しか無い。`markCompleted` も `try?`（`:462`）で失敗が観測不能 | `Podcast/PodcastViewModel.swift:462,840-853` | R3, R2 | F-A5, G12, CI-P23, CI-P24, OB-C14, OB-T15, SG-A8 | 観測方針（状態反映 / 計測 / 受容）は SG-A8。`try?` 22 件のうちネットワーク失敗の黙殺 8 件は per-file 表（verification-run §5） |
| RF17 | minor | completeness | `Podcast.status` が閉じた値集合ではなく `String`。status × audio_url × error_message の矛盾組合せ（`"processing"` ∧ `audioUrl == ""` ∧ …）を decode で構築でき、再生可否判定（`resolvePlaybackURL`）は status を読まない。文字列分岐は `PodcastRowView.swift:118-133`（View）にある | `Models/Podcast.swift:69-73,121-141`, `Podcast/PodcastRowView.swift:118-133`, `Podcast/PodcastViewModel.swift:238-249` | R2, R1 | G8, IV11, OB-C10, OB-T10, U2 | Playable の判定所在を Model に置く。未知 status の fail-open/closed は U2 |
| RF18 | minor | architecture | `AppState.apiClient` は computed で毎アクセス新規 `APIClient` を生成し `sessionToken` を `let` でスナップショットする。`ContentView`（authenticated 時のみ生成、`NewsListenAppApp.swift:65-70`）に注入された client を `PodcastViewModel`/`FeedViewModel`/`StarredViewModel` が `let` で保持。**router 評価**: logout で ContentView ごと破棄されるため「失効後の旧 token 送出」はセッション内に限られ、実害は backend の失効 token 挙動（U-A2）に依存 → minor・inferred | `AppState.swift:137-142`, `Networking/APIClient.swift:55,75`, `NewsListenAppApp.swift:65-70,113-122`, `Podcast/PodcastViewModel.swift:85`, `Feed/FeedViewModel.swift:53`, `Starred/StarredViewModel.swift:38` | R3 | F-A8, CI-S06, SG-A7, U-A2 | 記録のみ。RF2 の 401 集中処理を入れる際に token 鮮度の owner を一緒に決める |
| RF19 | minor | completeness | `refreshOnboardingStatus` の取得失敗で `onboardingCompleted = true`（fail-open、WHY 記載あり）。`true` が「完了」「取得失敗」「保存失敗」の 3 意味を持ち再試行・計測ができない | `AppState.swift:88-93,305-315` | R2 | G14, IV12, OB-C16 | 記録のみ（WHY が明記されており QL4 に抵触しない） |
| RF20 | minor | contract | `PlaybackQueue` が spec §2.7 で「アダプタ責務・コア仕様外」とされる IndexSet 複数移動をコアに実装（`applyMove:131-141`）。操作名も spec `moveUpNext` ↔ 実装 `reorderUpNext`。conformance 32 件は全て `IndexSet(integer:)` の単一要素で呼び、複数要素の期待値を固定するテストは 0。Q-01〜Q-32 の期待値は Contract package が全行突合（§5） | `Podcast/PlaybackQueue.swift:118-142`, `NewsListenAppTests/PlaybackQueueConformanceTests.swift:249-253`, `docs/design/shared-playback-spec.md:84-93` | R9 | G13, CI-Q13, LF7, OB-C15, SG5 / SG-C2, X3, D5 | 複数移動の contract owner（コア or アダプタ）を SG5 で決め、spec §2.7 の iOS 欄か VM 側アダプタのどちらかに記す |
| RF21 | minor | contract | `PlaybackQueue.init(items:currentIndex:)` と `setQueue` は不変条件 1（id 一意）を検査せず、重複 id を含む配列をそのまま保持できる（不変条件 2・3 は clamp で維持）。production 経路では `add/playNext` が dedupe するため到達しないが、テスト 0 | `Podcast/PlaybackQueue.swift:21-28,53-56` | R9 | CI-Q02, CI-Q08, SG-C1 | smart constructor か不変条件テスト（web RF18 と同型） |
| RF22 | minor | verification | CI（`ci.yml`）は `xcodebuild test`（`-only-testing:NewsListenAppTests`）と gitleaks のみ。lint 無し（swiftlint/swiftformat 未導入）、独立 build 無し、UI テスト常時未実行、カバレッジ計測無し。`make test`（`scripts/test.sh`）と CI がシミュレータ選択の正規表現・resultBundle・xcbeautify で二重化し、`ios/CLAUDE.md:8` は `make test` を規定。`timeoutInterval` 設定 0（URLSession 既定 60s、rule 12 :13） | `.github/workflows/ci.yml:30-51,61-64`, `scripts/test.sh:13-36`, `ios/CLAUDE.md:8`, verification-run §2,§9 | R8 | OB-A5 | ゲート追加・一本化は運用判断（SG の later 候補） |
| RF23 | minor | architecture | `InMemorySessionStore`（token を平文プロパティで保持）が production ターゲットに `#if DEBUG` ガード無しで含まれる。現状は本番から未到達（`AppState.swift:343` 既定は Keychain） | `Networking/SessionStore.swift:19-22`, `AppState.swift:343` | R6 | F-A10 | 記録のみ（テストターゲットへ移すか DEBUG ガード） |

### 4.4 finding にしなかったもの（RC7・反証済み・SG へ隔離）

- **web 決定との差分 D1〜D4**（正本 = Queue.currentIndex / 速度 2 概念の接続 / auto-advance 失敗は停止 / 失効時の主体データ消去）: iOS 単独で決められないクロスプラットフォーム決定として §7 の SG-A1 / A2 / A3 / A5（Completeness SG1〜SG4 と同一主題）に隔離。RF5 / RF7 / RF15 / RF1 は「現状が不整合・未定義である」事実のみを finding とし、収束先は選んでいない。
- **web 決定は設計決定であって web 実装は未反映**: web review §7 は `engineering_status: not_started`、Spec S2 は `planned`。iOS が「web 実装に合わせる」対象は現時点で存在しないため、整合の Evidence は web の Spec（`web/docs/design/2026-09-16-implementation-spec-domain-model.md` §3.1）とする（OB-A1 を router が解決）。
- **admin gate（web RF3 相当）**: iOS の admin 出し分けは `isAdmin` 述語 1 箇所（`Models/AuthModels.swift:24`）を View 3 箇所が読むだけで、`unknown` 中の描画問題は無い（`authStatus == .unknown` は `ProgressView` のみ、`NewsListenAppApp.swift:51-54`）。ロール文字列の散在は RF9(f) に含めた。
- **Keychain / ログ**: トークンは Keychain のみ、ログ API 出現 0、ATS 例外は LocalNetworking のみ、Secrets.xcconfig は gitignore＋gitleaks。QL4 の主題は R6（残留）と R5（失効）に限られる。
- **force unwrap 4 件**（`APIClient.swift:275,277,303,305`）: `:275,303` の `URLComponents(url:resolvingAgainstBaseURL:)!` は自前の有効 URL に対してのみ呼ばれ、`:277,305` の `components.url!` は直前で組んだ queryItems からの再構成で、いずれも実質到達不能（独立評価 N9 で根拠を 2 種に分けた）。CI-A04 として契約化候補に留め finding にしない。
- **test-runner（T1）報告の誤り 2 件**を router が訂正: 「空 catch 4 件」→ 1 件（`:849`）、「AVPlayer 参照 4 ファイル」→ コード行では 2 ファイル（verification-run §5・§7 の erratum）。
- **性能**: Evidence なし。intentionally_not_optimized。
- **意匠・backend 契約・web/android**: out_of_scope。
## 5. Function packages（lossless 付録）

router の要約は §4 に圧縮しているが、stable ID・Evidence 状態・authority・coverage 分母/分子・subject verdict は次のファイルで保持する（`2026-09-16-code-design-review/` 配下）。

```yaml
function_plan:
  - {function: architecture, run_if: "ios 内 data authority が複数＋品質 trade-off", status: completed, artifact: architecture-strategy-package.md（1,208 行）, subject_verdict: incomplete, package_decision: {status: awaiting_approval, artifact_readiness: ready}, note: "data authority 7 fact のうち一意は token とネットワーク writer のみ。F-A1〜F-A10、DV1〜DV7、SG-A1〜SG-A10（全 pending）、web 差分 D1〜D5。option は候補のみで未選択"}
  - {function: discovery, run_if: "用語・context 発見", status: not_applicable, not_applicable_reason: "用語は Models/・PlaybackQueue・共有再生仕様で確定。term ledger は §2 context_packet.terminology で足りる"}
  - {function: completeness, run_if: "状態・遷移・失敗の欠落判定", status: completed, artifact: completeness-package.md（1,025 行）, subject_verdict: incomplete, package_decision: {status: pass, artifact_readiness: ready}, note: "scope S1〜S5、12 dimension screening 72/72（applicable 68 / present 15）、IV1〜IV12、G1〜G14（blocker G1/G4/G6）、OB-C1〜C16、OB-T1〜T17、SG1〜SG5、contradiction X1〜X4。R10（Podcast モデル整合）を候補要件として追加（router は R2 の一部として §4 RF17 に吸収）"}
  - {function: contract, run_if: "公開 operation の pre/post/failure", status: completed, artifact: contract-package.md（1,629 行）, subject_verdict: insufficient, package_decision: {status: "ready_with_open_gates → router 読替 awaiting_approval", artifact_readiness: ready}, note: "operation 21、CI 55（met 35 / partial 5 / unmet 15）、test covered 32 + planned 7 = 39/55、Q-01〜Q-32 期待値突合 32/32 一致（部分 oracle Q-06）、RT 17/17 一致、SG-C1〜SG-C5、OB-N1〜OB-N5、planned test T-Q1/T-P1/T-P2/T-A1/T-A2/T-C1/T-S1（not_run）"}
  - {function: boundary, run_if: "技術漏出・caller 分岐・長大処理", status: completed, artifact: boundary-package.md（932 行）, subject_verdict: leaky, package_decision: {status: pass, artifact_readiness: ready}, note: "C1〜C6、LF1〜LF16、PodcastViewModel = 14 purpose（OS 連携 P9〜P12 で約 217 行）、重複 D1〜D6（意味同一は D2/D5 のみ）、CS1〜CS12（pass: CS3/CS6）、RO1〜RO7、SG-B1〜SG-B3"}
  - {function: change_safety, run_if: "既存挙動変更", status: not_applicable, not_applicable_reason: "review mode・変更提案なし。修正着手時（Implementation Spec）に再判定"}
```

router による obligation の解決:
- **OB-A1 / OB-N5（web 実装の実挙動確認）**: web は決定済みだが未実装（web review §7 `engineering_status: not_started`、Spec S2 `planned`）。整合対象は web の Spec §3.1（Queue.current を正本、INV-P1、`nowPlaying()`、速度 2 概念、advance 失敗は停止）。P7 で iOS がこの Spec に合わせるかを問う。
- **OB-N1（Contract → Completeness の ID）**: Completeness 完成後に router が対応付けた: CI-Q02 ↔ SG-C1（Completeness 側に該当 G なし）、CI-P05 ↔ G3/OB-C2、CI-P13 ↔ G1/OB-C1、CI-S05/C05 ↔ G6/OB-C8、CI-S03 ↔ G5/OB-C7、CI-Q13 ↔ G13/OB-C15。
- **OB-N2 / SG-B1（API 失敗の意味を確定する層）**: Boundary は SG-B1 として user 判断へ。router は候補「Networking 層で `APIError` を意味ケースに変換し、404 の subject は endpoint 関数が付与（web Spec CI-T12 と同形）」を P7 に提示する。
- **OB-N4 / OB-B4（backend の完聴・位置 PUT 冪等性）**: out_of_scope。unknown U3 として保持。memory「issue #112 backend PUT 未実装」は `/settings/sources` の PUT であり位置 PATCH とは別（矛盾なし）。
- **OB-A3 / OB-B2 / OB-B3（主体依存 UserDefaults 棚卸し・404 の概念名・View 内規則の所有概念）**: Implementation Spec（P8）の term ledger と Preferences 節で扱う。棚卸しの現時点の観測: `AppState.swift:40-47` の 5 キー（難易度・速度・週目標・記事の開き方・時刻表記）、`DSFeedback.swift:27-28`（効果音・ハプティクス）、`LearningEngagement.swift:147`（実績既読。logout で削除済み）。主体依存と言えるのは実績既読と週目標・難易度・速度（サーバ同期値のローカルコピー）。
- **OB-A5 / OB-B5（CI・UI テスト方針）**: RF22 と SG-A10 として P7 へ。
- **OB-A6（spec §6.3 の iOS 欄の改訂）**: SG-A5 決定後。read-only の本レビューでは実施しない。

## 6. Traceability と検証

### 6.1 要件 → package → test（分母 9）

| R | Architecture | Completeness | Contract（CI / test） | Boundary | 既存 test | status |
|---|---|---|---|---|---|---|
| R1 | F-A9（責務集中） | —（scope 外。R10 に一部） | CI-P06 のみ（再開閾値） | LF9, LF12, CS4 fail, CS7 fail, D4/D5 | AccountSettingsView / QuizSheetView はテスト無し | **missing**（owner が View / 2 VM） |
| R2 | F-A3 | G1, G2, G8, G9, IV1-IV3, IV11 | CI-P01-P03, P13, P19, Q01（test 39/55 全体） | LF1, LF2, LF4, CS1 fail | PodcastViewModelTests（68）は現状挙動を pin（`:483` は違反側） | **partial** |
| R3 | F-A1, F-A4, F-A6, F-A7, F-A8, AR (a)-(g) | G3, G7, G11, G12, IV4, IV5, IV10 | CI-P05, P08, P17, P23, S06（owner unknown） | LF3, LF10, LF14, CS10 fail, CS12 fail | — | **missing**（authority 未選択） |
| R4 | — | G9 | CI-A01, A02, P03, P09 | LF5, LF6, LF12, LF15, CS5 fail | APIClientTests（34）は正常系＋httpError | **partial** |
| R5 | — | G4, G5, G14, IV6-IV8, IV12 | CI-S01-S03（S03 unmet） | LF6, LF9 | AppStateAuthTests（8） | **missing**（実行中 401 の遷移なし） |
| R6 | F-A2, F-A10 | G6, G10, IV9 | CI-C01, C05, S05（unmet） | LF8, CS11 fail | `AppStateAuthTests.swift:34,87` green | **contradictory**（仕様 §6.3 vs 実装。green だが要件に反する） |
| R7 | — | OB-T1〜T17 | test 39/55（既存 32） | LF13, LF16 | seam は URLSession 層（良好）。テスト 0 の型 8 | **partial** |
| R8 | — | — | out_of_scope（Contract） | — | ci.yml | **missing**（inferred 要件） |
| R9 | D5 | G13, X3 | CI-Q01-Q14（Q 32/32・RT 17/17 一致。Q02/Q08/Q13 は表外） | LF7 | conformance 49 green | **partial**（表は満たすが名前差・IndexSet が未契約） |

coverage: covered 0 / partial 4（R2, R4, R7, R9）/ missing 4（R1, R3, R5, R8）/ contradictory 1（R6）。

### 6.2 validation

```yaml
validation:
  executed:
    - {id: V1, command: "DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination 'platform=iOS Simulator,id=14BBBBE4-70F0-47BF-9BFF-517D7F6B1AF7' -only-testing:NewsListenAppTests", result: pass, evidence: "Executed 509 tests, with 0 failures; 21.6 s; Xcode 26.6"}
    - {id: V6, command: "grep 定量（@Published / try? / catch / force unwrap / URLSession / AVPlayer / UserDefaults / status 数値分岐 / double 定義 / conformance ID）", result: pass, evidence: "verification-run.md §3〜§8。T1 報告の erratum 2 件を router が訂正"}
    - {id: V7, command: "package 内 path:line の範囲検査（wc -l 超過・ファイル欠落の検出、1 コマンド）", result: pass, evidence: "architecture 101 / completeness 145 / contract 130 / boundary 119 参照、すべて範囲内・欠落 0（各 package 末尾にも自己検査あり）"}
    - {id: V8, command: "Q-01〜Q-32・RT-01〜RT-A02 の期待値と conformance テストの実引数の突合（Contract package §4・§8）", result: pass, evidence: "32/32・17/17 一致、矛盾 0、部分 oracle Q-06"}
  passed: [V1, V6, V7, V8]
  failed: []
  unexecuted:
    - {id: UV1, reason: "UI テスト（XCUITest 3 件）はテンプレートのみ・アサーション 0・CI 除外", required_runner: "xcodebuild test -only-testing:NewsListenAppUITests", planned_commands: [], owner: user}
    - {id: UV2, reason: "lint は未導入（swiftlint / swiftformat 不在）。導入は R8 の運用判断", required_runner: "test-execution", planned_commands: ["brew install swiftlint && swiftlint lint"], owner: user}
    - {id: UV3, reason: "logout 後の NowPlaying 残留・auto-advance 失敗時の UI・署名 URL 失効後の再生失敗は XCTest で観測できず実機/シミュレータ目視が必要", required_runner: "iOS Simulator / 実機", planned_commands: ["ログイン→再生→logout→ロック画面確認", "一覧取得後 1 時間放置→再生"], owner: user}
    - {id: UV4, reason: "Contract package の planned test 7 件（T-Q1, T-P1, T-P2, T-A1, T-A2, T-C1, T-S1）と OB-T1〜T17 は未実装（design 段階）", required_runner: "tdd-implementation", planned_commands: ["owner 確定 CI から RED"], owner: user}
  platform_validation: {required_platforms: [ios], executed: [], unexecuted: [], parity_result: not_applicable, platform_specific_risks: ["iOS 単一 platform。macOS/Linux/Windows の parity 要件なし。iOS 17 deployment target に起因する既知の限界は trial-log transcript-sync-highlight.md:53"]}
```

注: V1 は「現状の実装が現状のテストに対して green」であることの Evidence であり、R6 の contradictory と RF8（違反側を pin する green テスト）が示すとおり要件充足の Evidence ではない（rule 11 :70-74）。

## 7. Canonical decision

```yaml
decision:
  status: pass                       # review artifact として必須 gate を満たし、未実行事項と risk を明示
  artifact_readiness: ready
  engineering_status: not_started    # 修正は未着手
  release_status: not_applicable
  decision_maturity: {status: approved, owner: user, scope: [ios/ の finding 採否と Selection Gate], evidence_status: confirmed, approval_evidence: ["§8 dig-me セッション 2026-09-16（Q1〜Q10 の回答と共通理解の確認）"], baseline_version: "c8c1ada", change_control: "本文書の §8 を更新して再承認"}
  subject_verdict_summary: {architecture: incomplete, completeness: incomplete, contract: insufficient, boundary: leaky}
  next_phase:
    name: Implementation Spec（design mode）
    status: allowed
    reasons: ["主要 SG は 2026-09-16 の人間判断（§8）で satisfied", "RF1 は Q1 で major へ降格、着手順は §8.3 で確定"]
    human_approvals_required: []
    resolved_by: "§8（dig-me セッション 2026-09-16、owner: user）"
  evidence: [V1, V6, V7, V8, 各 package の Evidence 記録]
  assumptions: ["R1-R5・R8 は router が実コードと rule から導いた inferred 要件（user 未承認）", "P9: backend の月次 quota・admin 認可・パスワード検証値・id 生成規則・失効 token 挙動・完聴冪等性は未確認", "web 決定は Spec 上の決定であり web 実装は未反映（整合対象は Spec）"]
  unknowns:
    - {id: U1, subject: "backend の podcast id 生成規則（RF4 の severity）", confirmation_method: "backend repo の podcasts handler 確認", impact_if_unresolved: "RF4 は minor のまま", owner: user, evidence: [G10, CI-C01]}
    - {id: U2, subject: "未知 `status` 値の扱い（fail-open / fail-closed）", confirmation_method: "backend の status 列挙と ADR-021 確認", impact_if_unresolved: "RF17 の契約方向（OB-C10）が定まらない", owner: user, evidence: [G8]}
    - {id: U3, subject: "backend の完聴記録・位置更新の冪等性 / 失効 token の応答", confirmation_method: "backend repo の markCompleted / position handler 確認", impact_if_unresolved: "RF16 の duplicate 契約と RF18 の severity が確定しない", owner: user, evidence: [OB-N4, U-A2]}
    - {id: U4, subject: "`AudioPlayerView.swift:303-606` の内部 @State と reader 在庫", confirmation_method: "View の読解（trial-log 方針により XCTest 対象外）", impact_if_unresolved: "RF5 の reader 数に漏れ", owner: router, evidence: [Completeness U4]}
    - {id: U5, subject: "既定速度が再生に適用されないのは意図か欠落か", confirmation_method: "P7 で user に確認（ADR-022・設計書は保存先のみ規定）", impact_if_unresolved: "RF15 が finding か仕様か決まらない", owner: user, evidence: [F-A4, G11]}
  contradictions:
    - "C1: shared-playback-spec §6.3:312（iOS は logout 時に removeAllDownloads() 自動呼出）vs AudioCacheManager（API 無し）・AppState.logout（呼出無し）"
    - "C2: ADR-009 / ios-design.md §8 手順 3 / PodcastViewModel.swift:254 doc（再生直前に署名 URL 再取得）vs play():262-290（再取得なし）。既存テスト :483 は実装側を pin"
    - "C3: spec §2.1 不変条件 4（current = items[currentIndex]）vs 主要 reader（PodcastView.swift:90）が currentPodcast を正本として読む"
    - "C4: spec §2.7（複数選択はアダプタ責務）vs PlaybackQueue.applyMove:131-141 がコアで実装"
    - "C5: AppState.refreshAuth の doc（:199-201 失効のみ）vs 実装（:216-220 全例外で破棄）"
    - "R6: 既存テスト green と要件違反が併存"
  failed_gates: []
  unexecuted_validation: [UV1, UV2, UV3, UV4]
  platform_validation: {parity_result: not_applicable}
  residual_risks: ["RF1 の blocker は共有端末前提（spec §6.3 の明記）に基づく。user が端末共有なしと回答すれば web RF1 同様 major へ降格", "RF18 は router が経路確認で minor へ置いた（Architecture は priority unknown）。backend の失効 token 挙動（U3）で再評価", "件数主張は per-file 内訳のあるもの（verification-run）以外は inferred として読むこと", "T1 report の erratum 2 件（空 catch 件数・AVPlayer 参照ファイル数）は router が訂正済み", "独立評価（§7.1）で RF8 の副主張と RF12 の double 性質を訂正した。上位 8 件以外は独立評価未到達", "Explorer 報告の行番号 2 件（setSpeed 576→575、PreviewSupport 153/165→152/164）は package 側で訂正済み"]
  human_approvals_required: []   # §8 で解決
```

### 7.1 独立評価（adversarial-review ロール）

全文: `2026-09-16-code-design-review/t5-adversarial.md`。評価者は T1〜T4 の package を判定材料にせず、§4 の主張を自分で grep / read して反証を試みた（反証試行 10 件）。

```yaml
reviewed_by:
  kind: independent_evaluator
  identity: adversarial-verifier (T5)
  review_status: partially_accepted   # CONDITIONAL PASS → 条件 6 件を router が反映
  scope_accepted: [RF1, RF2, RF3, RF6, RF7, RF10, "RF10 の件数 10/10・404×6 意味 2 種", "RF6 の 15/9", "RF9(a) パスワード 2 実装", "§4.4 admin gate / web 差分の SG 隔離", "RC3/RC6/RC7 合格"]
  scope_weakened: [RF5（writer 限定の表現）, RF8（テスト副主張を refuted → 非識別テストへ再分類）, RF9（(f) 件数 4→3 ファイル）, RF12（double 性質を refuted → URLError/非 HTTP のみの限界へ訂正。RF2 への誤依存を解消）]
  scope_unverifiable: [RF4, RF11, RF13〜RF23]   # turn 上限で未到達
  citations_checked: 71
  citations_wrong: 1        # N1: ios-design.md:373 → :374
  citations_loose: 4        # N2 パス基準混在, N8 1 行ずれ ×2, AdminUsersView.swift:32 の片側落ち
  claims_refuted: 2         # N6（MockURLSession は任意 status を返せる）, N7（:483 は再取得を観測しない非識別テスト）
  counts_mismatched: 1      # N5
```

router が反映した差分（初版 → 現版）:

| 対象 | 初版 | 現版 | 理由 |
|---|---|---|---|
| RF8 | 「`:483` は仕様違反側を pin する green テスト」 | 「`:507` の assert 1 本のみで再取得を観測しない非識別テスト」。required_action を「観測の追加」へ | N7（ADR-009 準拠にしても green） |
| RF12 | 「`MockURLSession` は常に成功を返し RF2/RF3/CI-A02 の契約テストが書けない」 | 「任意 status は返せる（`AuthAPIClientTests.swift:59-65` が 401 検証済み）。限界は URLError / 非 HTTPURLResponse のみ。RF3・CI-A02 だけが double 拡張を前提」。RF2 → RF12 の依存を削除 | N6 |
| RF9(f) | 「4 ファイルに散在」 | 「3 ファイル 7 出現（per-file 内訳）」。(a) に `AdminUsersView.swift:28` の UI 文言を追記 | N5 |
| RF5 | 「writer `:281` のみ」 | 「`PodcastViewModel` 内では `:281` のみ。DEBUG の PreviewSupport は RF13」 | N3 |
| RF10 | 例示 2 つを `APIError.errorDescription` に帰属 | VM リテラル（`:265`, `:418`）と `APIError`（`:33-36`）を分けて帰属。分岐 10 箇所を行内に列挙 | N4, RC1 |
| RF8 / RF3 / RF10 | `ios-design.md:373`、`AppState.swift:199-201`、`APIClient.swift:19-39` | `:374`、`:200`、`:20-40` | N1, N8 |
| RF7 | `docs/trial-log/...`（ルート基準） | `ios/docs/trial-log/...` | N2 |
| RF12 | 「テスト 0 の型 8」「空テスト 3 ファイル」に path:line なし | 型ごとのファイルパスと空テストの `path:line` を補充 | RC1 |
| §4.4 | force unwrap 4 件を 1 種として「到達不能」 | `URLComponents(...)!` と `components.url!` の 2 種に分けて根拠を記述 | N9 |

削除した finding: なし。severity 変更: なし（RF8 は本体 accepted のまま major 維持。副主張の訂正のみ）。

canonical decision への影響: `status: pass` を維持（訂正はすべて finding 本文の根拠・件数・依存関係であり、gate の失敗ではない）。未到達の RF4・RF11・RF13〜RF23 は `residual_risks` に記録済みで、router の自己確認のみ。評価者の提案どおり `verification-run.md` の件数（`try?` 22・空 catch 1・AVPlayer 2 ファイル）は router が Explorer ③ と test-runner の 2 経路で照合済み（§5 の erratum）。

## 8. 人間判断の結果（2026-09-16・dig-me セッション、owner: user）

Selection Gate と finding の採否を、ユーザーとの一問一答（Q1〜Q10）で確定した。AI 復唱ではなく user の回答が Evidence。共通理解の明文化に対し user が「これでよい」と確認（2026-09-16）。

### 8.1 前提（user 回答）

- 端末・アプリの共有は現状なし。ただし共有再生仕様 §6.3 の「共有端末対応」契約は維持する（Q1）。
- 次サイクルの主題は再生領域。web の Spec 決定（Queue 正本・速度 2 概念・auto-advance 失敗は停止・失効時消去）に iOS を揃える（Q2〜Q5）。
- web の決定は Spec 上の決定で web 実装は未反映。iOS が揃える対象は `web/docs/design/2026-09-16-implementation-spec-domain-model.md` §3.1。

### 8.2 Selection Gate の状態

```yaml
selection_gates_resolution:
  - {id: SG-A5 / SG4, status: satisfied, decision: "logout と失効（401）の両経路で音声キャッシュ全削除＋NowPlaying クリア＋主体依存 UserDefaults（実績既読・週目標・難易度・速度のローカルコピー）削除＋再生セッション停止。spec §6.3 の iOS 欄は実装名を実態へ改訂。RF1 は blocker → major（現状共有なし）", evidence: [Q1, Q5]}
  - {id: SG-A1 / SG2, status: satisfied, decision: "『現在再生中』の正本 = PlaybackQueue.currentIndex（spec §2.1 不変条件 4）。currentPodcast は queue.current の派生値。playById は『キューに無ければ現在の次に挿入して jump』（playNow と同規則）としてキュー操作化。replayCurrentEpisode は current の再開始", evidence: [Q2]}
  - {id: SG-A3 / SG1, status: satisfied, decision: "auto-advance 先の再生失敗は停止。currentIndex は進めたまま、失敗エピソードを current にして error(reason: offline_uncached | invalid_source | engine_failed)。手動 play で再試行。spec §2 に『advance 後の再生失敗』を追記（3 platform 共通）", evidence: [Q3]}
  - {id: SG-A2 / SG3, status: satisfied, decision: "速度は 2 概念。既定速度（AppState・永続・サーバ同期）は再生開始時にセッション速度の初期値になる。セッション中の変更は既定を書き換えない", evidence: [Q4]}
  - {id: SG-C5, status: satisfied, decision: "refreshAuth の失敗を unauthorized（401 相当）と unavailable（通信断・5xx・decode）に分類し、前者のみトークン破棄", evidence: [Q5]}
  - {id: SG-C4, status: satisfied, decision: "ADR-009 どおり、オンライン＋未キャッシュの再生直前に GET /podcasts/{id} で再取得し、取得失敗時は保持 URL でフォールバック。テストに fetchPodcast 呼出の観測を追加", evidence: [Q6]}
  - {id: SG-B1, status: satisfied, decision: "APIClient が APIError を意味（network / unauthorized / forbidden / not_found(subject) / conflict / rate_limited(retryAfter) / server）へ変換。404 の主語は endpoint メソッドが付与。日本語文言は 1 箇所の policy。VM/View に status 数値比較を残さない", evidence: [Q7]}
  - {id: SG-A6 / SG-A10 / SG-B3, status: satisfied, decision: "PodcastViewModel を目的別 capsule（再生セッション / キュー / オフライン保存庫 / OS 連携 port / 位置同期）に分割し、VM は配線と派生値のみ。AudioCacheManager は合成 root で 1 インスタンスを注入。既存 68 テストを特性テストとして固定後に一括切替", evidence: [Q8]}
  - {id: SG-B2, status: satisfied, decision: "パスワード規則は 8〜20 文字（web SG7 と同値）を 1 policy に。AccountSettingsView の changePassword / saveProfile は VM へ移す", evidence: [Q9]}
  - {id: SG-A7, status: satisfied_by_default, decision: "token 鮮度は Q5 の失効遷移（ContentView 破棄で client 再生成）で足りる。token provider 注入は作らない", evidence: [Q5, RF18 の router 評価]}
  - {id: SG-A4 / SG-A8 / SG-A9, status: deferred, decision: "ネットワーク参照の統一・best-effort 失敗の観測方針・View 直書きは Q8 の分割で自然に閉じる範囲のみ。独立の作業にしない", evidence: [Q8]}
  - {id: SG-C1 / SG-C2 / SG-C3 / SG5, status: satisfied_by_default, decision: "Queue の id 一意性は内部 gate（init/setQueue で dedupe）、IndexSet 複数移動はコアに残し spec §2.7 の iOS 欄に明記、seek は clamp。いずれも Spec の契約表で確定し user 承認は Spec 承認（P9）で得る", evidence: [Q8]}
```

### 8.3 finding の採否と着手順

| 順 | 対象 | 決定 |
|---|---|---|
| 1 | RF10（失敗の意味層） | Networking 層で意味へ変換、10 消費者を置換、文言 1 箇所（Q7） |
| 2 | RF1 / RF2 / RF3 | 401 集中処理＋失効・logout の同一経路で主体データ消去＋refreshAuth の失敗分類（Q1, Q5） |
| 3 | RF5 / RF6 / RF7 / RF8 / RF13 / RF15（付随: RF11 / RF14 / RF16 / RF17 / RF20 / RF21） | 再生ドメイン再構成: 正本一本化・状態 union・auto-advance 停止・速度 2 概念・署名 URL 再取得・capsule 分割・AudioCacheManager 共有（Q2, Q3, Q4, Q6, Q8） |
| 4 | RF9 (a)(b) / RF22 | パスワード 8〜20 の 1 policy と VM 化。CI は make test 呼出への一本化のみ（Q9） |
| 記録のみ | RF4, RF12（double 拡張は順 2 で必要な範囲のみ）, RF18, RF19, RF23, RF9 (c)〜(f) | 変更しない。RF4 は backend の id 規則確認のみ |

### 8.4 残存する仮定・未決

- backend のパスワード検証値が 8〜20 と整合する（未確認。順 4 の着手前に確認）。
- U1〜U3（backend の id 規則・失効 token 応答・完聴/位置更新の冪等性）は out_of_scope のまま。順 2・3 の契約に「backend 依存」として明記する。
- 主体依存 UserDefaults の範囲は §5 の棚卸し（実績既読・週目標・難易度・速度）を仮定。Spec の Preferences 節で確定。
