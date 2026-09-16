# trial-log: mino 設計 Skill 群による ios 設計レビューの委譲運用
範囲: review mode で 4 Function（architecture / completeness / contract / boundary）を read-only サブエージェントへ委譲する際の運用上の試行と失敗。レビュー内容（finding・package）は `docs/research-reports/2026-09-16-code-design-review.md` が正本で、ここでは扱わない。web 側の同種記録は `web/docs/trial-log/mino-design-review-delegation.md`。

## 2026-09-16 初回実行（`docs/research-reports/2026-09-16-code-design-review.md`）

### 起きたこと
- 目的: web ランブック（`docs/operations/module-design-review-runbook.md`）を ios で再現し、web の失敗（turn 上限・連結読みの行番号・件数誤り）を繰り返さない。
- 前提: 共通ブリーフ（`2026-09-16-code-design-review/p4-common-brief.md`）に web の教訓（10 ターン以内に書き始める・読みは 1〜2 Bash に束ねる・1 ファイル 1 `grep -Hn`・提出前 `wc -l` 検査・件数は per-file）を最初から入れた。
- 結果:
  1. **行番号の誤りは 4 package 495 参照で 0 件**（router の 1 コマンド検査。web 初回の 54 件超過は再発せず）。Explorer 報告の行番号 2 件（`setSpeed` 576→575、PreviewSupport 153/165→152/164）を package 側が再読で自己訂正。→ ブリーフの `path:line` 規律は有効。
  2. **turn 上限（20）に 4 体中 2 体が到達**（Completeness・Contract）。ただし両者とも「10 ターン以内に書き始める」規律により成果物は 1,000 行以上書けており、Completeness は §13 まで完成、Contract は §7 まで。router が「読みなしで残り節を 1 heredoc で追記」と再開指示 → 完走。web 初回の「成果物ゼロ」は再発せず。→ 1,200 行超の package を 20 ターンで書き切るのは限界に近い。次回は「必須 7 項目」を 5 項目に絞るか、Contract を「Queue+RT」と「VM+API+Auth」の 2 体に分ける。
  3. **test-runner（12 ターン上限）が 1 回目に成果物ゼロ**で停止。原因は定量 grep を項目ごとに別 Bash で打ったこと。「1 回の Bash に束ねろ」と再開指示で完走。→ 計測ブリーフには最初から「for ループ 1 本の heredoc スクリプト」を指定する。
  4. **test-runner の件数主張に誤り 2 件**（空 catch「4 件」→ 実は 1 件、AVPlayer 参照「4 ファイル」→ コード行では 2 ファイル）。いずれもコメント行・状態反映 catch を数え込んだもの。Explorer ③ の per-file 内訳が正しく、router が再読で確定（`verification-run.md` §5・§7 の erratum）。→ 件数は「定義行・コメント行・DEBUG 内の扱い」を明示させ、2 経路（Explorer と test-runner）で一致しない値は router が再計測する。
  5. Contract 担当は Completeness package が並列作成中（122 行時点）で安定 ID が無く、`domain_obligation_ids` を空にして OB-N1 で返した（捏造せず）。router が完成後に対応付け（レポート §5）。→ web と同じく「無ければ obligation」で問題なし。
- 残課題: なし（ブリーフ雛形の改善点 2・3 は agentDevTemplate 側の雛形へ昇格候補）。

### 棄却した案
- Contract と Boundary を波 1 と同時に 4 体並列で起動する案: ランブックどおり 2 波にした。Contract が Architecture の data authority 表（§3）と SG（§7）を owner 候補の参照に使えたため、波分けの価値はあった。
- test-runner に定量計測まで任せず router が全部 grep する案: 計測 10 項目を router の context で回すと統合作業の context を圧迫するため委譲を維持し、誤りは router の再計測で吸収した。

### 2026-09-16 Implementation Spec の事前実装ゲート（architecture ロール 1 回）
- 目的: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` を mino Design gate / code-design / §8 整合 / 共有再生仕様互換 / testability / 移行現実性で監査。
- 結果: **revise**（6 件）。主要指摘: (M1) AppState から再生側への参照が無く SubjectCleanup の経路が未定義 → composition root 節と `PlaybackLifecycle` port を追加、(M2) §8 逸脱 3 件（SG-S1 の pending 化・role 文字列 enum 化・読取側 id 検証）を撤回し `ApiFailure.timeout` を削除、(M3) spec §2.7 の「コア拡張」表現が spec 本文と衝突 → 書き方を変え複数要素移動を CI-T9b で契約化、(M4) T-T7b のコンパイル境界は oracle にならず grep へ、S3 の「AVFoundation 11 箇所」は実測 17 テスト関数 → S3a/S3b に分割、(M5) S2 の暫定実装を TP4 として登録、(M6) 公開操作の補完。全文: `docs/research-reports/2026-09-16-code-design-review/spec-gate.md`。
- 運用: ゲート担当も turn 上限（20）で 1 回目は成果物ゼロ。「読みなしで手持ちを 1 heredoc で書け」の再開指示で完走。読み範囲を 8 観点分に広げすぎた（Spec + review §4/§8 + spec + web Spec + 2 reference + 6 ソース範囲）。次回は「Spec と review §8 と共有仕様」に絞り、ソース確認は router が事前に済ませた事実表を渡す。
- 棄却した案（ゲートの検討より）: 旧 VM を feature flag で温存する段階移行（AVPlayer 2 系統で NowPlaying・AudioSession が競合）、AudioEngine port を置かず純関数ガード拡張で済ませる案（16 遷移中 6 本が実 AVPlayer 依存）、PlaybackQueue の failable init（conformance 32 件の呼出形を壊す）。
- 残課題: Spec の user 承認。
