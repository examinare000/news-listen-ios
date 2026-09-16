# spec-gate — Implementation Spec 事前実装ゲート（architecture ロール / read-only / 1 回）

対象: `/Users/rio/git/news-listen/ios/docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（352 行）
参照: `ios/docs/research-reports/2026-09-16-code-design-review.md` §4・§8、`docs/design/shared-playback-spec.md` §2/§5/§6、`web/docs/design/2026-09-16-implementation-spec-domain-model.md`、`~/.claude/skills/mino-core/references/code-design.md`、実コード（PodcastViewModel / PlaybackQueue / AppState / APIClient / NewsListenAppApp / NewsListenAppTests）
baseline: HEAD `c8c1ada`（Spec 記載）

## gate_verdict

**revise**（構造・判断順・port 選定は妥当。実装着手を止める欠落は 2 件＝M1 合成 root の所有権未定義、M2 §8 逸脱の無断拡張。他は記述修正）

blocked にしない理由: 設計の骨格（Queue 正本 + INV-P1 / 状態 union / 4 port / ApiFailure / SubjectCleanup）は §8 の user 決定と web Spec に整合し、修正はいずれも Spec 内の追記・削除で閉じる。S1 着手は M1〜M4 反映後に可能。

## 観点別判定

| # | 観点 | 判定 | 根拠（1 行） |
|---|---|---|---|
| 1 | Design gate（判断順・port 4 つ） | pass | actor→UC→概念→契約→capsule→依存方向→移行の順に節が並び、`rejected_overdesign` で RO1〜RO7 を名指し却下。port は AudioEngine / NowPlayingCenter / FileStore / URLSessionProtocol の 4 つで、前 2 つに「16 遷移の XCTest」「logout クリアの外部制御点」という品質根拠がある |
| 2 | code-design（公開操作・漏出・branch 分類） | revise | 公開操作は意図名（`startEpisode` / `nowPlaying()` / `stopForLogout`）で mutable setter を廃し、leakage guard に AVPlayer / CMTime / status 数値を列挙。ただし CP1 の `state` が query か公開プロパティか未定義、branch_decisions に RF9(f) の isAdmin 行が §8「変更しない」と矛盾（M2） |
| 3 | §8 人間判断との整合（Q1〜Q10） | revise | Q1〜Q8 は反映済み（Q2 playById のキュー操作化＝`startEpisode` 1 経路、Q3 停止方針＝CI-T6、Q6 再取得＋フォールバック＝CI-T5）。逸脱 3 件: (a) SG-S1 が Q3 で確定済みの「3 platform 共通」を pending として再審議、(b) S4 の role 文字列 enum 化は §8.3「RF9(c)〜(f) 変更しない」の外、(c) OfflineLibrary 読取側 validateId は §8.3「RF4 は記録のみ・id 規則確認のみ」の外（M2） |
| 4 | 共有仕様互換 | revise | 公開操作名・不変条件 1〜5・Q-01〜Q-32 は不変で、S0 は §2 追記・§2.7 iOS 欄・§6.3 iOS 欄のみ＝既存行を変えない。ただし §2.7 は「IndexSet 複数移動はアダプタ責務・コア仕様外」と明記しており、iOS 欄を「コア拡張」と書くと正本文と衝突する。加えて §3.1 が約束する「名前差の対応表（reorderUpNext ↔ moveUpNext）」が S0 の改訂項目に無い（M3） |
| 5 | 過剰・不足（G/IV/unmet 15） | revise | G1〜G14・IV1〜IV12 は §3 の target model と CI-T1〜T18 で対応し、unmet 15＋partial 1 = 16 件の met 見込みと「変えない 3 件（A04 / S06 / P11）」を明示＝閉じ方は追える。不足は multi-move の契約（RF20 が要求した owner 決定の裏に契約・テストが無い、M3）。過剰は観点 3 の (b)(c) |
| 6 | testability | revise | CI-T1〜T18 の oracle は概ね公開 API 経由（`state` / `nowPlaying()` / gateway double の呼出列 / `savedIds` / `lastSyncFailure`）で、AudioEngine double が `EngineEvent` を publish する設計なら 16 遷移は駆動可能。T-T13（grep）は CI 実行の静的 oracle として妥当だが T-T7b（「コンパイル境界で直接代入不可を保証」）は XCTest で観測できず oracle にならない（M4）。**S3 の移植見積りが実測と不一致**: Spec は「AVFoundation 型を触る 11 箇所」と書くが、実測は AVPlayer/AVPlayerItem のリテラル出現 6 + engine 結合 API 呼出（`handlePlayerItemStatusChange` / `handleTimeControlStatusChange` / `shouldProcess*` / `didPlayToEndTimeNotification` / `vm.player`）計 22 箇所、**影響テスト関数は 68 中 17**（M4） |
| 7 | 移行現実性 | revise | S0→S5 の順序と TP1〜TP3 の削除条件は妥当で、「特性テストが全件 green になってから一括切替」という S3 の回復規律も明示。iOS 17 の typed throws 非対応は §4 冒頭で回避策込みで扱えている。致命的欠落は **合成 root の所在**（M1）。S2 の二重作業（現行 VM に `stopForLogout` を先に実装）は S2 で Cleanup を閉じるための意図的コストとして許容だが、破棄条件（S3 で置換）を temporary path 化していない（M5） |
| 8 | 記述の整合（ID 相互参照・分母） | pass（軽微修正あり） | CI-T1〜T18 / CP1〜CP11 / UC 12 件 / SG-S1〜S3 は §7 trace から解決でき、UC 分母 12（CI 対象 11 + 対象外 UC-S3）・遷移分母 16・decode 分母 20・conformance 49（32+17）と分母を明示。テスト件数は実測一致（PodcastViewModel 68 / Queue 12+32=44 / NowPlayingInfo 13 / AudioCache 13 / Transcript 13 / APIClient 34 / AuthAPIClient 8 / Feed 40 / Starred 15 / Settings 26 / Login 4 / Passkey 6+7=13 / Onboarding 5 / AppState 8+3+1）。CP5 `EpisodeDecoder` と CP9 `PositionReporter` の公開操作が §5 `public_operations` に無い（M6） |

path:line 範囲検査: router 側で実施済みのため省略（本ゲートでは wc -l 検査を行っていない＝**未確認**）。

## 修正リスト（重要度順）

### M1（blocker 相当・S1 着手前に必須）合成 root と Coordinator の所有権を §2 で確定する
- 事実: `AppState` は `NewsListenAppApp.swift:19` の `@StateObject`、`PodcastViewModel` は `ContentView` の `@StateObject`（`:104,113-122`）で **authenticated ブランチでのみ生成**される。現状 AppState から VM/Coordinator への参照は存在しない。
- 問題: §3.3 の SubjectCleanup は `PlaybackCoordinator.stopForLogout()` と単一 `OfflineLibrary.clearAll()` を呼ぶ前提だが、その参照をどこから得るかが Spec に無い。§2 の図は「Composition root (NewsListenAppApp / AppState)」と書くだけで所有者・生存期間・注入方法を定義していない。このままでは CI-T15 の oracle（`nowPlaying()` nil / `NowPlayingCenter.clear` 1 回 / `usage() == 0`）を AppState 側の unit test から駆動できず、S2 の「現行 VM に stopForLogout」も配線できない。
- 直し方: §2 に capsule 表と同格で **composition root 節**を新設し、(a) `OfflineLibrary` / `NowPlayingCenter` / `AudioEngine` adapter / `PlaybackCoordinator` の生成場所（App struct 直下の `AppDependencies` 値か AppState 保持か）、(b) ContentView 破棄に耐える生存期間、(c) AppState → Coordinator の参照経路を **port 名付きで**（例: `protocol PlaybackLifecycle { func stopForLogout() }` を AppState が weak で保持し、生成時に登録）明記する。§6 の S2 行に「Coordinator 生存期間の移動」を独立ステップとして追加し、この port が S2 の RED（T-T15）を成立させることを書く。

### M2（高）§8 の決定からの無断逸脱 3 件を削除するか SG として user へ返す
- (a) §8 `selection_gates` の `SG-S1`: Q3 は「spec §2 に追記（3 platform 共通）」で **satisfied**。pending として再提示するのは決定の再審議にあたる。`status: satisfied, evidence: [Q3]` に改め、残る論点（Android の追随義務の書き方）だけを注記に落とす。
- (b) §6 S4 行と §5 `branch_decisions` の「role 文字列の enum 化」: §8.3 は RF9(c)〜(f) を「変更しない」と決定済み。S4 から削除する（削除が既定）。残したいなら新規 SG として `status: pending, owner: user` で §8 に立て、S4 の作業から外す。
- (c) §3.1 OfflineLibrary の「読取側（`url` / `has`）にも `validateId` を適用」: §8.3 は RF4 を「記録のみ・backend の id 規則確認のみ」と決定。CI-T10 の該当句とともに削除し、unknown U1 の確認事項に留める。残すなら同じく新規 SG にする。
- 併せて §3.5 の `ApiFailure` から `timeout` を削除する（Q7 の列挙に無く、`network(URLError)` と意味が重なる。`validation` / `unknown(status)` は網羅性のため許容だが、CI-T12 の statement に「`unknown(status)` は 2xx/既知以外の status」とマッピング規則を 1 行書く）。

### M3（高）§2.7 との衝突回避と multi-move の契約化
- S0 の §2.7 iOS 欄の文言を「**コア拡張**」から「コア仕様の対象外である IndexSet 複数移動を iOS 実装が内部的に提供する（コア契約は単一要素のみ。複数要素の期待値は iOS ローカル契約）」に改める。正本文（アダプタ責務・スコープ外）を否定しない書き方にする。
- §4 に **CI-T9b** を追加: 「複数要素 `reorderUpNext` の期待値（onMove 規約・削除前オフセット）」を iOS ローカル契約として固定し、T-T9b（`upNext=[b,c,d]`、`IndexSet([0,1])`→`toOffset=3` 等の表駆動）を置く。RF20 が要求した owner 決定は、契約とテストが無いと検証不能。
- §3.1(2) が約束する「名前差は spec の対応表で吸収」を S0 の改訂項目に明記する（`moveUpNext`(正本) ↔ `reorderUpNext`(iOS 実装) ↔ `PodcastViewModel.moveUpNext`(アダプタ) の 3 者対応。実コードでは VM が既に `moveUpNext` 名を持つ＝`PodcastViewModel.swift` の該当メソッドが `queue.reorderUpNext` を呼ぶ構造）。
- 併せて §6 S0 に「複数移動をアダプタ（VM）へ移す案を採らなかった理由」を 1 行足す（RF20 は core / adapter の二択を要求しており、Spec は core を選んだが却下理由が未記載）。

### M4（中）testability の 2 点
- T-T7b を差し替える: 「コンパイル境界で保証」は XCTest の oracle にならない。(i) `currentPodcast` を `private(set)` / computed にすることを §5 leakage guard の静的規約とし、(ii) **T-T13 と同種の grep oracle**（`grep -rn 'currentPodcast =' NewsListenApp/NewsListenApp --include=*.swift` が 0 件、DEBUG ファクトリを除く）として CI で実行する形に書き換える。
- S3 行の「AVFoundation 型を触る 11 箇所」を実測値へ訂正する: AVPlayer/AVPlayerItem リテラル 6 箇所（`PodcastViewModelTests.swift:750,757,771,778,1069,1094`）に加え、engine 結合 API の呼出（`handlePlayerItemStatusChange` / `handleTimeControlStatusChange` / `shouldProcessPlayerItemCallback` / `shouldProcessPlayerCallback` / `didPlayToEndTimeNotification`）17 箇所と `vm.player` 参照 5 箇所、**影響を受けるテスト関数は 68 中 17**。移植コストの見積りが約 1.5 倍になるため、S3 を「S3a: 17 関数を AudioEngine double へ移植して green 維持」「S3b: 一括切替」に分割し、S3a 完了を S3b の入口条件（回復手段）として §6 の rollback 節に書く。

### M5（中）S2 の二重作業を temporary path 化する
- S2 の「この時点では `stopForLogout` は現行 `PodcastViewModel` に実装」は S3 で捨てる実装。**TP4** として owner・導入 slice・削除条件（S3 で `PlaybackCoordinator.stopForLogout` へ移管完了）を temporary path 表に追加する。M1 の `PlaybackLifecycle` port を先に決めれば、S2 実装は port の adapter として S3 でそのまま生き残るため、二重作業を実質回避できる（推奨）。

### M6（低）記述の整合
- §5 `public_operations` に CP5（`decode(dto) -> Episode`）と CP9（`attach` / `flush` は記載済みだが `lastSyncFailure` の読出）と CP2 の `isEmpty`（実コードに存在）を補う。CP1 の `state` を「query（読取専用）」と明記する。
- §4 冒頭の「`ApiFailure` 以外の Error が gateway から出ないことを CI-T12 が保証」に対し、T-T12 の oracle に「全 endpoint で `catch { XCTAssertTrue(error is ApiFailure) }` を通す」表駆動を明記する（現状は「既存 34 件を移植」としか書いておらず、分母が endpoint 数になるのか test 数になるのかが読めない）。
- §8 `unknowns` の U3（完聴・位置更新の冪等性）は CI-T8 の「1 セッション内 1 回」がクライアント側抑止である旨を CI-T8 の statement 本体にも 1 句入れる（現在は unknowns 側にしか無い）。

## 棄却した代替案

- **目的**: S3 の一括切替リスクを、facade を二重化した段階移行で下げられないか検討した。／**前提**（未検証）: `PodcastViewModel` の旧公開プロパティ 8 本を新旧両実装から供給する並行運転が SwiftUI の `@Published` 更新経路で破綻しない。／**やったこと**: TP3（旧プロパティを computed で残す）に加えて旧 VM 実装を feature flag で温存する案を比較した。／**結果**: 棄却。`AVPlayer` インスタンスが 2 系統になり NowPlaying / AudioSession の外部状態が競合するため、切替コストよりリスクが高い。Spec の「特性テスト全件 green 後に一括切替」の方が安全。／**残課題**: S3a/S3b 分割（M4）で入口条件を機械的に検査できるようにすること。
- **目的**: `AudioEngine` port を置かず、既存の純関数ガード（`shouldProcess*` / `handle*StatusChange`）の拡張で 16 遷移をテストできないか検討した。／**前提**（未検証）: 状態 union の遷移は KVO 由来の 2 値だけで駆動できる。／**やったこと**: 既存 17 テスト関数が触る API を数え、遷移の駆動源を洗った。／**結果**: 棄却。`ready` / `ended` / `buffering` の 3 事象が `AVPlayerItem` インスタンスと `NotificationCenter` に張り付いており、port 無しでは 16 遷移のうち少なくとも 6 本が実 AVPlayer 依存になる。Spec の port 採用が正しい。／**残課題**: `EngineEvent` の列挙を §3.5 に明示すること（現在は「`AsyncStream<EngineEvent>`」とだけあり、事象の分母が未確定）。
- **目的**: `PlaybackQueue` の dedupe を smart constructor（failable init）にする案を検討した。／**前提**: 共有仕様 §2 の「公開操作は throw しない」規約。／**やったこと**: RF21 / SG-C1 の 2 案（smart constructor vs 内部 gate）を Spec の選択と突き合わせた。／**結果**: 棄却。failable init は conformance テスト 32 件の呼出形を壊すため、Spec の「内部 dedupe gate」が正しい。／**残課題**: なし。

## 未確認（本ゲートで検証できなかったもの）

- path:line 範囲検査（`wc -l` 突合）: router 側で実施済みとの指示により本ゲートでは未実行。
- web Spec `web/docs/design/2026-09-16-implementation-spec-domain-model.md` §3.1 / §4 の CI-T 番号と主題の逐語突合: 未読のため **未確認**。Spec §4 の「番号と主題は web Spec の CI-T と揃える」という主張（T1/T4/T6/T7/T8/T9/T10/T11/T12/T15/T17）は検証していない。M2 で `ApiFailure` のケース集合を変える場合は web 側 CI-T12 との差分も確認が要る。
- `mino-reproducible-development/references/integrated-workflow.md` Phase 7 の `implementation_spec` キー集合（`method_provenance` / `premises` / `causal_chain` / `context_packet` / `reasoning_traces` / `rejection_criteria` / `change_boundary` 等）に対する Spec の網羅性: 読み取り途中で打ち切ったため **未確認**。観測した範囲では `decision_frame` / `function_plan` / `selection_gates` / `verification_plan` / `decision` は存在し、`premises` / `causal_chain` / `rejection_criteria` は Spec 本体に無く review 側の package に委譲されている（委譲先が明記されていれば可、要確認）。
- 実行系の検証（`make test` の現状 green、CI 設定の実内容）: read-only ゲートのため未実行。
