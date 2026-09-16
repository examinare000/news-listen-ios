# Contract Package — ios モジュール（再生キュー / 再生セッション / API / キャッシュ / 認証）

```yaml
routing_context: {origin: integrated, mode: review, requested_by: router, requested_artifact: contract-package, return_to: router, mutation_authorized: false}
```

対象 HEAD: `c8c1ada`（ブリーフ §5 と同一）。すべての `path:line` は本 package 作成時に該当ファイルを個別に `grep -n` / `sed -n` して再読した行である（§12 の範囲検査参照）。

```yaml
contract_package:
  subject: "NewsListenApp: PlaybackQueue / PodcastViewModel 再生操作 / APIClient / AudioCacheManager / AppState 認証 / RelativeTimeFormatter の公開操作契約"
  platform_context:
    required_platforms: [iOS]
    rationale: "対象は単一 platform の app target。Windows / Linux 実行は scope 外（`ios/CLAUDE.md` のスタック定義）。"
    environment_dependencies:
      - "AVFoundation（AVPlayer / AVAudioSession）・MediaPlayer（MPNowPlayingInfoCenter / MPRemoteCommandCenter）・UIApplication background task: `Podcast/PodcastViewModel.swift:276-291,456-460`"
      - "FileManager（`FileManagerProtocol` 背後・注入可）: `Networking/AudioCacheManager.swift:31-40`"
      - "URLSession（`URLSessionProtocol` 背後・注入可）: `Networking/APIClient.swift:11-17,57,71`"
      - "Keychain / UserDefaults: `Networking/SessionStore.swift`、`AppState.swift:40-47`"
  platform_validation:
    status: single_platform
    rationale: "契約を分岐させる OS 差が本 scope に存在しない（対象は iOS のみ）。platform matrix は作らない。"
    executed_platforms: []
    note: "本 package は review mode。test は全て planned / not_run（既存テストの実行結果は `verification-run.md` の V1=509/509 green を引用するが、本 package が新規実行した test は無い）。"
```

---

## 1. Change Safety

```yaml
  change_safety:
    applicability: not_applicable
    not_applicable_reason: "本依頼は read-only の契約監査であり（`mutation_authorized: false`）、既存挙動も公開契約も変更しない。契約差分の是正手段は Selection Gate として user へ返す。"
    confirmation_method: "オーケストレータが SG-C1〜SG-C5 / SG-A* を決定し、実装タスクを起票する段階で Change Safety を別途作成する。"
    impact_if_unresolved: "SG 未決のまま実装すると、spec §2 / §6 と実装の差分をどちらへ寄せるかが暗黙決定される。"
    evidence:
      - {status: confirmed, source: "p4-common-brief.md §0", supports: "mutation_authorized: false"}
  public_contract_changes:
    - id: PCC1
      contract_item_ids: [CI-C06, CI-S05]
      applicability: unknown
      approval: {status: pending, owner: user, evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:312 vs AppState.swift:282-302", supports: "仕様が要求する removeAllDownloads が実装に存在しない"}]}
      compatibility_window: unknown
      migration_steps: []
      rollback_or_recovery: []
      confirmation_method: "SG-A5（消去範囲）の user 決定後、共有仕様 §6.3 を改訂するのか iOS 実装を追随させるのかを確定する。"
      impact_if_unresolved: "共有仕様（3 platform 正本）と iOS 実装の不一致が残り、どちらが正しいか読者が判定できない。"
      evidence:
        - {status: confirmed, source: "Networking/AudioCacheManager.swift:42-95", supports: "公開 API は cachedURL / isCached / cache / remove / cacheSize / clearCache の 6 つで removeAllDownloads は無い"}
```

---

## 2. Requirements（ブリーフ §4 seed を本 Function の観点で参照）

```yaml
  requirements:
    - id: R2
      statement: "再生セッションの不正状態を公開経路から構築できない"
      in_scope: true
      evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:40-50,281,435-450", supports: "@Published var の外部書込可・advance 後の非同期化"}]
    - id: R3
      statement: "現在再生中 / 再生速度 / 再生位置 / キャッシュ有無 / ネットワーク / 認証の source of truth が一意"
      in_scope: true
      evidence: [{status: confirmed, source: "architecture-strategy-package.md §3(a)-(g)", supports: "data authority 表（owner 未決・SG-A1〜A9）"}]
    - id: R4
      statement: "消費者は失敗の意味を受け取り、statusCode 数値比較や英語 localizedDescription に依存しない"
      in_scope: true
      evidence: [{status: confirmed, source: "Networking/APIClient.swift:20-40,534-546", supports: "APIError は httpError(statusCode) を主要ケースにしている"}]
    - id: R5
      statement: "実行中セッション失効（401）で未認証へ遷移する"
      in_scope: true
      evidence: [{status: confirmed, source: "AppState.swift:197-221", supports: "refreshAuth の catch が全例外を未認証扱いにする"}]
    - id: R6
      statement: "logout・失効時に前利用者の主体データが端末に残らない"
      in_scope: true
      evidence: [{status: contradiction, source: "docs/design/shared-playback-spec.md:305-314 vs AppState.swift:282-302", supports: "仕様の removeAllDownloads 呼出が実装に無い"}]
    - id: R9
      statement: "PlaybackQueue は共有仕様 §2 不変条件 1〜5 と Q-01〜Q-32 を満たし、名前差（reorderUpNext vs moveUpNext・IndexSet 複数移動）は契約として明示される"
      in_scope: true
      evidence: [{status: confirmed, source: "docs/design/shared-playback-spec.md:48-128,199-232 / Podcast/PlaybackQueue.swift:15-143", supports: "仕様本文と実装"}]
    - id: R1
      statement: "業務ルールが Model/policy 層に単一所有される"
      in_scope: partial
      rationale: "本 package では再生・キャッシュ・認証の operation 契約に現れる範囲（再開位置 2 秒閾値・id 形式・quota 解釈以外）だけを扱う。パスワード規則・admin 判定・featured grouping は Boundary / Domain Function 所管（OB-N2）。"
      evidence: [{status: confirmed, source: "Podcast/PodcastViewModel.swift:304-308", supports: "再開位置閾値が VM 内の式として存在"}]
    - id: R7
      statement: "テストは production 経路を通り契約に対応付く"
      in_scope: partial
      rationale: "本 package は既存テストを contract item への oracle として対応付けるところまでを負う。テスト戦略・CI 方針（R8）は Test Function 所管（OB-N3）。"
      evidence: [{status: confirmed, source: "NewsListenAppTests/APIClientTests.swift:11-660", supports: "実 APIClient + URLSession double 経路"}]
    - id: R8
      statement: "CI と make test が同一経路"
      in_scope: false
      rationale: "operation 契約ではなく成果物 readiness の観点。Test Function 所管。"
      evidence: [{status: confirmed, source: "p4-common-brief.md §5", supports: "ci.yml は test + gitleaks のみ"}]
  domain_obligation_note:
    status: unknown
    rationale: "`completeness-package.md` は本 package 作成時点で 122 行の途中状態であり、安定 gap / obligation ID（G* 等）が発行されていない。`domain_obligation_ids` は捏造せず空にする。"
    confirmation_method: "Domain Function の package 完成後、CI-Q02 / CI-P03 / CI-S05 の 3 件を gap ID へ紐付ける（OB-N1）。"
    impact_if_unresolved: "requirement → domain gap → contract item の 3 段 traceability が 2 段に留まる。"
```

---

## 3. Operation inventory

### 3.1 PlaybackQueue（`Podcast/PlaybackQueue.swift`・純粋値型）

```yaml
  operations:
    - id: OP-Q0
      name: "init(items:currentIndex:)"
      caller: "テスト（`PlaybackQueueConformanceTests.swift:32,135,163,189,313`）・`PodcastViewModel.swift:59`（既定引数）"
      boundary: "Value/Aggregate 構築"
      contract_owner: "PlaybackQueue（aggregate）"
      inputs: ["items: [Podcast]", "currentIndex: Int?"]
      expected_result: "不変条件 2・3 を満たす queue。範囲外 index は clamp、空なら nil。"
      side_effects: []
      failures: ["無し（throw しない）"]
      evidence: {status: contradiction, sources: ["Podcast/PlaybackQueue.swift:21-28", "docs/design/shared-playback-spec.md:39-56"]}
      note: "共有仕様は init を定義していない（§2.3 以降は操作のみ）。iOS 固有の公開 API であり、conformance テストの前提状態構築にも使われているため契約が必要。"
    - id: OP-Q1
      name: "current / upNext / isEmpty（アクセサ）"
      caller: "`PodcastViewModel.swift:441`、`Podcast/QueueSheet.swift:22,29,34,39`"
      boundary: "読み取り専用アクセサ"
      contract_owner: "PlaybackQueue（aggregate）"
      inputs: []
      expected_result: "spec §2.2 / 不変条件 4・5 のとおり"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:31-44", "docs/design/shared-playback-spec.md:53-61"]}
    - id: OP-Q2
      name: "start(with:)"
      caller: "本番未使用（テストのみ: `PlaybackQueueTests.swift:34`、`PlaybackQueueConformanceTests.swift:40,242`）"
      boundary: "aggregate 状態遷移"
      contract_owner: "PlaybackQueue"
      inputs: ["podcast: Podcast"]
      expected_result: "items=[podcast]、currentIndex=0"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:47-50"]}
    - id: OP-Q3
      name: "setQueue(_:startAt:)"
      caller: "本番未使用（テストのみ）。「ここから連続再生」導線は現状 VM に無い"
      boundary: "aggregate 状態遷移"
      contract_owner: "PlaybackQueue"
      inputs: ["podcasts: [Podcast]", "index: Int"]
      expected_result: "空なら currentIndex=nil、そうでなければ clamp(index)"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:53-56", "docs/design/shared-playback-spec.md:67-71"]}
    - id: OP-Q4
      name: "add(_:)"
      caller: "`PodcastViewModel.swift:527`（addToQueue）"
      boundary: "aggregate 状態遷移"
      contract_owner: "PlaybackQueue"
      inputs: ["podcast: Podcast"]
      expected_result: "末尾追加。同一 id 在中なら no-op"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:59-62"]}
    - id: OP-Q5
      name: "playNext(_:)"
      caller: "`PodcastViewModel.swift:518,536`"
      boundary: "aggregate 状態遷移"
      contract_owner: "PlaybackQueue"
      inputs: ["podcast: Podcast"]
      expected_result: "現在の直後へ挿入。current と同一 id は no-op。既存重複は除去してから挿入。current 無しなら先頭挿入で currentIndex は nil のまま"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:65-75", "docs/design/shared-playback-spec.md:77-82"]}
    - id: OP-Q6
      name: "jump(to:) -> Bool"
      caller: "`PodcastViewModel.swift:517,519`"
      boundary: "aggregate 状態遷移 + 結果値"
      contract_owner: "PlaybackQueue"
      inputs: ["id: String"]
      expected_result: "在中なら currentIndex を移して true、無ければ無変更で false"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:79-83"]}
    - id: OP-Q7
      name: "advance() -> Podcast?"
      caller: "`PodcastViewModel.swift:441`（handlePlaybackEnded）"
      boundary: "aggregate 状態遷移 + 結果値"
      contract_owner: "PlaybackQueue"
      inputs: []
      expected_result: "currentIndex nil かつ非空 → 先頭。次あり → +1。末尾 → currentIndex 据置で nil。空 → nil"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:86-97", "docs/design/shared-playback-spec.md:112-118"]}
    - id: OP-Q8
      name: "remove(id:)"
      caller: "`PodcastViewModel.swift:544`（removeFromQueue）"
      boundary: "aggregate 状態遷移"
      contract_owner: "PlaybackQueue"
      inputs: ["id: String"]
      expected_result: "spec §2.10 の 5 分岐"
      side_effects: []
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:100-113", "docs/design/shared-playback-spec.md:120-127"]}
    - id: OP-Q9
      name: "reorderUpNext(fromOffsets:toOffset:)"
      caller: "`PodcastViewModel.swift:549`（moveUpNext）→ `Podcast/QueueSheet.swift` の onMove"
      boundary: "aggregate 状態遷移"
      contract_owner: "PlaybackQueue"
      inputs: ["source: IndexSet", "destination: Int"]
      expected_result: "upNext 基準・onMove（削除前オフセット）規約。範囲外は no-op。currentIndex 不変"
      side_effects: []
      failures: []
      evidence: {status: contradiction, sources: ["Podcast/PlaybackQueue.swift:118-141", "docs/design/shared-playback-spec.md:84-92"]}
      note: "名前・引数型が正本（`moveUpNext(from, toOffset)`）と異なり、かつ正本が明示的に scope 外とした複数要素移動を実装している（CI-Q10 / CI-Q11）。"
    - id: OP-RT1
      name: "formatRelativeTime(_:now:)"
      caller: "一覧・詳細の表示層"
      boundary: "アダプタ（ISO8601 パース）+ コア（しきい値判定）"
      contract_owner: "RelativeTimeFormatter"
      inputs: ["iso: String", "now: Date"]
      expected_result: "spec §3.2 のしきい値表（年判定が月判定に優先）。空文字・パース失敗は空文字"
      side_effects: []
      failures: ["パース失敗 → \"\"（例外を投げない）"]
      evidence: {status: confirmed, sources: ["NewsListenAppTests/RelativeTimeConformanceTests.swift:16-125", "docs/design/shared-playback-spec.md:141-167"]}
```

### 3.2 PodcastViewModel 再生操作（`Podcast/PodcastViewModel.swift`・@MainActor）

```yaml
    - id: OP-P1
      name: "play(podcast:expandsPlayer:)"
      caller: "View（一覧タップ経由 playNow）・`:442`（自動次再生）・`:483`（replay）・`:384`（playById）"
      boundary: "Application use case（再生セッション開始）"
      contract_owner: "PodcastViewModel（再生セッション owner。ただし『現在再生中』の source of truth は SG-A1 未決）"
      initial_state: "任意（再生中でも可）"
      inputs: ["podcast: Podcast", "expandsPlayer: Bool = true"]
      expected_result: "AVPlayer が生成され再生開始。currentPodcast が置換され presentation が確定"
      side_effects: ["AVAudioSession 設定", "NowPlaying 更新", "旧 player の破棄と再生位置 server 同期（stopPlayback 経由）", "periodic observer / KVO / 終了通知の再登録", "15 秒同期タイマ開始"]
      failures: ["resolvePlaybackURL が nil（オフライン未キャッシュ **または URL 文字列不正**）→ errorMessage 設定のみで return", "AVPlayerItem.status == .failed → handlePlayerItemStatusChange 経由で errorMessage + isPlaying=false"]
      evidence: {status: contradiction, sources: ["Podcast/PodcastViewModel.swift:238-249,262-308", "docs/design/shared-playback-spec.md:286-296"]}
    - id: OP-P2
      name: "playById(_:)"
      caller: "通知ディープリンク（`AppState.swift:193-195` の selectedPodcastId 経由）"
      boundary: "Application use case"
      contract_owner: "PodcastViewModel"
      inputs: ["id: String"]
      expected_result: "サーバから取得した Podcast を再生"
      side_effects: ["API 1 回", "OP-P1 の全副作用"]
      failures: ["fetch 失敗 → errorMessage = error.localizedDescription（英語・R4 違反）"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:381-388"]}
    - id: OP-P3
      name: "playNow(_:) / addToQueue(_:) / playNext(_:)"
      caller: "一覧・キューシートの操作"
      boundary: "Application use case（キュー操作 + 再生開始）"
      contract_owner: "PodcastViewModel"
      inputs: ["podcast: Podcast"]
      expected_result: "playNow: queue.current == podcast かつ再生開始。addToQueue/playNext: キュー更新のみ、ただし『何も再生していない』なら即再生"
      side_effects: ["queue 変更", "条件付きで OP-P1"]
      failures: ["OP-P1 の失敗がそのまま伝播（キュー変更は巻き戻らない）"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:516-540"]}
    - id: OP-P4
      name: "handlePlaybackEnded(endedId:)"
      caller: "AVPlayerItemDidPlayToEndTime 通知（`:1049,1078` のテストが登録経路を検証）"
      boundary: "Application use case（自動次再生 + 完聴記録）"
      contract_owner: "PodcastViewModel"
      inputs: ["endedId: String? = nil"]
      expected_result: "次があれば次を再生、無ければ停止して didFinishCurrentEpisode=true。完聴を best-effort 記録"
      side_effects: ["queue.advance()", "OP-P1 または stopPlayback()", "markCompleted API", "refreshListeningStreak"]
      failures: ["stale endedId → 全体 no-op", "markCompleted 失敗 → try? で握り潰し", "次エピソードの play 失敗 → **currentIndex は進んだまま currentPodcast は前のまま**"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:435-465"]}
    - id: OP-P5
      name: "removeFromQueue(id:) / moveUpNext(fromOffsets:toOffset:)"
      caller: "QueueSheet"
      boundary: "Application use case（キュー編集）"
      contract_owner: "PodcastViewModel（委譲先は PlaybackQueue）"
      inputs: ["id: String / (IndexSet, Int)"]
      expected_result: "OP-Q8 / OP-Q9 と同一"
      side_effects: ["queue 変更のみ（再生セッションは触らない）"]
      failures: []
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:542-550"]}
    - id: OP-P6
      name: "togglePlayPause() / seek(to:) / setSpeed(_:)"
      caller: "AudioPlayerView / MiniPlayerView / リモートコマンド"
      boundary: "Application use case（トランスポート制御）"
      contract_owner: "PodcastViewModel"
      inputs: ["（なし）/ seconds: Double / speed: Float"]
      expected_result: "isPlaying 反転 / currentTime 更新 / playbackSpeed 更新。いずれも NowPlaying へ反映"
      side_effects: ["AVPlayer 操作", "MPNowPlayingInfoCenter 更新"]
      failures: ["player == nil のとき togglePlayPause は no-op。seek / setSpeed は状態のみ更新して AVPlayer には届かない"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:552-579"]}
    - id: OP-P7
      name: "stopPlayback() / replayCurrentEpisode()"
      caller: "View・OP-P1 内・OP-P4"
      boundary: "Application use case"
      contract_owner: "PodcastViewModel"
      inputs: []
      expected_result: "stopPlayback: player 解放と再生状態リセット（currentPodcast / queue / didFinish は保持）。replay: 同一エピソードを 0 秒から"
      side_effects: ["再生位置の server 同期（fire-and-forget）", "observer / KVO / timer 解除", "NowPlaying クリア"]
      failures: ["replay で play が失敗（オフライン未キャッシュ）→ player == nil のため seek(0) せず、finished 表示のまま errorMessage"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:581-612,479-487"]}
    - id: OP-P8
      name: "download(podcast:) / removeDownload(podcast:)"
      caller: "一覧行のダウンロードボタン"
      boundary: "Application use case（外部連携 + FS）"
      contract_owner: "PodcastViewModel（キャッシュ実体の owner は AudioCacheManager）"
      inputs: ["podcast: Podcast"]
      expected_result: "download: 署名 URL 再取得 → 音声取得 → キャッシュ保存 → downloadedIds へ追加。removeDownload: キャッシュ削除 → downloadedIds から除去"
      side_effects: ["API 2 回", "FS 書込 / 削除", "downloadingIds / downloadedIds 更新"]
      failures: ["URL 不正 → errorMessage = \"Invalid audio URL\"", "API / FS 失敗 → errorMessage = error.localizedDescription（英語）。downloadedIds は変更しない"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:188-224"]}
    - id: OP-P9
      name: "flushPlaybackPosition() / syncPlaybackPositionIfNeeded()"
      caller: "scenePhase（View）・15 秒タイマ・stopPlayback"
      boundary: "Application use case（外部同期）"
      contract_owner: "PodcastViewModel"
      inputs: []
      expected_result: "currentPodcast があれば現在位置をサーバへ送る"
      side_effects: ["detached Task による API 呼出（await しない）"]
      failures: ["通信失敗 → 空の catch。痕跡も再試行も無い"]
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:828-853"]}
```

### 3.3 APIClient / AudioCacheManager / AppState

```yaml
    - id: OP-A1
      name: "validateResponse(_:)（private・全 API の共通失敗契約）"
      caller: "APIClient 内部の全リクエスト経路"
      boundary: "API / message boundary"
      contract_owner: "APIClient"
      inputs: ["response: URLResponse"]
      expected_result: "2xx なら通過"
      side_effects: []
      failures: ["429 → rateLimited(retryAfter: Int?)", "その他 non-2xx → httpError(statusCode:)", "**HTTPURLResponse でない → 無検証で通過**"]
      evidence: {status: confirmed, sources: ["Networking/APIClient.swift:534-546"]}
    - id: OP-A2
      name: "downloadAudio(from:)"
      caller: "`Podcast/PodcastViewModel.swift:205`"
      boundary: "API boundary（外部署名 URL・自社 API ではない）"
      contract_owner: "APIClient"
      inputs: ["url: URL"]
      expected_result: "音声 Data"
      side_effects: ["外部 GET"]
      failures: ["validateResponse の失敗契約に従う", "URLSession の transport error はそのまま伝播"]
      evidence: {status: confirmed, sources: ["Networking/APIClient.swift:153-164"]}
    - id: OP-A3
      name: "removeSource(url:) / unregisterDeviceToken(_:)（クエリ組立経路）"
      caller: "Settings / logout"
      boundary: "API boundary"
      contract_owner: "APIClient"
      inputs: ["url: String / token: String"]
      expected_result: "DELETE 実行 + validateResponse"
      side_effects: ["外部 DELETE"]
      failures: ["URLComponents 生成・url 取得が nil → **force unwrap により crash**（throw ではない）"]
      evidence: {status: confirmed, sources: ["Networking/APIClient.swift:272-277,300-305"]}
    - id: OP-C1
      name: "cachedURL(for:) / isCached(_:)"
      caller: "`Podcast/PodcastViewModel.swift:158,240,241`"
      boundary: "Repository（FS）"
      contract_owner: "AudioCacheManager"
      inputs: ["id: String"]
      expected_result: "キャッシュパス / 存在有無"
      side_effects: []
      failures: ["**id 検証を行わない**（`validateId` は cache / remove のみ）"]
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:45-55,62-76,99-107"]}
    - id: OP-C2
      name: "cache(_:for:) / remove(_:) / clearCache()"
      caller: "`Podcast/PodcastViewModel.swift:207,219`、`Settings/SettingsViewModel.swift`"
      boundary: "Repository（FS）"
      contract_owner: "AudioCacheManager"
      inputs: ["data: Data, id: String / id: String / （なし）"]
      expected_result: "保存 / 削除 / 全削除"
      side_effects: ["FS 書込・削除・ディレクトリ生成"]
      failures: ["invalidId（cache/remove のみ）", "I/O エラーは throw", "clearCache は列挙失敗を無視、削除途中の失敗で **部分削除のまま throw**"]
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:62-95"]}
    - id: OP-S1
      name: "completeLogin(_:)"
      caller: "LoginView"
      boundary: "Application use case（認証）"
      contract_owner: "AppState"
      inputs: ["response: LoginResponse"]
      expected_result: "token 永続化・currentUser・authStatus=.authenticated・デバイストークン登録の予約"
      side_effects: ["Keychain 書込", "API（非同期 Task）"]
      failures: ["同期部分に失敗経路なし（SessionStore の書込失敗は setter 内で吸収）"]
      evidence: {status: confirmed, sources: ["AppState.swift:149-157"]}
    - id: OP-S2
      name: "refreshAuth()"
      caller: "起動時 / foreground 復帰"
      boundary: "Application use case（認証）"
      contract_owner: "AppState"
      inputs: []
      expected_result: "/auth/me 成功で authenticated + preferences 同期 + デバイストークン登録"
      side_effects: ["API 複数回", "Keychain 破棄（失敗時）"]
      failures: ["**全例外を同一視**して token 破棄 + unauthenticated（401 もネットワーク断も区別しない）", "未設定 / token 無し → token は残したまま unauthenticated"]
      evidence: {status: confirmed, sources: ["AppState.swift:197-221"]}
    - id: OP-S3
      name: "logout()"
      caller: "設定画面"
      boundary: "Application use case（認証）"
      contract_owner: "AppState"
      inputs: []
      expected_result: "サーバ失効を best-effort で試み、ローカル認証状態を必ず落とす"
      side_effects: ["デバイストークン登録 Task の cancel", "unregisterDeviceToken / logout API（try?）", "UserDefaults から seenAchievementIDs 削除", "Keychain 破棄"]
      failures: ["API 失敗はすべて無視（設計どおり）"]
      evidence: {status: confirmed, sources: ["AppState.swift:278-302"]}
    - id: OP-S4
      name: "apiClient（computed）"
      caller: "AppState 内部・`Settings/SettingsViewModel.swift`・起動時に PodcastViewModel へ 1 回注入"
      boundary: "合成（依存の解決点）"
      contract_owner: "AppState"
      inputs: []
      expected_result: "その時点の token を持つ APIClient、または未設定なら nil"
      side_effects: []
      failures: ["URL 不正 / 未設定 → nil（呼出側が沈黙する経路あり）"]
      evidence: {status: confirmed, sources: ["AppState.swift:134-142"]}
```

---

## 4. Contract items — PlaybackQueue（CI-Q*）

```yaml
  contract_items:
    - id: CI-Q01
      operation_id: OP-Q0
      requirement_ids: [R9]
      kind: invariant
      statement: "currentIndex は nil、または 0 ≤ currentIndex ≤ items.count−1。すべての操作の前後で範囲外の値を保持しない（spec 不変条件 2）。"
      applicability: {status: required, rationale: "current / upNext / advance / remove の全アクセサが index の妥当性に依存する。"}
      contract_level: aggregate
      authority_type: invariant_owner
      authoritative_owner: "PlaybackQueue（`Podcast/PlaybackQueue.swift:15-143` の private(set) + mutating 群）"
      defensive_validations:
        status: present
        rationale: "init は外部から与えられた範囲外 index を clamp する。"
        entries: [{location: "Podcast/PlaybackQueue.swift:21-28", purpose: "malformed_input"}]
      implementation_status: met
      test_status: "covered（間接。`PlaybackQueueConformanceTests.swift:59,67,241,313` が clamp と nil 化を観測）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:21-28,31-34,86-97,100-113", "docs/design/shared-playback-spec.md:51"]}
    - id: CI-Q02
      operation_id: OP-Q0
      requirement_ids: [R9, R3]
      kind: invariant
      statement: "items は id について一意（spec 不変条件 1）。"
      applicability: {status: required, rationale: "jump / remove / playNext が `firstIndex(where:)` で id を単一解決する前提であり、重複があると『どちらの b か』が未定義になる。"}
      contract_level: aggregate
      authority_type: invariant_owner
      authoritative_owner: "unknown"
      defensive_validations:
        status: present
        rationale: "add と playNext のみが重複を排除する。"
        entries:
          - {location: "Podcast/PlaybackQueue.swift:60", purpose: "defense_in_depth"}
          - {location: "Podcast/PlaybackQueue.swift:68", purpose: "defense_in_depth"}
      implementation_status: unmet
      gap: "`setQueue(_:startAt:)`（`:53-56`）と `init(items:)`（`:21-28`）は重複除去も検証も行わず、与えられた配列をそのまま保持する。不変条件 1 を守る責務が add / playNext に散在し、集約 owner がいない。仕様側も『add / playNext が維持する』としか書いておらず（`docs/design/shared-playback-spec.md:50`）、setQueue 経路の責務が未定義。"
      test_status: "uncovered（重複 id を含む配列で setQueue / init する test は 0 件。`grep 'func test' NewsListenAppTests/PlaybackQueue*.swift` の 44 件に該当なし）"
      resolution_gate: SG-C1
      evidence: {status: contradiction, sources: ["Podcast/PlaybackQueue.swift:53-56", "docs/design/shared-playback-spec.md:50"]}
    - id: CI-Q03
      operation_id: OP-Q1
      requirement_ids: [R9]
      kind: postcondition
      statement: "current は currentIndex==nil なら nil、そうでなければ items[currentIndex]。upNext は currentIndex==nil なら items 全体、そうでなければ currentIndex より後ろ（spec 不変条件 4・5）。"
      applicability: {status: required, rationale: "UI と自動次再生の両方がこの派生規則に依存する。"}
      contract_level: aggregate
      authority_type: semantic_owner
      authoritative_owner: "PlaybackQueue（`Podcast/PlaybackQueue.swift:31-41`）"
      defensive_validations: {status: present, rationale: "current は `items.indices.contains(i)` で二重に守る（CI-Q01 を前提にすれば冗長だが害はない）。", entries: [{location: "Podcast/PlaybackQueue.swift:32", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `PlaybackQueueConformanceTests.swift:23`（Q-01）, `:31`（Q-02）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:31-41"]}
    - id: CI-Q04
      operation_id: OP-Q2
      requirement_ids: [R9]
      kind: postcondition
      statement: "start(with:) の後、items == [podcast] かつ currentIndex == 0。既存キューは破棄される。"
      applicability: {status: required, rationale: "spec §2.3 が定義する操作。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:47-50`）"
      defensive_validations: {status: not_applicable, rationale: "入力は単一の値オブジェクトで、妥当性検証を要する外部入力ではない。"}
      implementation_status: met
      test_status: "covered: `PlaybackQueueConformanceTests.swift:40`（Q-03）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:47-50"]}
    - id: CI-Q05
      operation_id: OP-Q3
      requirement_ids: [R9]
      kind: postcondition
      statement: "setQueue の後、items が空なら currentIndex==nil、非空なら currentIndex == clamp(startAt, 0, count−1)。"
      applicability: {status: required, rationale: "spec §2.4。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:53-56`）"
      defensive_validations: {status: present, rationale: "範囲外 startAt を clamp（例外にしない）。", entries: [{location: "Podcast/PlaybackQueue.swift:55", purpose: "malformed_input"}]}
      implementation_status: met
      test_status: "covered: `:50`（Q-04）, `:59`（Q-05）, `:67`（Q-06）, `:76`（Q-07）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:53-56"]}
    - id: CI-Q06
      operation_id: OP-Q4
      requirement_ids: [R9]
      kind: postcondition
      statement: "add は末尾へ追加し、同一 id が既にあれば状態を一切変えない（冪等）。"
      applicability: {status: required, rationale: "spec §2.5。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:59-62`）"
      defensive_validations: {status: not_applicable, rationale: "重複判定は契約本体であり防御的検証ではない。"}
      implementation_status: met
      test_status: "covered: `:86`（Q-08）, `:95`（Q-09）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:59-62"]}
    - id: CI-Q07
      operation_id: OP-Q5
      requirement_ids: [R9]
      kind: postcondition
      statement: "playNext は (a) current と同一 id なら no-op、(b) 既存重複を除去してから current の直後へ挿入、(c) current 無しなら先頭へ挿入し currentIndex は nil のまま。いずれの場合も current が指すエピソードは変わらない。"
      applicability: {status: required, rationale: "spec §2.6 の 3 分岐。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:65-75`）"
      defensive_validations: {status: present, rationale: "重複除去で currentIndex がずれるため current の id から再計算する（`:70-72`）。", entries: [{location: "Podcast/PlaybackQueue.swift:70-72", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `:105`（Q-10）, `:115`（Q-11）, `:125`（Q-12）, `:134`（Q-13）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:65-75"]}
    - id: CI-Q08
      operation_id: OP-Q5
      requirement_ids: [R9]
      kind: postcondition
      statement: "playNext の対象が current より**前**に既存している場合も、除去後に current の id から index を再計算するため current は同一エピソードを指し続ける。"
      applicability: {status: required, rationale: "`:68-72` に専用の再計算コードがあり、明示的に守ろうとしている条件である。仕様の Q 表には該当行が無い。"}
      contract_level: aggregate
      authority_type: invariant_owner
      authoritative_owner: "PlaybackQueue（`:70-72`）"
      defensive_validations: {status: not_applicable, rationale: "外部入力の検証ではなく内部整合の再計算。"}
      implementation_status: met
      test_status: "uncovered（Q-11 は current より後ろの重複のみ。前方重複を動かす test は `PlaybackQueueConformanceTests.swift` / `PlaybackQueueTests.swift` の 44 件に無い）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:65-75"]}
    - id: CI-Q09
      operation_id: OP-Q6
      requirement_ids: [R9]
      kind: postcondition
      statement: "jump は在中なら currentIndex をその位置にして true、無ければ状態を変えず false を返す。"
      applicability: {status: required, rationale: "spec §2.8。戻り値が `PodcastViewModel.playNow`（`:517-519`）の分岐条件になっている。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:79-83`）"
      defensive_validations: {status: not_applicable, rationale: "存在判定が契約本体。"}
      implementation_status: met
      test_status: "covered: `:144`（Q-14）, `:152`（Q-15）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:79-83"]}
    - id: CI-Q10
      operation_id: OP-Q7
      requirement_ids: [R9]
      kind: postcondition
      statement: "advance は (a) currentIndex==nil かつ非空 → 0 にして先頭を返す、(b) 次があれば +1 して返す、(c) 末尾なら **currentIndex を据え置いて** nil を返す、(d) 空なら nil。"
      applicability: {status: required, rationale: "spec §2.9。自動次再生の停止判定そのもの。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:86-97`）"
      defensive_validations: {status: not_applicable, rationale: "入力なし。"}
      implementation_status: met
      test_status: "covered: `:162`（Q-16）, `:170`（Q-17）, `:179`（Q-18）, `:188`（Q-19）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:86-97"]}
    - id: CI-Q11
      operation_id: OP-Q8
      requirement_ids: [R9]
      kind: postcondition
      statement: "remove は id 不在なら no-op、空になれば currentIndex=nil、idx<cur なら cur−1、idx==cur なら min(cur, count−1)、idx>cur なら不変。"
      applicability: {status: required, rationale: "spec §2.10 の 5 分岐。"}
      contract_level: aggregate
      authority_type: transition_owner
      authoritative_owner: "PlaybackQueue（`:100-113`）"
      defensive_validations: {status: not_applicable, rationale: "存在判定が契約本体。"}
      implementation_status: met
      test_status: "covered: `:195`（Q-20）, `:204`（Q-21）, `:213`（Q-22）, `:222`（Q-23）, `:231`（Q-24）, `:240`（Q-25）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:100-113"]}
    - id: CI-Q12
      operation_id: OP-Q9
      requirement_ids: [R9]
      kind: postcondition
      statement: "単一要素の IndexSet を与えた `reorderUpNext(fromOffsets:toOffset:)` は、正本 `moveUpNext(from, toOffset)` と観測上等価である（upNext 基準・削除前オフセット方式・currentIndex 不変）。"
      applicability: {status: required, rationale: "名前・引数型が正本と異なるため、等価性を契約として固定しないと『準拠している』と言えない（R9 が明示的に要求）。"}
      contract_level: aggregate
      authority_type: contract_owner
      authoritative_owner: "PlaybackQueue（`:118-141`）"
      defensive_validations: {status: present, rationale: "範囲外は clamp せず no-op（`:133`）。upNext が空のとき早期 return（`:121-122`）。", entries: [{location: "Podcast/PlaybackQueue.swift:133", purpose: "malformed_input"}, {location: "Podcast/PlaybackQueue.swift:121-122", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `:255`（Q-26）, `:265`（Q-27）, `:274`（Q-28）, `:284`（Q-29）, `:294`（Q-30）, `:304`（Q-31）, `:312`（Q-32）。いずれも `IndexSet(integer:)` の単一要素で呼んでおり、等価性の前提が test 側にも明記されている（`:249-253` のコメント）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:118-141", "NewsListenAppTests/PlaybackQueueConformanceTests.swift:249-319"]}
    - id: CI-Q13
      operation_id: OP-Q9
      requirement_ids: [R9]
      kind: postcondition
      statement: "**複数要素 IndexSet** の移動結果は、コア仕様が定義しない（spec §2.7 は『複数選択はプラットフォームアダプタの責務であり本コア仕様のスコープ外』と明記）。iOS はアダプタ層を設けず `PlaybackQueue`（＝コア）に SwiftUI `onMove` 互換の複数移動を実装しているため、この挙動の契約 owner が未定義である。"
      applicability: {status: required, rationale: "`QueueSheet` の `onMove` は SwiftUI が複数 index を渡し得る公開経路であり、実際に `applyMove`（`:131-141`）が複数要素を処理する。未定義のまま公開されている契約は R9 の『名前差・IndexSet 複数移動を契約として明示する』要求に直接該当する。"}
      contract_level: aggregate
      authority_type: contract_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: present, rationale: "`source.allSatisfy { array.indices.contains($0) }`（`:133`）で 1 つでも範囲外なら全体 no-op。", entries: [{location: "Podcast/PlaybackQueue.swift:133", purpose: "malformed_input"}]}
      implementation_status: partial
      gap: "コアが scope 外挙動を実装している（境界の取り違え）。正本に期待値表が無いため、他 platform との一致も検証できない。"
      test_status: "uncovered（複数要素 IndexSet を渡す test は 0 件。全 conformance test が `IndexSet(integer:)`）"
      resolution_gate: SG-C2
      evidence: {status: contradiction, sources: ["docs/design/shared-playback-spec.md:92", "Podcast/PlaybackQueue.swift:131-141"]}
    - id: CI-Q14
      operation_id: OP-Q9
      requirement_ids: [R9]
      kind: invariant
      statement: "reorderUpNext は currentIndex を変更しない（再生済み・現在は動かさない）。"
      applicability: {status: required, rationale: "spec §2.7 の明示的不変条件。"}
      contract_level: aggregate
      authority_type: invariant_owner
      authoritative_owner: "PlaybackQueue（`:118-128` が upNext 部分列だけを置換する構造）"
      defensive_validations: {status: not_applicable, rationale: "構造上 currentIndex へ代入する経路が無い。"}
      implementation_status: met
      test_status: "covered: `:255`（Q-26 が current==a を検証）, `:312`（Q-32 が currentIndex nil を検証）"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:118-128"]}
```

### 4.1 Q-01〜Q-32 準拠対応表（分母 32）

各行の「期待結果一致」は、spec の期待結果と test の `XCTAssert*` 実引数を 1 行ずつ突き合わせて確認した結果である。

| ID | spec 期待結果（`shared-playback-spec.md`） | 検証テスト（`NewsListenAppTests/PlaybackQueueConformanceTests.swift`） | 一致 |
|---|---|---|---|
| Q-01 | :201 `current=b`, `upNext=[c]` | :23 | ○ |
| Q-02 | :202 `current=null`, `upNext=[a,b]` | :31 | ○ |
| Q-03 | :203 `items=[z]`, `current=z` | :40 | ○ |
| Q-04 | :204 `items=[a,b,c]`, `current=b`, `upNext=[c]` | :50 | ○ |
| Q-05 | :205 `currentIndex=0`, `current=a` | :59 | ○ |
| Q-06 | :206 `currentIndex=2`, `current=c`, `upNext=[]` | :67 | △ `upNext=[]` の assert が無い（他 2 条件は一致） |
| Q-07 | :207 `items=[]`, `currentIndex=null` | :76 | ○ |
| Q-08 | :208 `items=[a,b]`, `upNext=[b]` | :86 | ○ |
| Q-09 | :209 無変更 `items=[a,b]` | :95 | ○ |
| Q-10 | :210 `items=[a,b,d,c]`, `current=b`, `upNext=[d,c]` | :105 | ○ |
| Q-11 | :211 `items=[a,c,b]`, `current=a`, `upNext=[c,b]` | :115 | ○ |
| Q-12 | :212 無変更 | :125 | ○ |
| Q-13 | :213 `items=[c,a,b]`, `currentIndex=null` | :134 | ○ |
| Q-14 | :214 `found=true`, `current=c` | :144 | ○ |
| Q-15 | :215 `found=false`, `current=a` | :152 | ○ |
| Q-16 | :216 `next=a`, `currentIndex=0` | :162 | ○ |
| Q-17 | :217 `next=b`, `currentIndex=1` | :170 | ○ |
| Q-18 | :218 `next=null`, `current=c` | :179 | ○ |
| Q-19 | :219 `next=null` | :188 | ○ |
| Q-20 | :220 `items=[b,c]`, `current=c` | :195 | ○ |
| Q-21 | :221 `items=[a,c]`, `current=c` | :204 | ○ |
| Q-22 | :222 `items=[a,b]`, `current=b` | :213 | ○ |
| Q-23 | :223 `items=[a,b]`, `current=a` | :222 | ○ |
| Q-24 | :224 無変更, `current=b` | :231 | ○ |
| Q-25 | :225 `items=[]`, `currentIndex=null` | :240 | ○ |
| Q-26 | :226 `upNext=[c,b,d]`, `items=[a,c,b,d]`, `current=a` | :255 | ○ |
| Q-27 | :227 `upNext=[d,b,c]`, `items=[a,d,b,c]` | :265 | ○ |
| Q-28 | :228 `upNext=[c,d,b]`, `items=[a,c,d,b]` | :274 | ○ |
| Q-29 | :229 無変更 | :284 | ○ |
| Q-30 | :230 無変更 | :294 | ○ |
| Q-31 | :231 無変更 `upNext=[b,c,d]` | :304 | ○ |
| Q-32 | :232 `upNext=[b,a,c]`, `items=[b,a,c]`, `currentIndex=null` | :312 | ○ |

- 分母 32 / 一致 32 / 部分 oracle 1（Q-06）/ 矛盾 0。
- spec §5:274 の「テスト名に行 ID を含める」規約も 32/32 で満たす（`testQ01_`〜`testQ32_`）。
- ただし **Q 表が覆わない契約**が 3 件ある: CI-Q02（重複 id での setQueue / init）、CI-Q08（current より前の重複を playNext）、CI-Q13（複数要素 IndexSet）。「Q 32/32 green」は R9 の充足を意味しない。

### 4.2 RT-01〜RT-15 / RT-A01・A02 対応表（分母 17）

| ID | spec 期待（`shared-playback-spec.md`） | 検証テスト（`NewsListenAppTests/RelativeTimeConformanceTests.swift`） | 一致 |
|---|---|---|---|
| RT-01 | :246 `もうすぐ` | :16 | ○ |
| RT-02 | :247 `たった今` | :24 | ○ |
| RT-03 | :248 `たった今` | :30 | ○ |
| RT-04 | :249 `たった今` | :36 | ○ |
| RT-05 | :250 `1分前` | :44 | ○ |
| RT-06 | :251 `59分前` | :50 | ○ |
| RT-07 | :252 `1時間前` | :58 | ○ |
| RT-08 | :253 `23時間前` | :64 | ○ |
| RT-09 | :254 `1日前` | :72 | ○ |
| RT-10 | :255 `29日前` | :78 | ○ |
| RT-11 | :256 `1か月前` | :86 | ○ |
| RT-12 | :257 `11か月前` | :92 | ○ |
| RT-13 | :258 `12か月前` | :98 | ○ |
| RT-14 | :259 `12か月前` | :104 | ○ |
| RT-15 | :260 `1年前` | :112 | ○ |
| RT-A01 | :266 `""` | :120 | ○ |
| RT-A02 | :267 `""` | :124 | ○ |

- 分母 17 / 一致 17 / 矛盾 0。`now` を引数注入しているため clock 依存が無く（spec:137 の要求）、環境条件を持たない。
- 対応する contract item は CI-RT01（§7）。

---

## 5. Contract items — PodcastViewModel 再生操作（CI-P*）

テスト参照はすべて `NewsListenAppTests/PodcastViewModelTests.swift`（1211 行）。

```yaml
    - id: CI-P01
      operation_id: OP-P1
      requirement_ids: [R2]
      kind: postcondition
      statement: "play が成功した場合、player != nil、currentPodcast == podcast、errorMessage == nil、didFinishCurrentEpisode == false、presentation は expandsPlayer ? .expanded : (hidden なら .mini、それ以外は維持)。"
      applicability: {status: required, rationale: "再生開始という公開操作の中心的な保証。UI 4 画面がこの状態に依存する。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "PodcastViewModel（`Podcast/PodcastViewModel.swift:262-308`）"
      defensive_validations: {status: present, rationale: "presentation が .hidden のとき明示展開しない経路でも .mini へ上げる防御的既定（`:284-287`）。", entries: [{location: "Podcast/PodcastViewModel.swift:284-287", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `:483`, `:512`, `:816`, `:849`, `:1005`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:262-308"]}
    - id: CI-P02
      operation_id: OP-P1
      requirement_ids: [R2, R4]
      kind: failure_guarantee
      statement: "再生 URL を解決できない場合、errorMessage 以外の状態（currentPodcast・queue・presentation・didFinishCurrentEpisode・player）を一切変更せずに return する。"
      applicability: {status: required, rationale: "『失敗したのに画面が再生中に見える』を防ぐ最小の失敗保証。replay 経路（`:481-487`）が finished 表示の維持をこの保証に依存している。"}
      contract_level: use_case
      authority_type: failure_recovery_owner
      authoritative_owner: "PodcastViewModel（`:264-267` の guard が唯一の早期 return 点）"
      defensive_validations: {status: not_applicable, rationale: "入力の妥当性ではなく環境（キャッシュ・回線）に依存する失敗であり、入口検証で防げない。"}
      implementation_status: met
      test_status: "covered: `:456`, `:537`, `:968`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:262-272"]}
    - id: CI-P03
      operation_id: OP-P1
      requirement_ids: [R4]
      kind: failure_guarantee
      statement: "失敗理由は利用者が次の行動を選べる粒度で区別される（オフライン未キャッシュ / 音声 URL 不正 / 再生エンジン失敗）。"
      applicability: {status: required, rationale: "R4 が『消費者は失敗の意味を受け取る』を要求し、UI はこの文言をそのままアラートに出す。"}
      contract_level: use_case
      authority_type: semantic_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "分類の欠落であり検証の欠落ではない。"}
      implementation_status: unmet
      gap: "`resolvePlaybackURL`（`:238-249`）は『オフライン未キャッシュ』と『`URL(string: podcast.audioUrl)` が nil（オンラインだが URL 不正）』の両方を nil に畳む。呼出側（`:264-266`）はどちらでも英語固定文字列 `\"Offline and not cached\"` を出すため、オンライン時に不正 URL を踏むと事実と異なる説明が表示される。文言も英語（R4 の『英語 localizedDescription の露出』と同型）。"
      test_status: "uncovered（`:345` は『オフライン + 未キャッシュ』のみ。オンライン + 不正 audioUrl の test は 0 件）"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:238-249,262-267"]}
    - id: CI-P04
      operation_id: OP-P1
      requirement_ids: [R2]
      kind: precondition
      statement: "キャッシュ無 + オンラインで再生する場合、再生に使う署名 URL は再生時点でサーバから取得した新鮮なものである（共有仕様 §6.1 の 2 番目の分岐）。"
      applicability: {status: required, rationale: "共有仕様 `docs/design/shared-playback-spec.md:292-293` が『毎回 getPodcast() で最新署名を取得（署名失効の再取得に対応・ADR-009）』と明記しており、3 platform 共通の契約である。"}
      contract_level: use_case
      authority_type: contract_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "再取得の有無であり検証ではない。"}
      implementation_status: unmet
      gap: "`play()` は `podcast.audioUrl`（一覧取得時の署名 URL）をそのまま使い、再取得しない（`:243-245`）。`fetchPodcast` の呼出は app target 全体で 2 箇所のみ（`:199` download、`:383` playById）で、`play()` 経路には無い（`grep -rn 'fetchPodcast(' NewsListenApp/` で確認）。さらに `:254` の doc コメントは『署名付き URL を再取得して再生（失敗時は元 audioUrl でフォールバック）』と書いており、コード・コメント・共有仕様の 3 者が食い違う。"
      test_status: "uncovered（`:483` は『audioUrl をそのまま使う』ことを期待値にしており、現状挙動を固定している。つまり既存テストは仕様違反側を pin している）"
      resolution_gate: SG-C4
      evidence: {status: contradiction, sources: ["docs/design/shared-playback-spec.md:292-293", "Podcast/PodcastViewModel.swift:243-245,254", "NewsListenAppTests/PodcastViewModelTests.swift:483"]}
    - id: CI-P05
      operation_id: OP-P1
      requirement_ids: [R2, R3]
      kind: invariant
      statement: "再生セッションが確立している間、`queue.current?.id == currentPodcast?.id` が成り立つ（共有仕様 §2.1 不変条件 4 の『現在再生中＝currentIndex が指すもの』を iOS の 2 系統状態へ適用したもの）。"
      applicability: {status: required, rationale: "`QueueSheet` は queue 側を、`MiniPlayerView` / `AudioPlayerView` は currentPodcast 側を表示するため、乖離は利用者から直接観測できる。R2 が禁止する『advance 後に current と queue が別エピソード』そのもの。"}
      contract_level: use_case
      authority_type: source_of_truth
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "2 正本の同期漏れであり、入口検証の問題ではない。"}
      implementation_status: unmet
      gap: "`play()` は queue を一切触らない（`:262-308`）。同期するのは `playNow`（`:516-521`）と `handlePlaybackEnded` の成功経路（`:441-442`）だけで、`playById`（`:381-388`）・`replayCurrentEpisode`（`:481-487`）・`removeFromQueue`（`:542-545`）・handlePlaybackEnded の失敗経路は同期しない。"
      test_status: "uncovered（queue と currentPodcast の一致を assert する test は 0 件）"
      resolution_gate: SG-A1
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:262-308,381-388,441-442,481-487,516-521", "docs/design/shared-playback-spec.md:53"]}
    - id: CI-P06
      operation_id: OP-P1
      requirement_ids: [R1]
      kind: postcondition
      statement: "保存済み再生位置は `durationSeconds > 0 && playbackPositionSeconds >= durationSeconds − 2` のとき復元せず 0 から再生し、それ以外で position > 0 なら復元する。"
      applicability: {status: required, rationale: "完聴済みエピソードの再タップが即 didPlayToEndTime を起こす完了ループを防ぐ業務ルール（`:296-303` の WHY）。"}
      contract_level: use_case
      authority_type: semantic_owner
      authoritative_owner: "PodcastViewModel（`:304-308`）"
      defensive_validations: {status: present, rationale: "`durationSeconds > 0` 前置がメタデータ欠損時のレジューム全面無効化を防ぐ。", entries: [{location: "Podcast/PodcastViewModel.swift:304", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `:1017`, `:1028`, `:1038`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:296-308"]}
      note: "2 秒ウィンドウと閾値判定が use case（VM）に埋め込まれており、Podcast 値オブジェクト側に無い。R1 の『業務ルールは Model/policy 層へ』の観点は Domain Function 所管（OB-N2）。"
    - id: CI-P07
      operation_id: OP-P1
      requirement_ids: [R3]
      kind: postcondition
      statement: "再生開始時、AVPlayer の rate はセッション再生速度（`playbackSpeed`）に一致する。"
      applicability: {status: required, rationale: "`:291` が明示的に設定しており、`togglePlayPause`（`:559`）・`setSpeed`（`:577`）と同じ値を使う。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "PodcastViewModel（`:50` 宣言・`:291,559,577` が唯一の適用点）"
      defensive_validations: {status: not_applicable, rationale: "内部状態の適用であり外部入力検証ではない。"}
      implementation_status: met
      test_status: "covered（間接）: `:292`, `:647`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:50,291,552-579"]}
      note: "既定速度（`AppState.swift:63-64`）からの初期化契約は存在しない（接続コードが 0 行）。web 確定決定（ブリーフ §7）は『セッション速度は再生開始時に既定から初期化』なので差異がある → SG-A2。本 package では新たな契約を発明せず差分のみ記録する。"
    - id: CI-P08
      operation_id: OP-P2
      requirement_ids: [R3]
      kind: postcondition
      statement: "playById の後、再生中のエピソードはキューからも到達可能である（キュー表示と再生中が矛盾しない）。"
      applicability: {status: required, rationale: "通知ディープリンクは一覧に無いエピソードも開くため、キュー表示（QueueSheet）に『再生中』が現れない状態が公開経路から作れる。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "状態遷移の欠落。"}
      implementation_status: unmet
      gap: "`playById`（`:381-388`）は fetch → `play` のみで queue を触らない。この後 `handlePlaybackEnded` が走ると `queue.advance()` は**別系列の**次エピソードを返す。"
      test_status: "uncovered（playById の test は 0 件。`grep 'playById' NewsListenAppTests/` で 0 hit）"
      resolution_gate: SG-A1
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:381-388,435-442"]}
    - id: CI-P09
      operation_id: OP-P2
      requirement_ids: [R4]
      kind: failure_guarantee
      statement: "playById の fetch 失敗時、利用者に提示されるのは意味づけされた失敗であり、`APIError.errorDescription` の英語文字列ではない。"
      applicability: {status: required, rationale: "R4 が明示的に禁止している露出形態。"}
      contract_level: use_case
      authority_type: semantic_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "分類の欠落。"}
      implementation_status: unmet
      gap: "`:386` が `error.localizedDescription` をそのまま errorMessage へ入れる。`APIError` の説明文は `\"HTTP Error 404\"` 等の英語（`Networking/APIClient.swift:34-37`。429 のみ日本語）。"
      test_status: uncovered
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:386", "Networking/APIClient.swift:31-39"]}
    - id: CI-P10
      operation_id: OP-P3
      requirement_ids: [R2]
      kind: postcondition
      statement: "playNow の後、`queue.current?.id == podcast.id` である（既存の待機列は保持される）。"
      applicability: {status: required, rationale: "`:515` の WHY が『start で丸ごと置換すると待機列が消える』ため挿入方式を選んだと明記しており、契約として固定すべき設計判断。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:516-521`）"
      defensive_validations: {status: present, rationale: "jump が false のとき playNext + 再 jump で必ず到達させる二段構え。", entries: [{location: "Podcast/PodcastViewModel.swift:517-519", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered（間接）: `:80`, `:183`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:513-521"]}
    - id: CI-P11
      operation_id: OP-P3
      requirement_ids: [R3]
      kind: precondition
      statement: "addToQueue / playNext が『何も再生していない』と判定する述語は、再生状態の source of truth と一致していなければならない。"
      applicability: {status: required, rationale: "誤判定すると『追加しただけなのに再生が始まる』『追加しても始まらない』のどちらかが起きる。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "述語の選択の問題。"}
      implementation_status: partial
      gap: "`:526,535` は `currentPodcast == nil` を使う。CI-P05 が未成立のため、`queue.current != nil` だが `currentPodcast == nil`（および逆）の組合せを公開経路から作れる。owner が決まるまで、どちらが正しい述語かは決められない。"
      test_status: "covered（現状挙動のみ）: `:80`"
      resolution_gate: SG-A1
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:524-540"]}
    - id: CI-P12
      operation_id: OP-P4
      requirement_ids: [R2]
      kind: precondition
      statement: "endedId が非 nil かつ `currentPodcast?.id` と異なる場合、handlePlaybackEnded は何もしない（stale 通知の拒否）。"
      applicability: {status: required, rationale: "通知は `DispatchQueue` を跨いで遅延発火し、その間に利用者が別エピソードへ切り替え得る（`:392-397` の WHY）。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:436`）"
      defensive_validations: {status: present, rationale: "純粋関数 `shouldProcessPlayerItemCallback` / `shouldProcessPlayerCallback`（`:399-409`）が KVO 側で同型のガードを担う。", entries: [{location: "Podcast/PodcastViewModel.swift:399-409", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `:1103`, `:1049`, `:1078`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:432-437"]}
    - id: CI-P13
      operation_id: OP-P4
      requirement_ids: [R2, R3]
      kind: failure_guarantee
      statement: "自動次再生で `queue.advance()` が次を返したのち再生に失敗した場合、キュー位置と再生セッションは矛盾しない状態に収束する（停止して失敗エピソードを current に保持する、または currentIndex を戻す）。"
      applicability: {status: required, rationale: "オフライン + 未キャッシュのキューでは日常的に起きる経路であり、R2 が名指しで禁じる不正状態を作る。"}
      contract_level: use_case
      authority_type: failure_recovery_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "失敗後の収束処理そのものが無い。"}
      implementation_status: unmet
      gap: "`:441-442` は `advance()` の副作用（currentIndex += 1）を確定させたうえで `await play(...)` を呼ぶ。play が CI-P02 により何もせず戻ると、currentIndex は次を指し currentPodcast は前のエピソードのまま、isPlaying は false、errorMessage のみが変化する。停止でもスキップでもない中間状態が残る。"
      test_status: "uncovered（`:87` は成功経路、`:96` はキュー枯渇。advance 成功 + play 失敗の組合せを作る test は 0 件）"
      resolution_gate: SG-A3
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:435-450,262-267"]}
    - id: CI-P14
      operation_id: OP-P4
      requirement_ids: [R2]
      kind: postcondition
      statement: "キュー終端では stopPlayback() し、currentPodcast を保持したまま didFinishCurrentEpisode = true にする（語彙・クイズ導線を残す）。"
      applicability: {status: required, rationale: "`:444-449` の WHY が明示する UI 契約。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:443-450`）"
      defensive_validations: {status: not_applicable, rationale: "内部遷移。"}
      implementation_status: met
      test_status: "covered: `:96`, `:105`, `:836`, `:907`, `:918`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:443-450"]}
    - id: CI-P15
      operation_id: OP-P4
      requirement_ids: [R2]
      kind: postcondition
      statement: "完聴記録は、自動遷移の前に捕捉した『終了したエピソードの id』に対して行う（遷移後の currentPodcast ではない）。"
      applicability: {status: required, rationale: "捕捉を誤ると次エピソードが完聴扱いになる。"}
      contract_level: use_case
      authority_type: semantic_owner
      authoritative_owner: "PodcastViewModel（`:437` の `completedPodcastId` 捕捉）"
      defensive_validations: {status: not_applicable, rationale: "内部順序の契約。"}
      implementation_status: met
      test_status: "covered: `:121`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:435-464"]}
    - id: CI-P16
      operation_id: OP-P4
      requirement_ids: [R2]
      kind: failure_guarantee
      statement: "markCompleted / refreshListeningStreak の失敗は自動次再生・停止の結果を変えない（best-effort）。"
      applicability: {status: required, rationale: "`:452-454` に明示された設計方針。"}
      contract_level: use_case
      authority_type: failure_recovery_owner
      authoritative_owner: "PodcastViewModel（`:462` の try? と、UI 収束を先に行う順序）"
      defensive_validations: {status: not_applicable, rationale: "失敗の握り潰しが契約本体。"}
      implementation_status: met
      test_status: "covered: `:162`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:439-464"]}
      note: "失敗が痕跡を残さない点（観測可能性）は SG-A8 所管。契約としては『止めない』が満たされている。"
    - id: CI-P17
      operation_id: OP-P5
      requirement_ids: [R2]
      kind: postcondition
      statement: "現在再生中のエピソードを removeFromQueue した場合の再生セッションの扱い（停止するのか、再生を続けたままキューからだけ消えるのか）が定義されている。"
      applicability: {status: required, rationale: "QueueSheet からは現在行も含めて削除操作が到達し得る。`PlaybackQueue.remove` は currentIndex を次へ昇格させる（CI-Q11）ため、削除後は queue.current != currentPodcast が確定的に発生する。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "未定義の遷移であり検証の問題ではない。"}
      implementation_status: unmet
      gap: "`:542-545` は queue へ委譲するのみで再生セッションに触れない。"
      test_status: "covered（現状挙動のみ・待機列の要素削除）: `:192`。現在再生中を削除する test は 0 件"
      resolution_gate: SG-A1
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:542-545", "Podcast/PlaybackQueue.swift:100-113"]}
    - id: CI-P18
      operation_id: OP-P6
      requirement_ids: [R2]
      kind: precondition
      statement: "togglePlayPause は player != nil のときのみ意味を持ち、player が無ければ isPlaying を変えない。"
      applicability: {status: required, rationale: "`:554` の guard。isPlaying が実体と乖離すると UI のボタンが嘘をつく。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "PodcastViewModel（`:552-563`）"
      defensive_validations: {status: present, rationale: "guard による早期 return。", entries: [{location: "Podcast/PodcastViewModel.swift:554", purpose: "early_feedback"}]}
      implementation_status: met
      test_status: "covered: `:627`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:552-563"]}
      note: "`isPlaying.toggle()` は AVPlayer の実際の再生開始成否を確認しない。rate 設定直後に失敗した場合の乖離は `handlePlayerItemStatusChange`（`:416-420`）が isPlaying=false に戻す経路でのみ回復する。"
    - id: CI-P19
      operation_id: OP-P6
      requirement_ids: [R2]
      kind: postcondition
      statement: "seek 後の `currentTime` が取り得る範囲（クランプするか、範囲外を許すか）が定義されている。"
      applicability: {status: required, rationale: "`currentTime` は NowPlaying（ロック画面）と再生位置サーバ同期（`:845`）の両方へ流れるため、負値や duration 超過が外部へ出る。"}
      contract_level: use_case
      authority_type: invariant_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "検証が存在しない。"}
      implementation_status: unmet
      gap: "`seek(to:)`（`:567-571`）は引数を検証せず `currentTime = seconds` を実行する。AVPlayer 側は内部でクランプするが `@Published currentTime` はクランプされないため、両者が乖離し、その値が `updatePlaybackPosition` で永続化され得る。"
      test_status: "covered（正常値のみ）: `:639`。範囲外 seek の test は 0 件"
      resolution_gate: SG-C3
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:565-571,836-853"]}
    - id: CI-P20
      operation_id: OP-P7
      requirement_ids: [R2]
      kind: postcondition
      statement: "stopPlayback の後、player == nil、isPlaying == false、currentTime == 0、duration == 0、isBuffering == false、NowPlaying 情報は消える。currentPodcast・queue・didFinishCurrentEpisode は変更しない。"
      applicability: {status: required, rationale: "play の前処理としても使われるため、残留状態があると次の再生へ漏れる。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:583-612`）"
      defensive_validations: {status: not_applicable, rationale: "内部解放処理。"}
      implementation_status: met
      test_status: "covered: `:655`, `:729`, `:985`, `:993`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:581-612"]}
    - id: CI-P21
      operation_id: OP-P7
      requirement_ids: [R2]
      kind: postcondition
      statement: "replayCurrentEpisode は currentPodcast があるときのみ動作し、再生に成功した場合のみ currentTime を 0 にする。失敗時は finished 表示と errorMessage を保つ。"
      applicability: {status: required, rationale: "`:484-486` が明示的に player の有無で分岐している。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:479-487`）"
      defensive_validations: {status: present, rationale: "`guard player != nil`（`:485`）が失敗経路での誤った seek を防ぐ。", entries: [{location: "Podcast/PodcastViewModel.swift:485", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `:929`, `:943`, `:959`, `:968`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:479-487"]}
    - id: CI-P22
      operation_id: OP-P9
      requirement_ids: [R3]
      kind: postcondition
      statement: "再生位置同期は、Task 生成の**前**に currentTime を捕捉した値を送る（stopPlayback による 0 リセットに先行される順序を保証する）。"
      applicability: {status: required, rationale: "`:839-842` の WHY が過去の実バグ（停止直前の位置が 0 で上書き）を記録している。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:843-853`）"
      defensive_validations: {status: not_applicable, rationale: "順序の契約。"}
      implementation_status: met
      test_status: "covered: `:785`, `:865`, `:890`"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:836-853"]}
    - id: CI-P23
      operation_id: OP-P9
      requirement_ids: [R3]
      kind: postcondition
      statement: "同期の結果（サーバが返す最新位置）をローカルへ反映するかどうかが定義されている。共有仕様 §6.2 は server-wins（`docs/design/shared-playback-spec.md:302`）。"
      applicability: {status: required, rationale: "複数端末利用時の位置解決方針が仕様に明記されており、iOS もその 1 実装である。"}
      contract_level: use_case
      authority_type: source_of_truth
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "反映処理が無い。"}
      implementation_status: partial
      gap: "`:848` は `_ = try await apiClient.updatePlaybackPosition(...)` で戻り値を破棄し、`podcasts` / `currentPodcast` の `playbackPositionSeconds` は更新されない。server-wins は『再取得時に上書きされる』形でのみ成立し、同一セッション内では local が勝つ。単調性（位置が巻き戻らない）を保証する仕組みは無い。"
      test_status: "covered（送信のみ）: `:785`, `:865`。反映・単調性の test は 0 件"
      resolution_gate: SG-A3
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:843-853", "docs/design/shared-playback-spec.md:298-303"]}
    - id: CI-P24
      operation_id: OP-P8
      requirement_ids: [R2]
      kind: idempotency
      statement: "同一 podcast への download 呼出が重複しても、ダウンロードとキャッシュ書込は 1 回だけ実行される。"
      applicability: {status: required, rationale: "一覧のボタンは連打可能で、@MainActor 上とはいえ await を跨いで再入し得る。"}
      contract_level: use_case
      authority_type: transition_owner
      authoritative_owner: "PodcastViewModel（`:192-195`: guard と `downloadingIds.insert` が最初の await より前に同期実行されるため再入を排他する）"
      defensive_validations: {status: present, rationale: "downloaded 済みも弾く二重条件。", entries: [{location: "Podcast/PodcastViewModel.swift:192", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "uncovered（重複呼出で API 呼出が 1 回であることを assert する test は 0 件。`:363` は単発成功のみ）"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:188-213"]}
    - id: CI-P25
      operation_id: OP-P8
      requirement_ids: [R2, R3]
      kind: failure_guarantee
      statement: "download が失敗した場合、downloadedIds は変化せず downloadingIds から必ず除去される（『ダウンロード中』のまま固まらない）。"
      applicability: {status: required, rationale: "UI のボタン状態がこの 2 集合から導出される（`:163-180`）。"}
      contract_level: use_case
      authority_type: failure_recovery_owner
      authoritative_owner: "PodcastViewModel（`:195` の defer と `:209` の成功時のみ insert）"
      defensive_validations: {status: not_applicable, rationale: "失敗後処理。"}
      implementation_status: met
      test_status: "uncovered（失敗系の download test は 0 件。`:363` は成功のみ）"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:188-213"]}
```

---

## 6. Contract items — APIClient / AudioCacheManager / AppState（CI-A* / CI-C* / CI-S*）

```yaml
    - id: CI-A01
      operation_id: OP-A1
      requirement_ids: [R4]
      kind: failure_guarantee
      statement: "HTTP 応答が 2xx でない場合、429 は `APIError.rateLimited(retryAfter:)`、それ以外は `APIError.httpError(statusCode:)` を投げる。Retry-After ヘッダがあれば Int へ変換して添える（無い・非数値なら nil）。"
      applicability: {status: required, rationale: "全 API 呼出の共通失敗契約であり、呼出側 10 箇所が statusCode 数値で分岐している。"}
      contract_level: api
      authority_type: contract_owner
      authoritative_owner: "APIClient（`Networking/APIClient.swift:536-546`）"
      defensive_validations: {status: not_applicable, rationale: "応答検証そのものが契約本体。"}
      implementation_status: met
      test_status: "covered: `NewsListenAppTests/APIClientTests.swift:90`, `:156`, `:295`, `:312`, `:329`"
      evidence: {status: confirmed, sources: ["Networking/APIClient.swift:534-546"]}
    - id: CI-A02
      operation_id: OP-A1
      requirement_ids: [R4]
      kind: failure_guarantee
      statement: "HTTP 応答として解釈できない URLResponse を成功として扱わない。"
      applicability: {status: required, rationale: "`downloadAudio` は外部から渡された任意 URL（file:// を含む）に対して実行され得るため、非 HTTP 応答が成功扱いになると検証を素通りする。"}
      contract_level: api
      authority_type: contract_owner
      authoritative_owner: "APIClient（`:537`）"
      defensive_validations: {status: present, rationale: "キャストに失敗したら `return`（＝成功）している。", entries: [{location: "Networking/APIClient.swift:537", purpose: "defense_in_depth"}]}
      implementation_status: unmet
      gap: "`guard let http = response as? HTTPURLResponse else { return }` は非 HTTP 応答を無検証で通す fail-open。"
      test_status: "uncovered（`MockURLSession`（`APIClientTests.swift:637`）は常に HTTPURLResponse を返すため、この分岐へ到達する test が存在しない）"
      evidence: {status: confirmed, sources: ["Networking/APIClient.swift:536-538"]}
    - id: CI-A03
      operation_id: OP-A2
      requirement_ids: [R4]
      kind: invariant
      statement: "downloadAudio は外部署名 URL へ `X-API-Key` / `Authorization` を付与しない。"
      applicability: {status: required, rationale: "`:155-156` が security 要件として明記。第三者ストレージへの資格情報漏洩を防ぐ。"}
      contract_level: api
      authority_type: contract_owner
      authoritative_owner: "APIClient（`:159-161` が `buildRequest` を経由しない専用経路）"
      defensive_validations: {status: not_applicable, rationale: "ヘッダを付ける経路が存在しないことによる構造的保証。"}
      implementation_status: met
      test_status: "covered: `APIClientTests.swift:264`, `:278`, `:295`"
      evidence: {status: confirmed, sources: ["Networking/APIClient.swift:153-164"]}
    - id: CI-A04
      operation_id: OP-A3
      requirement_ids: [R4]
      kind: precondition
      statement: "クエリ組立経路（removeSource / unregisterDeviceToken）は、URL 構築に失敗した場合でも crash せず失敗として呼出側へ返す。"
      applicability: {status: required, rationale: "`baseURL` は UserDefaults 由来の可変値（`AppState.swift:139-141`）であり、endpoint path には `url` / `token` という外部由来文字列が入る。crash は失敗契約ではない。"}
      contract_level: api
      authority_type: contract_owner
      authoritative_owner: "unknown"
      defensive_validations:
        status: present
        rationale: "同一クラスの共通経路（`request` → `buildRequest`）は URL 不正を `APIError.invalidURL` として扱う設計だが、この 2 メソッドだけがそこを通らない。"
        entries: [{location: "Networking/APIClient.swift:518-520", purpose: "malformed_input"}]
      implementation_status: unmet
      gap: "force unwrap 4 件: `:275`, `:277`（removeSource）, `:303`, `:305`（unregisterDeviceToken）。nil になる条件は不明だが、契約としては『crash しない』を約束できていない。"
      test_status: "covered（正常系のみ）: `APIClientTests.swift:76`, `:615`。異常 baseURL / 異常 token の test は 0 件"
      evidence: {status: inferred, sources: ["Networking/APIClient.swift:272-285,300-310"], note: "『実際に nil になる入力が存在するか』は未確認。確認方法は T-A1 の property 的入力（空文字・制御文字・極端長）での実行。"}
    - id: CI-C01
      operation_id: OP-C1
      requirement_ids: [R6]
      kind: precondition
      statement: "id は `[A-Za-z0-9_-]` のみで構成され空でない。path traversal を構成する文字を含まない。"
      applicability: {status: required, rationale: "id はサーバ応答由来（`Models/Podcast.swift:123`）の外部入力であり、そのままファイルパスへ連結される。"}
      contract_level: repository
      authority_type: invariant_owner
      authoritative_owner: "AudioCacheManager（`Networking/AudioCacheManager.swift:102-107` の `validateId`）"
      defensive_validations: {status: present, rationale: "cache / remove の入口で検証。", entries: [{location: "Networking/AudioCacheManager.swift:63", purpose: "malformed_input"}, {location: "Networking/AudioCacheManager.swift:72", purpose: "malformed_input"}]}
      implementation_status: partial
      gap: "**`cachedURL(for:)`（`:45-47`）と `isCached(_:)`（`:52-55`）は validateId を呼ばない。** 読み取り経路は検証されないため、`PodcastViewModel.resolvePlaybackURL`（`:240-241`）は不正 id に対して cacheDirectory 外のパスを組み立てて `isCached` → `cachedURL` を返し、その URL が AVPlayer に渡る。書込側だけを守る非対称な境界になっている。"
      test_status: "covered（書込側のみ）: `AudioCacheManagerTests.swift:158`, `:175`, `:188`, `:204`。読取側（cachedURL / isCached に不正 id）の test は 0 件"
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:45-55,62-76,99-107", "Podcast/PodcastViewModel.swift:238-249"]}
    - id: CI-C02
      operation_id: OP-C2
      requirement_ids: [R3]
      kind: postcondition
      statement: "cache 成功後、`isCached(id) == true` かつ `cachedURL(id)` に data が存在する。キャッシュディレクトリは必要なら生成される。"
      applicability: {status: required, rationale: "オフライン再生の前提。"}
      contract_level: repository
      authority_type: source_of_truth
      authoritative_owner: "AudioCacheManager（`:62-66` と FS）"
      defensive_validations: {status: present, rationale: "`ensureCacheDirectory` が不在時のみ作成（冪等）。", entries: [{location: "Networking/AudioCacheManager.swift:111-117", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `AudioCacheManagerTests.swift:52`, `:61`, `:75`"
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:62-66,109-117"]}
    - id: CI-C03
      operation_id: OP-C2
      requirement_ids: [R3]
      kind: idempotency
      statement: "remove は対象が無ければ何もせず正常終了する（冪等）。同じ id への連続呼出で結果が変わらない。"
      applicability: {status: required, rationale: "削除操作は UI とエラー復帰経路の双方から重複到達する。"}
      contract_level: repository
      authority_type: transition_owner
      authoritative_owner: "AudioCacheManager（`:74` の存在チェック）"
      defensive_validations: {status: not_applicable, rationale: "存在チェックが契約本体。"}
      implementation_status: met
      test_status: "covered: `AudioCacheManagerTests.swift:82`, `:98`"
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:71-76"]}
    - id: CI-C04
      operation_id: OP-C2
      requirement_ids: [R3]
      kind: failure_guarantee
      statement: "clearCache が途中の removeItem 失敗で throw した場合に残るファイル集合（部分削除）が定義されている。"
      applicability: {status: required, rationale: "SG-A5 が採用する logout 時一括削除は、この部分失敗の扱いに依存する（共有仕様 §6.3:314 は『失敗しても UI は即座に未認証へ』とするが、残留ファイルの扱いは書いていない）。"}
      contract_level: repository
      authority_type: failure_recovery_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: present, rationale: "ディレクトリ列挙失敗は `try?` で握り潰し no-op（`:91`）。", entries: [{location: "Networking/AudioCacheManager.swift:91", purpose: "defense_in_depth"}]}
      implementation_status: partial
      gap: "`:92-94` のループは最初の失敗で throw し、それ以前のファイルは削除済み・以降は残存する。呼出側（`Settings/SettingsViewModel.swift`）が再試行するか、残留を許容するかの契約が無い。"
      test_status: "covered（正常系・ディレクトリ不在）: `AudioCacheManagerTests.swift:133`, `:150`。途中失敗の test は 0 件"
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:88-95"]}
    - id: CI-C05
      operation_id: OP-C2
      requirement_ids: [R6]
      kind: postcondition
      statement: "logout 時、端末上のユーザー固有音声キャッシュが削除される（共有仕様 §6.3: iOS は `AudioCacheManager.removeAllDownloads()` をビルトインで持ち logout 時に自動呼出）。"
      applicability: {status: required, rationale: "共有端末でのデータ残留防止（QL4・R6）。3 platform 共通仕様として明記されている。"}
      contract_level: use_case
      authority_type: contract_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "該当 API が存在しない。"}
      implementation_status: unmet
      gap: "`AudioCacheManager` の公開 API は `cachedURL:45` / `isCached:52` / `cache:62` / `remove:71` / `cacheSize:80` / `clearCache:90` の 6 つで、`removeAllDownloads` は存在しない。`AppState.logout()`（`AppState.swift:282-302`）にもキャッシュ削除の呼出は無い。仕様と実装が矛盾する。"
      test_status: "uncovered"
      resolution_gate: SG-A5
      evidence: {status: contradiction, sources: ["docs/design/shared-playback-spec.md:305-314", "Networking/AudioCacheManager.swift:42-95", "AppState.swift:282-302"]}
    - id: CI-S01
      operation_id: OP-S1
      requirement_ids: [R5]
      kind: postcondition
      statement: "completeLogin の後、sessionStore.token == response.token、currentUser == response.user、authStatus == .authenticated であり、保持済み APNs トークンがあれば登録が予約される。"
      applicability: {status: required, rationale: "認証確立の唯一の入口。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "AppState（`AppState.swift:151-157`）"
      defensive_validations: {status: not_applicable, rationale: "内部遷移。"}
      implementation_status: met
      test_status: "covered: `NewsListenAppTests/AppStateAuthTests.swift:17`, `:105`"
      evidence: {status: confirmed, sources: ["AppState.swift:149-157"]}
    - id: CI-S02
      operation_id: OP-S2
      requirement_ids: [R5]
      kind: postcondition
      statement: "refreshAuth 成功時、currentUser が /auth/me の結果で更新され authStatus == .authenticated になり、preferences 同期とデバイストークン登録が続く。"
      applicability: {status: required, rationale: "起動時の認証復元経路。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "AppState（`:206-215`）"
      defensive_validations: {status: present, rationale: "前提不成立（未設定 / token 無し / apiClient nil）を guard で分離。", entries: [{location: "AppState.swift:202-205", purpose: "early_feedback"}]}
      implementation_status: met
      test_status: "covered（前提不成立経路のみ）: `AppStateAuthTests.swift:49`。成功経路の test は AppStateAuthTests に 0 件"
      evidence: {status: confirmed, sources: ["AppState.swift:197-221"]}
    - id: CI-S03
      operation_id: OP-S2
      requirement_ids: [R5, R4]
      kind: failure_guarantee
      statement: "refreshAuth の失敗は『資格情報が無効（401 相当）』と『一時的に確認できない（ネットワーク断・5xx・デコード失敗）』を区別し、前者のときだけ保存済みトークンを破棄する。"
      applicability: {status: required, rationale: "R5 は 401 での未認証遷移を要求するが、区別しない実装は圏外起動で Keychain のトークンを消し、再ログインを強制する。破棄は不可逆（Keychain から復元不能）。"}
      contract_level: use_case
      authority_type: failure_recovery_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "分類が存在しない。"}
      implementation_status: unmet
      gap: "`:216-220` の catch は型を見ずに `sessionStore.token = nil` を実行する。`APIError.httpError(statusCode:)` は 401 と 500 を同型で表すため（CI-A01）、呼出側が区別しようとしても数値比較しか手段が無い。"
      test_status: "uncovered（ネットワークエラーで token が残ることを assert する test は 0 件。`MockURLSession`（`APIClientTests.swift:637`）が URLError を再現できない点も制約）"
      resolution_gate: SG-C5
      evidence: {status: confirmed, sources: ["AppState.swift:197-221", "Networking/APIClient.swift:20-29"]}
    - id: CI-S04
      operation_id: OP-S3
      requirement_ids: [R5]
      kind: postcondition
      statement: "logout の後、authStatus == .unauthenticated、currentUser == nil、sessionStore.token == nil であり、サーバ側失効の成否によらずこの 3 つは成立する。"
      applicability: {status: required, rationale: "『ローカルは必ず落とす』が `:280` に明記された設計方針。"}
      contract_level: use_case
      authority_type: state_authority
      authoritative_owner: "AppState（`:299-301`）"
      defensive_validations: {status: present, rationale: "API 呼出を `try?` で包み、失敗がローカル破棄へ波及しない。", entries: [{location: "AppState.swift:292-294", purpose: "defense_in_depth"}]}
      implementation_status: met
      test_status: "covered: `AppStateAuthTests.swift:34`, `:87`"
      evidence: {status: confirmed, sources: ["AppState.swift:278-302"]}
    - id: CI-S05
      operation_id: OP-S3
      requirement_ids: [R6]
      kind: prohibited_transition
      statement: "logout 完了後の端末に、前利用者を特定・再現できるデータ（音声キャッシュ・ロック画面の再生情報・主体依存の UserDefaults 値・メモリ上の再生セッション）が残らない。"
      applicability: {status: required, rationale: "共有端末前提（共有仕様 §6.3）と QL4（must-hold 制約）。"}
      contract_level: use_case
      authority_type: contract_owner
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "削除処理が部分的にしか存在しない。"}
      implementation_status: unmet
      gap: "`logout()`（`:282-302`）が消すのは (a) `seenAchievementIDs`（`:298`）、(b) Keychain の token（`:299`）、(c) currentUser / authStatus のみ。残るもの: 音声キャッシュ全体（CI-C05）、`MPNowPlayingInfoCenter.default().nowPlayingInfo`（`PodcastViewModel.swift:611` で消えるのは stopPlayback 時のみで logout は stopPlayback を呼ばない）、`apnsDeviceToken` プロパティ、UserDefaults の主体依存値（`AppState.swift:40-47` の 5 キー。どれが主体依存かは未棚卸し）、`PodcastViewModel` のメモリ上の `currentPodcast` / `queue` / `downloadedIds`（logout 後も同一インスタンスが生存）。"
      test_status: "uncovered（`AppStateAuthTests.swift:34` は token / currentUser のみ検証）"
      resolution_gate: SG-A5
      evidence: {status: contradiction, sources: ["AppState.swift:282-302", "docs/design/shared-playback-spec.md:305-314", "Podcast/PodcastViewModel.swift:581-612"]}
    - id: CI-S06
      operation_id: OP-S4
      requirement_ids: [R3, R5]
      kind: invariant
      statement: "API 呼出時に送出されるセッショントークンは、その時点で有効な最新のトークンである。"
      applicability: {status: required, rationale: "logout / 失効後に旧トークンが送出される経路があると、失効の意味が端末側で保証されない（QL4）。"}
      contract_level: use_case
      authority_type: source_of_truth
      authoritative_owner: "unknown"
      defensive_validations: {status: not_applicable, rationale: "鮮度保証の機構が無い。"}
      implementation_status: unmet
      gap: "`apiClient` は computed で毎回生成されるが（`AppState.swift:137-142`）、生成時の `sessionStore.token` を `let` でスナップショットする（`Networking/APIClient.swift:55,75`）。`PodcastViewModel` は起動時に 1 度受け取った instance を `private let` で保持するため（`Podcast/PodcastViewModel.swift:85,126`）、以後 token が破棄されても旧 token を送り続ける。`:462`（markCompleted）と `:848`（updatePlaybackPosition）は `try?` / 空 catch のため失敗しても観測されない。"
      test_status: uncovered
      resolution_gate: SG-A7
      evidence: {status: confirmed, sources: ["AppState.swift:134-142", "Networking/APIClient.swift:54-77", "Podcast/PodcastViewModel.swift:84-85,120-130"]}
    - id: CI-RT01
      operation_id: OP-RT1
      requirement_ids: [R9]
      kind: postcondition
      statement: "相対時刻の出力は共有仕様 §3.2 のしきい値表に一致し、年判定を月判定より先に行う。入力の `now` は注入され、システム時計に依存しない。空文字・パース不能入力は空文字を返す。"
      applicability: {status: required, rationale: "spec §3 と §4.2 の 17 行が正本。"}
      contract_level: value_object
      authority_type: semantic_owner
      authoritative_owner: "RelativeTimeFormatter（`NewsListenApp/Utilities/RelativeTimeFormatter.swift`）"
      defensive_validations: {status: present, rationale: "アダプタ層が ISO8601 パース失敗を空文字へ落とす（spec §3.3 が scope 外挙動として記録）。", entries: [{location: "NewsListenAppTests/RelativeTimeConformanceTests.swift:120-125", purpose: "malformed_input"}]}
      implementation_status: met
      test_status: "covered: `RelativeTimeConformanceTests.swift:16`〜`:125`（17/17。§4.2 の表を参照）"
      evidence: {status: confirmed, sources: ["NewsListenAppTests/RelativeTimeConformanceTests.swift:12-125", "docs/design/shared-playback-spec.md:141-169,244-267"]}
```

---

## 7. Idempotency assessments

```yaml
  idempotency_assessments:
    - operation_id: OP-Q4
      applicability: required
      rationale: "add は spec §2.5 で明示的に『既に同一 id が含まれていれば no-op』と定義された冪等操作。"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:59-62"]}
      contract_item_ids: [CI-Q06]
      mechanism: {key_scope: "Podcast.id（キュー内で一意）", key_lifetime: "queue インスタンスの生存期間", duplicate_result: "状態無変化", fingerprint_rule: "id 一致のみ（内容差は見ない）", retry_rule: "not_applicable（同期・失敗しない）"}
    - operation_id: OP-Q9
      applicability: not_applicable
      rationale: "並べ替えは冪等ではない（同じ引数の 2 回目は別の結果を生む）。純粋な同期操作で retry も duplicate delivery も発生しない。"
      evidence: {status: confirmed, sources: ["Podcast/PlaybackQueue.swift:118-141"]}
      contract_item_ids: []
    - operation_id: OP-P8
      applicability: required
      rationale: "UI からの重複タップと await を跨ぐ再入が実在し、外部副作用（API 2 回 + FS 書込）を伴う。"
      evidence: {status: confirmed, sources: ["Podcast/PodcastViewModel.swift:188-213"]}
      contract_item_ids: [CI-P24, CI-P25]
      mechanism: {key_scope: "podcast.id（downloadingIds / downloadedIds の集合メンバシップ）", key_lifetime: "VM インスタンス生存期間（永続化されない。アプリ再起動後は syncDownloadedState（`:157-159`）が FS から再構成）", duplicate_result: "即 return（エラーにしない）", fingerprint_rule: "id のみ", retry_rule: "自動 retry 無し。失敗後は集合から除かれるため再タップで再実行できる"}
    - operation_id: OP-P4
      applicability: unknown
      rationale: "`markCompleted(id:)` は同一エピソードに対して複数回到達し得る（replay → 再終了、通知の二重発火、次回起動後の再視聴）。サーバ側が完聴を冪等に扱うか、ストリークを二重加算するかが本 review の scope 外で未確認。`try?` で結果を捨てるため、重複の影響をクライアントからは観測できない。"
      confirmation_method: "backend の `POST /podcasts/{id}/complete` 実装（completed_at の upsert か insert か）と listening streak 集計ロジックを確認する（OB-N4）。"
      impact_if_unresolved: "重複加算があれば学習ストリークという利用者に見える値が壊れる。逆に冪等なら CI-P16 の best-effort 方針で十分であることが確定する。"
      evidence: {status: unknown, sources: ["Podcast/PodcastViewModel.swift:455-464", "Networking/APIClient.swift:153-164"]}
      contract_item_ids: []
    - operation_id: OP-C2
      applicability: required
      rationale: "remove / clearCache は失敗後の再試行と logout 経路からの重複呼出があり得る。"
      evidence: {status: confirmed, sources: ["Networking/AudioCacheManager.swift:71-95"]}
      contract_item_ids: [CI-C03, CI-C04]
      mechanism: {key_scope: "podcast id に対応するファイルパス", key_lifetime: "FS 上のファイル存在期間", duplicate_result: "no-op で正常終了", fingerprint_rule: "パス存在チェック", retry_rule: "呼出側が任意に再試行可能（clearCache は部分削除後の再試行で残りを削除できる）"}
    - operation_id: OP-S3
      applicability: required
      rationale: "logout は連打・失敗後の再実行があり得る。"
      evidence: {status: confirmed, sources: ["AppState.swift:278-302"]}
      contract_item_ids: [CI-S04]
      mechanism: {key_scope: "not_applicable（キー不要。すべての post が絶対状態への代入）", key_lifetime: not_applicable, duplicate_result: "2 回目も同じ最終状態（token nil / user nil / unauthenticated）", fingerprint_rule: not_applicable, retry_rule: "サーバ失効 API は失敗しても retry しない（`:290` に許容理由を明記）"}
    - operation_id: OP-RT1
      applicability: not_applicable
      rationale: "副作用の無い純粋関数であり、同じ (target, now) から常に同じ文字列を返す。retry / duplicate の概念が成立しない。"
      evidence: {status: confirmed, sources: ["docs/design/shared-playback-spec.md:133-139"]}
      contract_item_ids: []
```

---

## 8. RelativeTimeFormatter（RT）対応表の所在

RT-01〜RT-15 / RT-A01・RT-A02 の 17 行と `NewsListenAppTests/RelativeTimeConformanceTests.swift` の突合表は **§4.2 に記載済み**（分母 17 / 一致 17 / 矛盾 0）。期待値は spec 本文の行（`docs/design/shared-playback-spec.md:246-267`）と test の `XCTAssertEqual` 実引数を 1 行ずつ読んで確認した。対応する contract item は CI-RT01。

---

## 9. Coverage

```yaml
  coverage:
    requirement:
      denominator: 9        # R1〜R9（ブリーフ §4 seed 全件）
      numerator: 6          # R1, R2, R3, R4, R5, R9
      uncovered_ids:
        - {id: R6, status: contradictory, reason: "CI-C05 / CI-S05 が仕様と実装の矛盾を特定済みだが、required CI に oracle 付き test が 1 件も無く、SG-A5 が pending のため T* 化できない"}
        - {id: R7, status: missing, reason: "テスト経路そのものの要件であり、本 package に所有 contract item が無い。Test Function 所管（OB-N3）"}
        - {id: R8, status: out_of_scope, reason: "CI / make test の同一性は operation 契約ではない。§2 で in_scope: false と宣言済み"}
      note: "R1・R7 は §2 で in_scope: partial。R1 は CI-P06（再開位置閾値）だけを裏付けており、パスワード規則・admin 判定・featured grouping は対象外。"
    contract:
      denominator: 55       # applicability: required の contract item 総数（applicability: unknown / not_applicable の item は 0 件）
      numerator: 37         # statement + contract_level + authority_type + 単一の authoritative_owner + Evidence が揃う item
      incomplete_item_ids:  # authoritative_owner: unknown（＝ owner 未決）の 18 件。statement と Evidence はあるが owner が確定しない
        [CI-Q02, CI-Q13, CI-P03, CI-P04, CI-P05, CI-P08, CI-P09, CI-P11, CI-P13, CI-P17, CI-P19, CI-P23, CI-A04, CI-C04, CI-C05, CI-S03, CI-S05, CI-S06]
    test:
      denominator: 55
      numerator: 39         # 既存テストで covered 32 + 本 package が新規に設計した planned test 7（T-Q1, T-P1, T-P2, T-A1, T-A2, T-C1, T-S1）
      uncovered_item_ids:   # 16 件。すべて SG 未決のため T* を定義しない
        [CI-Q02, CI-Q13, CI-P03, CI-P04, CI-P05, CI-P08, CI-P09, CI-P13, CI-P17, CI-P19, CI-P23, CI-C04, CI-C05, CI-S03, CI-S05, CI-S06]
    implementation_status_breakdown:
      met: 35
      partial: 5            # CI-Q13, CI-P11, CI-P23, CI-C01, CI-C04
      unmet: 15             # CI-Q02, CI-P03, CI-P04, CI-P05, CI-P08, CI-P09, CI-P13, CI-P17, CI-P19, CI-A02, CI-A04, CI-C05, CI-S03, CI-S05, CI-S06
      unknown: 0
      denominator: 55
    conformance_tables:
      queue: {denominator: 32, matched: 32, partial_oracle_ids: [Q-06], contradictions: 0, uncovered_contract_ids_outside_table: [CI-Q02, CI-Q08, CI-Q13]}
      relative_time: {denominator: 17, matched: 17, contradictions: 0}
    unknown_item_ids: []    # applicability が unknown の item は無い。未決は「owner」と「手段」であり、SG-* / OB-N* として分離した
```

**読み方の注意**: Q 32/32・RT 17/17 green は「正本テストケース表の全行を満たす」ことだけを意味し、R9（契約として名前差と IndexSet 複数移動を明示する）は満たしていない。表の外に required contract item が 3 件（CI-Q02 / CI-Q08 / CI-Q13）ある。

---

## 10. Contract tests（未 coverage CI のうち owner が確定している 7 件のみ。design mode = planned / not_run）

```yaml
  tests:
    - id: T-Q1
      operation_id: OP-Q5
      requirement_ids: [R9]
      verifies: [CI-Q08]
      given: "items=[a,b,*c*]（currentIndex=2、current=c）"
      when: "playNext(a) を呼ぶ（current より前に既存する要素を『次に再生』する）"
      then: ["items == [b, c, a]", "current?.id == \"c\"（同一エピソードを指し続ける）", "upNext == [a]"]
      oracle: "`PlaybackQueue` の items 配列の id 列と current?.id を XCTAssertEqual で比較する。実装詳細（currentIndex の再計算方法）には触れない。"
      environment_conditions: []
      implementation_status: planned
      execution_status: not_run
      evidence: ["Podcast/PlaybackQueue.swift:65-75"]
    - id: T-P1
      operation_id: OP-P8
      requirement_ids: [R2]
      verifies: [CI-P24]
      given: "未ダウンロードの podcast と、fetchPodcast / downloadAudio の呼出回数を数える URLSession double を注入した PodcastViewModel"
      when: "download(podcast:) を await せずに 2 回起動し、両方の完了を待つ"
      then: ["downloadAudio に対応するリクエストが 1 回だけ発行される", "downloadedIds が podcast.id を 1 度だけ含む", "downloadingIds が空に戻る"]
      oracle: "URLSession double が記録した URLRequest 列の件数と、VM の公開 Set の内容。"
      environment_conditions: ["@MainActor 上で実行する（VM が MainActor 隔離のため）"]
      implementation_status: planned
      execution_status: not_run
      evidence: ["Podcast/PodcastViewModel.swift:188-213"]
    - id: T-P2
      operation_id: OP-P8
      requirement_ids: [R2, R3]
      verifies: [CI-P25]
      given: "downloadAudio が失敗（非 2xx）を返す URLSession double"
      when: "download(podcast:) を呼ぶ"
      then: ["downloadedIds に podcast.id が含まれない", "downloadingIds に podcast.id が含まれない", "errorMessage が非 nil", "downloadState(for:) == .notDownloaded"]
      oracle: "VM の公開プロパティ。キャッシュ FS 側は `isCached == false` でも確認する。"
      environment_conditions: []
      implementation_status: planned
      execution_status: not_run
      evidence: ["Podcast/PodcastViewModel.swift:188-213"]
    - id: T-A1
      operation_id: OP-A1
      requirement_ids: [R4]
      verifies: [CI-A02]
      given: "HTTPURLResponse ではない URLResponse（素の `URLResponse(url:mimeType:expectedContentLength:textEncodingName:)`）を返す URLSession double"
      when: "downloadAudio(from:) を呼ぶ"
      then: ["呼出が throw する（データを成功として返さない）"]
      oracle: "`XCTAssertThrowsError`。投げるエラー型の選択は実装判断に委ねるが、『成功として Data を返さない』ことは観測可能な契約。"
      environment_conditions: []
      implementation_status: planned
      execution_status: not_run
      evidence: ["Networking/APIClient.swift:536-538"]
      note: "現行の `MockURLSession`（`NewsListenAppTests/APIClientTests.swift:637`）は常に HTTPURLResponse を返すため、この test を書くには double の拡張が必要（R7 と接続）。"
    - id: T-A2
      operation_id: OP-A3
      requirement_ids: [R4]
      verifies: [CI-A04]
      given: "baseURL が末尾スラッシュ有無・パーセントエンコード必須文字を含む複数パターン、url / token 引数が空文字・制御文字・極端長の組合せ"
      when: "removeSource(url:) と unregisterDeviceToken(_:) を呼ぶ"
      then: ["プロセスが crash しない", "リクエストが発行されるか、または呼出側が捕捉できるエラーが throw される"]
      oracle: "テストプロセスが生存したまま完了すること（crash すれば test runner が落ちる）と、URLSession double が受け取った URLRequest。"
      environment_conditions: []
      implementation_status: planned
      execution_status: not_run
      evidence: ["Networking/APIClient.swift:272-277,300-305"]
    - id: T-C1
      operation_id: OP-C1
      requirement_ids: [R6]
      verifies: [CI-C01]
      given: "キャッシュディレクトリの外に実在するファイル（テスト用一時ディレクトリに作成）と、それを指す相対パスを含む id（例 `\"../evil\"`）"
      when: "isCached(id) と cachedURL(for: id) を呼ぶ"
      then: ["isCached が false を返す、または AudioCacheError.invalidId を投げる（＝キャッシュディレクトリ外の実在ファイルを『キャッシュ済み』と報告しない）", "cachedURL が返す URL が cacheDirectory 配下から出ない、または throw する"]
      oracle: "返り値の URL パス文字列が cacheDirectory の path で始まるかを判定する。書込側（cache / remove）の既存 test（`AudioCacheManagerTests.swift:158,175,204`）と同じ id 集合を読取側へ適用する。"
      environment_conditions: ["FileManagerProtocol の double または一時ディレクトリを使い、実ユーザーディレクトリへ触れない"]
      implementation_status: planned
      execution_status: not_run
      evidence: ["Networking/AudioCacheManager.swift:45-55,99-107"]
    - id: T-S1
      operation_id: OP-S2
      requirement_ids: [R5]
      verifies: [CI-S02]
      given: "有効な token を持つ InMemorySessionStore と、/auth/me が 200 + User JSON を返す APIClient（apiClientOverride 経由で注入）"
      when: "refreshAuth() を await する"
      then: ["authStatus == .authenticated", "currentUser が応答の user と一致", "sessionStore.token が保持されたまま"]
      oracle: "AppState の公開プロパティ。"
      environment_conditions: ["@MainActor"]
      implementation_status: planned
      execution_status: not_run
      evidence: ["AppState.swift:197-221", "NewsListenAppTests/AppStateAuthTests.swift:49"]
```

**T* を定義しなかった未 coverage CI（16 件）と理由**:

| CI | 保留理由（対応 gate） |
|---|---|
| CI-Q02 | 不変条件 1 を setQueue / init でも守るのか、caller 責務にするのかが未決（SG-C1）。owner 確定後に T* 化。 |
| CI-Q13 | 複数要素 IndexSet の期待値が正本に無い。アダプタを分けるか正本へ行を追加するかが未決（SG-C2）。owner 確定後に T* 化。 |
| CI-P03 / CI-P09 | 失敗の意味分類（APIError の再設計）が Boundary Function 所管かつ未決。owner 確定後に T* 化。 |
| CI-P04 | 署名 URL 再取得を iOS へ入れるか、共有仕様 §6.1 を改訂するかが未決（SG-C4・PCC1）。既存 test `:483` が現状挙動を pin している点も同時に決める必要がある。 |
| CI-P05 / CI-P08 / CI-P11 / CI-P17 | 「現在再生中」の source of truth が未決（SG-A1）。owner 確定後に T* 化。 |
| CI-P13 | auto-advance 失敗時の方針（停止 / スキップ）が未決（SG-A3）。owner 確定後に T* 化。 |
| CI-P19 | seek を clamp するか precondition にするかが未決（SG-C3）。owner 確定後に T* 化。 |
| CI-P23 | 再生位置の source of truth（server-wins の適用範囲）が未決（SG-A3）。owner 確定後に T* 化。 |
| CI-C04 | 部分削除の許容可否が未決。SG-A5 の消去範囲決定に従属。 |
| CI-C05 / CI-S05 | logout 時の消去範囲が未決（SG-A5）かつ公開契約変更（PCC1）。owner 確定後に T* 化。 |
| CI-S03 | 失敗分類と token 破棄条件が未決（SG-C5）。owner 確定後に T* 化。 |
| CI-S06 | token 鮮度の保証手段が未決（SG-A7）。owner 確定後に T* 化。 |

---

## 11. Selection Gate 候補と Obligation

### 11.1 本 Function が新たに検出した Selection Gate（すべて owner: user・status: pending）

```yaml
  selection_gate_candidates:
    - id: SG-C1
      subject: "PlaybackQueue の不変条件 1（items の id 一意）を誰が保証するか"
      contract_item_ids: [CI-Q02]
      candidates: ["(i) setQueue / init でも重複を除去し aggregate が常に保証する", "(ii) setQueue を precondition 付き（重複無し配列を渡すのは caller 責務）とし、違反時の挙動を未定義と明記する", "(iii) 共有仕様 §2.1:50 を『add / playNext のみが維持する』の明文どおりに読み、setQueue 経路は仕様の対象外とする"}
      decision_condition: "『キュー全体を外部配列で置換する経路を今後 UI から公開するか』（現状 setQueue は本番未使用）。公開しないなら (ii) で足りる。"
      owner: user
      status: pending
      note: "web 決定（ブリーフ §7）に対応項目なし。3 platform 共通仕様の改訂が必要なら PCC 化する。"
    - id: SG-C2
      subject: "IndexSet 複数要素移動の契約 owner（コアに置くかアダプタを分けるか）"
      contract_item_ids: [CI-Q13]
      candidates: ["(i) `QueueSheet` と `PlaybackQueue` の間にアダプタを置き、コアは単一要素 moveUpNext だけを公開する（正本 §2.7:92 の責務分割どおり）", "(ii) 複数移動を正本仕様へ昇格させ Q 表に行を追加して 3 platform で揃える", "(iii) 現状維持とし、複数移動は iOS 固有の未仕様挙動であると明記する"]
      decision_condition: "SwiftUI onMove が実際に複数 index を渡す UI（複数選択編集モード）を提供する予定があるか。"
      owner: user
      status: pending
    - id: SG-C3
      subject: "seek の範囲外入力を clamp するか precondition 違反とするか"
      contract_item_ids: [CI-P19]
      candidates: ["(i) VM が [0, duration] へ clamp する", "(ii) precondition として明記し、違反時は未定義（現状）", "(iii) 範囲外を失敗として errorMessage にする"]
      decision_condition: "範囲外 currentTime が `updatePlaybackPosition` でサーバへ永続化されることを許容するか。"
      owner: user
      status: pending
    - id: SG-C4
      subject: "キャッシュ無 + オンライン再生で署名 URL を再取得するか（共有仕様 §6.1 との差分）"
      contract_item_ids: [CI-P04]
      candidates: ["(i) iOS の play() に fetchPodcast を入れて仕様へ追随（再生開始が 1 RTT 遅れる）", "(ii) 一覧取得からの経過時間が閾値を超えたときだけ再取得する", "(iii) 共有仕様 §6.1:292-293 を改訂し『再取得は download 時のみ』へ揃える（web / Android への影響を確認したうえで）"]
      decision_condition: "署名 URL の有効期限と、一覧取得〜再生タップまでの実測経過時間の関係。"
      owner: user
      status: pending
      note: "**web 確定決定との差分**。ブリーフ §7 は明示していないが、共有仕様は 3 platform 正本のため、iOS だけの逸脱は cross-platform 決定として扱う。既存 test `PodcastViewModelTests.swift:483` が現状挙動を pin している点も同時に決める。"
    - id: SG-C5
      subject: "refreshAuth の失敗分類と token 破棄条件"
      contract_item_ids: [CI-S03, CI-A01]
      candidates: ["(i) APIError に unauthorized / network 等の意味ケースを追加し、401 のときだけ破棄する（R4 の恒久解と同時）", "(ii) URLError のみ判別して『確認できない』扱いにし、それ以外は現状維持", "(iii) 現状維持（全失敗で破棄）とし、圏外起動で再ログインが必要な仕様であると明記する"]
      decision_condition: "圏外・機内モードでの起動頻度と、再ログイン強制の許容度。"
      owner: user
      status: pending
      note: "APIError の再設計は Boundary Function の所管と重なるため、決定は 1 箇所で行う（OB-N2）。"
```

### 11.2 既存 Selection Gate への従属（architecture-strategy-package.md §7 の ID を参照。新規 ID は発行しない）

| 既存 SG | 本 package で従属する contract item |
|---|---|
| SG-A1（現在再生中の正本） | CI-P05, CI-P08, CI-P11, CI-P17 |
| SG-A2（既定速度とセッション速度の接続） | CI-P07（note） |
| SG-A3（auto-advance 失敗時の方針 / 再生位置） | CI-P13, CI-P23 |
| SG-A5（logout 時の消去範囲） | CI-C04, CI-C05, CI-S05, PCC1 |
| SG-A7（APIClient と token 鮮度） | CI-S06 |
| SG-A8（best-effort 失敗の観測方針） | CI-P16（note）, CI-S06（失敗が観測されない点） |

### 11.3 Obligation（他 Function / オーケストレータへの依頼）

```yaml
  obligations:
    - id: OB-N1
      to: domain-model-completeness
      request: "`completeness-package.md` 完成後、CI-Q02（id 一意性の owner 不在）・CI-P05（現在再生中の 2 正本）・CI-S05（logout 後の残留データ）を gap ID へ紐付けて返す。本 package は安定 ID 未発行のため domain_obligation_ids を空にしている。"
      blocking: false
    - id: OB-N2
      to: interface-implementation-separation（Boundary Function）
      request: "`APIError` の意味ケース設計（CI-A01 / CI-P03 / CI-P09 / CI-S03 が同一の根に依存）と、View 直呼び経路（`Settings/AccountSettingsView.swift:305-333`）の扱いを 1 箇所で決める。本 package は失敗分類の contract item だけを発行し、手段は選択していない。"
      blocking: true
      blocks: [CI-P03, CI-P09, CI-S03]
    - id: OB-N3
      to: test-strategy（Test Function）
      request: "(a) `MockURLSession`（`NewsListenAppTests/APIClientTests.swift:637`）が非 HTTPURLResponse と URLError を再現できるよう拡張する方針（T-A1 / SG-C5 の前提）。(b) R7 / R8 は本 package に contract item を持たない。"
      blocking: false
    - id: OB-N4
      to: orchestrator
      request: "backend の完聴記録（`POST /podcasts/{id}/complete`）とストリーク集計が重複呼出に対して冪等かを確認する。OP-P4 の idempotency assessment が `unknown` のまま hard gate に触れている。"
      blocking: true
      blocks: [CI-P15, CI-P16]
    - id: OB-N5
      to: orchestrator
      request: "本 package の CI-P04（署名 URL 再取得）は共有仕様 `docs/design/shared-playback-spec.md` の改訂可能性を含む。web / Android の同一契約の実装状況を確認しないと SG-C4 を決定できない。"
      blocking: true
      blocks: [CI-P04]
```

---

## 12. Verdict と decision

```yaml
  subject_verdict: insufficient
  subject_verdict_rationale: >
    対象（iOS の再生・キャッシュ・認証の公開操作）は、共有仕様の正本テストケース表に対しては完全準拠している（Q 32/32・RT 17/17・矛盾 0）。
    一方で required contract item 55 件のうち 15 件が unmet・5 件が partial であり、うち 4 件は仕様と実装の矛盾（CI-P04 署名 URL 再取得・CI-C05 removeAllDownloads 不在・CI-S05 logout 残留・CI-Q13 scope 外挙動のコア実装）として Evidence 付きで特定できる。
    gap が特定可能である以上 indeterminate ではなく insufficient。
  key_unmet_by_severity:
    - {id: CI-S05, why: "QL4（must-hold 制約）違反。共有端末で前利用者の音声キャッシュと再生情報が残る"}
    - {id: CI-C01, why: "検証が書込側だけの非対称な境界。サーバ由来 id がそのまま読取パスへ入る"}
    - {id: CI-P04, why: "3 platform 共通仕様との矛盾。署名失効時に再生できない経路が残る"}
    - {id: CI-P13, why: "R2 が名指しで禁じる不正状態（advance 後に current と queue が別エピソード）が日常経路で発生する"}
    - {id: CI-S03, why: "圏外起動で不可逆に token を破棄する"}
    - {id: CI-A02, why: "非 HTTP 応答の fail-open。既存 double では到達不能"}
  decision:
    status: ready_with_open_gates
    artifact: contract-package
    completed:
      - "公開 operation 21 件の inventory（PlaybackQueue 10 / VM 再生 9 / API 3 / Cache 2 / AppState 4 / RT 1 を OP-* として発行）"
      - "required contract item 55 件（pre / post / invariant / failure_guarantee / prohibited_transition / idempotency）"
      - "Q-01〜Q-32（32 行）と RT-01〜RT-A02（17 行）の期待値突合（実コードと test の実引数を 1 行ずつ確認）"
      - "idempotency assessment 7 件（required 4 / not_applicable 2 / unknown 1）"
      - "planned contract test 7 件（verifies + 観測可能 oracle 付き・未実行）"
      - "coverage の分母 / 分子 / 未 coverage ID"
    open_gates:
      selection_gates: [SG-C1, SG-C2, SG-C3, SG-C4, SG-C5]
      inherited_gates: [SG-A1, SG-A2, SG-A3, SG-A5, SG-A7, SG-A8]
      blocking_obligations: [OB-N2, OB-N4, OB-N5]
    not_ready_reasons:
      - "authoritative_owner が unknown の required item が 18 件あり、Skill の hard gate（required item に authoritative owner が必要）に抵触する。owner は data authority / boundary の決定に従属するため、本 Function が単独で確定してはならない。"
      - "OP-P4 の idempotency が unknown（backend 契約未確認）。"
      - "公開契約変更（PCC1）の approval が pending。"
    ai_recitation:
      proposed_status: matched
      reviewed_by: unresolved
      note: "AI 復唱は自己証明にならない。公開契約（CI-P04 / CI-C05 / CI-S05）・data meaning（CI-P05 / CI-P23）・認可（CI-S03 / CI-S06）は AI が確定せず Selection Gate へ隔離した。独立評価または人間承認はオーケストレータが取る。"
    mode: review
    mutation_performed: none
    files_written: ["/private/tmp/claude-501/-Users-rio-git-news-listen-ios/553632af-0e6e-4210-bef5-56d77d1b3e4d/scratchpad/contract-package.md"]
```

---

## 13. path:line 範囲検査

本 package 内の `file:N` 表記を重複排除して抽出し、各ファイルの総行数と比較した。

```bash
for f in $(grep -oE '[A-Za-z0-9_/.-]+\.(swift|md):[0-9]+' contract-package.md | sort -u); do
  p="${f%:*}"; n="${f##*:}"
  for root in .../NewsListenApp/NewsListenApp .../NewsListenApp /Users/rio/git/news-listen; do
    if [ -f "$root/$p" ]; then tot=$(wc -l < "$root/$p"); [ "$n" -gt "$tot" ] && echo "OUT_OF_RANGE $f (total $tot)"; break; fi
  done
done
```

結果: **参照 `file:N` 150 件（重複排除後）／範囲外 0 件**。

参照先ファイルの総行数（検査時点・HEAD `c8c1ada`）:
`Podcast/PlaybackQueue.swift` 143 / `Podcast/PodcastViewModel.swift` 854 / `Networking/APIClient.swift` 547 / `Networking/AudioCacheManager.swift` 119 / `AppState.swift` 366 / `Models/Podcast.swift` 214 / `docs/design/shared-playback-spec.md` 327 / `NewsListenAppTests/PlaybackQueueConformanceTests.swift` 320 / `PlaybackQueueTests.swift` 130 / `PodcastViewModelTests.swift` 1211 / `AudioCacheManagerTests.swift` 222 / `AppStateAuthTests.swift` 126 / `APIClientTests.swift` 660 / `RelativeTimeConformanceTests.swift` 127。

行番号はすべて 1 ファイル単位の `grep -n` / `sed -n` で取得しており、複数ファイルを連結した出力の通し番号は引用していない。
