# news-listen-ios Implementation Spec — 再生ドメインモデル・失効境界・カプセル化（design mode）

日付: 2026-09-16 ／ 最終更新: 2026-09-30（本文の表を現行値へ更新。§9 改訂履歴）／ mode: design（read-only、実装は別フェーズ）／ owner: user ／ decision_maturity: **approved**（2026-09-16 user 承認。P9 事前ゲート revise 6 件反映版）
入力: `docs/research-reports/2026-09-16-code-design-review.md`（finding RF*・§8 人間判断 Q1〜Q10）と同ディレクトリの Function package（F-A*/G*/IV*/OB-C*/CI-*/LF*/SG-*）。
位置づけ: 親リポ `docs/design/ios-design.md` §5〜§8 の **target 版**。実装が進んだ節から ios-design.md を書き換える（本書は移行中の設計正本）。web の同種 Spec（`web/docs/design/2026-09-16-implementation-spec-domain-model.md`）と用語・capsule 構成・契約 ID の対応を保つ。

> 事前実装ゲート（`docs/research-reports/2026-09-16-code-design-review/spec-gate.md`、verdict revise）の修正 M1〜M6 を本版に反映: composition root 節（§2）、§8 逸脱 3 件の撤回（SG-S1 satisfied・role enum 化と読取側 id 検証を削除・`timeout` 削除）、§2.7 の書き方と CI-T9b、T-T7b の grep oracle 化と S3a/S3b 分割、TP4、公開操作の補完。

> 設計原則（本書の判断順）: actor の目的 → use case → その判断に必要な概念・不変条件 → 契約 → カプセル（公開操作と隠す技術）→ 依存方向 → 移行。pattern 名・class 数は成果にしない。1 実装しかない箇所に protocol を作らない（Boundary RO1〜RO7 を踏襲。port は品質根拠のある 4 つだけ）。


> **本書の読み方（2026-09-30 改訂）**: 本文（§0〜§8）の表は 2026-09-30 に現行値へ更新した。直した行には決定 ID（親 docs 監査レポート `docs/research-reports/2026-09-23-design-docs-mino-audit.md` §5 の SG-\*、§5.0 の I-\*、ADR）を括弧で併記し、旧値は §9 改訂履歴に残した。下の追記節は改訂の経緯として残す（本文と追記が食い違えば本文が正しい）。以後は本文を直し、§9 に 1 行足す。
> - order（`docs/plan/2026-09-16-design-review-refactor/`）は実行後に削除するので、恒久の契約を order に置かない。I-S3b1 の order にあった規則の表は §3.6 へ移した。
> - 2026-09-23 の ADR-104（主体離脱と主体別資産）と SG-C10〜C16 は、追記節を作らずに本文（§3.1・§3.3・§4・§5・§6）へ直接反映した。
> - ID の読み方: 本文に元からある `SG-A1〜A10`・`SG-B1〜B3`・`SG-C1〜C5`（`Q*`・`RF*`・`CI-P*` と並ぶもの）は 2026-09-16 の iOS レビューの Selection Gate で、監査レポート §5 の同じ番号とは別の決定。2026-09-30 の改訂で足した監査レポート側の ID は、番号が重なるものだけ「台帳 SG-A1」のように「台帳」を付けて書く（`SG-C10` 以降と `SG-X*` は重ならないので付けない）。
>
> **追記（2026-09-16・共有仕様 §6.7 の確定による上書き）**: 親 docs `shared-playback-spec.md` §6.7 の Selection Gate が user 判断で確定し、本書の次の記述を上書きする（2026-09-30 に本文へ反映済み。この追記は経緯として残す）。
> - SG-X1: 完聴時にサーバーへ送る位置は **`duration` を明示的に 1 回送る**（§3.1 PositionReporter と CI-T8 の「完聴 → 位置 0 の順」を置換。順序は listenCompleted → `duration` → advance）。
> - SG-X3: 主体離脱で cleanup 完了を待たない（本書どおり）。SG-X4: 一時停止中は周期送信しない（本書どおり）。
> - SG-X5: 設定画面の既定速度 Picker（`SettingsView.swift:50` の 5 段）を `PlaybackConstants.speeds` 8 段へ揃える（S4 に追加）。
> - パスワード（SG-B2）: **12〜20 文字**（ADR-101。本書 §3.3・CI-T16 の「8〜20」を置換）。
>
> **追記（2026-09-30・wave 1 完了後の前提点検による上書き）**: I-S2 の完了で I-S3a の前提が変わり、再生の停止の扱いを user 判断で確定した（親 docs 監査レポート §5 の SG-C21〜C28）。本書の次の記述を上書きする（2026-09-30 に本文へ反映済み。この追記は経緯として残す）。
> - SG-C22: `AudioEngine` port は **7 操作**（load / play / pause / seek / rate / **stop** / 事象 stream）。`stop` は「止めて読み込みを外す。以後も `load` で再利用できる」（§2 port 表と §5 rejected_overdesign RO4 の「6 操作」を置換）。RO4 が棄却するのは AVPlayer の鏡写しで、基準は「Session が必要とする操作に絞る」のまま。
> - SG-C24: `PlaybackSession.stop` は §3.1 の遷移表の外の**リセット**。どの状態からでも `idle` へ戻し、分母 16 には数えない。契約 **CI-T1b**: 任意の状態で `stop` → `idle`・`AudioEngine.stop` が届く・`idle` での `stop` は何もしない。検証 T-T1b は engine double の状態で観測する（I-S3b1）。`removeFromQueue` と `stopForLogout` の `session.stop()` はこの操作を指す。
> - SG-C23: I-S3a の時点では Session が無いため、「engine に音声が読み込まれているか」は `PodcastViewModel` の private な旗が持つ（`load` で立て、`stop` で倒す）。**TP5**（owner: user／導入: I-S3a／削除条件: I-S3b2 で Session の状態（`idle` か否か）に置き換わった時）。
> - SG-C21・SG-C26: 主体離脱時の再生停止のテストは、利用者に見える状態に加えて engine double が「読み込み済みでない」ことを観測する。呼出回数は問わない。
> - SG-C27: `NowPlayingCenter` adapter は App が 1 個作り、`AppState` と再生側の両方へ渡す（§2 composition root 表どおり。`AppState` の既定引数は Preview とテスト用）。
> - SG-C28: リモートコマンドの解除の契機は現行どおり登録者の破棄時。主体離脱の後始末へ移すかは I-S3b1 / I-S3b2 で判断する。
>
> **追記（2026-09-30・I-S3a 実装時の裁定による上書き）**: I-S3a の実装で、本書と order の port の形では現行の挙動を写しきれない箇所が見つかり、user 判断で確定した（親 docs 監査レポート §5 の SG-C29〜C38）。方針は「現行の観測可能な挙動を優先し、port の拡張は加法的なものに限る」。本書の次の記述を上書きする。
> - `EngineEvent` は **10 種**（§5 CP1 note の 8 種を置換）: `ready / buffering / resumed / paused / ended / failed(description: String?) / timeUpdate(seconds:duration:) / interrupted / interruptionEnded(shouldResume:) / outputDeviceLost`。`paused` は一時停止時の buffering 解除のため（SG-C32）、`outputDeviceLost` は出力機器の切断による一時停止のため（SG-C33）、`timeUpdate` の `duration` は再生中の総時間を伝えるため（SG-C31）。
> - `AudioEngine.load(url:)` は致命的でない失敗（AudioSession の設定失敗）の説明を `String?` で同期的に返す（SG-C34）。操作数は 7 のまま。
> - 事象 stream は **load ごとに作り直す**（SG-C36）。`stop` で finish し、購読側は load ごとに購読して停止時に cancel する。旧 load の事象は cancel 済みの判定で捨てる。payload に世代番号は付けない。
> - `NowPlayingCenter` は **5 操作**（§5 CP10 の ops を置換）: `update(info) / updateElapsed(elapsed, duration) / clear / registerCommands(handler) -> RemoteCommandRegistration / unregister(registration)`。`updateElapsed` は経過時間だけの軽量更新（SG-C35）。登録は token を返し、解除は token 単位で行う（SG-C37）。共有 adapter（SG-C27）で引数なしの解除を使うと、前の登録者の破棄が次の登録者の登録まで消すため。SG-C28 の「登録者の破棄時に解除」はこの token で行う。
> - `PodcastViewModel.init` の `engine:` / `nowPlaying:` は既定値に本番 adapter を持つ（Preview とテスト用。SG-C29）。`MediaPlayerNowPlaying(` の生成は production で 3 箇所（App・`AppState` の既定引数・VM の既定引数）、`AVPlayer(` の生成は 1 箇所のまま。App 経由の経路は 1 個を共有する。
> - 割り込み後の再有効化は adapter 内部のフラグで行う（SG-C38）。受け入れる差: 一時停止中に割り込みが入って終わり、その後に利用者が自分で再開したとき、`setActive(true)` が 1 回余分に走る。
> - 「Platform の外に AVFoundation / MediaPlayer が無い」の判定は `GrepOracleTests` で行う（SG-C30）。パターンは型名 `AVPlayerEngine` に一致しない形にし、`Podcast/NowPlayingInfo.swift` を除外する。
>
> **追記（2026-09-30・I-S3b1 着手前の裁定による上書き）**: I-S3a で足した事象と戻り値を `PlaybackSession` がどう扱うかを user 判断で確定した（親 docs 監査レポート §5 の SG-C39〜C44）。§3.1 の遷移表の分母 16 は変えない。既存の辺 `playing → paused`・`buffering → paused` に engine 由来の契機が加わる。
> - **engine 由来の一時停止は Session が自分で遷移する**。契機と遷移は次の表（表に無い状態では何もしない）。
>
>   | 契機 | `playing` | `buffering` |
>   |---|---|---|
>   | engine `paused`（SG-C39） | 何もしない | → `paused` |
>   | `outputDeviceLost`（SG-C40） | → `paused` | → `paused` |
>   | 割り込みの開始（SG-C44） | → `paused` | → `paused` |
>
>   `buffering` 中の engine `paused` は現行と表示が変わる（現行は buffering 表示だけ消えて再生中のまま）。I-S3b2 の変更行に載せる。位置同期は「一時停止で即時 1 回」の規則に乗る。
> - **割り込みの分担**（SG-C44。§3.1 の「割り込みは `paused` への遷移として表し、`wasPlayingBeforeInterruption` は Coordinator の内部値」を具体化）: Session は一時停止の遷移を行い、割り込みの開始（再生中だったか）と終了（再開してよいか）を外へ知らせる（CP1 の emits は 4 つ）。Coordinator が記憶を持ち、再開するなら `session.play()` を呼ぶ。Session 自身は再開しない。
> - **`load` の警告**（SG-C41）: Session の状態は変えず、`start` の結果として 1 回だけ外へ出す。facade が `errorMessage` に書く（id からの再生開始の解決失敗と同じ経路）。`errored` にしない。
> - **文言**（SG-C42）: 警告は OS の説明文をそのまま運び、facade がそのまま表示する（`engine_failed(description)` と同じ扱い）。§5 leakage guard の「`localizedDescription` の英語文言」は「説明文を解釈・加工せず、理由値の中身として運ぶだけにする」と読む。再生エラー文言の日本語化は構造変更の完了後に独立した slice として扱う（親 plan の保留）。
> - **総時間**（SG-C43）: `PlayableEpisode.durationSeconds` で初期化し、`timeUpdate` の `duration` が 0 より大きければ置き換える。DTO と engine がどちらも 0 の間は「不明」とし、位置を上限で丸めず下限 0 だけ守る（§3.1 の不変条件 `position ∈ [0, duration]` は総時間が分かっている間に適用する）。
> - 契約: **CI-T1c**（engine 由来の一時停止と割り込みの通知）・**CI-T1d**（警告）・**CI-T1e**（総時間と丸め）。検証は I-S3b1 の T-T1c〜T-T1e。
>
> **追記（2026-09-30・wave 3 の前提点検による上書き）**: I-S3b1 の指示書を I-S3a の実装と照合し、user 判断で確定した（親 docs 監査レポート §5 の SG-C50・C52・C54・C58〜C63、共有仕様 §2.4・§2.11・§2.12・§6.4・§6.6、親 docs `adr/106-ios-audio-engine-port-and-session-contract.md`・`adr/105-playback-session-out-of-table-operations-and-shared-rules.md`、`design/ios-design.md` §11.4）。本書の次の記述を上書きする。
> - **再生開始の手順**（SG-C58。§3.1 の `loading` 行「engine `ready` → `paused` → 即 `play()`」を置換）: `start` は「`load` → `setRate(speed)` → `seek(resume)`（resume が 0 より大きいとき）→ `play()`」を続けて行う（**engine を呼ぶ順序は下の追記の I-1 で改めた**）。`ready` は状態を進めるためだけに使い、engine への再生指示は繰り返さない。理由: 実 adapter は読み込みごとの監視（`ready` / `buffering` / `resumed` / `paused` / `ended` / `timeUpdate`）を、その読み込みの最初の `play()` で登録する（古い発火を捨てるための設計）。`ready` を待ってから `play()` すると、実機では `ready` が届かず再生が始まらない。
> - **test double の振る舞い**（SG-C58）: engine の double は実 adapter と同じく、`play()` が呼ばれるまで読み込みごとの事象を届けない。`pause` / `setRate` / `seek` の結果も状態として持つ（呼出回数は公開しない。SG-C26）。状態ごとに各事象をどう扱うかの全表は本書 §3.6 に置く。
> - **取得前・開始前の失敗**（SG-C52。§3.1 の `errored` 行「取得前の失敗は `episodeRef: {id}`」を実現する入口）: `PlaybackSession` に遷移表の外の操作「失敗にする」を足す。どの状態からでも、id だけの参照と理由（`offline_uncached` / `invalid_source` / `fetch_failed`）を渡して `errored` に入れる。分母 16 には数えない。契約 **CI-T1f**。
> - **手動で選んだエピソードが開始前に再生できないと分かる場合**（SG-C62。§3.1 Coordinator の `startEpisode`）: キューもセッションも変えず、通知だけを返す（現行の「Offline and not cached」と同じ挙動）。`errored` にするのは、キューが既にそのエピソードを現在にしている場合（`onEnded` 後の advance・再試行）だけ。
> - **リモートコマンド**（SG-C59。SG-C28 の保留を解消。§3.1 の `stopForLogout()` を置換）: Coordinator は、登録が無ければ再生開始時に登録して token を持つ。`stopForLogout()` は「`session.stop()` → `nowPlaying.clear()` → リモートコマンドの解除 → `queue = PlaybackQueue()`」。Coordinator の破棄時にも token を解除する（二重の解除は無害）。
> - **Coordinator の公開操作は 19**（SG-C60。§5 CP4 の ops と「17」を置換）: `minimizePlayer` と `expandPlayer` を足す（名前と規則は現行 `PodcastViewModel` と同じ。最小化は非表示のとき何もしない、展開は再生中のものがあるときだけ効く）。表示形態の遷移規則は本書 §3.6 に表で置く。
> - **`skipToNext`**（SG-C63）: 共有仕様 §2.12 のとおり（次が再生できれば今を止めて次を再生し、位置を 1 回送り、完聴は送らず、表示形態は変えない。次が再生不可と分かれば何も変えない。待機列が空なら何もしない）。操作は I-S3b1 で作る。ロック画面の「次のトラック」への接続（I-S3c）は保留（SG-C70。実機での確認の後に決める）。
> - **error 状態の再生ボタン**（共有仕様 §2.11 から導出）: `togglePlayPause` が `errored` で呼ばれたら再試行（`startEpisode(current)`）を行う。
> - **完聴時の順序**（SG-C61。§3.1 PositionReporter・CI-T8）: 完聴の記録と総時間の位置書込をこの順で送り始める。次の再生開始は応答を待たない（現行と同じ。画面ロック中の無音でアプリが休止されるのを避ける）。
> - **総時間の完聴時の扱い**（SG-C54。SG-C43 を補う）: 完聴時に送る値は「engine の値 → DTO の値」の優先順で得た値。不明なら完聴時点の現在位置、それも 0 なら送らない。
> - **`setQueue` の重複 id**（SG-C50。§3.1 PlaybackQueue の dedupe を具体化）: 開始位置は元の入力で clamp して id を決め、先勝ちで重複を除いた後のその id の位置を現在にする（共有仕様 Q-33。I-S3b2）。
>
> **追記（2026-09-30・I-S3b1 の書き直しで導いた宣言）**: 上の決定から、order を書く側が導いて固定した細部（親 docs 監査レポート §5.0 の **I-1〜I-23**。根拠は同表）。規則の表は本書 §3.6 に置く（型の宣言の字面は実装が持つ）。本書の次の記述を上書きする（2026-09-30 に本文へ反映済み）。
> - **I-1**（上の SG-C58 の順序を改める）: `start` が engine を呼ぶ順序は「`load` → `seek(resume)`（resume が 0 より大きいとき）→ `play()` → `setRate(speed)`」。`AVPlayer.play()` は速度を 1.0 に戻す（2026-09-30 に macOS の AVFoundation で実測）。再開は `setRate` で行い、`play()` を呼ぶのは開始の 1 回だけ。
> - **I-2**: engine の test double は `play()` の前の読み込みごとの事象を失敗にし、`rate`・`lastSeekSeconds`・`loadedURL` を状態として持つ（`play()` は `rate` を 1.0 に戻す）。
> - **I-3**: 状態 × 事象の全表（本書 §3.6）。`loading` での `pause()` は辺 `loading → paused`。`resumed` は `loading` でも `ready` と同じ。`paused` で届いた `failed` は保留し、次の `play()` の直後に `errored` へ進める。
> - **I-4**（§3.1 の `errored` 行を置換）: `errored` は id・位置・理由だけを持つ。engine が読み込み済みなのは `loading / playing / buffering / paused` の間だけ。
> - **I-5**: CP1 の通知は 4 種（状態・位置・終了・割り込み）。登録順に同期で呼ぶ。Reporter を先に登録する。
> - **I-6**（§5 CP4）: Coordinator は閉じられる通知 `notice` を 1 つ持つ。公開する状態は `session`・`presentation`・`queue`・`notice`・`isAdvancing` の 5 つ。`dismissError()` は `notice` を消す（`errored` の状態は変えない）。
> - **I-7**（§3.1 Coordinator の `startEpisode`・`onEnded` を置換）: 「開始前の判定 → 取り直しの待ち → 世代の確認 → キューと Session を同期で変える」。`onEnded` も取り直しの後で `advance` する。
> - **I-8**: Coordinator が `fetchFailed` を作る経路は無い（SG-C4 のフォールバック）。PS-01 の理由は iOS では `engineFailed`。
> - **I-9**（§3.1 PositionReporter・§5 CP9 を置換）: `Timer` を持たない。開始直後には送らない。一時停止への遷移で 1 回。停止の前は Coordinator が `flush()` を呼ぶ（`stopForLogout()` は呼ばない。SG-C16）。同じ位置は再送しない。巻き戻した位置も送る（SG-C67）。完聴は「完聴の記録 → 位置 → ストリークの更新」の直列で、呼んだ側は待たない。
> - **I-10**（§3.1 OfflineLibrary・§5 CP3 を置換）: `save(data, for: id)`・`has`・`url`・`remove`・`clearAll`・`usage`・`refresh(candidateIds:)`・`savedIds` の 8 操作。取得は呼ぶ側に残す。
> - **I-11**: `NowPlaying` は `Podcast` の同名の規則を写した computed を 5 つ持つ（field には数えない）。
> - **I-12**: リモートコマンドが効くのと、ロック画面に再生情報を出すのは `loading / playing / buffering / paused` の間。
> - **I-13**: 表示形態は、開始が確定したときだけ変わる。
> - **I-14**: `replayCurrent` は再開位置 0 で開始する。`startEpisode(id:)` の取得は 1 回。
> - **I-15**（§4 CI-T3 の「`ready` 後に再適用」を置換）: 再開位置を `ready` の後に掛け直さない。
> - **I-16**: 自動で次へ進むときの取り直しは background task で囲む。
> - **I-17**: Coordinator は Preview 用の DEBUG 専用の入口を 1 つ持つ。
> - **I-18**（§5 naming_decisions の「`didFinishCurrentEpisode` → `session == .ended`」を置換）: 「聴き終わりました」の表示条件は「`ended` かつ、自動で次へ進む途中でない」。Coordinator が `isAdvancing` を公開し、facade が `isFinished` として導く。
> - **I-19**: 旧プロパティ `isPlaying` は `loading / playing / buffering`、`isBuffering` は `buffering` だけ。
> - **I-20**（I-S3c。**保留** = SG-C70）: `NowPlayingCenter` は「次のトラックを受け付けるか」の切替を足して 6 操作、`RemoteCommand` は 8 種。
> - **I-21**（上の SG-C40・C44 の表を補う）: `loading` の間の割り込みの開始と出力機器の切断も、`playing` と同じく一時停止にする（辺は既存の `loading → paused`）。
> - **I-22**: `loading` の間のシークは、再開位置を置き換える形で受ける。`paused` で届いた `ended` は保留して次の `play()` の直後に進め、`buffering` で届いた `ended` は `playing` を経て進める。
> - **2026-09-30 夜の確認**（監査レポート §5 の SG-C64〜C79）: I-1・I-18・I-21・I-23 は user が確認した（SG-C66・C72・C71・C73）。`partial_failed` は再生不可のまま（SG-C64）。位置同期の新しい規則（記録時刻の新しい方を正とする・オフラインで記録した位置を後から同期する・再開時の確認。SG-C74〜C79・親 docs ADR-109）は、§3.1 の PositionReporter と `resolveResumePosition`、§2 の「backend の契約は変えない」（位置の書込の 1 点）を改めるが、iOS への反映は I-S3b3 の後の別の slice で行う（要点と解除条件は §3.1「位置同期の新しい規則」）。
> - **I-23**（I-7 を補う）: 待ちに入る入口は待ちの前に世代を進める（後から始めたものが勝つ）。利用者が起こした開始の待ちが残っている間、自動で次へ進む処理は始めない。完聴で書く id と値は `listenCompleted` の呼出時点で確定する。

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
  public_contract_change_allowed: false   # backend API・共有再生仕様 §2 の意味論は不変。§2 への「advance 後の再生失敗」追記と §6.3 の実装名改訂は spec 先行（§6 参照）。2026-09-30 時点の例外: 位置の書込の契約は ADR-109（SG-C74〜C79）で改まる（iOS への反映は保留。§3.1）。`user_id`（ADR-104 決定 15）は backend が足した契約を I-S5 が読む
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
| UC-A2 アカウント管理 | Account owner | 表示名・パスワード・Passkey・セッション | パスワード規則（12〜20、1 policy。Q9・ADR-101） | Account |
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
| `AudioEngine`（**7 操作**: `load(url:)`（致命的でない失敗の説明を返す）/ play / pause / seek / rate / stop / 事象 stream。SG-C22・C34） | Session の 16 遷移（§3.1）を AVPlayer 抜きで XCTest する（CI-T1）。AVFoundation 型を直接扱っていたテストは I-S3a で double 駆動へ移植済み | `shouldProcessPlayerItemCallback` 等の純関数ガード |
| `NowPlayingCenter`（**5 操作**: `update` / `updateElapsed` / `clear` / `registerCommands`（token を返す）/ `unregister(token)`。SG-C35・C37。「次のトラック」の受付を切り替える 6 操作目は保留 = I-20・SG-C70） | logout でクリアする入口が必要（Q1、CI-T15）。シングルトン直参照ではテスト seam も外部制御点も無い（LF8） | `NowPlayingInfo.make` 純関数 |
| `FileStore` | 既存 `FileManagerProtocol`（`Networking/FileManagerProtocol.swift`）をそのまま | 既存 |
| `URLSessionProtocol` | 既存。`ApiGateway` は既存 `APIClient` の内部変更 | 既存 |

**Composition root（gate 指摘 M1）**: 現状 `AppState` は App 直下の `@StateObject`（`NewsListenAppApp.swift:19`）、`PodcastViewModel` は `ContentView` の `@StateObject`（`:104`、authenticated 時のみ生成）で、**AppState から再生側への参照は存在しない**。target では次の所有関係にする。

| 所有者 | 生成物 | 生存期間 | 参照方向 |
|---|---|---|---|
| `NewsListenAppApp`（App） | `AppState`、`OfflineLibrary`（1 インスタンス）、`NowPlayingCenter` adapter、`AudioEngine` adapter（adapter は 1 個ずつ作り、`AppState` と再生側で共有する。SG-C27） | プロセス | App → 全 adapter |
| `AppState` | `AuthSession`、`SubjectCleanup`、`PreferenceRegistry` | プロセス | `SubjectCleanup` は `PlaybackLifecycle` port（`stopForLogout()` のみ）と `OfflineLibrary.clearAll`（I-S5 で離脱主体の範囲の削除に置き換える。ADR-104 決定 26）/ `NowPlayingCenter.clear` を **注入で**受ける。Coordinator 本体は参照しない |
| `ContentView`（authenticated 時） | `PlaybackCoordinator`（＝`PlaybackLifecycle` の実装）、`PodcastViewModel`（facade）、`PositionReporter` | ログインセッション | Coordinator 生成時に `AppState.registerPlaybackLifecycle(self)`、破棄時に解除（weak 保持）。未登録なら `SubjectCleanup` は再生停止を no-op として `CleanupIncomplete` に含めない（再生側が無い＝消すものが無い） |
| `SettingsView` | `SettingsViewModel` | 画面 | `OfflineLibrary` を App から environment 経由で受ける（既定引数生成を廃止） |

`AudioCacheManager` の protocol 化（RO7）・`BaseViewModel`（RO3）・再生ソース Strategy（RO2）・汎用 Repository（RO1）・stale guard 共通抽象（RO6）・HTTP 網羅 Error 階層（RO5）は作らない。`AudioSession` / `NotificationCenter`（割り込み・route change）は `AudioEngine` adapter の内部に閉じ、port にしない。

## 3. ドメインモデル（Completeness target）

### 3.1 Playback

**PlaybackSession（transport 状態の正本）** — 排他 union。既存 15 atom（isPlaying / currentTime / duration / playbackSpeed / isBuffering / errorMessage / didFinishCurrentEpisode …）は派生値。

| 状態 | 保持する値 | 遷移（コマンド／事象） |
|---|---|---|
| `idle` | — | `start(episode, source, resume, speed)` → `loading` |
| `loading` | episode, resumePosition, speed | engine `ready` → `paused` → 続けて `playing`（`ready` は状態を進めるだけで engine を呼ばない。engine への指示は `start` が「`load` → `seek(resume)` → `play()` → `setRate(speed)`」の順で済ませている。SG-C58・I-1 / SG-C66）／`pause()`・割り込みの開始・出力機器の切断 → `paused`（I-3・I-21 / SG-C71）／シークは再開位置の置き換えとして受ける（I-22）／engine `failed` → `errored(engine_failed)` |
| `playing` | episode, position, duration, speed | `pause()` → `paused`／engine `buffering` → `buffering`／engine `ended` → `ended`／engine `failed` → `errored`／`timeupdate`（位置更新。保存は PositionReporter）／`outputDeviceLost`・割り込みの開始 → `paused`（SG-C40・C44） |
| `buffering` | 同上 | engine `resumed` → `playing`／`pause()` → `paused`／engine `failed` → `errored`／engine `paused`・`outputDeviceLost`・割り込みの開始 → `paused`（SG-C39・C40・C44） |
| `paused` | 同上 | `play()` → `playing`／`seek`／`start` |
| `ended` | episode, duration | Coordinator が `ListenCompleted` を通知し `advance` |
| `errored` | episodeId, position, `reason: offline_uncached \| invalid_source \| engine_failed(description) \| fetch_failed(ApiFailure)`（id・位置・理由だけを持つ。I-4。`fetch_failed` は型に残るが、Coordinator が作る経路は無い。I-8） | `play()`（手動再試行）→ `loading`／`start`（注: I-S3b1 の order は `errored` での `play()` を何もしないとしている。判断待ち） |

遷移表の分母（T-T1 用に固定）: idle→loading, loading→paused, loading→errored, paused→playing, paused→paused(seek), paused→loading(start), playing→paused, playing→buffering, buffering→playing, buffering→paused, playing→ended, playing→errored, buffering→errored, ended→loading(advance), errored→loading(retry), errored→loading(start) の **16 遷移**。表外（例: idle→playing、ended→playing、errored→paused）は禁止。IV2（error と paused の同居）・IV3（buffering ∧ error）は型で構築不能になる。遷移表の外の操作が 2 つあり、分母 16 に数えない: `stop`（どの状態からでも `idle` へ戻すリセット。SG-C24・CI-T1b）と `fail`（どの状態からでも、id と理由 `offline_uncached / invalid_source / fetch_failed` を受けて `errored` に入れる。取得前・開始前の失敗の入口。SG-C52・CI-T1f）。engine が読み込み済みなのは `loading / playing / buffering / paused` の間だけ（I-4）。操作 × 状態・engine の事象 × 状態・16 辺を起こすものの全表は §3.6。

不変条件: 総時間が分かっている間は `position ∈ [0, duration]`（seek / seekRelative とも clamp、CI-P19 / SG-C3）。総時間は DTO の `durationSeconds` で初期化し、engine の値が 0 より大きければ置き換える。どちらも 0 の間は「不明」とし、位置を上限で丸めず下限 0 だけ守る（SG-C43）。速度は `PlaybackConstants` の許容値内。`start` 時のセッション速度は Preferences の既定速度で初期化し、以後はセッション内で保持（Q4、CI-P12 / G11）。`errored` からの `play()` は同じ source 解決をやり直す（オフライン → オンライン復帰で再試行が通る。注: I-S3b1 の order は `errored` での `play()` を何もしないとし、再試行を Coordinator の `retry()` に置く。判断待ち）。割り込み（電話）は `paused` への遷移として表し、`wasPlayingBeforeInterruption` は Coordinator の内部値。Session は一時停止の遷移を行い、割り込みの開始（再生中だったか）と終了（再開してよいか）を外へ知らせる。再開の判断は Coordinator が行い、Session 自身は再開しない（SG-C44）。`load` の警告（AudioSession の設定失敗の説明）は状態を変えず、`start` の結果として 1 回だけ外へ出す（SG-C41）。

**「現在再生中」の一本化（Q2 / SG-A1）**: `PlaybackQueue`（既存 struct、spec §2）が「順序と現在位置」の正本。`PlaybackSession` は「現在位置の decode 済み `PlayableEpisode`（再生に必要な payload）」の保持者。不変条件 **INV-P1**: `session` が `idle` でないとき `session.episode.id == queue.current?.id`。UI が「何が再生中か」を問う唯一の入口は Coordinator の `nowPlaying()` query（`NowPlaying` を返す。共通 7 field `episodeId / displayTitle / japaneseIntroText / segments / vocabulary / quiz / difficulty` ＋ iOS 固有 2 field `sourceArticles / sourceKind`。SG-C11・C14。`session` が `idle` なら無し、それ以外は `queue.current` の DTO から作る。`Podcast` の同名の規則を写した computed 5 つ `hasTranscript / hasVocabulary / hasQuiz / hasSourceArticles / showsCcBySaLicense` は field に数えない = I-11。`Podcast` DTO は View に出さない。位置・総時間・状態は `session` から読む）。`PodcastViewModel.currentPodcast` は `nowPlaying()` の派生 computed に置き換え（reader 19 箇所は型変更なしで読める形を保つ）。`QueueSheet.swift:22` の AND 合成と `PodcastView.swift:90` の比較は `nowPlaying()?.episodeId` へ。

**PlaybackQueue** — 共有仕様 §2 の状態モデルと公開操作を **そのまま**（`start / setQueue / add / playNext / jump / advance / remove / reorderUpNext`）。変更は 3 点のみ。(1) 内部 gate: `init` / `setQueue` で id 重複を dedupe（不変条件 1。CI-Q02 / SG-C1。公開操作は throw しない）。`setQueue` の重複 id は、開始位置を元の入力で clamp して id を決め、先勝ちで重複を除いた後のその id の位置を現在にする（SG-C50。共有仕様 Q-33）。(2) `reorderUpNext(fromOffsets:toOffset:)` の IndexSet 複数移動は、spec §2.7 が「コア仕様の対象外（アダプタ責務）」とする範囲を **iOS 実装がコア型の内部で提供している**ものとして §2.7 の iOS 欄に記す（「コア仕様の拡張」とは書かない。gate M3。SG-C2）。単一要素は正本 `moveUpNext` と等価（CI-Q12）。複数要素の期待値は iOS 固有契約 CI-T9b として本書で固定する。別 adapter 型へ切り出す案は、呼出側が `QueueSheet.onMove` 1 箇所で切り出しても責務が移るだけで契約は増えないため採らない。名前は変えない（既存テスト 44 件・View の `onMove` 配線に影響するため。web は逆に `moveUpNext` に寄せた: 名前差は spec の対応表で吸収）。(3) `start` / `setQueue` は conformance が検証する操作なので **残す**（production 未使用でも削除しない）。

**PlaybackSource** — 既存 `resolvePlaybackURL` を `resolvePlaybackSource(hasCached:isOnline:) → cached | network | unavailable` の純関数（spec §6.1 と同名・同形）と、Coordinator 側の URL 解決に分ける。`unavailable` の扱いは入口で分かれる: 手動の開始では、キューもセッションも変えず通知だけを返す（SG-C62）。キューが既にそのエピソードを現在にしている場合（自動で進んだ先・再試行）は `errored(offline_uncached)`。

**OfflineLibrary** — 既存 `AudioCacheManager` を包む「再生可能なエピソードの保存庫」。合成 root で **1 インスタンス**を生成し `PlaybackCoordinator` と `SettingsViewModel` に注入（現状の 2 既定引数生成を解消。RF11 / SG-A6）。

| 操作 | 事後条件 |
|---|---|
| `save(data, for: id)` | 渡された音声データを保存し、`savedIds` に足す。完了後 `has()` true。取得（`fetchPodcast` → URL の検査 → gateway `downloadAudio`。成功データだけを渡す。既存 CI-C01 系）と二重実行の抑止は呼ぶ側に残す（I-10。保存庫は App が 1 個持ち、ログインのたびに作り直される `APIClient` をまたいで生きるので、gateway を持てない） |
| `has(id)` / `url(id)` | ファイル実体を正本とする。`downloadedIds` ミラーは廃止し `@Published private(set) var savedIds` を Library が publish（`clearAll` で即 空。IV10 / G7 を閉じる） |
| `remove(id)` / `clearAll()` / `usage()` | `clearAll` は主体離脱の後始末（SubjectCleanup。Q1）からも呼ばれる。`remove` / `clearAll` が失敗したら、`savedIds` を実体に合わせ直してから error を投げる（I-10・CI-T10） |
| `refresh(candidateIds:)` | 候補 id のうち実体のあるものだけを `savedIds` にする（I-10。`AudioCacheManager` に id を列挙する操作が無いため） |
| id 検証 | 現状（書込側のみ）を維持。RF4 は §8.3 で「記録のみ」（backend の id 規則 U1 確認後に再判定） |

公開操作は `save / has / url / remove / clearAll / usage / refresh / savedIds` の 8（I-10）。

**主体別キャッシュと起動時回収（target。ADR-104 決定 5〜9・16・25・26。実装は I-S5・未実装）**: 現状の保存先は端末単位の平置き（`Caches/NewsListenApp/audio-cache/`）で、主体離脱時は `clearAll()` が全削除する。I-S5 で次へ改める（準拠テストは共有仕様 §4.4 の SL-06〜SL-10）。
- 音声キャッシュを主体ごとのディレクトリに分ける（`{cacheDir}/audio/{user_id}/{podcast_id}.mp3`。キーは backend の `user_id`。決定 5・6・26）。主体離脱の後始末は、離脱する主体の範囲にだけ作用する（決定 2）。
- 旧い平置きキャッシュは初回起動で全削除し、移行しない（決定 7・台帳 SG-A1）。
- 起動時に、現在の主体以外のディレクトリを削除して回収する。未認証なら全ディレクトリが対象（決定 8）。主体が定まらない間（`resolving` / `unavailable`）は回収せず、確定した時点で 1 回走らせる（台帳 SG-B3）。確定の契機は `getMe` 成功・401・同じ起動中の login 成功（SG-C13）。
- `user_id` が欠落・形式不正のときはキャッシュを無効にして動作を続け、回収は未認証と同じ扱い（決定 16・台帳 SG-B6）。
- ダウンロードジョブは開始時に主体を固定する。離脱時は cancel を試みるが完了を待たない。離脱後に完了した書込は離脱主体のディレクトリに入り、次回起動の回収で消える（決定 9）。

**PlaybackCoordinator（use case orchestration・非 React 相当の `@MainActor final class`）**

公開操作は 19（§5 CP4。SG-C10・C60）。読み取り専用で公開する状態は `session`・`presentation`・`queue`・`notice`・`isAdvancing` の 5 つ（I-6・I-18）。開始の流れ・世代・`notice`・表示形態・リモートコマンドの規則の全表は §3.6。

- `startEpisode(_ podcast: Podcast, expandsPlayer:)`（一覧タップなどの手動の入口）: **状態を変えるのは、待ちが終わって世代を確かめた後だけ**（I-7）。(1) 開始前の判定: `decodeEpisode` が Playable でない、または `audioUrl` が URL にならないなら `invalid_source`、`resolvePlaybackSource(hasCached: library.has(id), isOnline)` が `unavailable` なら `offline_uncached` を `notice` に置いて戻る。キューもセッションも変えない（SG-C62。IV11 / G8）。(2) 世代を進めて控え、再生元を用意する: `cached` なら `library.url`（待たない）／`network` なら **`fetchPodcast(id)` を 1 回呼んで再取得**し、取り直した DTO を使う。取得失敗と、取り直した DTO が再生可能でないときは、保持している DTO へフォールバック（Q6 / ADR-009 / CI-P04）。(3) 世代が変わっていたら、その開始を捨てる。(4) キュー: `queue.jump(to:)` が false なら `queue.playNext` → `jump`（現状 `playNow` の規則を **全経路**に適用。Q2）。(5) 開始の確定: `reporter.flush()`（前の再生の位置を送る）→ `session.start(episode, url, resume, speed: prefs.defaultPlaybackSpeed)`（`resume = resolveResume(serverPosition, duration)`。末尾 2 秒規則は既存のまま）→ 表示形態 → リモートコマンドの登録（SG-C59）。`load` の警告が返ったら `notice` に置く（SG-C41）。
- `startEpisode(id:)`（通知ディープリンクの入口。SG-C10）: `fetchPodcast(id)` で解決し、上と同じ流れに入る。解決した DTO を再取得の結果として使い、取得は 1 回（I-14）。解決の失敗は error をそのまま投げ、キュー・セッション・`notice` を変えない。
- `replayCurrent()`（「もう一度聴く」。SG-C10）: `nowPlaying()` が無ければ何もしない。`queue.current` を手動の入口と同じ流れで、再開位置 0 で始める（I-14）。キューは変えない。
- `onEnded(endedId)`: stale ガード（`endedId != queue.current?.id` なら無視。既存方式）→ `PositionReporter.listenCompleted(id)`（best-effort。待たない）→ 利用者が起こした開始の待ちが残っていれば、ここで終わる（I-23 / SG-C73）→ `next` が無ければ `session = ended` を保持する（キューは進めない。ロック画面の情報は消す）→ `next` が開始前の判定に落ちたら **停止**: `queue.advance()` の後に `session.fail(next の id, 理由)`。`queue.currentIndex` は進めたまま `errored(reason)`、`nowPlaying()` は失敗エピソードを返し、`retry()` が同じエピソードをやり直す（Q3 / CI-P13 / G1。共有仕様 §2.11）→ それ以外は、世代を進めて控え、`isAdvancing` を立て、background task で囲んで再生元を用意し（I-16）、待ちの後で世代を確かめてから `queue.advance()` → 開始の確定（`expandsPlayer: false`。取り直しの後で `advance` する = I-7）。次の読み込みで engine が失敗した場合も `errored` で止まり、その先へは進まない。「聴き終わりました」の表示条件は「`ended` かつ、自動で次へ進む途中でない」（`isAdvancing`。I-18 / SG-C72。`didFinishCurrentEpisode` atom は廃止）。
- `removeFromQueue(id)`: 現在再生中を消した場合は `reporter.flush()` → `queue.remove` → `session.stop()` の順（停止の前に位置を送る。I-9）で、`queue.current`（次要素）を `idle` 扱いで表示（CI-P17。自動再生はしない）。
- `retry()`: `errored` のときだけ `queue.current` を再生元の用意からやり直す。`togglePlayPause` が `errored` で呼ばれたときも同じ（共有仕様 §2.11）。
- `skipToNext()`: 共有仕様 §2.12 のとおり（SG-C63）。操作は作るが、ロック画面の「次のトラック」への接続（I-S3c）は保留（SG-C70）。
- `stopForLogout()`: 世代を進める → `session.stop()` → `nowPlaying.clear()` → リモートコマンドの解除 → `queue = PlaybackQueue()` → 表示形態を非表示に → `notice` を消す（SubjectCleanup から呼ばれる。Q1・SG-C59）。**`reporter.flush()` を呼ばない**（主体離脱では位置を送らない。SG-C16）。Coordinator の破棄時にも token を解除する（二重の解除は無害）。名前は logout 専用だが、主体離脱の遷移①②④（§3.3）すべてで呼ばれる。
- 位置保存は **`PositionReporter`** が単独所有（I-9。`Timer` を持たない）: 再生中は Session の `positionChanged` と注入した時計で 15 秒を数えて送る。開始直後には送らない。一時停止への遷移で 1 回送り、一時停止中は周期送信しない（SG-X4）。停止・別のエピソードの開始の前は Coordinator が `flush()` を呼ぶ。背景遷移でも 1 回送る（共有仕様 §6.4 の契機。現行は App が `scenePhase` の変化で送っている。2026-09-30 の本文更新で一度この契機を落としたため戻した。I-S3b1 / I-S3b2 の order は背景遷移を契機の表に載せていないので、投入前に足す）。同じ位置は再送しないが、巻き戻した位置は送る（SG-C67）。完聴は `listenCompleted` → **総時間**の位置書込の順で送り始め、呼んだ側は待たない（SG-X1・SG-C61。値は「engine の値 → DTO の値」、不明なら完聴時点の現在位置、それも 0 なら位置は送らない = SG-C54）。完聴で書く id と値は `listenCompleted` の呼出時点で確定する（I-23）。応答の `Podcast` は捨てず `Catalog` へ渡してローカル値を更新（G12）。失敗は `@Published lastSyncFailure: ApiFailure?` として観測可能に（黙殺しない。SG-A8 の最小対応）。契機ごとの全表は §3.6。
- **位置同期の新しい規則（ADR-109・SG-C74〜C79。保留・未実装）**: 上の規則は「届いた順にサーバーが上書きする」現行の契約の上にある。次の規則は採用済みだが、iOS には入れていない。解除条件 = backend B-S7（記録時刻の比較）が main に入り、I-S3b3 が終わった後に起こす位置同期の slice（SG-C79。order は未作成）。
  - 位置は記録時刻の新しい方を正とし、位置の書込に記録時刻を付ける（SG-C74）。
  - 端末は、エピソードごとに最後に記録した位置と時刻を**永続保存**する。送れなかった記録は、接続が戻ったとき・起動時・次に位置を送るときに送る。再開位置は、端末の記録とサーバーの値のうち時刻が新しい方（SG-C76。`resolveResume` の入力が変わる）。
  - サーバーの記録の方が新しいと分かっても、セッションの位置は動かさない。この端末で一時停止中のエピソードを、前面の画面の再生ボタンで再開するとき、位置の**差が 15 秒以上**なら、どちらの位置から続けるかを尋ねる。15 秒未満と、**確認を出せない経路**（ロック画面・イヤホン・車載機）は、尋ねずにこの端末の位置から再開する（SG-C77）。
  - 主体が離れるときは、**未送信のものも含めて送らずに消す**（SG-C76。§3.4 の主体依存の対象に加わる）。
  - 詳細は共有仕様 §6.2・§6.4・§6.5。

### 3.2 Catalog

**Episode** — `Podcast` DTO の decode 結果（DTO 型と `CodingKeys` は不変。web Spec §3.2 と同じ判別）。

| 種別 | 条件 | 保持 |
|---|---|---|
| `PlayableEpisode` | `status == "completed"` ∧ `audioUrl != ""` ∧ `errorMessage == nil` | id, title(fallback: japaneseIntroText), audioUrl, durationSeconds, difficulty, createdAt, serverPosition, 任意: segments / vocabulary / quiz / sourceArticles / sourceKind |
| `GeneratingEpisode` | `status == "processing"` | id, title, difficulty, createdAt |
| `FailedEpisode` | `status ∈ {"failed","partial_failed"}` または矛盾組合せ（fail-closed。`partial_failed` は音声があっても再生不可 = SG-C64・ADR-108） | id, title, errorMessage ?? "inconsistent" |
| 未知 `status` | `FailedEpisode`（fail-closed。SG-S3 で確定。U2 は解消済み） | — |

`PodcastRowView.swift:118-133` の文字列分岐は `Episode` 種別の switch へ。▶は `PlayableEpisode` にのみ付く。

### 3.3 Account

**AuthSession** — 判別共用体（G4 / G5 / IV6〜IV8 を閉じる。web Spec §3.3 と同形）。

| 状態 | 値 | 遷移 |
|---|---|---|
| `resolving` | — | `fetchMe` 成功 → `authenticated(user)`／`unauthorized` → `anonymous`／それ以外の `ApiFailure` → `unavailable(failure)`（**トークンは保持**。Q5 / RF3） |
| `authenticated` | `user: AuthUser` | `logout` → `anonymous`／任意の API 呼出が `unauthorized` → `anonymous`（**失効**。Q5 / RF2）／認証中の login 成功 → `authenticated(別の主体)`（主体の直接交代 = 遷移④。ADR-104 決定 3。離脱としての後始末は I-S5・未実装） |
| `anonymous` | — | login / passkey 成功 → `authenticated` |
| `unavailable` | `failure` | 再試行 → `resolving`（一時障害でログアウト表示しない） |

**主体離脱と SubjectCleanup**（Q1 / SG-A5。ADR-104 決定 1〜3）: 離脱の経路は列挙せず、認証状態の遷移から導く。対象は ① `authenticated(A)` → `anonymous`（明示 logout）、② `authenticated(A)` → `anonymous`（実行中 API の `unauthorized` = 失効）、④ `authenticated(A)` → `authenticated(B)`（主体の直接交代）の 3 つで全数。`authenticated → unavailable`（通信断など）はトークンを保持するので離脱ではない。起動時の失効（遷移元が `authenticated` でない）は起動時回収（§3.1 OfflineLibrary）で拾う。順序は **トークン破棄 → 認証状態の遷移（次の主体の確立）→ 後始末**で、次の主体の確立は後始末の完了を待たない（決定 1。SG-X3 revised）。後始末（SubjectCleanup）の事後条件: (1) `PlaybackCoordinator.stopForLogout()`（session 停止・NowPlaying クリア・リモートコマンドの解除・queue 空。位置同期は送らない = SG-C16）、(2) `NowPlayingCenter.clear()`、(3) 主体依存 UserDefaults の削除（§3.4 registry で `subjectScoped: true` の key: 実績既読・週目標・既定難易度・既定速度のローカルコピー。記事の開き方・時刻表記・効果音は端末設定として残す）、(4) 音声キャッシュの削除。消去失敗は `CleanupIncomplete` として観測可能に返し、認証状態の遷移自体は止めない（spec §6.3 のベストエフォート方針）。`ContentView` の破棄（`NewsListenAppApp.swift:65-70`）は従来どおり起きるが、消去は破棄に依存させない。

現状（I-S2 で実装済み）と target（I-S5・未実装）の差:

| 項目 | 現状 | target（決定 ID） |
|---|---|---|
| 対象の遷移 | ①②（logout・失効） | ④ を足す。A の後始末を行い、B の確立は待たない（ADR-104 決定 3。SL-07） |
| 音声キャッシュ | `clearAll()`（端末単位の全削除） | 離脱主体のディレクトリだけを消す。ダウンロードジョブは cancel を試みるが待たない（決定 2・9・26） |
| logout の API 呼出 | トークン破棄の前に `POST /auth/logout` を await する | 破棄前に捕捉したトークンで既存の `Authorization: Bearer` を付け、遷移の後に送る。破棄の前に await しない（決定 14） |
| APNs 登録の解除 | logout の中で client が `unregisterDeviceToken` を呼ぶ | client 呼出を削除し、サーバーのセッション削除の連鎖に任せる（SG-C12。決定 10） |

**失効の検知点**: `ApiGateway` が `unauthorized` を返した事象を 1 箇所（`AppState.handle(failure:)`）で受ける。各 VM は `ApiFailure.unauthorized` を文言化せず、遷移は AppState に委ねる。

**PasswordPolicy** — `Auth/PasswordPolicy.swift` に 1 実装。**12〜20 文字**（ADR-101。旧: 8〜20 = Q9 の仮決定。文字種規則は現状 iOS に無いため追加しない）。`AccountSettingsView.swift:305-333` の `saveProfile` / `changePassword` は `AccountSettingsViewModel`（新設）へ移し、View は状態を描くだけ。`AdminUsersViewModel.swift:47` と `AdminUsersView.swift:28` の文言はこの policy から導出。backend 側の検証値は ADR-101 で確認済み（最小 12。OB-A1 は解消）。

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

**ApiGateway（既存 `APIClient` の内部変更。Q7 / SG-B1）**: `validateResponse` が `APIError` を `ApiFailure` へ変換する。`ApiFailure = network(URLError) | unauthorized | forbidden | notFound(subject: NotFoundSubject) | conflict | rateLimited(retryAfter: Int?) | validation | server(status) | decoding | unknown(status)`。`notFound.subject` は endpoint メソッドが付与（`streak / quota / quiz` = 機能未提供、`credential / session / star` = 冪等削除成功。既存 404 の 2 意味）。非 `HTTPURLResponse` は `network` として失敗（fail-open を閉じる。CI-A02）。`downloadAudio` はヘッダ非付与の方針を保ちつつ同じ `validateResponse` を通す（既存）。日本語文言は `Networking/FailureMessages.swift` の 1 関数 `message(for: ApiFailure, context:)` に集約し、`localizedDescription` の露出を消す。互換層 **TP1**（`APIError` を `ApiFailure` から生成して throw）は I-S1 で導入し、10 消費者の置換完了で削除済み（production に `APIError` の参照は無い）。

**AudioEngine / NowPlayingCenter**: `Podcast/Platform/AVPlayerEngine.swift`（AVPlayer・KVO・periodic observer・didPlayToEnd・AudioSession・割り込み・route change を内包し、`AsyncStream<EngineEvent>` を publish）と `Podcast/Platform/MediaPlayerNowPlaying.swift`（`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`）。background task は「開始して、終了の closure を返す」closure として PositionReporter と Coordinator に注入し、`Podcast/Playback/` に `UIApplication` を書かない（I-16。§2 の依存方向）。adapter 2 本は I-S3a で実装済み。

### 3.6 導出の詳細（再生ドメイン）

2026-09-30 に I-S3b1 の order（`docs/plan/2026-09-16-design-review-refactor/I-S3b1-playback-domain.md`）から移した規則の表。order は実行後に削除するので、規則の正本は本節に置く（型の宣言の字面は実装が持つ）。根拠は親 docs 監査レポート §5（SG-\*）と §5.0（I-\*）。表の「—」は「何もしない」。

**行の確かさ**: 台帳 §5.0 の導出（I-3・I-6・I-7・I-9・I-12・I-13 など）は「全表は order に置く」という形で登録されており、台帳の文面に 1 行ずつは書かれていない。本節の行のうち、台帳の文面や SG に個別の記載があるものは決定である。個別の記載が無い行（例: `start` が先に `idle` を 1 回出す、選択肢に無い速度は 1.0 として扱う、`fail` の位置は 0、保留は `failed` を先に扱う、`lastSyncFailure` の意味、cancel された取得は捨てる、リモートコマンドの戻り値）は、その導出の下で order が固定した細部で、user の個別の確認は経ていない（親 docs 還流監査 2026-09-30 の §6）。利用者に見える挙動を変える形で直すときは、台帳に導出または SG として登録してから直す。

#### 3.6.1 PlaybackSession: 開始の手順と通知（I-1・I-4・I-5・I-15）

`start(episode, url, resumePosition, speed)` はどの状態から呼んでもよく、次を続けて行う。

1. 現在の状態が `loading / playing / buffering` なら、先に `stop` と同じ後始末をして `stateChanged(idle)` を 1 回出す。`paused` からは、前の読み込みの事象の購読を止めるだけで、`idle` の通知は出さない。保留中の失敗・終了は消す。
2. `speed` が `PlaybackConstants.speeds` に無ければ 1.0 として扱う。
3. engine の `load`。直後に、この読み込みの事象 stream を購読する（stream は load ごとに作り直される。SG-C36）。
4. `resumePosition` が 0 より大きければ engine の `seek`。
5. engine の `play()`。
6. engine の `setRate(speed)`。
7. 状態を `loading` にして `stateChanged` を出す。
8. `load` が返した警告を返す（無ければ何も返さない。SG-C41）。

- 5 → 6 の順序を入れ替えない。`AVPlayer.play()` は速度を 1.0 に戻す（I-1 / SG-C66）。engine の `play()` を呼ぶのは `start` の中の 1 回だけで、一時停止からの再開は `setRate` で行う。
- `ready` を待ってから `play()` を呼ばない。実 adapter は読み込みごとの監視を最初の `play()` で登録するので、待つと `ready` が届かない（SG-C58）。
- 再開位置を `ready` の後に掛け直さない（I-15）。
- 公開操作は 9 個: `start / play / pause / seek / seekRelative / setSpeed / stop / fail / state`。通知の受け口 `observe` は操作に数えない。
- 通知は 4 種: `stateChanged(状態)`・`positionChanged(秒, 総時間)`・`ended(episodeId)`・`interruption(開始(再生中だったか) / 終了(再開してよいか))`。登録した順に、その場で同期に呼ぶ。Coordinator は Reporter を先に登録する（I-5）。
- `stateChanged` は状態の値が変わるたびに 1 回出す。engine の `timeUpdate` による位置・総時間の更新では `stateChanged` を出さず、`positionChanged` だけを出す。
- `ended`・`errored` に入るときと `stop` のとき、「事象の購読を止める → engine の `stop`」の順で読み込みを外す（I-4）。

#### 3.6.2 PlaybackSession: 操作 × 状態（I-3・I-22）

| 操作 | idle | loading | playing | buffering | paused | ended | errored |
|---|---|---|---|---|---|---|---|
| `play()` | — | — | — | — | engine の `setRate(速度)` → `playing`。保留中の失敗・終了があれば続けて進める | — | 判断待ち（表の下の注） |
| `pause()` | — | engine の `pause` → `paused`（位置 = 再開位置、総時間 = DTO の値） | engine の `pause` → `paused` | 同左 | — | — | — |
| `seek` / `seekRelative` | — | 丸めた位置へ engine の `seek` を呼び、再開位置を置き換える（`loading` のまま。`seekRelative` の基準は再開位置。I-22） | 丸めた位置へ engine の `seek` を呼び、位置を更新 | 同左 | 同左 | — | — |
| `setSpeed(s)` | — | 速度を更新し、engine の `setRate(s)` | 同左 | 同左 | 速度だけ更新（engine は呼ばない） | — | — |
| `stop()` | — | 後始末 → `idle` | 同左 | 同左 | 同左 | → `idle` | → `idle` |
| `fail(id, 理由)` | → `errored` | 後始末 → `errored` | 同左 | 同左 | 同左 | → `errored` | → `errored`（値を置き換える） |
| `start(…)` | §3.6.1 の手順 | 同左 | 同左 | 同左 | 同左 | 同左 | 同左 |

- `setSpeed` は `PlaybackConstants.speeds` に無い値を無視する。
- `seek` の丸め: 総時間が 0 より大きければ `[0, 総時間]`、不明（0）なら下限 0 だけ（SG-C43）。`loading` の総時間は DTO の `durationSeconds`。
- `fail` で入る `errored` の位置は 0。理由に `engine_failed` は渡さない（engine の事象からだけ生まれる。SG-C52）。
- 注（判断待ち）: `errored` での `play()` について、§3.1 の遷移表は「`play()`（手動再試行）→ `loading`」、I-S3b1 の order は「何もしない（再試行は Coordinator の `retry()` が `start` を呼ぶ）」としている。order の側に導出 ID が無いので、本書は決めない。

#### 3.6.3 PlaybackSession: engine の事象 × 状態（I-3・I-21・I-22）

表に無い組合せは起こさない。

| 事象 | idle | loading | playing | buffering | paused | ended | errored |
|---|---|---|---|---|---|---|---|
| `ready` | — | → `paused` → `playing`（`stateChanged` を 2 回出す。engine は呼ばない） | — | — | — | — | — |
| `resumed` | — | `ready` と同じ | — | → `playing` | — | — | — |
| `buffering` | — | — | → `buffering` | — | — | — | — |
| `paused` | — | — | —（SG-C39） | → `paused` | — | — | — |
| `ended` | — | `ready` と同じに進めてから、`playing` の欄 | 後始末 → `ended` → 通知 `ended(episodeId)` | `playing` に進めてから、`playing` の欄 | 終了を保留する（状態は変えない） | — | — |
| `failed(説明)` | — | 後始末 → `errored(engine_failed(説明))` | 同左 | 同左 | 失敗を保留する（状態は変えない） | — | — |
| `timeUpdate(秒, 総時間)` | — | — | 位置を更新。総時間が 0 より大きければ総時間も置き換える。通知 `positionChanged` | 同左 | 同左 | — | — |
| `interrupted` | — | engine の `pause` → `paused`。通知「割り込みの開始（再生中だった）」（I-21） | 同左 | 同左 | 通知「割り込みの開始（再生中でなかった）」だけ | — | — |
| `interruptionEnded(再開可否)` | — | 通知「割り込みの終了（再開可否）」 | 同左 | 同左 | 同左 | 同左 | 同左 |
| `outputDeviceLost` | — | engine の `pause` → `paused`（I-21） | 同左 | 同左 | — | — | — |

- `ready` で `playing` になるときの位置は再開位置、総時間は DTO の `durationSeconds`。
- `errored(engine_failed)` の位置は、直前の状態の位置（`loading` なら再開位置）。
- `paused` で届いた `failed` と `ended` は捨てずに保留し、次の `play()` で `playing` に入った直後に `errored` または `ended` へ進める（辺は既存の `paused → playing`・`playing → errored`・`playing → ended`。分母 16 に辺を足さない）。保留は `start`・`stop`・`fail` で消す。両方が保留されていれば `failed` を先に扱う。
- `paused` で届いた `resumed`・`buffering`、`playing` で届いた `paused` は、操作より前に engine が出した事象が遅れて届いたものとして、状態を動かさない。
- 割り込みの終了で Session は自分から再開しない（SG-C44）。

#### 3.6.4 分母 16 の辺と、それを起こす操作・事象（I-3）

| # | 辺 | 起こすもの |
|---|---|---|
| 1 | idle → loading | `start` |
| 2 | loading → paused | engine `ready`（直後に 4 が続く）。`loading` での `pause()`・`interrupted`・`outputDeviceLost` も同じ辺 |
| 3 | loading → errored | engine `failed` |
| 4 | paused → playing | `play()` |
| 5 | paused → paused（seek） | `seek` / `seekRelative` |
| 6 | paused → loading | `start` |
| 7 | playing → paused | `pause()`（engine 由来は CI-T1c） |
| 8 | playing → buffering | engine `buffering` |
| 9 | buffering → playing | engine `resumed` |
| 10 | buffering → paused | `pause()`（engine 由来は CI-T1c） |
| 11 | playing → ended | engine `ended` |
| 12 | playing → errored | engine `failed` |
| 13 | buffering → errored | engine `failed` |
| 14 | ended → loading | `start`（次のエピソード） |
| 15 | errored → loading（再試行） | `start`（同じエピソード） |
| 16 | errored → loading（別の開始） | `start`（別のエピソード） |

表の外: `stop`（どこからでも `idle`）、`fail`（どこからでも `errored`）、`loading / playing / buffering` からの `start`（`idle` を挟む）。

#### 3.6.5 PositionReporter: 契機ごとの送る / 送らない（I-9・I-23）

`Timer` を持たない。周期は `positionChanged` の通知と、注入した時計で数える。

| 契機 | 動作 |
|---|---|
| `attach` | Session の通知に自分を登録する。Coordinator が生成時に 1 回呼ぶ |
| 状態が `loading` になった | 新しい再生の基準に戻す（送信済みの位置なし・完聴は未送信・現在位置 = 再開位置） |
| `paused` から `playing` に入った（開始直後の `ready` を含む） | 周期の起点を今にする。**開始直後には送らない**。`buffering` から戻ったときは起点を変えない |
| `playing` 中の `positionChanged` | 現在位置を更新する。起点から 15 秒以上たっていれば 1 回送り、起点を今にする |
| `playing` / `buffering` → `paused` | その位置を 1 回送る（利用者の一時停止も engine 由来も同じ） |
| `loading` → `paused` | 送らない |
| `paused`・`buffering` 中の `positionChanged` | 現在位置だけ更新する（送らない） |
| `ended`・`errored`・`idle` に入った | 送らない |
| `flush()` | 状態が `playing / buffering / paused` のときだけ、現在位置を 1 回送る。ほかの状態では何もしない |
| 背景遷移（App が `scenePhase` の変化を受けたとき） | 1 回送る（共有仕様 §6.4。現行の挙動を保つ。呼ぶ入口は order に無く、I-S3b1 / I-S3b2 の投入前に決める） |
| `listenCompleted(id)` | 下の「完聴」 |

- 同じ位置は再送しない（直近に送った値と等しければ送らない）。値の大小では止めない: 巻き戻した位置も送る（SG-C67）。
- 停止の前に位置を送るのは Coordinator の役目（`session.stop()` や別のエピソードの開始の前に `flush()` を呼ぶ）。`stopForLogout()` は `flush()` を呼ばないので、主体離脱では何も送らない（SG-C16）。
- 送信は待たない。位置の書込が成功したら、応答の `Podcast` を Catalog 側へ渡す。`lastSyncFailure` は「最後に終わった送信の結果」を表す（位置の書込・完聴の記録のどちらも、成功で無し、`ApiFailure` での失敗でその値。ほかの error は無視する）。
- 完聴（SG-X1・SG-C54・SG-C61）: `listenCompleted(id)` はすぐ戻る。同じ再生の中で 2 回目以降は何もしない（`loading` で基準が戻るので、同じエピソードをもう一度聴けばまた送る）。1 本の直列の処理で「background task の開始 → 完聴の記録 → 位置の書込 → ストリークの更新 → background task の終了」を行う。完聴の記録が失敗しても続きを行う。位置の書込に使う値は「`ended` の状態が持つ総時間（0 より大きい）→ 完聴した時点の現在位置（0 より大きい）」の順で、どちらも 0 なら位置の書込を飛ばす。
- 完聴で書く id と値は `listenCompleted` を呼ばれた時点で確定し、直列の処理の中では Reporter の状態を読まない（次のエピソードの `loading` が先に来て基準が戻るため。I-23）。

#### 3.6.6 Coordinator: 通知 `notice`（I-6）

利用者に 1 回見せる知らせを 1 つ持つ。型は「失敗（理由）」か「`load` の警告（説明文）」のどちらか。

| 契機 | `notice` |
|---|---|
| 手動の開始が、開始前に再生できないと分かった（SG-C62） | 失敗（理由）を置く |
| Session が `errored` に入った | 失敗（理由）を置く |
| `start` が警告を返した（SG-C41） | 警告（説明文）を置く |
| `dismissError()` | 消す。`errored` の状態そのものは変えない（失敗したエピソードが現在のまま残り、再生ボタンが再試行になる） |
| 開始の確定（§3.6.7 の最初） | 消す |
| `retry()` がまた開始前の判定に落ちた | `session.fail` の後で、Coordinator が自分で失敗（理由）を置き直す（`errored` の値が前と同じだと `stateChanged` が出ないため） |
| `startEpisode(id:)` の解決が失敗した | 変えない。error をそのまま投げる |
| `stopForLogout()` | 消す |

#### 3.6.7 Coordinator: 世代と開始の流れ（I-7・I-14・I-16・I-23）

**状態を変えるのは、待ちが終わって世代を確かめた後だけ**。Coordinator は世代番号を持つ。

| 世代を 1 進める契機 | 補足 |
|---|---|
| 待ちに入る入口の、待ちの前（手動の開始・`startEpisode(id:)`・`replayCurrent`・`retry`・`skipToNext`・自動の `onEnded`） | 進めた値を控える。待ちの後で世代が控えた値と違っていたら、その開始を捨てる（何も変えない）。後から始めた入口が勝つ（I-23） |
| 開始の確定 | 待っている別の開始を捨てさせる |
| `session.stop()`・`session.fail()` を呼ぶとき | 同上 |
| `stopForLogout()` | 同上 |

- 利用者の操作を自動より優先する（I-23 / SG-C73）: 利用者が起こした入口（`onEnded` 以外）の待ちが 1 つでも残っている間、`onEnded` は完聴を送るだけで、次へ進む処理を始めない。`onEnded` の待ちの間に利用者の入口が始まれば、世代が進むので `onEnded` の側が捨てられる。
- `fetchPodcast` が cancel による error を投げたら、その開始は捨てる（何も変えない）。
- 待ちが入るのは再生元が `network` のときだけ。待ちの間はキューも Session も前のままなので、INV-P1 は途中でも崩れない。
- `session.start` に渡すエピソード・URL・再開位置の元・総時間は、同じ 1 つの DTO（取り直したものか、保持しているもの）から作る。

開始の確定（待たずに続けて行う）:

1. 世代を 1 進め、`notice` を消し、`isAdvancing` を倒し、割り込みの記憶を消す。
2. `reporter.flush()`（前の再生の位置を送る。送る状態でなければ何も起きない）。
3. `session.start`。再開位置は `resolveResume` の結果、速度は既定速度。警告が返ったら `notice` に置く。
4. 表示形態（§3.6.8）。
5. リモートコマンドの登録が無ければ登録して token を持つ（SG-C59）。

`onEnded(endedId)` の手順:

1. `endedId` が `queue.current` の id と違えば何もしない（古い通知）。
2. `reporter.listenCompleted(endedId)`（待たない）。
3. 利用者が起こした入口の待ちが残っていれば、ここで終わる（I-23）。
4. 待機列の先頭が無ければ、ロック画面の情報を消して終わる（`ended` の状態を残す。キューは進めない）。
5. 次が開始前の判定に落ちたら、`queue.advance()` → `session.fail(次の id, 理由)`（共有仕様 §2.11。先にキューを進めるので、失敗したエピソードが現在になり、INV-P1 が保たれる。その先へは進まない）。
6. それ以外は、世代を 1 進めて控え、`isAdvancing` を立て、background task で囲んで再生元を用意する（I-16。画面ロック中は音が止まるとアプリが休止され得る）。待ちが終わったら `isAdvancing` を倒す。
7. 世代が変わっていたら戻る。待機列の先頭が用意したものと違っていたら、4 からやり直す（完聴は送り直さない）。
8. `queue.advance()` → 開始の確定（`expandsPlayer: false`）。

ほかの入口:

| 操作 | 内容 |
|---|---|
| `startEpisode(id:)` | 世代を進めて控え、`fetchPodcast(id)`。失敗は、受けた error をそのまま投げて戻る（キュー・Session・`notice` を変えない）。成功したら手動の入口と同じ流れに入る。解決した DTO を再取得の結果として使い、取得は 1 回（I-14） |
| `replayCurrent()` | `nowPlaying()` が無ければ何もしない。`queue.current` を手動の入口と同じ流れで始める（開始前に再生できないと分かれば `notice` だけで、`ended` の表示は残る）。キューは変えない。再開位置は 0（I-14）。表示形態は `expandsPlayer: false` の規則 |
| `retry()` | `session` が `errored` で `queue.current` があるときだけ動く。開始前の判定に落ちたら `session.fail(id, 理由)` を呼び、`notice` を置き直す（§3.6.6）。それ以外は、世代を進めて控え、再生元の用意 → 世代の確認 → 開始の確定（`expandsPlayer: false`） |
| `togglePlayPause()` | `loading / playing / buffering` → `session.pause()`。`paused` → `session.play()`。`errored` → `retry()`（共有仕様 §2.11）。`idle`・`ended` → 何もしない |
| `addToQueue` / `playNext` | 先に「何も再生していないか」（`session` が `idle`）を控えてからキューに足す。控えが真なら手動の入口と同じ流れで始める（キューに足したことは、開始できなくても残る）。現行 `PodcastViewModel` と同じ規則（導出 ID なし） |
| `removeFromQueue(id)` | `id` が現在のもので `session` が `idle` でなければ、`reporter.flush()` → `queue.remove` → `session.stop()`。次の要素が現在になるが、自動では再生しない（CI-P17）。それ以外は `queue.remove` だけ。表示形態は変えない |
| `skipToNext()` | 共有仕様 §2.12（SG-C63）。利用者の操作として扱う。待機列の先頭が無ければ何もしない。先頭が開始前の判定に落ちたら `notice` だけ。それ以外は、世代を進めて控え、再生元の用意 → 世代の確認 → 待機列の先頭が用意したものと同じなら `queue.advance()` → 開始の確定（`expandsPlayer: false`）。先頭が変わっていたら何もしない。完聴は送らない |
| 割り込みの通知 | 開始の通知で「再生中だったか」を覚える。終了の通知では、「再開してよい」かつ覚えた値が真、かつ `session` が `paused` のときだけ `session.play()` を呼び、覚えた値を消す（SG-C44） |
| `stopForLogout()` | 世代を進める → `session.stop()` → ロック画面の情報を消す → token を解除して手放す → キューを空にする → 表示形態を非表示に → `notice` を消す → `isAdvancing` を倒す → 割り込みの記憶を消す。`reporter.flush()` を呼ばない（SG-C16）。2 回呼んでも同じ |

- Coordinator が `fetch_failed` を作る経路は無い（I-8）。共有仕様 PS-01 の「取得が失敗」は、iOS では「取り直しが失敗し、保持している URL の読み込みも engine が失敗した」場合で、理由は `engine_failed` になる。

#### 3.6.8 Coordinator: 表示形態の遷移規則（I-13・SG-C60）

表示形態は `hidden`（非表示。初期値）・`mini`・`expanded` の 3 つ。

| 契機 | 表示形態 |
|---|---|
| 開始の確定（`expandsPlayer` が真） | `expanded` |
| 開始の確定（`expandsPlayer` が偽） | `hidden` のときだけ `mini`。`mini` / `expanded` なら変えない |
| 開始前に再生できないと分かった・id の解決が失敗した・待機列の終端（`ended`）・現在の削除 | 変えない |
| `minimizePlayer()` | `hidden` なら何もしない。それ以外は `mini` |
| `expandPlayer()` | `nowPlaying()` が無ければ何もしない。それ以外は `expanded` |
| `stopForLogout()` | `hidden`（現行 `PodcastViewModel` と同じ） |

- `expandsPlayer` が偽の規則で始めるもの: `replayCurrent`・`retry`・`skipToNext`・自動の次。

#### 3.6.9 Coordinator: リモートコマンドの戻り値とロック画面の情報（I-12）

「操作できる」= `session` が `loading / playing / buffering / paused`。handler は Coordinator を弱く参照し、Coordinator が無ければ「コマンド失敗」を返す。

| コマンド | 操作できるとき | できないとき |
|---|---|---|
| `play` | `paused` なら `session.play()`。成功を返す | 「該当する内容なし」 |
| `pause` | `paused` でなければ `session.pause()`。成功を返す | 「該当する内容なし」 |
| `togglePlayPause` | `togglePlayPause()`。成功を返す | 「該当する内容なし」 |
| `skipBackward` | `PlaybackConstants.skipBackwardSeconds` だけ戻す。成功を返す | 「該当する内容なし」 |
| `skipForward` | `PlaybackConstants.skipForwardSeconds` だけ進める。成功を返す | 「該当する内容なし」 |
| `changePosition(秒)` | `seek`。成功を返す | 「コマンド失敗」 |
| `changeRate(速度)` | `setSpeed`。成功を返す | 「該当する内容なし」 |

戻り値の名前は port の `RemoteCommandResult`（`success` / `noSuchContent` / `commandFailed`）に対応する。

| Session の通知 | ロック画面の情報（`NowPlayingCenter`） |
|---|---|
| `stateChanged` で `loading / playing / buffering / paused` になった | 全量を更新する（再生中の印は `loading / playing / buffering` で真） |
| `stateChanged` で `idle`・`errored` になった、または `queue.current` が無い | 消す |
| `stateChanged` で `ended` になった | ここでは変えない。`onEnded` が決める（待機列が尽きていれば消す） |
| `positionChanged` | 経過時間だけを更新する |

- リモートコマンドは、登録が無ければ開始の確定で登録し、`stopForLogout()` と Coordinator の破棄の両方で token を解除する（SG-C59。二重の解除は無害）。
- 「次のトラック」（`RemoteCommand` の 8 種目）と、受付を切り替える 6 操作目は保留（I-20・SG-C70）。

## 4. 契約（Contract target）

既存 Contract package の CI-*（`docs/research-reports/2026-09-16-code-design-review/contract-package.md`）を再利用し、target 固有の契約を CI-T* として追加する。番号と主題は web Spec の CI-T と揃える（T1 状態 union、T4 速度、T6 advance 失敗、T7 INV-P1、T8 位置、T9 Queue、T10 保存庫、T11 decode、T12 失敗の意味、T15 AuthSession、T17 Preferences）。テスト仕様 T-T* は Given-When-Then と oracle。

**失敗の表現**: `ApiGateway` は `throws ApiFailure`（Swift の typed throws は deployment target 17 で使えないため `Error` として throw し、消費者は `catch let f as ApiFailure` で受ける。`ApiFailure` 以外の Error が gateway から出ないことを CI-T12 が保証）。`PlaybackQueue` の公開操作は throw しない。

| CI | 対象 capsule | statement（要約） | 由来 | test（oracle は公開 API 経由） |
|---|---|---|---|---|
| CI-T1 | PlaybackSession | 状態は §3.1 の union のみ。16 遷移以外は起きない。`errored` は `paused` / `buffering` と区別できる | G2, IV2, IV3, OB-C3 | T-T1: 16 遷移を `AudioEngine` double の事象で駆動し `state` を観測（分母 16） |
| CI-T1b | PlaybackSession | 任意の状態で `stop` → `idle`、engine の読み込みが外れる。`idle` での `stop` は何もしない（遷移表の外。分母 16 に数えない） | SG-C24 | T-T1b（engine double の状態で観測。I-S3b1） |
| CI-T1c | PlaybackSession | engine 由来の一時停止: engine `paused` は `buffering` のときだけ、`outputDeviceLost` と割り込みの開始は `loading / playing / buffering` のとき `paused` へ。割り込みは開始（再生中だったか）と終了（再開してよいか）を 1 回ずつ外へ知らせ、Session は自分から再開しない | SG-C39・C40・C44・C71（I-21） | T-T1c（I-S3b1） |
| CI-T1d | PlaybackSession | `load` の警告は状態を変えず（`loading` のまま）、`start` の結果として 1 回だけ返る | SG-C41・C42 | T-T1d（I-S3b1） |
| CI-T1e | PlaybackSession | 総時間は DTO の値で始まり、engine の値が 0 より大きければ置き換わる。どちらも 0 の間は seek を上限で丸めない。分かっている間は `[0, 総時間]` | SG-C43 | T-T1e（I-S3b1） |
| CI-T1f | PlaybackSession | どの状態からでも `fail(id, 理由)` → `errored`（理由は `offline_uncached / invalid_source / fetch_failed`）。engine の読み込みが外れる。その後の `start` で `loading` へ進める（遷移表の外。分母 16 に数えない） | SG-C52 | T-T1f（I-S3b1） |
| CI-T2 | PlaybackSession | engine `failed` → `errored(engine_failed)`。重複 `play()` は 1 状態に収束 | CI-P10, OB-C4 | T-T2 |
| CI-T3 | Coordinator | `start` 後の位置は server 値（末尾 2 秒以内 or duration 0 なら 0）。再開位置は `start` の中の seek 1 回で掛け、`ready` の後に掛け直さない（I-15） | CI-P06 | T-T3（既存 `PodcastViewModelTests` の resume 系を特性テストとして流用） |
| CI-T4 | Coordinator / Session | セッション速度は `start` で既定速度に初期化、以後保持。既定速度は Preferences のみが書く | G11, CI-P12, Q4 | T-T4 |
| CI-T5 | Coordinator | 手動の開始で `unavailable` → gateway 呼出なし、キューもセッションも変えず、`notice` に `offline_uncached`（SG-C62。`errored(offline_uncached)` になるのは自動で進んだ先と再試行だけ = CI-T6）。`network` → `fetchPodcast` を 1 回呼び、その `audioUrl` で開始。取得失敗は保持 URL でフォールバック。`startEpisode(id:)` も取得は 1 回（I-14） | CI-P02, CI-P04, Q6 | T-T5: gateway double の呼出回数と URL を観測（既存 `:483` を書き換え） |
| CI-T6 | Coordinator | advance 後の再生失敗: `queue.current` = 失敗エピソード（index は進む）、`errored(reason)`、`retry()` が同エピソードで `startEpisode` を再実行。`errored` の間は位置を送らない（Reporter は `Timer` を持たない。I-9） | G1, IV1, CI-P13, Q3 | T-T6 |
| CI-T7 | Coordinator | INV-P1（`session.episode.id == queue.current?.id`）が全公開操作（19。SG-C10・C60）後に成立。`playById` 相当（`startEpisode` 通知経路）後も `queue.current` が同エピソード。「何が再生中か」の唯一の読出口は `nowPlaying()`（`NowPlaying` の 9 field。SG-C11・C14） | G3, IV4, IV5, CI-P05, CI-P08, Q2 | T-T7a: 全操作後の INV-P1 検査（unit）。T-T7b: `grep -rn "currentPodcast\s*=" NewsListenApp/NewsListenApp --include=*.swift` が `Podcast/Playback/` 以外で 0 件（T-T13 と同じ grep oracle。コンパイル境界は oracle にしない。gate M4） |
| CI-T8 | PositionReporter | 完聴の記録 → 総時間の位置書込の順で送り始める（SG-X1・SG-C61。総時間が不明なら完聴時点の位置、それも 0 なら位置は送らない = SG-C54）。一時停止中は周期送信しない（SG-X4）。巻き戻した位置も送る（SG-C67）。主体離脱では送らない（SG-C16）。同一 episode の完聴通知は **クライアント側で** 1 セッション内 1 回に抑止（backend の冪等性 U3 には依存しない）。応答の位置は Catalog へ反映。失敗は `lastSyncFailure` に現れる | G12, CI-P23, CI-P24 | T-T8: gateway double の呼出列と `lastSyncFailure` |
| CI-T9 | PlaybackQueue | 公開操作は §2 どおり正規化し throw しない。`init` / `setQueue` は id を dedupe。単一要素 `reorderUpNext` は `moveUpNext` と等価。Q-01〜Q-32 不変 | CI-Q02, CI-Q12, SG-C1 | 既存 conformance 32 件（不変）＋ T-T9: 重複 id を含む `init` / `setQueue` の property test |
| CI-T9b | PlaybackQueue（iOS 固有） | 複数要素 `IndexSet` の `reorderUpNext` は SwiftUI `Array.move(fromOffsets:toOffset:)` と同じ結果（選択要素を元順序で一括取り出し、destination から選択済み要素数を差し引いた位置へ一括挿入）。`currentIndex` 不変。範囲外は no-op | CI-Q13, RF20, SG-C2 | T-T9b: 期待値表（upNext=[b,c,d,e]: {0,2}→4 = [c,e,b,d]、{1,3}→0 = [c,e,b,d]、{0,1}→2 = 無変更、範囲外 = 無変更）を `Array.move` の実行結果と突合 |
| CI-T10 | OfflineLibrary | `has` / `url` はファイル実体が正本。`clearAll` 後は `savedIds` が即 空。I-S5 で主体別の保存と起動時回収を足す（ADR-104。SL-06） | G7, IV10, CI-C04 | T-T10: `FileStore` double で `clearAll` 後の `has` と `savedIds` |
| CI-T11 | Episode decode | DTO → 判別共用体。矛盾 DTO・未知 status・`partial_failed`（SG-C64）は `FailedEpisode`。▶は Playable のみ | G8, G9, IV11 | T-T11（表駆動 status 4+未知 × audioUrl 2 × errorMessage 2 = 20） |
| CI-T12 | ApiGateway | 失敗は `ApiFailure` のみ（分母 = `APIEndpoint` の全 case。`Networking/APIEndpoint.swift` で数える）。`notFound.subject` は endpoint ごと。非 HTTPURLResponse は `network`。`rateLimited` は `retryAfter` を持つ | CI-A01, CI-A02, LF6, Q7 | T-T12（既存 `APIClientTests` 34 件を `ApiFailure` へ移植。`MockURLSession` に URLError / 非 HTTP 応答モードを追加） |
| CI-T13 | 消費者 | VM / View に `statusCode ==` / `httpError(` の数値比較が無い | RF10 | T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include=*.swift` が `Networking/` 以外で 0 件（CI で実行） |
| CI-T14 | AuthSession | 4 状態のみ。`fetchMe` の `unauthorized` 以外は `unavailable`（トークン保持）。実行中の任意 API の `unauthorized` で `anonymous` へ | G4, G5, IV6-IV8, CI-S03, Q5 | T-T14（`MockURLSession` の URLError モードで unavailable、401 で anonymous） |
| CI-T15 | SubjectCleanup | 主体離脱（遷移①②。④ は I-S5 で足す = SL-07）の事後に、音声キャッシュが空（I-S5 までは端末単位で `OfflineLibrary.usage() == 0`。I-S5 以降は離脱主体のディレクトリが空）、`nowPlaying()` nil、`NowPlayingCenter.clear` 呼出 1 回、`subjectScoped` key が UserDefaults に無い、位置同期を送らない（SG-C16）。消去失敗は `CleanupIncomplete` | G6, IV9, CI-C05, CI-S05, Q1、ADR-104 | T-T15（`FileStore` / `NowPlayingCenter` double＋UserDefaults suite） |
| CI-T16 | PasswordPolicy | 12〜20 文字（ADR-101）。`AccountSettingsViewModel` と `AdminUsersViewModel` が同じ policy を呼ぶ | RF9(a), Q9 | T-T16（境界値 11/12/20/21） |
| CI-T17 | PreferenceRegistry | registry 外 key・列挙外値は拒否／既定へ。`subjectScoped` の集合が §3.4 と一致 | OB-C7 相当, Q1 | T-T17 |
| CI-T18 | spec 追随 | spec §2.7 iOS 欄（IndexSet 複数移動）と §6.3 iOS 欄（実装名 `OfflineLibrary.clearAll`）、§2 追記「advance 後の再生失敗は停止」が実装と一致 | RF20, RF1, Q3 | T-T18: docs 側の改訂（spec §5 準拠規約: 本書を先に改訂） |

coverage（design 時点）: CI-T 24 件（T1〜T18 + T9b + T1b〜T1f。後の 5 件は 2026-09-30 に追加）すべてに test 仕様あり（design 時点では実行は未）。既存 CI のうち target で `met` へ変わる見込み: Q02, Q13, P03, P04, P05, P08, P09, P13, P17, P19, P23, A02, C05, S03, S05（計 15 件）。**変えない**: A04（force unwrap。到達不能を維持）、C01（読取側 id 検証。RF4 記録のみ）、S06（token 鮮度。SG-A7 default）、P11（partial のまま。挙動不変）。

## 5. カプセルと公開操作（Boundary / code design）

```yaml
code_design:
  capsules:
    - {id: CP1, name: PlaybackSession, owns: [transport 状態 union（§3.1 の 7 状態）, 位置 clamp, セッション速度, AudioEngine port の駆動], hides: [AVPlayer / KVO / observer], emits: [stateChanged(PlaybackState), "positionChanged(seconds, duration)", ended(episodeId), "interruption(began(wasPlaying) / ended(shouldResume))"], note: "state は §3.1 の enum。emits は 4 種（I-5・SG-C44）。EngineEvent は ready / buffering / resumed / paused / ended / failed(description) / timeUpdate(seconds, duration) / interrupted / interruptionEnded(shouldResume) / outputDeviceLost の 10 種（SG-C31〜C33）"}
    - {id: CP2, name: PlaybackQueue, owns: [QueueState と不変条件 1〜5（内部 dedupe）], hides: [配列操作], note: "共有仕様 §2 の公開操作をそのまま。名前は不変"}
    - {id: CP3, name: OfflineLibrary, owns: [保存庫の有無（ファイル実体）, savedIds publish, id 検証], hides: [FileManager, パス規約, 3 段の write], note: "既存 AudioCacheManager を包む。1 インスタンス"}
    - {id: CP4, name: PlaybackCoordinator, owns: [UC-P1/P3/P4/S1 の判断: source 選択・署名 URL 再取得・挿入規則・失敗方針・INV-P1・stopForLogout, 通知 notice, 表示形態, 開始の世代, リモートコマンドの登録と解除], hides: [gateway 関数, ports], note: "読み取り専用で公開する状態は session / presentation / queue / notice / isAdvancing の 5 つ（I-6・I-18）"}
    - {id: CP5, name: EpisodeDecoder, owns: [DTO → Episode 判別], hides: [status 文字列]}
    - {id: CP6, name: ApiGateway（APIClient）, owns: [request, ヘッダ, ApiFailure 正規化, notFound subject], hides: [URLSession, status 数値]}
    - {id: CP7, name: AuthSession + SubjectCleanup（AppState）, owns: [認証状態 union, 失効検知, 主体データ消去の順序], hides: [Keychain, fetchMe]}
    - {id: CP8, name: PreferenceRegistry, owns: [key・scope・subjectScoped・値域], hides: [UserDefaults]}
    - {id: CP9, name: PositionReporter, owns: [再生中 15 秒ごとの送信（位置の通知と注入した時計で数える）, 即時同期の契機, 完聴の記録→総時間の位置の順, 完聴 1 回, 失敗の観測], hides: [background task（closure で注入）, gateway], note: "Timer を持たない（I-9）。完聴時は総時間を送る（SG-X1）"}
    - {id: CP10, name: NowPlayingCenter port + adapter, owns: [ロック画面情報の更新・クリア, remote command 登録/解除], hides: [MPNowPlayingInfoCenter, MPRemoteCommandCenter]}
    - {id: CP11, name: PasswordPolicy, owns: [長さ規則 12〜20（ADR-101）], hides: []}
  public_operations:
    - {capsule: CP1, ops: [start(episode, url, resume, speed), play, pause, seek, seekRelative, setSpeed, stop, "fail(episodeId, reason)", state], note: "9 操作（fail は SG-C52）"}
    - {capsule: CP2, ops: [current, upNext, isEmpty, start, setQueue, add, playNext, jump, advance, remove, reorderUpNext]}
    - {capsule: CP5, ops: [decode(Podcast) → Episode, isPlayable]}
    - {capsule: CP3, ops: ["save(data, for: id)", has, url, remove, clearAll, usage, "refresh(candidateIds:)", savedIds], note: "8 操作（I-10）"}
    - {capsule: CP4, ops: [startEpisode, "startEpisode(id:)", replayCurrent, retry, togglePlayPause, seek, setSpeed, addToQueue, playNext, removeFromQueue, moveUpNext, skipToNext, nowPlaying(), upNext(), presentation, dismissError, stopForLogout, minimizePlayer, expandPlayer], note: "19 操作（startEpisode(id:) / replayCurrent は SG-C10、minimizePlayer / expandPlayer は SG-C60）"}
    - {capsule: CP6, ops: ["各 endpoint メソッド（既存名）→ throws ApiFailure"]}
    - {capsule: CP7, ops: [session, completeLogin, refreshAuth, logout, handle(failure:), retryResolve]}
    - {capsule: CP8, ops: [get(setting), set(setting, value), subjectScopedKeys]}
    - {capsule: CP9, ops: [attach(session), flush, listenCompleted(id), lastSyncFailure]}
    - {capsule: CP10, ops: [update(info), "updateElapsed(elapsed, duration)", clear, "registerCommands(handler) → token", unregister(token)], note: "5 操作（SG-C35・C37）。解除は token 単位"}
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
    - {from: APIError, to: ApiFailure, reason: "意味を持つ値。互換層 TP1 は I-S1 で削除済み"}
    - {from: "didFinishCurrentEpisode", to: "session が ended かつ isAdvancing でない", reason: "合成 atom を状態に（I-18 / SG-C72）"}
    - {from: "playNow / playById / replayCurrentEpisode", to: "startEpisode / startEpisode(id:) / replayCurrent（開始の流れは 1 つ）", reason: "挿入規則を全経路に。Q2。入口の 3 操作は SG-C10"}
  abstraction_decisions:
    - {subject: AudioEngine port, decision: adopt, rationale: "CI-T1 の 16 遷移を AVFoundation 抜きでテスト。1 実装"}
    - {subject: NowPlayingCenter port, decision: adopt, rationale: "logout クリアの外部制御点（Q1）。1 実装"}
    - {subject: "FileStore / URLSessionProtocol", decision: keep, rationale: "既存 seam"}
  rejected_overdesign:
    - {subject: AudioCacheManager の protocol 化, rationale: "RO7。CS2 fail の原因は port 不在ではなく file URL の公開。OfflineLibrary が URL を Coordinator にだけ渡す形で足りる"}
    - {subject: 共通 LoadableViewModel / BaseViewModel, rationale: "RO1 / RO3。一覧読込 9 箇所は change reason が異なる（Boundary D1）"}
    - {subject: 再生ソース Strategy, rationale: "RO2。3 分岐の純関数"}
    - {subject: stale guard 共通抽象, rationale: "RO6。3 方式は異なる正しさを守る"}
    - {subject: AVPlayer 鏡写しの AudioEngineProtocol, rationale: "RO4。port は Session が必要とする操作（7 操作。事象 stream を含む。SG-C22）に絞る"}
    - {subject: token provider 注入, rationale: "SG-A7 default。失効遷移で client 再生成"}
    - {subject: PlaybackQueue の rename（reorderUpNext → moveUpNext）, rationale: "既存テスト 44 件と onMove 配線への影響に対し、spec の対応表で名前差を吸収する方が安い。web と逆の判断を spec に明記"}
  dependency_direction: ["Views → ViewModels → Coordinator/AppState → Playback/Account/Catalog/Preferences ← Platform adapters", "Podcast/Playback ↛ AVFoundation/MediaPlayer/UIKit/SwiftUI", "Podcast/Playback ↛ APIClient（gateway 関数を注入）", "DesignSystem ↛ ViewModel 内部（DEBUG ファクトリ経由）"]
  change_scenarios:
    - {id: CS1, name: "replace AVPlayer → 別エンジン", expected: pass, evidence: "AudioEngine adapter の差替えで CP1/CP4 の契約テストが不変"}
    - {id: CS2, name: "replace FileManager → 別ストレージ", expected: pass, evidence: "OfflineLibrary の内部。公開 url は Coordinator のみが読む"}
    - {id: CS4/CS5/CS7, name: "change one business rule（パスワード / 404 意味 / 合格閾値）", expected: "pass（1 ファイル）。合格閾値は QuizSheetView の VM 化と同時（保留 views）"}
    - {id: CS10/CS11/CS12, name: "authority / logout 消去 / 速度 2 概念", expected: pass, evidence: "本 Spec の target"}
```

**interface が露出してはならないもの（leakage guard）**: `AVPlayer` / `AVPlayerItem` / `CMTime`、`MPNowPlayingInfoCenter`、`UIApplication`、`HTTPURLResponse` / status 数値、`APIError`（削除済み）、OS の説明文（`localizedDescription`）の解釈・加工（説明文は理由値の中身として運ぶだけにする。SG-C42）、`Podcast` DTO を「再生中」の意味で読むこと・View に出すこと（`nowPlaying()` の `NowPlaying` を使う。SG-C11）、`@Published var` の外部書込（全 capsule で `private(set)`）。

## 6. 移行（Change Safety）— §8 の着手順に沿った slice

原則: slice ごとに **特性テスト（現行挙動の pin）→ RED（CI-T*）→ 実装 → 旧 path 削除条件の確認**。1 slice = 1 PR 目安。temporary path は owner・導入日・削除条件を持つ。共有仕様の改訂は spec §5 の規約どおり **実装より先**に行う（I-S0）。

slice ID は親 docs の実行計画 `docs/plan/2026-09-16-design-review-refactor.md`（2026-09-23 再スライス版）の接頭辞付き ID **I-\*** を使う（親 docs `design/ios-design.md` §11.3・order フォルダの README と同じ）。旧 S3b の「一括切替」は ①ドメイン層の新設 → ②入口の差し替え → ③旧実装の削除 の 3 段に分け、Platform adapter 2 本は I-S3a へ前倒しした。**進捗の正本は `docs/plan/2026-09-16-design-review-refactor/README.md` の状態欄**で、本表には書かない。特性テストの件数は 2026-09-16 時点の値で、各 slice が着手時に実測し直す。

| slice（旧 ID） | 内容 | 特性テスト（baseline） | RED（T-T*） | temporary path |
|---|---|---|---|---|
| I-S0 spec（旧 S0） | `docs/design/shared-playback-spec.md` の改訂（親リポ・別 PR）: §2 に「advance 後の再生失敗は停止・失敗エピソードを current に保持（3 platform 共通。Android は追随義務）」を追記、§2.7 に操作名の 3 者対応表（spec `moveUpNext(from,toOffset)` / web `moveUpNext` / iOS `reorderUpNext(fromOffsets:toOffset:)`）と iOS 欄（IndexSet 複数移動はコア仕様対象外を iOS 実装が内部提供・単一要素は等価）、§6.3 iOS 欄を `OfflineLibrary.clearAll()`（logout・失効の両方）へ。ADR-053 の追記 | conformance 32/32・17/17 | T-T18 | なし |
| I-S1 failure meaning（旧 S1。§8 順 1） | `ApiFailure`・`validateResponse` の変換・`notFound.subject`・非 HTTP 応答・`FailureMessages`。10 消費者の置換。`MockURLSession` に URLError / 非 HTTP モード | `APIClientTests`（34）・`AuthAPIClientTests`（8）・各 VM テスト（Feed 40 / Starred 15 / Settings 26 / Login 4 / Passkey 13 / Onboarding 5） | T-T12, T-T13 | **TP1** `APIError` 互換 throw（`ApiFailure` から生成）。owner: user、導入: I-S1、削除条件: `Networking/` 以外に `APIError` の参照が 0。**削除済み**（削除条件が I-S1 の中で成立した。production に `APIError` の参照は無い） |
| I-S2 session boundary（旧 S2。§8 順 2） | `AuthSession` union・`handle(failure:)` の失効検知・`refreshAuth` の失敗分類・`SubjectCleanup`（token / `OfflineLibrary.clearAll` / `stopForLogout` / `subjectScoped` key）・`PreferenceRegistry`・`NowPlayingCenter` port（clear を呼ぶ最小）。この時点では `PlaybackLifecycle` port（§2 composition root）を現行 `PodcastViewModel` が実装。音声キャッシュの削除は I-S5 まで端末単位の `clearAll()` | `AppStateAuthTests`（8）・`AppStatePreferencesTests`（3）・`AppStateDefaultsTests`（1）・`AudioCacheManagerTests`（13）・`LearningEngagementModelTests`（seenAchievementIds） | T-T14, T-T15, T-T17（行 ID: SL-01〜SL-05） | **TP2** `AudioCacheManager` の 2 インスタンスを合成 root の 1 つに寄せるまで `SettingsViewModel` 側は既定引数を残す。owner: user、導入: I-S2、削除条件: I-S3b2 で `OfflineLibrary` の注入が完了した時点で成立（I-S3b2 では型を `OfflineLibrary` に変えた既定引数として残る）。物理削除は I-S3b3。**TP4** 現行 `PodcastViewModel` による `PlaybackLifecycle` 実装（`stopPlayback()` + NowPlaying クリア + `queue` 初期化）。owner: user、導入: I-S2、削除条件: I-S3b2 で Coordinator が実装を引き継いだ時点で成立（port 名が同じため呼出側 `SubjectCleanup` は不変。gate M5）。物理削除は I-S3b3 |
| I-S3a port と adapter（旧 S3a ＋ 旧 S3b の Platform adapter） | `AudioEngine` port（7 操作・事象 10 種）と test double、Platform adapter 2 本（`Podcast/Platform/{AVPlayerEngine,MediaPlayerNowPlaying}`）、`NowPlayingCenter` の 5 操作化、現行 `PodcastViewModel` の port 経由化（挙動不変・公開面不変）。`PodcastViewModelTests` のうち AVFoundation / `vm.player` / KVO ハンドラを直接扱う **17 関数**（78 中。2026-09-30 実測。11 は double 駆動へ、6 は `AVPlayerEngineTests` へ）を移植 | `PodcastViewModelTests` | —（全件 green が I-S3b1 の入口条件） | **TP5** 「engine に音声が読み込まれているか」を持つ `PodcastViewModel` の private な旗（SG-C23）。owner: user、導入: I-S3a、削除条件: I-S3b2 で Session の状態（`idle` か否か）に置き換わった時 |
| I-S3b1 playback domain（旧 S3b の ①） | `Podcast/Playback/{Session,Coordinator,OfflineLibrary,PositionReporter}`・`Models/Episode.swift`・Preview 用の DEBUG ファクトリをドメイン層として新設（§3.1・§3.2・§3.6）。engine の test double を実 adapter と同じ振る舞いに直す（I-2）。既存コードからは呼ばない | 既存テスト全件（既存の production は変えない） | T-T1・T1b〜T1f・T2〜T8・T10・T11（行 ID: RS-01〜RS-07・PS-04） | なし（新規コードのみ） |
| I-S3b2 playback entry（旧 S3b の ②） | 合成 root（`OfflineLibrary`・Coordinator・PositionReporter）・`PodcastViewModel` を facade 化（`currentPodcast` は `nowPlaying()` 派生の computed、`downloadedIds` → `savedIds`）・開始の流れ 1 つ（playNow / playById / replay 統合）・署名 URL 再取得・速度初期化・advance 失敗の停止・`PlaybackQueue` の dedupe gate・`Episode` 判別への切替・`PreviewSupport` の DEBUG ファクトリ化・`PodcastView.swift` の `errorMessage = nil` を `dismissError()` へ・`SettingsViewModel` / `SettingsView` へ `OfflineLibrary` 注入。共有仕様 §2・Q-* は挙動不変 | I-S3a で移植済みの `PodcastViewModelTests` を特性テストとして新 facade へ、`PlaybackQueueTests`（12）、`PlaybackQueueConformanceTests`（32）、`NowPlayingInfoTests`（13）、`AudioCacheManagerTests`（13）、`TranscriptTimingTests`（13。`currentTime` 駆動が不変であること） | 準拠テスト: PS-01〜PS-03（CI-T6）・PS-04（CI-T7 / T-T7b）・PS-05 / PS-05b / PS-06（CI-T8）・PS-07（CI-T11）・PS-08（CI-T4）・CI-T9 / T9b | **TP3** `PodcastViewModel` の旧公開プロパティ名（`isPlaying` / `currentTime` / `duration` / `playbackSpeed` / `isBuffering` / `errorMessage` / `currentPodcast` / `queue`）を computed で残す。owner: user、導入: I-S3b2、削除条件: I-S3b3 で View 側が `nowPlaying()` / `session` を直接読むよう置換完了。本 slice で TP5 を削除し、TP2・TP4 の削除条件が成立する |
| I-S3b3 playback cleanup（旧 S3b の ③ ＋ 旧 S5 の View 直読み化） | 旧実装の削除（`PodcastViewModel` の縮小・`didFinishCurrentEpisode` / `downloadedIds`）。`QueueSheet` / `PodcastView` / `MiniPlayerView` / `AudioPlayerView` の読出を `nowPlaying()` / `session` へ付け替える。子 View は `NowPlaying` を受け、`Podcast` DTO を出さない（SG-C11） | 契約テストの件数を減らさない | —（参照 0 件の grep で判定） | TP2・TP3・TP4 を物理削除 |
| I-S3c remote next track（**保留**。SG-C70） | リモートコマンド「次のトラック」を `skipToNext` につなぐ。待機列が空の間は無効にする（SG-C63）。`NowPlayingCenter` は 6 操作、`RemoteCommand` は 8 種になる（I-20）。解除条件 = 実機でロック画面の表示・イヤホンの操作の割り当て・CarPlay を確かめた後に user が決める | — | CI-T7 の抜粋（共有仕様 §2.12） | — |
| I-S4 rules & CI（旧 S4。§8 順 4） | `PasswordPolicy`（12〜20。ADR-101）・`AccountSettingsViewModel` 新設（`saveProfile` / `changePassword` を View から移す）・`AdminUsersViewModel` の policy 参照・既定速度 Picker を `PlaybackConstants.speeds` の 8 段へ（SG-X5）・`ci.yml` を `make test`（`scripts/test.sh` に `SIMULATOR` 動的選択と `CODE_SIGNING_*` を吸収）呼出へ。I-S5 と並行可 | `AdminUsersViewModel` はテスト 0 → 特性テストを先に追加 | T-T16 | なし |
| I-S5 subject cache（新設。ADR-104） | 主体別音声キャッシュ（`{cacheDir}/audio/{user_id}/`）・起動時の回収・旧平置きキャッシュの初回全削除・`user_id` 欠落時はキャッシュ無効・ダウンロードジョブの主体固定・遷移④・logout は破棄前に捕捉したトークンで既存 `Authorization: Bearer`・logout 時の APNs 解除の client 呼出の削除（ADR-104 決定 5〜9・14・16・26、台帳 SG-A1・SG-B3・SG-B6、SG-C12・C13。§3.1・§3.3）。依存: I-S3b3 ＋ backend main の `user_id` 契約（B-S5a） | `AudioCacheManagerTests`・`AppStateAuthTests`・`SettingsViewModelTests` | 準拠テスト SL-06 / SL-07、SL-01 / SL-02 の音声キャッシュ部分（CI-T10 / T15） | なし。**不可逆点**（キャッシュ構造の変更。移行なし） |
| 位置同期（**保留**。slice ID 未定） | ADR-109 決定 7〜13（SG-C74〜C79。§3.1「位置同期の新しい規則」）。解除条件 = backend B-S7 が main に入り、I-S3b3 が終わった後に order を起こす | — | — | — |
| 保留 views（旧 S5 の残り） | `QuizSheetView` の採点ロジック VM 化（CS7）・View の構造整理。学習機能のサイクルまで | — | — | — |

旧 ID との対応: S0 → I-S0、S1 → I-S1、S2 → I-S2、S3a → I-S3a、S3b → I-S3a（Platform adapter 2 本）＋ I-S3b1 ＋ I-S3b2 ＋ I-S3b3、S4 → I-S4、S5 → I-S3b3（View の直読み化・TP3 の削除）＋ 保留 views。I-S3c・I-S5・位置同期は 2026-09-23 以降の新設。

**I-S3b2 の scope 上の注意**: `AudioPlayerView.swift` は `vm.currentPodcast` を 12 箇所で読む（2026-09-16 実測）。TP3 の computed で型を保つため I-S3b2 では View の読出を触らない（付け替えは I-S3b3）。stale ガード（`vm.currentPodcast?.id == podcast.id`）は `nowPlaying()?.episodeId` と同値であることを T-T7a に含める。トランスクリプト同期（`currentTime` 駆動）は `session.position` の派生で不変。

**不可逆点**: I-S5 のキャッシュディレクトリ構造の変更（平置き → 主体別。ADR-104 決定 26。旧い平置きキャッシュは初回起動で全削除し、移行しない = 台帳 SG-A1）だけ。backend 契約・Keychain の service 名・UserDefaults の key 名・共有仕様 §2 の意味論は不変（§2 への追記は既存行の変更ではない）。
**rollback**: slice 単位の revert。旧 S3b の一括切替は 3 段に分けたので、巻き戻しの範囲は I-S3b1 = 追加ファイルの削除、I-S3b2 = 入口の差し替え、I-S3b3 = 削除の取り消しに分かれる。I-S3b2 は特性テスト（挙動不変の行）と準拠テスト（変わる行）で判定する。I-S0 の spec 改訂は iOS 実装より先に merge されるが、追記内容は web / Android の現行挙動を否定しない（advance 失敗時の挙動は両者とも未定義だった）。

## 7. Requirement → UC → model → contract → test の trace

| R | UC | model / capsule | CI | test | status（design） |
|---|---|---|---|---|---|
| R1 業務ルール単一所有 | UC-P1/P3, UC-A2 | CP4, CP5, CP11, FailureMessages | CI-T5/T6/T11/T16, CS4/CS5 | T-T5/6/11/16 | covered（クイズ閾値 CS7 は保留 views） |
| R2 再生の不正状態なし | UC-P1〜P6 | CP1, CP2, CP3, CP5 | CI-T1/T2/T3/T6/T9/T10/T11 | T-T1〜3, 6, 9〜11 | covered |
| R3 正本一意 | UC-P1/P2/P5/P6 | Queue.current + INV-P1, CP3 savedIds, CP8, CP9 | CI-T4/T7/T8/T10 | T-T4/7a/7b/8/10 | covered |
| R4 失敗の意味 | 全 UC | CP6 ApiFailure, errored(reason) | CI-T5/T12/T13 | T-T5/12/13 | covered |
| R5 失効・認可 | UC-A1 | AuthSession, handle(failure:) | CI-T14 | T-T14 | covered |
| R6 主体離脱で残留なし | UC-A1, UC-S2 | SubjectCleanup, CP10, CP8 subjectScoped | CI-T15, CI-T17 | T-T15/17 | covered（spec §6.3 は I-S0 で実装名へ改訂。主体別の資産は I-S5 = SL-06 / SL-07） |
| R7 本番経路のテスト | — | 既存 URLSession seam、AudioEngine / NowPlaying double、MockURLSession 拡張 | 各 T-T が実 APIClient / 実 PlaybackQueue を通す | UI テストは据置（UV1） | partial（UI 層は目視 UV3） |
| R8 CI ゲート | — | — | — | ci.yml → make test（I-S4） | covered（lint / カバレッジは Q9 で見送り） |
| R9 spec 準拠 | UC-P4 | CP2 dedupe gate、spec §2.7 iOS 欄 | CI-T9, CI-T18 | conformance 49 + T-T9 | covered |

**UC 側の coverage 分母**: UC 12 件のうち CI-T を持つのは UC-P1〜P6, UC-A1〜A3, UC-S1, UC-S2 の 11 件。**CI 対象外 1 件**: UC-S3（クラッシュ通報。現状維持で変更なし）。

## 8. 検証計画と decision

```yaml
verification_plan:
  per_slice: ["特性テスト green（baseline）", "T-T* RED → GREEN", "DEVELOPER_DIR=... xcodebuild test -only-testing:NewsListenAppTests（verification-run.md §1 の手順）", "I-S3b2 のみ: シミュレータ目視 UV3（logout 後のロック画面、auto-advance 失敗時の停止表示、一覧放置 1 時間後の再生）"]
  independent: ["slice ごとに code-review ロール 1 回（consolidated）", "I-S3b3 完了時（旧 S3b の 3 段が揃った時）に adversarial-review で CI-T1〜T11 の oracle を検算"]
  unexecuted_now: [UV1 UI テスト, UV3 目視, UV4 T-T* 実装]
  pre_implementation_gate: {role: architecture, result: "revise → 本版で M1〜M6 反映", artifact: "docs/research-reports/2026-09-16-code-design-review/spec-gate.md"}
selection_gates:
  - {id: SG-S1, subject: "spec §2 への『advance 後の再生失敗は停止』追記の適用範囲", owner: user, status: satisfied, decision: "3 platform 共通（review §8 Q3 で「spec §2 に追記（3 platform 共通）」と決定済み。gate M2(a) で pending 化を撤回）。Android は未実装のため追随義務を spec に明記"}
  - {id: SG-S2, subject: "PlaybackQueue.reorderUpNext の名前を維持する（web と逆の判断）", owner: user, status: satisfied, decision: "維持。spec の対応表で吸収"}
  - {id: SG-S3, subject: "未知 status の fail-closed（FailedEpisode）", owner: user, status: satisfied, decision: "fail-closed。U2 は解消（partial_failed も再生不可 = SG-C64・ADR-108。共有仕様 §6.6）"}
decision:
  status: pass
  artifact_readiness: ready
  engineering_status: in_progress   # slice ごとの進捗の正本は docs/plan/2026-09-16-design-review-refactor/README.md の状態欄
  release_status: not_applicable
  decision_maturity: {status: approved, owner: user, approval_evidence: ["review §8", "2026-09-16 user: Spec 承認・SG-S2 名前維持・SG-S3 fail-closed を含む"], baseline_version: "2026-09-16", change_control: "本書を更新して再承認。承認済みの決定（監査レポート §5・§5.0、ADR）の反映は、本文を直して §9 改訂履歴に 1 行足す"}
  next_phase: {name: "§6 の I-* の slice を、order フォルダ README の投入順で進める（tdd-implementation ロール）", status: allowed, human_approvals_required: []}
  resolved_unknowns: ["OB-A1: backend のパスワード検証値 → ADR-101 で確定（12〜20）", "U2: 未知 status の扱い → fail-closed で確定（SG-S3）。partial_failed も再生不可（SG-C64）"]
  unknowns: ["U1: backend の podcast id 規則（読取側検証は安全側で入れる）", "U3: backend の完聴・位置更新の冪等性（CI-T8 の『1 回』はクライアント側抑止として実装し backend 依存を注記）"]
  residual_risks: ["I-S3b2（入口の差し替え）は、I-S3a の移植済みテストと I-S3b1 の契約テストが green であることを入口条件にする", "R7 の UI 層は目視のまま（XCUITest は Q9 で見送り）", "I-S5 はキャッシュ構造を変える不可逆点（移行なし）", "位置同期の新しい規則（ADR-109）は iOS に未反映（保留。§3.1）"]
```

## 9. 改訂履歴

2026-09-30 に、冒頭の追記と ADR-104 系の決定を本文へ反映した。1 行 = 直した 1 箇所。決定 ID の「台帳」は親 docs 監査レポート §5、I-\* は同 §5.0。

| 日付 | 節 / 行 ID | 旧値 | 現行値 | 決定 ID |
|---|---|---|---|---|
| 2026-09-30 | 冒頭の追記の運用 | 本書は改訂せず、追記と order を優先する | 本文を直し、本節に 1 行足す。追記は経緯として残す | —（運用） |
| 2026-09-30 | §0 `public_contract_change_allowed` | backend API の意味論は不変 | 位置の書込（ADR-109。iOS は保留）と `user_id`（I-S5 が読む）を例外として注記 | ADR-109、ADR-104 決定 15 |
| 2026-09-30 | §1.2 UC-A2・§3.3 PasswordPolicy・§4 CI-T16・§5 CP11・§6 I-S4 | 8〜20 文字。境界値 7/8/20/21 | 12〜20 文字。境界値 11/12/20/21 | ADR-101 |
| 2026-09-30 | §2 port 表 `AudioEngine`・§5 RO4 | 6 操作（load / play / pause / seek / rate / 事象 stream）。遷移 13 本 | 7 操作（`stop` を足す。`load` は説明を返す）。遷移 16 | SG-C22・C34 |
| 2026-09-30 | §2 port 表 `NowPlayingCenter`・§5 CP10 ops | update / clear / 登録 / 解除 | 5 操作（`updateElapsed` を足す。登録は token を返し、解除は token 単位） | SG-C35・C37 |
| 2026-09-30 | §3.1 `loading` 行 | `ready` → `paused` → 即 `play()` | `start` が「load → seek → play → setRate」を続けて行う。`ready` は状態を進めるだけ。`pause()`・割り込み・出力機器の切断・シークを受ける | SG-C58、I-1 / SG-C66、I-3、I-21 / SG-C71、I-22 |
| 2026-09-30 | §3.1 `playing`・`buffering` 行 | engine 由来の一時停止の記載なし | engine `paused`（`buffering` のみ）・`outputDeviceLost`・割り込みの開始で `paused` | SG-C39・C40・C44 |
| 2026-09-30 | §3.1 `errored` 行 | episode（取得前は `episodeRef: {id}`）を持つ | id・位置・理由だけ。`fetch_failed` を作る経路は無い。`errored` での `play()` は判断待ちの注記 | I-4、I-8 |
| 2026-09-30 | §3.1 遷移表の外の操作 | 記載なし | `stop`（リセット）と `fail`（取得前・開始前の失敗）。分母 16 に数えない | SG-C24、SG-C52 |
| 2026-09-30 | §3.1 不変条件 | `position ∈ [0, duration]` | 総時間が分かっている間だけ。不明な間は下限 0 だけ | SG-C43 |
| 2026-09-30 | §3.1 `nowPlaying()` | title / difficulty / duration / position / 状態の view model | `NowPlaying`（共通 7 ＋ iOS 固有 2 field）。`Podcast` DTO を View に出さない | SG-C11・C14、I-11 |
| 2026-09-30 | §3.1 PlaybackQueue | dedupe とだけ記載 | `setQueue` の重複 id の決め方を明記 | SG-C50 |
| 2026-09-30 | §3.1 PlaybackSource | `unavailable` は `errored(offline_uncached)` | 手動の開始は通知だけ。`errored` は自動で進んだ先と再試行だけ | SG-C62 |
| 2026-09-30 | §3.1 OfflineLibrary・§5 CP3 ops | `save(episode)` を含む 7 操作 | `save(data, for: id)`・`refresh(candidateIds:)` を含む 8 操作。取得は呼ぶ側 | I-10 |
| 2026-09-30 | §3.1 OfflineLibrary（主体別キャッシュ） | 記載なし | 主体別ディレクトリ・旧キャッシュの初回全削除・起動時回収・`user_id` 欠落時の扱い・ジョブの主体固定（target。I-S5） | ADR-104 決定 5〜9・16・26、台帳 SG-A1・SG-B3・SG-B6、SG-C13 |
| 2026-09-30 | §3.1 Coordinator `startEpisode` | 先にキューを変え、再生不可なら `errored` | 開始前の判定 → 取り直しの待ち → 世代の確認 → キューと Session。手動の再生不可は通知だけ | I-7、SG-C62 |
| 2026-09-30 | §3.1 Coordinator の操作 | `startEpisode` 1 つに通知・replay を含める | `startEpisode(id:)`・`replayCurrent()`・`skipToNext()` を明記。公開 19 操作・公開する状態 5 つ | SG-C10・C60・C63、I-6・I-14・I-18 |
| 2026-09-30 | §3.1 `onEnded`・§5 naming | 完聴 → `advance` → 次を開始。表示は `session == .ended` | 取り直しの後で `advance`。利用者の開始を優先。表示は「`ended` かつ自動で進む途中でない」 | I-7、I-16、I-18 / SG-C72、I-23 / SG-C73 |
| 2026-09-30 | §3.1 `removeFromQueue` | `queue.remove` → `session.stop()` | 先に `reporter.flush()` | I-9 |
| 2026-09-30 | §3.1 `stopForLogout()` | `session.stop()` → `nowPlaying.clear()` → キューを空に | 世代を進める・リモートコマンドの解除・表示形態を非表示に・`notice` を消すを足す。`flush()` を呼ばない | SG-C59、SG-C16、I-7、I-13 |
| 2026-09-30 | §3.1 PositionReporter・§4 CI-T6 / T8・§5 CP9 | 15 秒 throttle（Timer）。完聴 → 位置 0 | `Timer` を持たない。完聴 → 総時間。一時停止中は送らない。巻き戻しも送る。主体離脱では送らない | I-9、SG-X1・X4、SG-C54・C61・C67、SG-C16、I-23 |
| 2026-09-30 | §3.1 位置同期の新しい規則 | 記載なし | 保留として要点と解除条件を記載（端末に永続保存・差 15 秒以上・確認を出せない経路・離脱で未送信も消す） | ADR-109、SG-C74〜C79 |
| 2026-09-30 | §3.2 未知 `status` | U2 が確定するまでの既定 | fail-closed で確定。`partial_failed` も再生不可 | SG-S3、SG-C64 |
| 2026-09-30 | §3.3 SubjectCleanup・§4 CI-T15 | 対象は logout・失効。手順 (1)〜(5) | 遷移①②④。順序は「破棄 → 遷移 → 後始末」。現状と target（I-S5）の差を表にした。logout の APNs 解除の client 呼出は I-S5 で削除 | ADR-104 決定 1〜3・14・26、SG-C12、SG-C16 |
| 2026-09-30 | §3.5 TP1・§5 naming / leakage guard | `APIError` 互換層を残す | 削除済み | 実装済みの事実（I-S1。production に `APIError` の参照 0 件） |
| 2026-09-30 | §3.5 background task | PositionReporter の adapter 側に閉じる | closure で Reporter と Coordinator に注入 | I-16 |
| 2026-09-30 | §3.6（新設） | I-S3b1 の order に置く | 操作 × 状態・事象 × 状態・16 辺・Reporter・`notice`・世代・表示形態・リモートコマンドの表を本書に置く | I-1・I-3・I-6・I-7・I-9・I-12・I-13・I-14・I-21・I-22・I-23 |
| 2026-09-30 | §4 CI-T1b〜T1f | 追記にだけ記載 | 契約表に 5 行を足した。CI-T は 24 件 | SG-C24・C39〜C44・C52・C71 |
| 2026-09-30 | §4 CI-T3 | `ready` 後に再適用 | 掛け直さない | I-15 |
| 2026-09-30 | §4 CI-T5 | `unavailable` → `errored(offline_uncached)` | 手動の開始は `notice` だけ | SG-C62 |
| 2026-09-30 | §5 CP1 | emits 3 種・EngineEvent 8 種・ops 8 | emits 4 種・EngineEvent 10 種・ops 9（`fail`） | I-5、SG-C31〜C33、SG-C52 |
| 2026-09-30 | §5 CP4 ops | 15 操作 | 19 操作 | SG-C10、SG-C60 |
| 2026-09-30 | §5 leakage guard | `localizedDescription` の英語文言 | 説明文を解釈・加工しない（理由値の中身として運ぶ） | SG-C42 |
| 2026-09-30 | §6 slice 表 | S0 / S1 / S2 / S3a / S3b（一括切替）/ S4 / S5 | I-S0 / I-S1 / I-S2 / I-S3a / I-S3b1〜b3 / I-S3c（保留）/ I-S4 / I-S5 / 位置同期（保留）/ 保留 views。TP2〜TP5 の現行の削除条件 | 親 plan の 2026-09-23 再スライス、SG-C23、SG-C70、ADR-104 |
| 2026-09-30 | §6 不可逆点 | なし | I-S5 のキャッシュ構造の変更 | ADR-104 決定 26、台帳 SG-A1 |
| 2026-09-30 | §8 decision | `engineering_status: planned`・`next_phase` は S0 → S1・unknowns に OB-A1 と U2 | `in_progress`・I-* を README の投入順で・OB-A1 と U2 は解消 | ADR-101、SG-S3、SG-C64 |
