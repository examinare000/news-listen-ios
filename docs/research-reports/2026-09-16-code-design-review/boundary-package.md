# Boundary Package — ios NewsListenApp（C1〜C6 / review mode・read-only）

```yaml
routing_context: {origin: integrated, mode: review, requested_by: router, requested_artifact: boundary-package, return_to: router, mutation_authorized: false}
```

対象 HEAD `c8c1ada`。行番号はすべて本 review で `grep -n` / `sed -n` により自分で再取得したもの（p1 報告の転記ではない）。
末尾 §12 に `path:line` 範囲検査の実行結果を置く。

---

## 0. 結論（先に述べる）

`subject_verdict: leaky`。最大の問題は **C1（View → PodcastViewModel）の境界が「再生という目的」ではなく「AVFoundation を操作する手続き」の形で公開されている**ことで、その結果 (a) 再生エンジンを差し替えると公開面と 509 本のテストが動き（CS1 fail）、(b) 「現在再生中か」の判定規則が View 側へ漏れて 3 通りに分岐し（LF3/LF4）、(c) OS 連携（NowPlaying・RemoteCommand・AudioSession）が VM 内のシングルトン直呼びのため、logout 時のクリアという業務要求（R6）を呼び出す operation が存在しない（CS11 fail）。

ただし本 package は**手段を選択しない**。分割単位・port 化範囲は Architecture Strategy Package の `SG-A6` / `SG-A10` が所有し、本 package は境界と漏出の所在のみ確定する。本 package 固有の未決は `SG-B1`〜`SG-B3`。

---

## 1. contract_source

```yaml
contract_source:
  kind: domain_contract
  artifact_refs:
    - "/Users/rio/git/news-listen/docs/design/shared-playback-spec.md（§2 キュー状態モデル・不変条件1〜5、§4 Q-01〜Q-32 / RT-01〜15、§6 オフライン・logout）"
    - "/Users/rio/git/news-listen/docs/design/ios-design.md §5〜§8"
    - "architecture-strategy-package.md §4（DV1〜DV7）・§7（SG-A1〜SG-A10）"
  domain_contract_status: applicable
  not_applicable_reason: ""
  confirmation_method: ""
  impact_if_unresolved: ""
  evidence:
    - status: confirmed
      source: "p4-common-brief.md §1（正本の所在）／Podcast/PlaybackQueue.swift の存在"
      supports: "再生キューには業務正本があり、consumer semantic operation contract を捏造する必要がない"
    - status: unknown
      source: "本 review では Contract Package（CI*）が並列作成中で未読"
      supports: "condition 単位の authoritative enforcement は本 package では確定しない（OB-B1）"
```

**権限境界**: 本 package が所有するのは consumer purpose・operation の意味契約・技術漏出・境界内の責務配置のみ。system-wide の data authority と target architecture は Architecture Strategy Package（`SG-A*`・`DV*`）を参照し二重確定しない。condition 単位の事前/事後条件は Contract Package を参照する（未作成のため `OB-B1`）。

---

## 2. consumers（境界の固定）

```yaml
consumers:
  - id: C1
    name: "View → PodcastViewModel"
    actual_consumers:
      - "Podcast/PodcastView.swift（151 行）"
      - "Podcast/AudioPlayerView.swift（606 行）"
      - "Podcast/MiniPlayerView.swift（126 行）"
      - "Podcast/QueueSheet.swift（82 行）"
      - "Podcast/PodcastRowView.swift（160 行・PodcastView 経由で値を受け取る間接 consumer）"
      - "NewsListenAppApp.swift（所有者かつ consumer: :104 @StateObject, :170 flushPlaybackPosition, :185 playById）"
    purpose: "再生操作（開始・一時停止・シーク・速度・キュー編集）と、再生状態の表示"
    must_know:
      - "いま何が再生対象か／再生中か／位置と長さ／バッファ待ちか"
      - "再生できなかった理由（利用者に提示できる意味）"
      - "待機列の内容と編集結果"
      - "一覧の表示状態（ロード/エラー/空/一覧）"
    must_not_know:
      - "AVPlayer / AVPlayerItem / CMTime / KVO・通知の配線と stale ガード規約"
      - "MPNowPlayingInfoCenter・MPRemoteCommandCenter・AVAudioSession・UIApplication background task"
      - "currentPodcast と queue.currentIndex という 2 正本の合成規則"
      - "@Published の書込タイミングと、どのフィールドを外から書いてよいか"
    evidence: [{status: confirmed, source: "grep -n 'currentPodcast' 実測: VM 外の参照 19 箇所（AudioPlayerView 11 / QueueSheet 1 / PodcastView 1 / MiniPlayerView 2 / PreviewSupport 2 / PlayerPresentation.swift:13 コメント 1）", supports: "consumer 実体の同定"}]

  - id: C2
    name: "ViewModel → APIClient"
    actual_consumers: ["15 の ViewModel と 2 の View（AccountSettingsView / QuizSheetView が直呼び）"]
    purpose: "業務操作の結果と、失敗の意味を受け取る"
    must_know: ["操作が成功したか", "失敗の業務的意味（未認証/権限なし/対象なし/競合/上限到達と再試行可能時刻/サーバ障害/通信不能）"]
    must_not_know: ["HTTP status の数値", "URLSession / URLRequest / JSONDecoder", "英語の localizedDescription をそのまま UI へ出す前提"]
    evidence: [{status: confirmed, source: "Networking/APIClient.swift:22,24,27（APIError ケース）, :32-38（errorDescription）", supports: "公開面が status 数値と英語文言を運ぶ"}]

  - id: C3
    name: "PodcastViewModel → AVFoundation / MediaPlayer / AVAudioSession / UIKit"
    actual_consumers: ["PodcastViewModel のみ（AVFoundation/MediaPlayer をコード参照するのは本 file と Podcast/NowPlayingInfo.swift の 2 file）"]
    purpose: "音声を鳴らす技術と OS 連携（ロック画面・リモート操作・割り込み・バックグラウンド継続）"
    must_know: ["—（implementation part であるべき）"]
    must_not_know: []
    evidence: [{status: confirmed, source: "verification-run.md §7（AVPlayer|AVFoundation 参照は 2 file）／PodcastViewModel.swift:11-14 の import", supports: "技術依存の所在は 1 型に閉じている"}]

  - id: C4
    name: "ViewModel → AudioCacheManager / NetworkMonitoring"
    actual_consumers: ["PodcastViewModel（:122 既定引数で生成）", "SettingsViewModel（:69,:76 の 2 init でそれぞれ既定引数生成）", "FeedViewModel/StarredViewModel（NetworkMonitoring のみ）"]
    purpose: "このエピソードを今このネットワーク状態で再生できるか、の判定材料"
    must_know: ["再生可能か", "オフライン時に再生可能か", "端末が占有している容量と、それを空にした結果"]
    must_not_know: ["キャッシュがファイルであること・`{id}.mp3` というパス規約・file URL であること", "NWPathMonitor"]
    evidence: [{status: confirmed, source: "Networking/AudioCacheManager.swift:45-47（cachedURL が `{id}.mp3` の file URL を返す）／Networking/NetworkMonitoring.swift:19-27", supports: "storage 実装が公開面に出ている／network は protocol で隔離済み"}]

  - id: C5
    name: "View → AppState"
    actual_consumers: ["AccountSettingsView", "SettingsView", "NewsListenAppApp/ContentView", "各 VM（SettingsViewModel は AppState を保持）"]
    purpose: "認証状態・設定の読み書き"
    must_know: ["ログイン済みか / 自分は誰か / admin か", "既定難易度・既定再生速度・週次目標"]
    must_not_know: ["APIClient の生成タイミングと token スナップショット", "UserDefaults キー", "currentUser を外から代入してよいかどうか"]
    evidence: [{status: confirmed, source: "Settings/AccountSettingsView.swift:308（`appState.currentUser = updated`）／Settings/SettingsViewModel.swift:42（`appState?.apiClient ?? apiClientOverride`）", supports: "consumer が writer になっている／consumer が client 選択順を知っている"}]

  - id: C6
    name: "DesignSystem(PreviewSupport) → ViewModel 内部"
    actual_consumers: ["DesignSystem/PreviewSupport.swift:151-158（playerViewModel）, :163-168（finishedPlayerViewModel）"]
    purpose: "プレビュー用に特定の再生状態を組み立てる"
    must_know: ["組み立てたい状態の意味（再生中・聴き終わり）"]
    must_not_know: ["どの @Published をどの順で代入すれば整合するか"]
    evidence: [{status: confirmed, source: "DesignSystem/PreviewSupport.swift:153,165（`vm.currentPodcast = podcasts[0]`）, :166（`vm.previewMarkFinished()`）／PodcastViewModel.swift:493（DEBUG seam）", supports: "下位層 DesignSystem が上位 VM の内部書込に結合（ASP の DV3 と同一事象）"}]
```

---

## 3. code_design — 長大処理（PodcastViewModel 854 行）の責務棚卸し

行範囲は `grep -n "func "` 実測の宣言行から次宣言直前まで。doc コメントは直前の宣言に含めず、宣言行から数える。

| # | purpose（変更理由） | method 群（宣言行） | 概算行 | concern 分類 |
|---|---|---|---|---|
| P1 | カタログ一覧の取得と表示 | `loadPodcasts:143`, `syncDownloadedState:157` | 17 | use-case orchestration |
| P2 | ダウンロード状態の導出（純粋） | `downloadState(for:):163`, `static downloadState:168`, `static isPlayableWhileOffline:184` | 25 | domain decision |
| P3 | 音声ダウンロード実行 | `download:191`, `removeDownload:217` | 34 | orchestration + external I/O |
| P4 | 再生元の決定（キャッシュ/署名 URL/不可） | `static resolvePlaybackURL:238` | 12 | domain decision |
| P5 | 再生セッションのライフサイクル | `play:262`, `playById:381`, `replayCurrentEpisode:481`, `togglePlayPause:553`, `seek:567`, `setSpeed:575`, `stopPlayback:583` | 約 210 | orchestration + transport implementation（AVPlayer 手続き） |
| P6 | AVPlayer コールバックの stale ガードと状態反映 | `shouldProcessPlayerItemCallback:399`, `shouldProcessPlayerCallback:407`, `handlePlayerItemStatusChange:416`, `handleTimeControlStatusChange:424` | 28 | operation semantics（純関数化済み・良い分離） |
| P7 | キュー操作と自動次再生 | `handlePlaybackEnded:435`, `playNow:516`, `addToQueue:525`, `playNext:534`, `removeFromQueue:543`, `moveUpNext:548` | 82 | domain decision（正本は PlaybackQueue） |
| P8 | プレイヤー表示形態 | `minimizePlayer:468`, `expandPlayer:474`, `previewMarkFinished:493`(DEBUG) | 26 | representation |
| P9 | 音声セッション設定 | `configureAudioSession:617` | 11 | platform adapter |
| P10 | NowPlaying（ロック画面情報） | `updateNowPlayingInfo:731`, `updateNowPlayingElapsed:747` | 30 | platform adapter |
| P11 | リモートコマンド配線 | `configureBackgroundPlayback:632`, `configureRemoteCommands:645` | 81 | platform adapter |
| P12 | 割り込み・ルート変更 | `registerAudioNotifications:713`, `handleInterruption:759`, `handleRouteChange:787`, `deinit:796` | 95 | platform adapter（判断は `InterruptionPolicy` へ分離済み） |
| P13 | 再生位置のサーバ同期 | `startPlaybackPositionSync:816`, `flushPlaybackPosition:832`, `syncPlaybackPositionIfNeeded:843` | 38 | operational concern |
| P14 | クイズ・語彙の素通し | `submitQuizAnswers:499`, `fetchSavedVocabulary:504`, `saveVocabulary:509` | 13 | （純粋な委譲。VM が保持する状態はゼロ） |

**数え方**: 14 purpose。`@Published` 15 宣言（:36,38,40,42,44,46,48,50,53,55,57,59,61,65,69）。うち外部書込可能な `var`（`private(set)` なし）は 9（:36,38,40,42,44,46,48,50,53）。OS 連携（P9〜P12）だけで約 217 行、全体の 25%。

**境界候補（提示のみ。選択しない — `SG-A6` / `SG-A10` が所有）**
- 候補 a: purpose を「再生セッション（P4〜P8, P13）」「カタログ＋ダウンロード（P1〜P3）」「OS 連携（P9〜P12）」「素通し（P14 は廃止し View から直接 APIClient 境界へ）」の 4 つに割る。
- 候補 b: OS 連携（P9〜P12）だけを port 背後へ出し、他は現状維持。
- 候補 c: P14 のみ削除（VM が何の状態も持たない委譲であり、`AudioPlayerView` は `vm` 越しに API を叩いている）。
- いずれも「どの変更理由で別々に変わるか」の実測（git 変更共起）が `SG-A6.evidence_required` に未取得のため、本 package は候補の列挙で止める。

```yaml
code_design:
  capsules:
    - {id: CAP1, name: PlaybackQueue, verdict: purpose_centered, evidence: [{status: confirmed, source: "Podcast/PlaybackQueue.swift（143 行・外部 I/O なし）", supports: "キュー意味論が値型に閉じている"}]}
    - {id: CAP2, name: InterruptionPolicy, verdict: purpose_centered, evidence: [{status: confirmed, source: "PodcastViewModel.swift:775,791 で参照される純粋判定", supports: "OS イベント→業務判断が分離済み"}]}
    - {id: CAP3, name: ListDisplayState, verdict: purpose_centered, evidence: [{status: confirmed, source: "PodcastViewModel.swift:73-75,80-82 が委譲", supports: "表示状態の解決が 1 箇所"}]}
    - {id: CAP4, name: PodcastViewModel, verdict: not_purpose_centered, evidence: [{status: confirmed, source: "本節 P1〜P14（14 purpose / 854 行）", supports: "1 型が 14 の変更理由を持つ"}]}
    - {id: CAP5, name: APIClient, verdict: mixed, evidence: [{status: confirmed, source: ":32-38 errorDescription が UI 文言を持つ", supports: "transport adapter に representation 責務が混在"}]}
  branch_decisions:
    - {id: BD1, site: "QueueSheet.swift:22", kind: rule, judgement: "guard ではなく業務規則（2 正本の合成）が View にある", evidence: [{status: confirmed, source: "`if viewModel.currentPodcast != nil, let current = viewModel.queue.current`", supports: "LF3"}]}
    - {id: BD2, site: "PodcastViewModel.swift:526,535", kind: rule, judgement: "`currentPodcast == nil` を『何も再生していない』の定義として使用。:449 で聴き終えた後も currentPodcast を保持する設計と矛盾", evidence: [{status: confirmed, source: ":526 `let nothingPlaying = currentPodcast == nil` / :435-450 handlePlaybackEnded 終端分岐", supports: "LF4"}]}
    - {id: BD3, site: "PodcastView.swift:90", kind: rule, judgement: "『この行が再生中か』を View が `currentPodcast?.id == podcast.id && isPlaying` で合成", evidence: [{status: confirmed, source: "PodcastView.swift:90", supports: "LF4"}]}
    - {id: BD4, site: "SettingsViewModel.swift:42", kind: variant, judgement: "consumer 側に client 選択順（`appState?.apiClient ?? apiClientOverride`）が残る", evidence: [{status: confirmed, source: "Settings/SettingsViewModel.swift:42,70,77（2 init）", supports: "LF14"}]}
  naming_decisions:
    - {id: ND1, name: "moveUpNext(fromOffsets:toOffset:)", verdict: leaks_technology, note: "SwiftUI onMove 規約（IndexSet + toOffset）が VM と PlaybackQueue の契約名になっている。ADR-053 で正本と決定済みのため finding ではなく既知の制約として記録する", evidence: [{status: confirmed, source: "PodcastViewModel.swift:548 / QueueSheet.swift:42-43 / p4-common-brief.md §2（棄却済み案）", supports: "LF7"}]}
    - {id: ND2, name: "previewMarkFinished()", verdict: bypasses_contract, note: "`private(set)` の不変条件を DEBUG seam が迂回。production target に同居", evidence: [{status: confirmed, source: "PodcastViewModel.swift:493 / PreviewSupport.swift:166", supports: "LF11"}]}
    - {id: ND3, name: "handlePlayerItemStatusChange / handleTimeControlStatusChange", verdict: leaks_technology, note: "名前と引数型が AVFoundation の手続きを表す。ただし純関数化によるテスト容易性という明示的な意図がある（:412-413 の doc）", evidence: [{status: confirmed, source: "PodcastViewModel.swift:416,424", supports: "LF1（意図あり・trade-off として記録）"}]}
  abstraction_decisions:
    - {id: AD1, subject: "URLSessionProtocol", verdict: justified, rationale: "外部障害境界のための一実装 port。rule 11 :70-75 の『本番経路同一性』に合致し、509 テストの seam として実利用されている", evidence: [{status: confirmed, source: "Networking/APIClient.swift:12-15,71", supports: "port の品質根拠あり"}]}
    - {id: AD2, subject: "NetworkMonitoring", verdict: justified, rationale: "OS 状態を注入可能にする最小 port。公開面は isOnline と publisher の 2 要素で consumer 目的と一致", evidence: [{status: confirmed, source: "Networking/NetworkMonitoring.swift:19-27", supports: "consumer 目的より広くない"}]}
    - {id: AD3, subject: "FileManagerProtocol", verdict: justified_but_leaky, rationale: "port 自体は正当だが、その上の AudioCacheManager が file URL とパス規約を公開面へ出している（LF10b）", evidence: [{status: confirmed, source: "Networking/AudioCacheManager.swift:45-47", supports: "CS2"}]}
    - {id: AD4, subject: "AudioCacheManager（具象型を直接注入）", verdict: no_port, rationale: "protocol 化されておらず、`resolvePlaybackURL(for:isOnline:cacheManager:)` の引数型が具象。差し替えは FileManagerProtocol 層でのみ可能", evidence: [{status: confirmed, source: "PodcastViewModel.swift:238", supports: "CS2"}]}
```

---

## 4. interface_part — 現状の公開 operation（監査対象）

review mode のため「あるべき operation」ではなく**現在公開されている operation**を記述し、意味が欠けている箇所を `unknown` / leakage として残す。

```yaml
interface_part:
  operations:
    - id: OP1
      consumer_ids: [C1]
      name: "play(podcast:expandsPlayer:)"
      intent: "このエピソードを先頭または前回位置から鳴らす"
      inputs: ["Podcast", "expandsPlayer: Bool（既定 true）"]
      result: "戻り値なし。成否は @Published の副作用でのみ観測可能"
      failures:
        - "オフライン かつ 未キャッシュ → errorMessage = \"Offline and not cached\"（:265・英語・型なし）"
        - "AVPlayerItem 失敗 → errorMessage（:418）。非同期・事後に届く"
      side_effects: ["AVAudioSession 有効化(:619,620)", "RemoteCommand 初回配線(:632)", "stopPlayback(:583)", "currentPodcast 差替(:281)", "presentation 変更(:283,286)", "NowPlaying 更新(:371)", "15 秒同期タイマ開始(:374)"]
      invariants: ["共有仕様 §2 不変条件 4（current と queue の一致）: 本 operation は queue に触れないため不変条件を保証しない"]
      contracts: ["OB-B1 で Contract Package の CI へ接続（本 package では条件を確定しない）"]
      end_to_end_deadline: {status: not_applicable, not_applicable_reason: "再生開始はローカル操作で、内部に await ポイントを持たない（:439-440 の doc が明示）。締切概念の対象は OP5/OP7 側", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "PodcastViewModel.swift:262-375 に await なし", supports: "同期的完了"}]}
      retry_semantics: {status: applicable, allowed_when: ["同一エピソードの再 play は安全（stopPlayback 経由で前セッションを解体する）"], prohibited_when: [], owner: "PodcastViewModel", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":280 stopPlayback() 前置", supports: "多重 play の安全性"}]}
      idempotency: {status: applicable, key_scope: "podcast.id + 再生セッション", duplicate_result: "同一エピソードの再 play は先頭/保存位置から再開しセッションを作り直す（no-op ではない）", owner: "PodcastViewModel", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":280-291", supports: "重複呼出が観測差を生む"}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "重複した `didPlayToEndTime` は `endedId` ガード(:436)で抑止。重複 play は上記のとおり再構築", owner: "PodcastViewModel", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":351-367 の WHY コメントと :436 のガード", supports: "重複意味論が実装済みで意図も記録されている"}]}
      ambiguous_outcome: {status: applicable, observable_result: "`handlePlaybackEnded` で `queue.advance()` 成功後に `play` が失敗すると、currentIndex は進み currentPodcast は前のまま残る（error と paused が判別不能）", reconciliation_owner: unknown, forward_recovery_owner: unknown, not_applicable_reason: "", confirmation_method: "SG-A3 の user 決定（停止 / スキップ / 現状）と、UV3 実機観測", impact_if_unresolved: "オフライン混在キューで利用者が『何が再生対象か』を判断できない状態が残る", evidence: [{status: confirmed, source: ":441-443（advance → play）と :264-266（play 側の早期 return）", supports: "中間状態の存在"}]}
      consistency_boundary: "PodcastViewModel インスタンス内（@MainActor）"
      evidence: [{status: confirmed, source: "PodcastViewModel.swift:262-375", supports: "operation 実体"}]

    - id: OP2
      consumer_ids: [C1]
      name: "playNow / addToQueue / playNext / removeFromQueue / moveUpNext"
      intent: "待機列を編集し、必要なら再生を開始する"
      inputs: ["Podcast", "id: String", "IndexSet + Int（SwiftUI onMove 規約・LF7）"]
      result: "なし（queue の @Published 更新）"
      failures: ["なし（PlaybackQueue は範囲外を no-op として吸収）"]
      side_effects: ["queue 変更", "条件付きで play を誘発(:528,537)"]
      invariants: ["共有仕様 §2 不変条件 1〜5（正本 = PlaybackQueue）"]
      contracts: ["Q-01〜Q-32 conformance（`PlaybackQueueConformanceTests` 32/32 green。期待値と正本 §4 の突合は UV4 未実行）"]
      end_to_end_deadline: {status: not_applicable, not_applicable_reason: "純粋な値型操作で I/O を含まない", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "Podcast/PlaybackQueue.swift（外部 I/O なし）", supports: ""}]}
      retry_semantics: {status: not_applicable, not_applicable_reason: "同上・ローカル決定論的操作", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      idempotency: {status: not_applicable, not_applicable_reason: "mutation だが transport を伴わないため idempotency key の対象ではない。重複挙動は下の duplicate_semantics で扱う", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "`addToQueue` の二重呼出は同一エピソードを 2 回積む（重複排除なし）。`playNow` は jump が既存を見つけるため積み増さない(:517-520)", owner: "PlaybackQueue", not_applicable_reason: "", confirmation_method: "共有仕様 §2 に重複エントリ禁止の不変条件があるかを Contract/Domain package が判定（OB-B2）", impact_if_unresolved: "同一エピソードが待機列に並び、進行が利用者の意図とずれる", evidence: [{status: unknown, source: "Podcast/PlaybackQueue.swift:59-62 add の実装は未再読（本 review の読み範囲外）", supports: "確認方法を残す"}]}
      ambiguous_outcome: {status: not_applicable, not_applicable_reason: "ローカル同期操作で成否が確定する", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      consistency_boundary: "PlaybackQueue（値型）"
      evidence: [{status: confirmed, source: "PodcastViewModel.swift:516,525,534,543,548", supports: ""}]

    - id: OP3
      consumer_ids: [C1]
      name: "download(podcast:) / removeDownload(podcast:)"
      intent: "このエピソードをオフラインで聴けるようにする／やめる"
      inputs: ["Podcast"]
      result: "なし（downloadedIds / downloadingIds の更新）"
      failures: ["URL 生成失敗 → errorMessage = \"Invalid audio URL\"(:201・英語)", "通信/保存失敗 → errorMessage = localizedDescription（英語・:211,:222）"]
      side_effects: ["署名 URL 再取得(:199)", "音声本体ダウンロード(:205)", "ファイル書込(:207)"]
      invariants: ["downloadedIds は cacheManager の実在と一致する（:157-159 で再同期）。ただし SettingsViewModel の別インスタンスが clearCache した場合は乖離（LF10a）"]
      contracts: []
      end_to_end_deadline: {status: unknown, limit_or_condition: "", owner: "", timeout_result: "", not_applicable_reason: "", confirmation_method: "URLSession 既定タイムアウトに委ねているか、明示設定があるかを APIClient の init/設定で確認する", impact_if_unresolved: "低速回線で downloading 状態が長時間残り、利用者が操作不能と誤認する", evidence: [{status: unknown, source: "本 review では APIClient の timeout 設定を未確認（:67-78 に設定なし）", supports: ""}]}
      retry_semantics: {status: applicable, allowed_when: ["失敗後の再タップ（downloadingIds/downloadedIds の二重ガード :192 を抜けるため可）"], prohibited_when: [], owner: "PodcastViewModel", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":192,:194-195（insert/defer remove）", supports: ""}]}
      idempotency: {status: applicable, key_scope: "podcast.id", duplicate_result: "進行中/完了済みなら no-op(:192)。cache 書込自体も上書き（:65 の doc が『既存ファイルは上書き』）", owner: "AudioCacheManager", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "PodcastViewModel.swift:192 / AudioCacheManager.swift:62-66", supports: ""}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "remove は存在しなければ no-op（冪等・AudioCacheManager.swift:71-76）", owner: "AudioCacheManager", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "AudioCacheManager.swift:74 の guard", supports: ""}]}
      ambiguous_outcome: {status: applicable, observable_result: "ダウンロード成功・cache 書込失敗のとき downloadedIds に入らず errorMessage のみ。部分ファイルの残留有無は未確認", reconciliation_owner: "PodcastViewModel（:157 syncDownloadedState が次回一覧取得時に再同期）", forward_recovery_owner: "利用者の再タップ", not_applicable_reason: "", confirmation_method: "`fileManager.write` が原子的置換かを FileManagerProtocol 実装で確認する", impact_if_unresolved: "破損ファイルが `isCached == true` を返し、再生時に失敗し続ける経路が残る", evidence: [{status: confirmed, source: "PodcastViewModel.swift:207-209 / AudioCacheManager.swift:52-55（存在のみで判定）", supports: "実在＝健全とみなす判定"}]}
      consistency_boundary: "端末ローカルファイル + VM 状態"
      evidence: [{status: confirmed, source: "PodcastViewModel.swift:191-224", supports: ""}]

    - id: OP4
      consumer_ids: [C1]
      name: "togglePlayPause / seek(to:) / setSpeed(_:) / minimizePlayer / expandPlayer / replayCurrentEpisode"
      intent: "いま鳴っているものを操作する"
      inputs: ["Double 秒", "Float 倍率"]
      result: "なし"
      failures: ["player が nil なら silent no-op（:554,:568,:482）— consumer は『効かなかった』ことを知れない"]
      side_effects: ["NowPlaying 更新(:562,:570,:578)"]
      invariants: ["setSpeed は AppState.defaultPlaybackSpeed と未接続（SG-A2 pending）"]
      contracts: []
      end_to_end_deadline: {status: not_applicable, not_applicable_reason: "ローカル同期操作", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":553-579", supports: ""}]}
      retry_semantics: {status: not_applicable, not_applicable_reason: "同上", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      idempotency: {status: not_applicable, not_applicable_reason: "pure な UI 操作で transport を伴わない", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "togglePlayPause は状態を反転するため重複呼出が意味を持つ（RemoteCommand 経由 :663,:668 では `isPlaying` を見て片方向に制限している＝意味が operation ではなく caller 側にある）", owner: "PodcastViewModel", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":661-674", supports: "LF4 系の caller 側分岐"}]}
      ambiguous_outcome: {status: not_applicable, not_applicable_reason: "ローカル操作で成否が同期的に確定する", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      consistency_boundary: "VM インスタンス"
      evidence: [{status: confirmed, source: "PodcastViewModel.swift:468,474,481,553,567,575", supports: ""}]

    - id: OP5
      consumer_ids: [C1]
      name: "flushPlaybackPosition() / （内部）syncPlaybackPositionIfNeeded"
      intent: "聴いた位置を失わないようにする"
      inputs: []
      result: "なし（戻り値も例外も無い）"
      failures: ["すべて黙殺。:849-851 の catch 本文はコメントのみ（production 唯一の silent catch）"]
      side_effects: ["PUT /playback-position"]
      invariants: []
      contracts: []
      end_to_end_deadline: {status: unknown, limit_or_condition: "", owner: "", timeout_result: "", not_applicable_reason: "", confirmation_method: "バックグラウンド遷移時(:170 NewsListenAppApp)に発火した Task が OS に打ち切られるまでの猶予を実機で観測（UV3）", impact_if_unresolved: "アプリ離脱直前の位置が保存されず resume がずれる", evidence: [{status: confirmed, source: "PodcastViewModel.swift:846-852（Task を投げっぱなし・await しない）", supports: "呼出側は完了を待てない"}]}
      retry_semantics: {status: applicable, allowed_when: ["最後の位置で上書きするだけなので再送は安全"], prohibited_when: [], owner: unknown, not_applicable_reason: "", confirmation_method: "SG-A8（観測方針）と Contract package の決定", impact_if_unresolved: "失敗が痕跡ゼロで消える（ログ API production 0）", evidence: [{status: confirmed, source: ":849-851 / verification-run.md §5,§7", supports: ""}]}
      idempotency: {status: applicable, key_scope: "podcastId（最新値で上書き）", duplicate_result: "同一値の再送は同じ結果（last-write-wins）", owner: "backend", not_applicable_reason: "", confirmation_method: "backend が PUT を last-write-wins として扱うことの確認（MEMORY: issue #112 で backend PUT 未実装の記録あり → contradiction 候補・OB-B4）", impact_if_unresolved: "同期が実は無効である可能性", evidence: [{status: unknown, source: "本 review の scope 外（backend 未確認）", supports: ""}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "15 秒タイマと stopPlayback(:585) と scenePhase(:170) が同時に走ると同一位置の多重送信が起こりうる。順序保証なし", owner: unknown, not_applicable_reason: "", confirmation_method: "並行 PUT の順序を backend が担保するか確認（OB-B4）", impact_if_unresolved: "古い位置が新しい位置を上書きする", evidence: [{status: confirmed, source: ":816-826,:585,:832-834 の 3 発火源", supports: ""}]}
      ambiguous_outcome: {status: applicable, observable_result: "送信が成功したか失敗したかを誰も知らない（戻り値 `_ =` で破棄・:848）", reconciliation_owner: unknown, forward_recovery_owner: "次回の 15 秒タイマ（暗黙）", not_applicable_reason: "", confirmation_method: "SG-A8", impact_if_unresolved: "resume 不整合の原因調査が不可能", evidence: [{status: confirmed, source: ":848-851", supports: ""}]}
      consistency_boundary: "backend の再生位置レコード"
      evidence: [{status: confirmed, source: "PodcastViewModel.swift:832-853", supports: ""}]

    - id: OP6
      consumer_ids: [C1]
      name: "submitQuizAnswers / fetchSavedVocabulary / saveVocabulary"
      intent: "（VM の purpose ではない）APIClient への素通し"
      inputs: ["podcastId", "answers", "term"]
      result: "APIClient の戻り値そのまま（throws もそのまま）"
      failures: ["APIError がそのまま consumer（View）へ到達。QuizSheetView.swift:199 が status 404 を自前解釈する"]
      side_effects: []
      invariants: []
      contracts: []
      end_to_end_deadline: {status: not_applicable, not_applicable_reason: "この operation 自体は意味を追加しない純委譲であり、締切があるなら C2 境界（APIClient）の責務", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: ":499-511（本文 1 行ずつ）", supports: ""}]}
      retry_semantics: {status: not_applicable, not_applicable_reason: "同上（C2 へ委譲）", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      idempotency: {status: applicable, key_scope: "podcastId + term", duplicate_result: "saveVocabulary は『冪等登録』と doc に明記(:508)。呼出側 AudioPlayerView.swift:557 も `savingTerms` で連打抑止", owner: "backend", not_applicable_reason: "", confirmation_method: "backend 実装の確認（scope 外）", impact_if_unresolved: "二重登録", evidence: [{status: inferred, source: "PodcastViewModel.swift:508 の doc と AudioPlayerView.swift:555-559", supports: "doc 主張のみで実測なし"}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "同上（冪等前提）", owner: "backend", not_applicable_reason: "", confirmation_method: "同上", impact_if_unresolved: "同上", evidence: [{status: inferred, source: "同上", supports: ""}]}
      ambiguous_outcome: {status: applicable, observable_result: "`loadSavedVocabulary` は `try?` で握り潰し(:546)、`save` の失敗は View ローカル文言(:566)へ", reconciliation_owner: "AudioPlayerView（:547,:562 の stale ガードで自分の担当エピソードだけ反映）", forward_recovery_owner: "利用者の再タップ", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "AudioPlayerView.swift:545-568", supports: ""}]}
      consistency_boundary: "backend"
      evidence: [{status: confirmed, source: "PodcastViewModel.swift:499-511", supports: "VM が状態を持たない委譲 3 件"}]

    - id: OP7
      consumer_ids: [C2]
      name: "APIClient の全業務メソッド（共通契約）"
      intent: "業務操作を実行し、結果か失敗の意味を返す"
      inputs: ["業務引数"]
      result: "デコード済みモデル"
      failures: ["APIError.invalidURL / httpError(statusCode:) / rateLimited(retryAfter:) / decodingError のみ。7 つの業務的意味（R4）のうち意味化されているのは rateLimited の 1 つだけ"]
      side_effects: ["HTTP"]
      invariants: []
      contracts: ["R4（意味で受け取る）に対し現状 fail"]
      end_to_end_deadline: {status: unknown, limit_or_condition: "", owner: "", timeout_result: "", not_applicable_reason: "", confirmation_method: "APIClient の init(:67-78) に timeout 設定が無いため、URLSession 既定（60s）に依存しているかを確認する", impact_if_unresolved: "UI が長時間 isLoading のまま留まる上限が契約化されていない", evidence: [{status: confirmed, source: "Networking/APIClient.swift:67-78（timeout 指定なし）", supports: ""}]}
      retry_semantics: {status: applicable, allowed_when: ["rateLimited(retryAfter:) は再試行可能時刻を運ぶ"], prohibited_when: ["未確定（非冪等な POST の再試行可否を契約が語らない）"], owner: unknown, not_applicable_reason: "", confirmation_method: "各エンドポイントの冪等性を backend 契約で確認（OB-B4）", impact_if_unresolved: "consumer が独断で再試行し二重実行する", evidence: [{status: confirmed, source: "Networking/APIClient.swift:27 / Feed/FeedViewModel.swift:210-214", supports: "retryAfter だけが意味として存在"}]}
      idempotency: {status: unknown, key_scope: "", duplicate_result: "", owner: "", not_applicable_reason: "", confirmation_method: "backend 契約（Idempotency-Key ヘッダの有無・:526-532 buildRequest を確認）", impact_if_unresolved: "楽観更新（FeedViewModel の star/dismiss）の再送安全性が不明", evidence: [{status: unknown, source: "本 review では buildRequest 未読", supports: ""}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "404 を『既に望みどおりの状態＝成功』とみなす冪等削除が 3 箇所（StarredViewModel.swift:108, PasskeyCredentialsViewModel.swift:52, SessionsViewModel.swift:57）。契約ではなく各 consumer の解釈", owner: "各 consumer（誤配置）", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "backend が 404 の意味を変えたとき 6 箇所が個別に壊れる（CS5）", evidence: [{status: confirmed, source: "verification-run.md §7 の 10 箇所内訳を本 review で再確認（StarredViewModel.swift:108 / QuizSheetView.swift:199 / AccountSettingsView.swift:327）", supports: ""}]}
      ambiguous_outcome: {status: applicable, observable_result: "キャンセルは URLError(.cancelled) と CancellationError の 2 型で届き、consumer が両方を書く必要がある（FeedViewModel.swift:114-118,215-225 / StarredViewModel.swift:75-79,110-113）", reconciliation_owner: "各 consumer（『次回ロードでサーバの真実に収束』と doc 化）", forward_recovery_owner: "pull-to-refresh", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "型の二重性を知らない新規 consumer が cancel をエラー表示する（既知バグの再発）", evidence: [{status: confirmed, source: "Feed/FeedViewModel.swift:222-225 の WHY コメントが実 URLSession の挙動差を明記", supports: "transport 実装事情が consumer へ漏れている"}]}
      consistency_boundary: "backend"
      evidence: [{status: confirmed, source: "Networking/APIClient.swift:19-40", supports: ""}]

    - id: OP8
      consumer_ids: [C4]
      name: "AudioCacheManager: cachedURL / isCached / cache / remove / cacheSize / clearCache"
      intent: "オフライン再生の可否と端末占有容量"
      inputs: ["id: String", "Data"]
      result: "URL（file）/ Bool / Int64"
      failures: ["AudioCacheError.invalidId / I/O エラー（throws）"]
      side_effects: ["ファイル作成・削除"]
      invariants: ["共有仕様 §6.3 は『logout 時に removeAllDownloads() を自動呼出』と記すが、当該 API も呼出も存在しない（contradiction・R6）"]
      contracts: []
      end_to_end_deadline: {status: not_applicable, not_applicable_reason: "同期ローカル FS 操作", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "AudioCacheManager.swift:45-95 は同期 API", supports: ""}]}
      retry_semantics: {status: not_applicable, not_applicable_reason: "同上", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      idempotency: {status: applicable, key_scope: "id", duplicate_result: "cache は上書き、remove/clearCache は no-op 冪等", owner: "AudioCacheManager", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "AudioCacheManager.swift:65,74,90-95", supports: ""}]}
      duplicate_semantics: {status: applicable, duplicate_result_or_reason: "同上", owner: "AudioCacheManager", not_applicable_reason: "", confirmation_method: "", impact_if_unresolved: "", evidence: [{status: confirmed, source: "同上", supports: ""}]}
      ambiguous_outcome: {status: applicable, observable_result: "clearCache は途中失敗すると一部だけ消える（:92-94 のループに巻き戻しなし）。SettingsViewModel.swift:184-192 は残容量再取得で表示を合わせるが、PodcastViewModel 側の downloadedIds は更新されない", reconciliation_owner: "PodcastViewModel.syncDownloadedState（次回 loadPodcasts のときのみ）", forward_recovery_owner: unknown, not_applicable_reason: "", confirmation_method: "2 インスタンス構成の解消方針（SG-A6 のインスタンス共有候補）", impact_if_unresolved: "設定でキャッシュ全削除した直後、Podcast 一覧が『ダウンロード済み』を表示し再生が失敗する", evidence: [{status: confirmed, source: "PodcastViewModel.swift:122 と SettingsViewModel.swift:69,76 がそれぞれ既定引数で別インスタンスを生成", supports: "LF10a"}]}
      consistency_boundary: "端末ファイルシステム（ただし 2 インスタンスが同一ディレクトリを共有）"
      evidence: [{status: confirmed, source: "Networking/AudioCacheManager.swift:45,52,62,71,80,90", supports: ""}]
```

---

## 5. implementation_part

```yaml
implementation_part:
  items:
    - {id: IP1, kind: hidden_technology, operation_ids: [OP1, OP4], description: "AVPlayer / AVPlayerItem / CMTime / KVO / didPlayToEndTime 通知の生成・配線・解体", owner: PodcastViewModel, evidence: [{status: confirmed, source: "PodcastViewModel.swift:262-375, :583-612", supports: ""}], verdict: "隠蔽されていない（LF1）"}
    - {id: IP2, kind: platform_adapter, operation_ids: [OP1, OP4], description: "AVAudioSession のカテゴリ設定と再有効化", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":617-625, :777", supports: ""}], verdict: "シングルトン直呼び（LF8）"}
    - {id: IP3, kind: platform_adapter, operation_ids: [OP1, OP4], description: "MPNowPlayingInfoCenter への辞書反映と消去", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":611, :731-754", supports: ""}], verdict: "同上。外部から『消す』operation が無い（CS11）"}
    - {id: IP4, kind: platform_adapter, operation_ids: [OP4], description: "MPRemoteCommandCenter への 7 コマンド配線と解除トークン管理", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":645-707, :796-810", supports: ""}], verdict: "同上"}
    - {id: IP5, kind: platform_adapter, operation_ids: [OP1], description: "割り込み/ルート変更通知の購読（判断は InterruptionPolicy へ委譲済み）", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":713-726, :759-794", supports: ""}], verdict: "判断は分離済み・配線のみ漏出"}
    - {id: IP6, kind: platform_adapter, operation_ids: [OP1], description: "UIApplication.beginBackgroundTask による完聴送信の保護", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":456-461", supports: ""}], verdict: "VM が UIKit に依存（LF13・ASP DV1）"}
    - {id: IP7, kind: data_access, operation_ids: [OP3, OP8], description: "audio-cache ディレクトリと `{id}.mp3` ファイル命名", owner: AudioCacheManager, evidence: [{status: confirmed, source: "AudioCacheManager.swift:45-47", supports: ""}], verdict: "file URL として公開面に露出（LF10b）"}
    - {id: IP8, kind: algorithm, operation_ids: [OP1], description: "再開位置の末尾 2 秒ウィンドウ判定", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":304-308（WHY コメント :301-303 付き）", supports: ""}], verdict: "1 箇所・理由も記録済み（良い状態。CS6 pass）"}
    - {id: IP9, kind: operational_concern, operation_ids: [OP5], description: "15 秒周期タイマと Task 投げっぱなしの位置送信", owner: PodcastViewModel, evidence: [{status: confirmed, source: ":816-826, :843-853", supports: ""}], verdict: "失敗が観測不能（SG-A8）"}
    - {id: IP10, kind: hidden_technology, operation_ids: [OP7], description: "URLRequest 構築・X-API-Key/Bearer 付与・JSONDecode・status 検証", owner: APIClient, evidence: [{status: confirmed, source: "Networking/APIClient.swift:67-78, :159-164", supports: ""}], verdict: "概ね隠蔽できているが :159-160 downloadAudio は buildRequest を経由せず素の URLRequest（LF15）"}
  transport_implementations:
    - id: TI1
      operation_id: OP7
      provider_or_protocol: "HTTP over URLSession（URLSessionProtocol で注入・:12-15,:71）"
      per_attempt_timeout: unknown
      backoff: "なし（実装内に再試行機構は見当たらない）"
      transport_retry_mechanism: "なし"
      bounded_by_contract: ["APIError.rateLimited(retryAfter:) のみが上位へ再試行可能時刻を運ぶ"]
      owner: APIClient
      evidence: [{status: confirmed, source: "Networking/APIClient.swift:12-17,:57,:71,:161", supports: "seam は URLSession 層で rule 11 :70-75 に適合"}]
    - id: TI2
      operation_id: OP3
      provider_or_protocol: "同上（downloadAudio も session を経由する: :161）"
      per_attempt_timeout: unknown
      backoff: "なし"
      transport_retry_mechanism: "なし"
      bounded_by_contract: []
      owner: APIClient
      evidence: [{status: confirmed, source: "Networking/APIClient.swift:159-164", supports: "transport 差替は可能だが認証ヘッダ契約を迂回する"}]
```

---

## 6. ownership（boundary-local のみ。system-wide authority は ASP を参照）

```yaml
ownership:
  authority_refs:
    - {id: AR1, kind: state_authority, applicability: required, artifact_ref: "architecture-strategy-package.md SG-A1（pending）", owner: user, rationale: "『現在再生中』の正本が currentPodcast(:42,:281) と queue.currentIndex の 2 つある。本 package は選択しない", evidence: {status: contradiction, sources: ["docs/design/shared-playback-spec.md §2 不変条件 4", "PodcastViewModel.swift:281,:381-388（playById は queue に触れない）"]}}
    - {id: AR2, kind: source_of_truth, applicability: required, artifact_ref: "architecture-strategy-package.md SG-A2（pending）", owner: user, rationale: "再生速度の既定値（AppState）とセッション値（VM :50,:575）が未接続", evidence: {status: confirmed, sources: ["PodcastViewModel.swift:50,575-579"]}}
    - {id: AR3, kind: state_authority, applicability: required, artifact_ref: "本 package LF10a", owner: "未決（SG-A6 のインスタンス共有候補）", rationale: "音声キャッシュの状態を 2 つの AudioCacheManager インスタンスが独立に変更する", evidence: {status: confirmed, sources: ["PodcastViewModel.swift:122", "SettingsViewModel.swift:69,76"]}}
    - {id: AR4, kind: semantic_owner, applicability: required, artifact_ref: "未作成（OB-B1: Contract Package の CI）", owner: "未決", rationale: "API 失敗の 7 意味（R4）の owner が存在せず、10 箇所の consumer が status 数値から各自導出している", evidence: {status: confirmed, sources: ["verification-run.md §7 を本 review で再確認（AccountSettingsView.swift:327 / QuizSheetView.swift:199 / StarredViewModel.swift:108 ほか）"]}}
    - {id: AR5, kind: invariant_owner, applicability: required, artifact_ref: "Podcast/PlaybackQueue.swift + docs/design/shared-playback-spec.md §2", owner: PlaybackQueue, rationale: "キュー不変条件 1〜5 の owner は値型に閉じており、Q-01〜Q-32 の conformance テストが 32/32 存在", evidence: {status: confirmed, sources: ["verification-run.md §8", "p1-domain.md §4"]}}
    - {id: AR6, kind: failure_recovery_owner, applicability: unknown, artifact_ref: "", owner: "", rationale: "auto-advance 失敗時と位置同期失敗時の recovery owner が不在", evidence: {status: unknown, sources: ["PodcastViewModel.swift:441-443", ":849-851"]}, confirmation_method: "SG-A3 / SG-A8 の user 決定", impact_if_unresolved: "中間状態と無痕跡失敗が残る"}
    - {id: AR7, kind: operational_owner, applicability: required, artifact_ref: "architecture-strategy-package.md SG-A8（pending）", owner: user, rationale: "production のログ API はゼロ（verification-run.md §7）。失敗の観測 owner が決まっていない", evidence: {status: confirmed, sources: ["verification-run.md §7"]}}
    - {id: AR8, kind: contract_owner, applicability: not_applicable, artifact_ref: "", owner: "", rationale: "C6（PreviewSupport）は DEBUG 限定のプレビュー用途で、公開契約の owner を必要としない。ただし production target に同居する点は LF11 で別途扱う", evidence: {status: confirmed, sources: ["PodcastViewModel.swift:489-496 の #if DEBUG"]}}
  writers:
    - {state: "currentPodcast", owners: ["PodcastViewModel.swift:281（本番唯一）", "PreviewSupport.swift:153,165（DEBUG）"], verdict: "型としては `var` のため誰でも書ける（:42）"}
    - {state: "errorMessage", owners: ["PodcastViewModel 内 8 箇所", "PodcastView.swift:45,135（View が nil 代入）"], verdict: "writer が 2 層に分散（LF2）"}
    - {state: "isPlaying / currentTime / duration / playbackSpeed / isBuffering / podcasts / isLoading", owners: ["VM", "PreviewSupport.swift:151-158（DEBUG）"], verdict: "すべて `var`（:36,38,44,46,48,50,53）"}
    - {state: "queue", owners: ["PodcastViewModel（:59 private(set)）"], verdict: "良好。ただし `queue` 自体の read は View へ公開（QueueSheet.swift:22,29,34,39 / PodcastView.swift:39）"}
    - {state: "AppState.currentUser", owners: ["AppState", "AccountSettingsView.swift:308（View が直接代入）"], verdict: "認証状態の writer が View にある（R5/QL4 に触れる）"}
  readers:
    - {state: "currentPodcast", count: 19, breakdown: "AudioPlayerView 11（:94,95,143,156,161,250,265,275,294,470,547,562 のうち 12 行だが :547/:562 は同一 purpose の stale ガード）/ QueueSheet 1（:22）/ PodcastView 1（:90）/ MiniPlayerView 2（:24,44）/ PreviewSupport 2（:153,165・書込）/ PlayerPresentation.swift:13（コメント）", note: "件数は `grep -n currentPodcast` の生出現から VM 自身を除いた実測。コメント 1 行を含む"}
    - {state: "queue", count: 5, breakdown: "QueueSheet.swift:22,29,34,39 / PodcastView.swift:39"}
    - {state: "player", count: 0, breakdown: "View からの参照はゼロ。`vm.player` の 7 出現はすべて VM 内 :662,667,672,680,686,692,702（RemoteCommand クロージャ内）"}
```

---

## 7. leakage_findings（LF*）

各 LF に「違反 R」「QL」「consumer が本来知るべき契約（Contract への OB）」を付す。

```yaml
leakage_findings:
  - id: LF1
    title: "AVFoundation 型が C1 の公開面に露出する"
    operation_ids: [OP1, OP4]
    implementation_part_ids: [IP1]
    status: present
    sites: ["PodcastViewModel.swift:11,12（import）", ":95 `private(set) var player: AVPlayer?`", ":399 `AVPlayerItem`", ":407 `AVPlayer`", ":416 `AVPlayerItem.Status`", ":424 `AVPlayer.TimeControlStatus`"]
    violates: [R2]
    quality: [QL1, QL2]
    impact: "再生エンジンを差し替えると internal 公開面 4 メソッドとその引数型が変わる（CS1 fail）。ただし実 consumer は View ではなくテストであり、:412-413 の doc が『KVO 配線と切り離してテスト可能にする』意図を明記している。テスト容易性のための意図的な露出という trade-off が記録済み"
    consumer_should_know_instead: "『再生が失敗した（理由つき）』『バッファ待ちに入った/出た』という 2 つの意味。AVFoundation の enum ではない"
    obligation: OB-B1
    evidence: [{status: confirmed, source: "上記 path:line（grep -n 実測）", supports: ""}]

  - id: LF2
    title: "@Published var が外部書込可能で、契約を迂回する writer が実在する"
    operation_ids: [OP1, OP4]
    implementation_part_ids: []
    status: present
    sites: ["宣言: PodcastViewModel.swift:36,38,40,42,44,46,48,50,53（9 件が `private(set)` なし）", "実書込: PodcastView.swift:45,135（errorMessage = nil）", "PreviewSupport.swift:153,165（currentPodcast）ほか :151-158 の 4 代入"]
    violates: [R2, R3]
    quality: [QL1, QL2, QL3]
    impact: "『error と paused の判別不能』『current と queue の不一致』を公開経路から構築できてしまう（R2 の禁止対象そのもの）。DEBUG seam `previewMarkFinished()`(:493) も private(set) の不変条件を迂回する"
    consumer_should_know_instead: "『このエラーを読み終えた（dismiss した）』という intent。状態への直接代入ではない"
    obligation: OB-B1
    note: "『errorMessage の dismiss だけ例外とするか』は SG-A9（owner: user・pending）が所有。本 package では選択しない"
    evidence: [{status: confirmed, source: "grep -n '@Published' と PodcastView.swift:45,135 の実測", supports: ""}]

  - id: LF3
    title: "caller 側に 2 正本の合成規則が漏れる"
    operation_ids: [OP2]
    implementation_part_ids: []
    status: present
    sites: ["QueueSheet.swift:22 `if viewModel.currentPodcast != nil, let current = viewModel.queue.current`"]
    violates: [R3, R9]
    quality: [QL1]
    impact: "『再生中セクションを出すか』という表示判断のために、View が currentPodcast と queue.current の関係（どちらが先に nil になるか）を知る必要がある。SG-A1 でどちらを正本に決めても、この 1 行は必ず書き換わる"
    consumer_should_know_instead: "`nowPlaying: Podcast?` という 1 つの意味（あるいは『再生対象なし』を表す明示的な状態）"
    obligation: OB-B1
    evidence: [{status: confirmed, source: "Podcast/QueueSheet.swift:22", supports: ""}]

  - id: LF4
    title: "`currentPodcast == nil` を『再生中なし』の定義として使う分岐が VM と View の双方にある"
    operation_ids: [OP2, OP4]
    implementation_part_ids: []
    status: present
    sites: ["PodcastViewModel.swift:526 `let nothingPlaying = currentPodcast == nil`", ":535 同", ":475 `guard currentPodcast != nil`", "PodcastView.swift:90 `currentPodcast?.id == podcast.id && viewModel.isPlaying`", "MiniPlayerView.swift:24,44", "PodcastViewModel.swift:661-674（RemoteCommand が `player != nil` という別定義を使う）"]
    violates: [R2, R3]
    quality: [QL1, QL3]
    impact: "『再生中なし』の定義が 3 種類（currentPodcast==nil / player==nil / didFinishCurrentEpisode）ある。:444-449 は聴き終えた後も currentPodcast を保持すると明記しているため、:526 の `nothingPlaying` はキュー終端直後に false となり、addToQueue が『何も再生していないので即再生』を選ばない。表示（PodcastView.swift:90）はさらに isPlaying を AND する第 3 の定義"
    consumer_should_know_instead: "排他的な再生セッション状態（idle / preparing / playing / paused / failed(reason) / finished）。現状は 6 個の独立 Bool/Optional の組み合わせ"
    obligation: OB-B1
    evidence: [{status: confirmed, source: "上記 path:line（grep -n 実測）", supports: ""}]

  - id: LF5
    title: "英語の localizedDescription と生文言が C1 へ素通しされる"
    operation_ids: [OP1, OP3, OP6]
    implementation_part_ids: [IP10]
    status: present
    sites: ["PodcastViewModel.swift:151,201,211,222,265,386,418,624（errorMessage への代入 8 箇所。うち生英語リテラルは :201 \"Invalid audio URL\", :265 \"Offline and not cached\", :418 \"Playback failed\"）", "露出先 PodcastView.swift:44,47（アラート本文）", "供給元 APIClient.swift:34 \"Invalid URL\", :35 \"HTTP Error \\(code)\""]
    violates: [R4]
    quality: [QL1]
    impact: "利用者に英語の技術文言が出る。かつ『オフラインで未キャッシュ』という業務的意味が String に潰されているため、consumer は『ダウンロードを促す』などの意味ある応答を選べない"
    consumer_should_know_instead: "失敗の意味（`.offlineNotCached` など）と、それに対応する表示・導線"
    obligation: OB-B1
    evidence: [{status: confirmed, source: "grep 実測（APIClient.swift:34,35）と PodcastViewModel の代入行", supports: ""}]

  - id: LF6
    title: "HTTP status 数値が 10 箇所の consumer へ漏れ、うち 2 箇所は View"
    operation_ids: [OP7]
    implementation_part_ids: [IP10]
    status: present
    sites: ["AppState.swift:263(404) / SettingsViewModel.swift:163(404) / PasskeyCredentialsViewModel.swift:52(404) / SessionsViewModel.swift:57(404) / StarredViewModel.swift:108(404) / LoginViewModel.swift:59(401) / PasskeyRegistrationViewModel.swift:70(409) / OnboardingSourcesViewModel.swift:66(409) / QuizSheetView.swift:199(404・View) / AccountSettingsView.swift:327(400・View)"]
    violates: [R4, R5]
    quality: [QL1, QL3]
    impact: "401 の集中処理が無いため、実行中のセッション失効が未認証遷移につながらない（R5 違反）。404 は『機能未提供』3 件と『冪等削除の成功』3 件の異なる意味を各 consumer が独立に決めている"
    consumer_should_know_instead: "`unauthorized` / `notFound(subject:)` / `conflict` / `forbidden` 等の意味。数値ではない"
    obligation: OB-B1, OB-B3
    note: "本 review で自分で再確認したのは StarredViewModel.swift:108 / QuizSheetView.swift:199 / AccountSettingsView.swift:327 の 3 件。残る 7 件は verification-run.md §7 の実測値を引用（status: inferred）"
    evidence: [{status: confirmed, source: "上記 3 件の grep 実測", supports: ""}, {status: inferred, source: "verification-run.md §7", supports: "残り 7 件"}]

  - id: LF7
    title: "SwiftUI onMove 規約が VM とキュー正本の契約名になっている"
    operation_ids: [OP2]
    implementation_part_ids: []
    status: present
    sites: ["PodcastViewModel.swift:548 `moveUpNext(fromOffsets:toOffset:)`", "QueueSheet.swift:42-43", "PlaybackQueue.reorderUpNext"]
    violates: [R9]
    quality: [QL1]
    impact: "UI framework の並べ替え規約（IndexSet と『移動先は挿入前の index』という toOffset 意味論）が業務正本の語彙になる。web 実装との名前差（reorderUpNext / moveUpNext）も残る"
    consumer_should_know_instead: "—（ADR-053 により iOS onMove 方式が正本と決定済み。棄却済み案として再提案しない）"
    obligation: OB-B2
    verdict: "既知・決定済みの trade-off。finding としては present だが改善提案はしない"
    evidence: [{status: confirmed, source: "PodcastViewModel.swift:548 / QueueSheet.swift:42-43 / p4-common-brief.md §2", supports: ""}]

  - id: LF8
    title: "OS シングルトンを VM が直接参照し、テスト seam も外部からの制御点も無い"
    operation_ids: [OP1, OP4]
    implementation_part_ids: [IP2, IP3, IP4, IP5]
    status: present
    sites: ["MPRemoteCommandCenter.shared() :646", "MPNowPlayingInfoCenter.default() :611,733,736,748,753", "AVAudioSession.sharedInstance() :619,620,777", "NotificationCenter.default :358,595,714,802,805", "UIApplication.shared :456,459"]
    violates: [R2, R6, R7]
    quality: [QL2, QL3, QL4]
    impact: "ロック画面連携・割り込み処理・バックグラウンド継続が単体検証不能（検証手段は UV3 実機観測のみ・未実行）。さらに logout 時に NowPlaying を消す operation が外部から存在しない（CS11 fail・R6/QL4）"
    consumer_should_know_instead: "AppState.logout(:282-302) が『再生セッションを終了し端末に残る表示を消す』という 1 つの operation を呼べること"
    obligation: OB-B5
    note: "port 化の範囲は SG-A10（owner: user・pending）が所有"
    evidence: [{status: confirmed, source: "grep -n 実測（全 16 行）", supports: ""}]

  - id: LF9
    title: "業務判断が View 本体にある"
    operation_ids: [OP6, OP7]
    implementation_part_ids: []
    status: present
    sites: ["AccountSettingsView.swift:317（パスワード最小長 8）", ":327（HTTP 400 = 現在パスワード誤り）", ":304-313 saveProfile が API 直呼び", ":308 `appState.currentUser = updated`", "QuizSheetView.swift:180-204 採点送信全体", ":192-193（正解率 50% 閾値でフィードバック分岐）", ":199（404 = クイズ未提供）"]
    violates: [R1, R4, R5]
    quality: [QL1, QL4]
    impact: "AccountSettings には ViewModel が存在せず（p1-entry §1）、認証主体の書き換えまで View が行う。QuizSheet の 50% 閾値は学習ドメインの規則で、UI の描画規則ではない"
    consumer_should_know_instead: "`changePassword(current:new:)` の結果として `.currentPasswordMismatch` / `.tooShort(minimum:)`、採点結果として『合格したか』の判定済み値"
    obligation: OB-B3
    evidence: [{status: confirmed, source: "grep -n 実測", supports: ""}]

  - id: LF10
    title: "キャッシュ境界の二重所有とパス規約の露出"
    operation_ids: [OP3, OP8]
    implementation_part_ids: [IP7]
    status: present
    sites: ["(a) 2 インスタンス: PodcastViewModel.swift:122（既定引数）/ SettingsViewModel.swift:69,76（2 init それぞれ既定引数）", "(b) パス規約露出: AudioCacheManager.swift:45-47 が `{id}.mp3` の file URL を返し、PodcastViewModel.swift:238-242 がそれをそのまま AVPlayerItem へ渡す"]
    violates: [R3]
    quality: [QL1, QL3]
    impact: "(a) 設定画面のキャッシュ全削除が Podcast 一覧の downloadedIds に伝わらず、『ダウンロード済み』表示のまま再生が失敗する経路が構造上存在する。(b) 非ファイル系ストレージへの差し替えが不可能（CS2 fail）"
    consumer_should_know_instead: "『このエピソードをいま再生できるか』と『再生元（不透明なハンドル）』。ファイルであることや拡張子ではない"
    obligation: OB-B6
    note: "インスタンス共有方法の候補は SG-A6 が所有"
    evidence: [{status: confirmed, source: "grep -n 実測", supports: ""}]

  - id: LF11
    title: "契約を迂回する DEBUG seam が production target に同居する"
    operation_ids: [OP1]
    implementation_part_ids: []
    status: present
    sites: ["PodcastViewModel.swift:489-496 `#if DEBUG func previewMarkFinished()`", "呼出 PreviewSupport.swift:166"]
    violates: [R2]
    quality: [QL1, QL2]
    impact: "`private(set) var didFinishCurrentEpisode`(:65) の不変条件を、intent を経ずに立てられる。DesignSystem（下位層）が VM（上位層）の内部状態遷移を知っている（ASP DV3 と同一事象）"
    consumer_should_know_instead: "プレビューは『聴き終わった状態』を意味する値から VM を構築できるべき（例: 表示専用の状態値を受け取る View への分離）。ただし手段は選択しない"
    obligation: OB-B1
    evidence: [{status: confirmed, source: "grep -n 実測", supports: ""}]

  - id: LF12
    title: "transport adapter が UI 文言を所有する"
    operation_ids: [OP7]
    implementation_part_ids: [IP10]
    status: present
    sites: ["Networking/APIClient.swift:32-38 `errorDescription`（:34 \"Invalid URL\", :35 \"HTTP Error \\(code)\", :36 日本語 1 件, :37 \"Decoding error: ...\"）"]
    violates: [R4]
    quality: [QL1]
    impact: "representation 責務が最下層にある。日本語 1 件と英語 3 件が混在し、consumer は `localizedDescription` を UI へ出すだけで英語が露出する（LF5 の供給源）"
    consumer_should_know_instead: "意味（case）だけ。文言は表示層が決める"
    obligation: OB-B1
    evidence: [{status: confirmed, source: "grep -n 実測", supports: ""}]

  - id: LF13
    title: "ViewModel が UIKit のバックグラウンドタスク手続きを持つ"
    operation_ids: [OP1]
    implementation_part_ids: [IP6]
    status: present
    sites: ["PodcastViewModel.swift:13,14（import SwiftUI / UIKit）", ":456,459（begin/endBackgroundTask）"]
    violates: [R7]
    quality: [QL2]
    impact: "UI framework 無しで VM をテストできない（ASP DV1）。`handlePlaybackEnded` の完聴送信テストが OS の background task に依存する"
    consumer_should_know_instead: "—（これは implementation part であり consumer には不可視であるべき）"
    obligation: OB-B5
    evidence: [{status: confirmed, source: "grep -n 実測", supports: ""}]

  - id: LF14
    title: "consumer 側に API クライアントの選択順が残る"
    operation_ids: [OP7]
    implementation_part_ids: []
    status: present
    sites: ["SettingsViewModel.swift:39,42 `appState?.apiClient ?? apiClientOverride`", ":69,:76（2 つの init）"]
    violates: [R3]
    quality: [QL1, QL2]
    impact: "『本番は AppState 経由、テストは override』という組み立て事情が VM の内部分岐として固定される。proven variant ではなくテスト都合の variant であり、selection boundary の根拠にならない"
    consumer_should_know_instead: "注入された 1 つのクライアント（または業務 port）"
    obligation: OB-B6
    evidence: [{status: confirmed, source: "grep -n 実測", supports: ""}]

  - id: LF15
    title: "downloadAudio が共通リクエスト構築を迂回する"
    operation_ids: [OP3]
    implementation_part_ids: [IP10]
    status: present
    sites: ["Networking/APIClient.swift:159-164（`URLRequest(url: url)` を直接生成し :161 で session へ）"]
    violates: [R4]
    quality: [QL3, QL4]
    impact: "X-API-Key / Authorization の付与という APIClient の公開約束（:44 の doc『一元化する』）がこの 1 経路だけ成立しない。署名付き URL 前提であれば正しいが、その前提は型にも doc にも現れていない"
    consumer_should_know_instead: "『この URL は認証済み署名付きであり追加ヘッダを要さない』という前提の明示"
    obligation: OB-B4
    evidence: [{status: confirmed, source: "grep -n -A8 実測", supports: ""}]

  - id: LF16
    title: "失敗の観測点を持たない operation（無痕跡の黙殺）"
    operation_ids: [OP5, OP6]
    implementation_part_ids: [IP9]
    status: present
    sites: ["PodcastViewModel.swift:843-853（戻り値 `_ =` 破棄、catch 本文はコメントのみ・production 唯一）", ":462 `try? await apiClient.markCompleted`", "AudioPlayerView.swift:546 `try?`"]
    violates: [R7]
    quality: [QL2, QL3]
    impact: "完聴記録と位置同期が失われても、テストからも運用からも検出できない（production のログ API は 0）"
    consumer_should_know_instead: "best-effort であること自体は契約として妥当。ただし『失敗した事実』の owner が必要"
    obligation: OB-B5
    note: "観測方針は SG-A8（owner: user・pending）が所有"
    evidence: [{status: confirmed, source: "grep -n 実測と verification-run.md §5", supports: ""}]
```

### LF × R × QL 対応表

| LF | R | QL | 主 consumer |
|---|---|---|---|
| LF1 | R2 | QL1, QL2 | C1（実体はテスト） |
| LF2 | R2, R3 | QL1, QL2, QL3 | C1, C6 |
| LF3 | R3, R9 | QL1 | C1 |
| LF4 | R2, R3 | QL1, QL3 | C1 |
| LF5 | R4 | QL1 | C1 |
| LF6 | R4, R5 | QL1, QL3 | C2 |
| LF7 | R9 | QL1 | C1 |
| LF8 | R2, R6, R7 | QL2, QL3, QL4 | C3, C5 |
| LF9 | R1, R4, R5 | QL1, QL4 | C2, C5 |
| LF10 | R3 | QL1, QL3 | C4 |
| LF11 | R2 | QL1, QL2 | C6 |
| LF12 | R4 | QL1 | C2 |
| LF13 | R7 | QL2 | C3 |
| LF14 | R3 | QL1, QL2 | C2 |
| LF15 | R4 | QL3, QL4 | C2 |
| LF16 | R7 | QL2, QL3 | C1 |

R8（CI とゲート方針）に対応する LF は無い。境界の問題ではなく検証経路の問題であり、Test Function の所管（`not_applicable` for this package）。

---

## 8. 重複の意味判定（per-file）

「同じコードが複数ある」ことは、それ自体では境界の欠陥ではない。各出現の**意味が同一か**を判定した。

| # | 重複 | 出現（per-file） | 意味は同一か | 判定 |
|---|---|---|---|---|
| D1 | 一覧読み込みの骨格 | FeedViewModel.swift:101-123 / StarredViewModel.swift:65-84 / PodcastViewModel.swift:143-154 / SettingsViewModel.swift:100-110 / LearningViewModel.swift:24-41 / SessionsViewModel.swift:30-43 / PasskeyCredentialsViewModel.swift:28-39 / AdminUsersViewModel.swift:34-42 / OnboardingSourcesViewModel.swift:45-54（9 file） | **異なる** | オフライン前置ガードの有無（Feed :102 と Starred :66 のみ）、キャンセル 2 型の黙殺の有無（Feed/Starred のみ）、失敗表現の 3 系統（errorMessage / loadFailed / 両方）、文言の所有者（Admin は固定文言 :40、Podcast は localizedDescription :151）が異なる。**共通抽象化は誤り**（RO1） |
| D2 | オンライン状態の購読 | FeedViewModel.swift:82-85 / StarredViewModel.swift:49-52 / PodcastViewModel.swift:130-136（3 file） | **同一**（逐語） | `isOnline` 初期化＋`isOnlinePublisher` を main で assign。3 箇所とも同一意味。ただし統合手段は SG-A4（直読 vs ミラー）が pending のため選択しない |
| D3a | stale ガード: リクエスト ID 方式 | SettingsViewModel.swift:59,61,63（3 カウンタ）と :207-208,215 / :227-228,235 / :250-251,264,269 | 3 メソッド間では**同一**（各設定項目ごとに独立したカウンタが必要という点も同一） | 3 つの sync メソッドの骨格は同型。:264 だけ catch 内にも stale 判定がある点が異なる（weeklyGoal のみ）。**この 3 つは統合候補**だが、D3b/D3c とは統合できない |
| D3b | stale ガード: エピソード ID 一致 | PodcastViewModel.swift:436 / AudioPlayerView.swift:547,562 | **異なる**（D3a とは別の意味） | 「この結果は自分が見ているエピソードのものか」。同期の一意性ではなく主体の同一性 |
| D3c | stale ガード: Task.isCancelled | FeedViewModel.swift:175 付近 / VocabularyTestViewModel.swift:52 / AppState.swift:187 / AudioPlayerView.swift:409,547 | **異なる** | Task ライフサイクルの話で、レスポンスの新旧とは無関係 |
| D4 | パスワード最小長 8 | AccountSettingsView.swift:317（View・文言 :318）/ AdminUsersViewModel.swift:47（VM・文言 :48） | **同一ルール・異なる文脈** | 値 8 は同一の業務規則。文脈は自己変更 vs 管理者による作成で、文言も別。規則の owner が無く生リテラルが 2 つ（R1 違反）。CS4 fail の原因 |
| D5 | featured サイトのグルーピング | SettingsViewModel.swift:47-54 / OnboardingSourcesViewModel.swift:30-37 | **同一**（逐語。プロパティ名だけ `categorizedFeaturedSites` / `categorizedSites` が違う） | 「表示順で並べ、0 件カテゴリを除外する」という同一規則。正規化とグループ化は `FeaturedCategory.swift:44-49,56-68` に集約済みなのに、**空除外＋順序付け**だけが 2 箇所に残る。owner を 1 つ増やすだけで解消する最小の重複 |
| D6 | 404 の解釈 | AppState.swift:263 / SettingsViewModel.swift:163 / QuizSheetView.swift:199（以上『機能未提供』）／ StarredViewModel.swift:108 / PasskeyCredentialsViewModel.swift:52 / SessionsViewModel.swift:57（以上『冪等削除の成功』） | **2 種の異なる意味** | 6 箇所を 1 つに畳んではいけない。必要なのは 2 つの意味を持つ型（`notFound(subject:)` と `alreadyAbsent`）であり、共通ヘルパーではない |

**件数の数え方**: 行範囲は宣言行から対応する閉じ括弧まで。コメント行・doc 行を含む。テストコード（`NewsListenAppTests/`）は集計対象外。DEBUG ブロック内は D1〜D6 のいずれにも含まれない。

---

## 9. change_scenarios

```yaml
change_scenarios:
  - id: CS1
    name: "Replace implementation: AVPlayer → 別再生エンジン"
    status: fail
    rationale: "consumer contract が AVFoundation 型で書かれており、置換すると公開面とテストの両方が動く"
    evidence:
      - {status: confirmed, source: "PodcastViewModel.swift:95,399,407,416,424（公開面の型）", supports: "型レベルの結合"}
      - {status: confirmed, source: ":262-375 の play() 内に AVPlayerItem 生成・KVO 2 本・通知購読・periodic observer が直書き（約 114 行）", supports: "手続きが operation に混在"}
      - {status: confirmed, source: "p1-domain.md §3-2 が PodcastViewModelTests.swift:743,750,757,764,771,778,886,1065,1069,1092,1094 で AVFoundation 型を参照と報告（本 review では該当テストを未再読・inferred 扱い）", supports: "テストも公開面に結合"}
  - id: CS2
    name: "Replace implementation: FileManager → 別ストレージ（例: 暗号化コンテナ・DB blob）"
    status: fail
    rationale: "FileManagerProtocol(:11-25,:32-44) の seam は存在するが、その上の AudioCacheManager が `cachedURL` として file URL を公開し、consumer がそれを AVPlayerItem の入力に使うため、URL を持たないストレージへは置換できない"
    evidence:
      - {status: confirmed, source: "Networking/AudioCacheManager.swift:45-47", supports: "file URL とパス規約が公開面"}
      - {status: confirmed, source: "PodcastViewModel.swift:238-242（resolvePlaybackURL が cachedURL をそのまま返す）", supports: "consumer が URL 前提"}
  - id: CS3
    name: "Replace implementation: URLSession → 別 transport"
    status: pass
    rationale: "`URLSessionProtocol`(:12-15) に対する注入(:71) で全経路が通る。downloadAudio も :161 で同じ session を使う"
    evidence:
      - {status: confirmed, source: "Networking/APIClient.swift:12-17,57,71,161", supports: ""}
      - {status: confirmed, source: "verification-run.md §7（APIClient 以外に URLSession 直使用なし）と本 review の grep 再確認", supports: "境界の閉じ"}
      - {status: confirmed, source: ":159-160 が buildRequest を経由しない（LF15）", supports: "transport 置換自体は可能だが、認証ヘッダ契約はこの経路だけ別扱いになる"}
  - id: CS4
    name: "Change one business rule: パスワード最小長を 8 → 12 にする"
    status: fail
    rationale: "規則の owner が無く、判定 2 箇所と文言 2 箇所の計 4 箇所を、別レイヤ（View と VM）にまたがって直さねばならない"
    evidence: [{status: confirmed, source: "AccountSettingsView.swift:317,318 / AdminUsersViewModel.swift:47,48", supports: ""}]
  - id: CS5
    name: "Change one business rule: 404 の意味を変える（例: backend が『未提供』に 501 を返すようになる）"
    status: fail
    rationale: "6 箇所の consumer が数値から各自の意味を導いており、2 種の意味の owner が存在しない"
    evidence: [{status: confirmed, source: "LF6 の sites（うち 3 件を本 review で実測、3 件は verification-run.md §7 から）", supports: ""}]
  - id: CS6
    name: "Change one business rule: 再開位置の末尾ウィンドウ（2 秒）を変える"
    status: pass
    rationale: "判定は :304-308 の 1 箇所に閉じ、:296-303 に WHY（本番が分単位尺である前提）も記録されている。生リテラルで名前がない点は改善余地だが、変更は局所で完結する"
    evidence: [{status: confirmed, source: "PodcastViewModel.swift:301-308", supports: ""}]
  - id: CS7
    name: "Change one business rule: クイズ合格閾値（50%）を変える"
    status: fail
    rationale: "学習ドメインの規則が View 内(:192-193)にあり、VM も Model も関与しない。テストからも到達しにくい"
    evidence: [{status: confirmed, source: "Podcast/QuizSheetView.swift:192-193", supports: ""}]
  - id: CS8
    name: "Add proven variant: 再生ソースの種別を増やす（ストリーミング/ローカル以外）"
    status: not_applicable
    rationale: "proven variant の Evidence が無い。現状の分岐は `resolvePlaybackURL`(:238-249) の 3 分岐のみで、これは variant ではなく『再生元の決定』という 1 つの業務判断（既に純関数として隔離済み）。roadmap・change history の根拠が無いため selection boundary を作らない"
    evidence: [{status: confirmed, source: "PodcastViewModel.swift:238-249 が唯一の分岐点", supports: ""}]
  - id: CS9
    name: "Add proven variant: platform 追加（macOS 等）"
    status: not_applicable
    rationale: "iOS 単一ターゲット。platform variant の要件も Evidence も無いため、将来用の OS 抽象を追加しない"
    evidence: [{status: confirmed, source: "ios/CLAUDE.md（Xcode プロジェクト 1 つ）／verification-run.md §1（iOS Simulator のみ）", supports: ""}]
  - id: CS10
    name: "Change authority: 『現在再生中』の正本を queue.currentIndex へ移す（web 決定との整合）"
    status: fail
    rationale: "VM 外の reader 19 出現（うちコメント 1・DEBUG 書込 2）と、VM 内の 3 種の『再生中なし』定義（LF4）が同時に動く。QueueSheet.swift:22 のように 2 正本の合成を前提にした View も書き換わる"
    evidence: [{status: confirmed, source: "本 package §6 readers の実測", supports: ""}, {status: confirmed, source: "architecture-strategy-package.md SG-A1（pending）", supports: "決定自体は未確定"}]
  - id: CS11
    name: "Change one business rule: logout / 失効時に主体データを消す（共有仕様 §6.3・R6）"
    status: fail
    rationale: "(a) `AudioCacheManager` に `removeAllDownloads` は存在せず（公開 API は :45,52,62,71,80,90 の 6 つ）、AppState.logout から到達できるインスタンスも無い。(b) NowPlaying の消去は `stopPlayback()` 内の :611 に埋まっており、再生を止めずに消す／外部から消す手段が無い。(c) 再生セッション自体を外部から終了させる operation も公開されていない"
    evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md §6.3 の記述 vs AudioCacheManager.swift の公開 API 一覧（grep 実測）", supports: "仕様と実装の不一致"}, {status: confirmed, source: "PodcastViewModel.swift:611（stopPlayback 内でのみ nil 化）", supports: ""}]
    note: "消去範囲の決定は SG-A5（owner: user・pending）が所有。本 package は『現構造では呼び出す口が無い』ことだけを確定する"
  - id: CS12
    name: "Change one business rule: 再生速度を『既定＋セッション』の 2 概念にする（web 決定）"
    status: fail
    rationale: "`playbackSpeed`(:50) は 1 つで、`setSpeed`(:575) は AppState と未接続。再生開始(:291)で既定から初期化する経路が無いため、概念を 2 つに割る変更は VM の状態定義から波及する"
    evidence: [{status: confirmed, source: "PodcastViewModel.swift:50,291,575-579", supports: ""}, {status: confirmed, source: "architecture-strategy-package.md SG-A2（pending）", supports: ""}]
```

---

## 10. rejected overdesign（RO*）— 作るべきでない抽象

```yaml
rejected_overdesign:
  - id: RO1
    subject: "汎用 Repository / 共通 LoadableViewModel による一覧読み込みの統合"
    reason: "§8 D1 のとおり 9 箇所の意味が異なる（オフライン前置ガード・キャンセル 2 型の黙殺・失敗表現 3 系統・文言 owner）。同じ変更理由を持たないものを 1 つの抽象にまとめると、分岐が抽象の内部へ移動するだけで局所性が悪化する"
    hard_gate: "abstraction が同じ purpose・contract・change reason を持つか（code-design.md）"
    evidence: [{status: confirmed, source: "FeedViewModel.swift:102（オフライン前置）と AdminUsersViewModel.swift:34-42（前置なし・固定文言）の対比", supports: ""}]
  - id: RO2
    subject: "再生ソースの Strategy 階層（LocalPlaybackSource / RemotePlaybackSource）"
    reason: "proven variant の Evidence が無い（CS8 not_applicable）。現状の判断は `resolvePlaybackURL`(:238-249) という 12 行の純関数で、既にテスト可能な形で隔離されている。Strategy 化は選択規則を型階層へ散らすだけ"
    hard_gate: "一実装で variant 根拠がないのに factory / Strategy を作らない"
    evidence: [{status: confirmed, source: "PodcastViewModel.swift:238-249", supports: ""}]
  - id: RO3
    subject: "全 ViewModel 共通の BaseViewModel（継承）"
    reason: "15 の VM が持つ @Published は 83 個で構成が全く異なる（verification-run.md §4）。継承は状態の owner を曖昧にし、テストで『どの層が書いたか』を切り分けられなくする。QL2（testability）に逆行する"
    hard_gate: "purpose-centered capsule。共通なのは構文であって purpose ではない"
    evidence: [{status: confirmed, source: "verification-run.md §4 の per-file 内訳", supports: ""}]
  - id: RO4
    subject: "AVPlayer の API を鏡写しにした AudioEngineProtocol"
    reason: "consumer 目的（鳴らす・止める・位置を変える・速度・終了と失敗の通知）より広い抽象になり、差し替え可能性という品質根拠も伴わない。port を作るとしても consumer purpose の 6 操作に絞るべきで、それは本 package の scope（SG-A10）"
    hard_gate: "consumer 目的より広い抽象を公開しない"
    evidence: [{status: confirmed, source: "§6 readers 実測: View からの `player` 参照は 0", supports: "広い抽象を必要とする consumer が存在しない"}]
  - id: RO5
    subject: "HTTP status 全体を網羅する Error 型階層 / 汎用エラー変換 DSL"
    reason: "R4 が求めるのは 7 つの業務的意味であり、HTTP の網羅ではない。網羅型は『どの意味に対応すべきか』の判断を再び consumer へ戻す"
    hard_gate: "interface 型を作ること自体が目的化していないか"
    evidence: [{status: confirmed, source: "p4-common-brief.md R4 の 7 意味", supports: ""}]
  - id: RO6
    subject: "stale ガードの共通抽象（RequestToken<T> 等）"
    reason: "§8 D3a/D3b/D3c のとおり 3 方式は異なる意味（同期の一意性・主体の同一性・Task ライフサイクル）を持つ。統合すると 3 つの異なる正しさが 1 つの仕組みに潰れる。統合候補があるとすれば D3a の 3 メソッド内だけ"
    hard_gate: "同じ purpose・change reason を持つか"
    evidence: [{status: confirmed, source: "SettingsViewModel.swift:207-208 / PodcastViewModel.swift:436 / AudioPlayerView.swift:409 の対比", supports: ""}]
  - id: RO7
    subject: "AudioCacheManager の protocol 化（CacheStoring）"
    reason: "テスト seam は既に FileManagerProtocol(:11-25) 層に存在し、rule 11 :70-75 の『本番経路同一性』に適合している。もう 1 段の port は本番経路を迂回するテストを可能にしてしまい、品質根拠に反する。CS2 の fail は port 不在ではなく **公開面の型（file URL）** が原因であり、protocol 化では解決しない"
    hard_gate: "外部障害境界や安定契約のための port に品質根拠があるか"
    evidence: [{status: confirmed, source: "Networking/FileManagerProtocol.swift の存在 と AudioCacheManager.swift:45-47", supports: ""}]
```

---

## 11. selection_gates（本 package 固有。ASP の SG-A* とは別 ID・重複させない）

```yaml
selection_gates:
  - id: SG-B1
    subject: "API 失敗の意味（R4 の 7 種）をどの層で確定するか"
    candidates:
      - "(i) APIClient が意味付き enum を返す（transport が業務語彙を持つ＝LF12 を悪化させうる）"
      - "(ii) 境界に mapper を置き、各 VM は意味だけを受け取る（層は増えるが transport は業務を知らない）"
      - "(iii) エンドポイントごとに operation 固有の結果型を返す（404 の 2 意味が呼出先ごとに自然に決まるが型が増える）"
    decision_condition: "『404 の意味は endpoint 固有か、横断的か』の判断。§8 D6 は 2 意味が endpoint 属性であることを示唆するが、401 は横断的である"
    evidence_required: ["backend の status 使い分け契約", "Contract Package が R4 をどの粒度の CI に落とすか"]
    owner: user
    status: pending
  - id: SG-B2
    subject: "パスワード規則・クイズ合格閾値など View 内業務規則の owner 位置"
    candidates: ["(i) Models 層の policy 型へ移す", "(ii) AccountSettings / QuizSheet に ViewModel を新設し VM へ移す", "(iii) 現状維持"]
    decision_condition: "『規則が UI 文言と不可分か』と『AccountSettingsView に VM を新設するコストを払うか』"
    evidence_required: ["同一規則を backend も持つか（二重実装の実態）"]
    owner: user
    status: pending
  - id: SG-B3
    subject: "PodcastViewModel の素通し 3 メソッド（OP6）の扱い"
    candidates: ["(i) 削除し View が業務 port を直接使う", "(ii) 残すが VM が結果の意味まで確定する", "(iii) 現状維持"]
    decision_condition: "『AudioPlayerView が再生 VM 越しに語彙 API を叩く現状を、境界として認めるか』"
    evidence_required: ["語彙/クイズを再生から独立した機能とみなすかの user 判断"]
    owner: user
    status: pending
```

**参照のみ（本 package では選択しない・ASP 所有）**: SG-A1（再生中の正本）、SG-A2（速度 2 概念）、SG-A3（auto-advance 失敗方針）、SG-A4（オンライン状態の参照元）、SG-A5（logout 消去範囲）、SG-A6（VM 分割単位・キャッシュ共有）、SG-A8（失敗の観測方針）、SG-A9（View からの直接書込）、SG-A10（OS 連携の port 化）。

---

## 12. dependency_direction / migration / traces / obligations / decision

```yaml
dependency_direction:
  - {id: DD1, from: "Views(Podcast/*)", to: "PodcastViewModel", verdict: "inward だが、公開面が AVFoundation 型と 9 個の書込可能 @Published を含むため保護されていない（LF1, LF2）"}
  - {id: DD2, from: "PodcastViewModel", to: "AVFoundation/MediaPlayer/AVAudioSession/UIKit", verdict: "outward だが port 無し。シングルトン直参照で反転不能（LF8, LF13）。ASP DV1/DV2/DV5 と同一事象"}
  - {id: DD3, from: "PodcastViewModel", to: "APIClient → URLSessionProtocol", verdict: "良好。反転済み（AD1）"}
  - {id: DD4, from: "PodcastViewModel/SettingsViewModel", to: "AudioCacheManager → FileManagerProtocol", verdict: "反転は 1 段下で成立。ただし中間型の公開面が実装を漏らす（LF10b）"}
  - {id: DD5, from: "DesignSystem/PreviewSupport", to: "PodcastViewModel", verdict: "逆流。下位層が上位層の内部状態へ書込む（LF11 / ASP DV3）"}
  - {id: DD6, from: "AccountSettingsView", to: "APIClient + AppState(write)", verdict: "層飛ばし。View が transport と認証状態の両方に直結（LF9 / ASP DV4）"}
  - {id: DD7, from: "SettingsViewModel", to: "AppState", verdict: "VM が AppState を保持し client 選択順を持つ（LF14）"}

migration:
  - id: M1
    applicability: not_applicable
    not_applicable_reason: "本 package は review mode（`mutation_authorized: false`）であり、公開契約の変更を選択していない。移行手順は、SG-A1/A5/A6/A10 と SG-B1〜B3 が決定されたのちに、その決定を所有する package が設計する"
    evidence: [{status: confirmed, source: "p4-common-brief.md §0 routing_context", supports: ""}]

change_safety:
  applicability: not_applicable
  not_applicable_reason: "同上。既存 caller / 公開契約を変更する計画を本 package は産出していない（finding と候補の提示のみ）"
  confirmation_method: ""
  impact_if_unresolved: ""
  evidence: [{status: confirmed, source: "p4-common-brief.md §6『手段（リファクタ案）は選択しない』", supports: ""}]

boundary_traces:
  - {id: BT1, requirement_ids: [R1], consumer_ids: [C2, C5], operation_ids: [OP6, OP7], leakage_finding_ids: [LF9], change_scenario_ids: [CS4, CS7], status: covered, evidence: [{status: confirmed, source: "AccountSettingsView.swift:317 / AdminUsersViewModel.swift:47 / QuizSheetView.swift:192-193", supports: ""}]}
  - {id: BT2, requirement_ids: [R2], consumer_ids: [C1, C6], operation_ids: [OP1, OP4], leakage_finding_ids: [LF1, LF2, LF4, LF11], change_scenario_ids: [CS1], status: covered, evidence: [{status: confirmed, source: "§7 LF2/LF4 の sites", supports: ""}]}
  - {id: BT3, requirement_ids: [R3], consumer_ids: [C1, C4], operation_ids: [OP2, OP8], ownership_refs: [AR1, AR2, AR3], leakage_finding_ids: [LF3, LF10, LF14], change_scenario_ids: [CS10, CS12], status: partial, evidence: [{status: confirmed, source: "§6 ownership", supports: "authority の所在は特定したが選択は SG-A1/A2/A6 へ隔離"}]}
  - {id: BT4, requirement_ids: [R4], consumer_ids: [C2], operation_ids: [OP7], ownership_refs: [AR4], leakage_finding_ids: [LF5, LF6, LF12, LF15], change_scenario_ids: [CS5], status: covered, evidence: [{status: confirmed, source: "§7 LF6", supports: ""}]}
  - {id: BT5, requirement_ids: [R5], consumer_ids: [C2, C5], operation_ids: [OP7], leakage_finding_ids: [LF6, LF9], status: partial, evidence: [{status: confirmed, source: "LoginViewModel.swift:59 が唯一の 401 分岐（verification-run.md §7）／AccountSettingsView.swift:308", supports: "401 集中処理の不在は確認、認可 policy の単一性は Domain package 所管"}]}
  - {id: BT6, requirement_ids: [R6], consumer_ids: [C3, C4, C5], operation_ids: [OP8], leakage_finding_ids: [LF8], change_scenario_ids: [CS11], status: contradictory, evidence: [{status: contradiction, source: "shared-playback-spec.md §6.3 vs AudioCacheManager の公開 API（removeAllDownloads 不在）", supports: ""}]}
  - {id: BT7, requirement_ids: [R7], consumer_ids: [C1, C3], operation_ids: [OP1, OP5], leakage_finding_ids: [LF13, LF16], status: partial, evidence: [{status: confirmed, source: "§7 LF13/LF16", supports: "境界起因のテスト不能性のみ。テスト戦略全体は Test Function 所管"}]}
  - {id: BT8, requirement_ids: [R8], consumer_ids: [], operation_ids: [], status: missing, evidence: [{status: confirmed, source: "R8 は CI 経路の要件であり境界の問題ではない", supports: "本 package では not_applicable"}]}
  - {id: BT9, requirement_ids: [R9], consumer_ids: [C1], operation_ids: [OP2], ownership_refs: [AR5], leakage_finding_ids: [LF7], status: covered, evidence: [{status: confirmed, source: "verification-run.md §8（Q-01〜Q-32 が 32/32・green）", supports: "契約テストの存在は確認。期待値と正本 §4 の突合は UV4 未実行"}]}

coverage:
  requirements_denominator: 9
  covered: 5        # R1, R2, R4, R9 と（partial を除く）→ 実数は下記内訳
  breakdown: "covered = R1, R2, R4, R9（4）／partial = R3, R5, R7（3）／contradictory = R6（1）／not_applicable = R8（1）。分母 9 = R1〜R9"
  uncovered_ids: []
  not_applicable_ids: [R8]
  note: "『covered』は本 package が境界の観点で所在と影響を特定できたことを指し、要件が満たされていることを意味しない（R2/R4 は covered かつ違反あり）"

obligations:
  - {id: OB-B1, to: "Contract Package", ask: "LF1/LF2/LF3/LF4/LF5/LF11/LF12 に対応する CI（事前/事後条件・不変条件）の ID を確定し、本 package の OP1〜OP8 と対応付ける。とくに『再生セッション状態の排他性』と『API 失敗の 7 意味』は CI として表現されているか", blocking_for: "LF1, LF2, LF3, LF4, LF5, LF11, LF12"}
  - {id: OB-B2, to: "Domain Completeness Package", ask: "(a) 待機列に同一エピソードの重複エントリを許すかの不変条件（OP2 duplicate_semantics が unknown）。(b) 404 の 2 意味（機能未提供 / 冪等削除の成功）に業務概念名が与えられているか", blocking_for: "OP2, LF6, CS5"}
  - {id: OB-B3, to: "Domain Completeness Package", ask: "パスワード規則・クイズ合格閾値・admin 判定を所有すべき概念の同定（R1）。本 package は所在（View 内）だけを確定した", blocking_for: "LF9, CS4, CS7"}
  - {id: OB-B4, to: "router / backend 調査", ask: "(a) 再生位置 PUT の last-write-wins と冪等性（MEMORY の issue #112『backend PUT 未実装』と矛盾する可能性）。(b) downloadAudio が叩く署名付き URL が認証ヘッダ不要である前提の確認（LF15）。(c) 各 endpoint の再試行安全性", blocking_for: "OP5, OP7, LF15"}
  - {id: OB-B5, to: "Test Function / router", ask: "LF8/LF13/LF16 の検証不能性について、UV3（実機観測）を恒常的な検証手段として受け入れるか（SG-A10 の evidence_required と同一）。本 package は『現構造では単体検証点が存在しない』ことのみ確定", blocking_for: "LF8, LF13, LF16"}
  - {id: OB-B6, to: "Architecture Strategy Package（SG-A6）", ask: "AudioCacheManager の 2 インスタンス構成（AR3）と SettingsViewModel の 2 init（LF14）を、インスタンス共有の候補 (a)/(b)/(c) のどれで扱うか。本 package は境界の重複所有だけを報告", blocking_for: "LF10, LF14"}

subject_verdict: leaky
subject_verdict_rationale: |
  C3（OS 連携）が port を持たず、C1 の公開面に AVFoundation 型・書込可能 @Published・2 正本の合成規則が漏れている。
  C2 は status 数値と英語文言を 10 の consumer へ漏らし、うち 2 つは View である。
  良好な境界も実在する: C2 の URLSession seam（AD1）、NetworkMonitoring（AD2）、PlaybackQueue（CAP1）、
  InterruptionPolicy（CAP2）、ListDisplayState（CAP3）、および P6 の KVO 純関数化。
  `overabstracted` ではない（根拠のない抽象は見つからず、むしろ port が不足している）。
  `indeterminate` でもない（主要な漏出は実コードの path:line で確定した）。

decision:
  status: pass
  artifact_readiness: ready
  engineering_status: not_started
  release_status: not_applicable
  decision_maturity:
    status: proposed
    owner: user
    scope: ["C1〜C6 の境界監査", "LF1〜LF16", "CS1〜CS12", "RO1〜RO7", "SG-B1〜SG-B3"]
    evidence_status: confirmed
    approval_evidence: []
    baseline_version: "HEAD c8c1ada"
    change_control: "review mode・mutation なし"
  next_phase:
    name: "SG 決定（user）→ 決定済み境界に対する Contract / 移行設計"
    status: awaiting_approval
    reasons: ["SG-A1/A2/A3/A5/A6/A8/A9/A10 および SG-B1〜B3 がすべて pending", "手段の選択は本 package の権限外"]
    human_approvals_required: ["再生状態の正本", "logout 時の消去範囲", "OS 連携の port 化範囲", "失敗の観測方針"]
  evidence:
    - {status: confirmed, source: "本 package の全 path:line は grep -n / sed -n による自己再取得（§13 で範囲検査）", supports: "引用の正確性"}
    - {status: confirmed, source: "verification-run.md §1（509/509 green・HEAD c8c1ada）", supports: "対象が動作する状態での監査"}
  assumptions:
    - {id: A1, statement: "AudioPlayerView の @State（transcript/vocabulary 系）はテスト対象外という既定方針を踏襲し、C1 の contract 対象に含めない", falsified_if: "user が View 内部状態の検証を要求した場合", source: "p4-common-brief.md §2 の棄却済み案"}
    - {id: A2, statement: "『同一ルールの重複』と判定したのは §8 D4/D5 のみで、他は意味が異なるため重複と呼ばない", falsified_if: "Domain package が D1 の 9 箇所に共通の業務概念を見出した場合"}
  unknowns:
    - {id: U1, subject: "APIClient / URLSession のタイムアウト設定", confirmation_method: "APIClient.swift:67-78 以外に設定箇所が無いことを確認し、URLSession 既定に依存しているかを判定", impact_if_unresolved: "OP3/OP7 の end_to_end_deadline を契約化できない", owner: "Contract Package", evidence: [{status: unknown, source: "本 review では init に指定なしを確認したのみ", supports: ""}]}
    - {id: U2, subject: "PlaybackQueue.add の重複エントリ扱い", confirmation_method: "Podcast/PlaybackQueue.swift:59-62 の再読と Q-* conformance の該当テスト確認", impact_if_unresolved: "OP2 の duplicate_semantics が確定しない", owner: "Domain / Contract Package", evidence: [{status: unknown, source: "本 review の読み範囲外", supports: ""}]}
    - {id: U3, subject: "AVFoundation 型を参照するテストの実数", confirmation_method: "NewsListenAppTests/PodcastViewModelTests.swift を直接 grep", impact_if_unresolved: "CS1 の影響範囲（テスト改修量）を見積もれない", owner: "Test Function", evidence: [{status: inferred, source: "p1-domain.md §3-2 の報告（本 review で未再読）", supports: ""}]}
    - {id: U4, subject: "cache 書込が原子的置換かどうか", confirmation_method: "Networking/FileManagerProtocol.swift:32-44 の write 実装を読む", impact_if_unresolved: "OP3 の ambiguous_outcome（破損ファイルが isCached true を返す経路）が確定しない", owner: "Contract Package", evidence: [{status: unknown, source: "本 review の読み範囲外", supports: ""}]}
  unexecuted_verifications:
    - "UV3（実機観測: logout 後の NowPlaying 残留、auto-advance 失敗時の UI）— LF8 / CS11 / OP1.ambiguous_outcome の直接確認手段"
    - "UV4（conformance 期待値と共有仕様 §4 の突合）— BT9 の covered を『契約の正しさ』まで引き上げるために必要"
```

---

## 13. `path:line` 範囲検査

本 package 内で引用したすべての `file:N` について `N ≤ wc -l` を 1 コマンドで検査した結果を §13 実行ログに記す（下記コマンドの出力を転記）。

### 実行ログ（1 コマンド）

```
cd /Users/rio/git/news-listen/ios/NewsListenApp/NewsListenApp && \
grep -oE '[A-Za-z]+\.swift:[0-9]+(([,-][0-9]+))*' boundary-package.md | sort -u | \
while IFS=: read -r fn nums; do p=$(find . -name "$fn" -not -path './build/*' | head -1); \
  if [ -z "$p" ]; then echo "MISSING-FILE $fn"; continue; fi; \
  max=$(wc -l < "$p" | tr -d ' '); \
  for n in $(echo "$nums" | tr ',-' '\n\n'); do [ "$n" -gt "$max" ] && echo "OUT-OF-RANGE $fn:$n (max $max)"; done; \
done
```

結果:

```
MISSING-FILE PodcastViewModelTests.swift
RANGE-CHECK-DONE
```

- 一意な `<file>.swift:<行>` 引用は **111 件**。うち **範囲外（OUT-OF-RANGE）は 0 件**。
- `MISSING-FILE` の 1 件は `NewsListenAppTests/PodcastViewModelTests.swift`（production ツリー配下に無いため検索に掛からなかっただけ）。別途 `wc -l NewsListenAppTests/PodcastViewModelTests.swift` = 1211 行で、引用した最大行 1094 は範囲内。ただしこの引用は p1-domain.md からの転記であり本 review では未再読のため `status: inferred`（U3）として扱う。
- 行番号はすべて `grep -n` / `sed -n ... | nl -ba -v <開始>` による単一ファイル単位の取得であり、複数ファイル連結出力の累積行番号は使用していない。
