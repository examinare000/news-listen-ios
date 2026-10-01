## iOS リファクタ I-S3c: リモートコマンド「次のトラック」を `skipToNext` につなぐ

> **保留（2026-09-30。SG-C70）**: 本 order は投入しない。イヤホンのリモコンの 2 回押しが、待機列の有無で「次のエピソードへ」と「30 秒送り」に変わること、ロック画面にボタンが出ない可能性があること、port の操作が 1 つ増えることを、実機で確かめてから user が改めて決める。確認は I-S3b2 の目視項目 (7) で記録する。以下は、つなぐと決めた場合の案として残す。

## 2026-10-01 目標アーキテクチャ（ADR-110・Spec §8.3）による補正
- 保留のまま（SG-C70）。TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §8.3 のとおり、`NowPlayingCenter` の宣言の置き場が I-T2b で `Podcast/Playback/NowPlayingCenter.swift` に変わるので、本文の path だけを追随させた（`Podcast/Platform/NowPlayingCenter.swift` の 2 箇所を置換）。中身・操作の数（6）・判断の扱いは変えていない。投入すると決めたときは、I-T1〜I-T12 の後の実物で着手前の前提点検を書き足してから投入する。

## 概要
I-S3b1 が作った Coordinator の `skipToNext`（共有仕様 §2.12）を、OS のリモートコマンド「次のトラック」（ロック画面・コントロールセンター・イヤホンのリモコン・CarPlay）につなぐ。待機列が空の間は、このコマンドを無効にする。アプリ内の画面にボタンは足さない。

正本は親 docs 監査レポート §5 の **SG-C63**（「iOS は操作を I-S3b1 で作り、ロック画面の『次のトラック』への接続は I-S3b3 の後の独立した slice で入れる。待機列が空の間はボタンを無効にする」）と共有仕様 §2.12。検証モード（再設計しない）。新しい契約 ID を作らない（CI-T7 の抜粋として検証する）。

## 前提・着手条件
- 依存: **I-S3b3 の ios PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（親で `git submodule status` の `ios` 行に `+` が無い）。
- コマンドの実行場所: 検査コマンドはすべて **`ios/`（submodule のルート）** で実行する。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/PlaybackCoordinator.swift`（rc=0）で場所を確かめる。
- 確定済み（再提案しない）: SG-C63（上記）、SG-C59（リモートコマンドの登録と解除は Coordinator）、SG-C37（解除は token 単位）、SG-C27（ロック画面 port は App が 1 個作る）。
- I-S4・I-S5 とは変更ファイルが重ならない。同じ submodule の slice なので、投入は直列にする。

## 対象（ios サブモジュールのみ）
**変更（production 3 本）**
1. `Podcast/Playback/NowPlayingCenter.swift`
   - `RemoteCommand` に `case nextTrack` を足す（8 種）。
   - `NowPlayingCenter` に `func setNextTrackEnabled(_ enabled: Bool)` を足す（6 操作。I-20）。意味は「『次のトラック』のコマンドを受け付けるかどうかを切り替える」。
2. `Podcast/Platform/MediaPlayerNowPlaying.swift`
   - `registerCommands` で `MPRemoteCommandCenter.shared().nextTrackCommand` を `handler(.nextTrack)` へ配線する（ほかのコマンドと同じ closure 方式。解除は同じ token に含める）。登録の時点では無効（`isEnabled = false`）にしておく。
   - `setNextTrackEnabled(_:)` は `nextTrackCommand.isEnabled` を設定する。
   - token の解除時に `nextTrackCommand.isEnabled = false` に戻す。
3. `Podcast/Playback/PlaybackCoordinator.swift`
   - リモートコマンドの handler に `.nextTrack` を足す。

     | 状態 | 動作 | 戻り値 |
     |---|---|---|
     | 操作できる（`session` が `loading / playing / buffering / paused`）かつ `queue.upNext` が空でない | `Task { await skipToNext() }` | `.success` |
     | それ以外 | 何もしない | `.noSuchContent` |
   - **有効・無効の切替**: リモートコマンドを登録した直後と、`queue` の値が変わるたびに、`nowPlayingCenter.setNextTrackEnabled(!queue.upNext.isEmpty)` を呼ぶ（`queue` の `didSet` でよい）。`stopForLogout()` は token を解除する（adapter が無効に戻す）。
   - 公開 19 操作・`@Published` 5 つ・`NowPlaying` の field は変えない。

**変更（test）**
- `NewsListenAppTests/AppStateTestSupport.swift` の `NowPlayingCenterSpy`: `private(set) var nextTrackEnabled: Bool?`（初期値 `nil`）を足し、`setNextTrackEnabled` で記録する。
- `PlaybackCoordinator+Preview.swift` の「何もしない」ロック画面 port に `setNextTrackEnabled` を足す（production のファイルだが、port の操作が増えるため。変更はこの 1 行だけ）。
- 契約テスト（Coordinator のテストファイルに足す）と `MediaPlayerNowPlayingTests`。

**削除**: なし。

## 契約（RED テスト）
| CI | テスト |
|---|---|
| CI-T7 | **T-T7h**: (a) `[a, b]` で a を再生中 → handler に `.nextTrack` → `.success` が返り、b が始まる（位置を 1 回送る・`markCompleted` 0 回・表示形態不変。§2.12）。(b) 待機列が空 → `.noSuchContent`・何も変わらない。(c) `idle`・`ended`・`errored` → `.noSuchContent`。(d) `nextTrackEnabled` の推移: 開始で登録した直後は待機列に応じた値。`addToQueue` で true、待機列が尽きる操作（`removeFromQueue`・`skipToNext`・自動で次へ）で false。(e) `stopForLogout` の後、spy の登録が 0（I-S3b1 の T-T7d と同じ観測） |
| CI-T7 | **T-T7i**（adapter）: `MediaPlayerNowPlaying` の `setNextTrackEnabled(true / false)` が `MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled` に反映される。token を解除すると false に戻る。既存 `MediaPlayerNowPlayingTests`（3）と同じ書き方で足す |

## 完了条件
- 契約テストが green。既存テストが全件 green（I-S3b1〜I-S3b3 の契約テスト・準拠テストの件数が減らない）。
- 変更した production が 4 本だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 4 行（上の 3 本 ＋ `PlaybackCoordinator+Preview.swift`）。
- `GrepOracleTests`（10）が無変更で green（`MPRemoteCommandCenter` の参照が `Podcast/Platform/` の外に出ていない = G03）。
- I-S3b1 の完了条件 4（`Podcast/Playback/` の import と `APIClient`）が 0 件のまま。
- `grep -c "nextTrack" NewsListenApp/NewsListenApp/Podcast/Playback/NowPlayingCenter.swift` が 1 以上、`grep -rn "nextTrackCommand" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "^NewsListenApp/NewsListenApp/Podcast/Platform/"` が 0 件。
- シミュレータまたは実機の目視を PR 説明に記す: (1) 待機列があるとき、イヤホンのリモコン（または CarPlay・コントロールセンター）の「次のトラック」で次へ進む。(2) 待機列が空のとき、進まない。(3) **ロック画面にボタンが出るかどうか**を記録する。現行は 15 秒戻し・30 秒送りのコマンドを登録しており、OS がロック画面にどちらのボタンを出すかは OS の表示規則で決まる（2026-09-30 時点で未確認）。出ない場合も本 slice は完了とし、表示の扱い（戻し・送りと入れ替えるか）は user の判断に回す。

## 禁止事項 / scope 外
- アプリ内の画面（`AudioPlayerView`・`MiniPlayerView`・`QueueSheet`）に「次へ」のボタンを足さない。
- 15 秒戻し・30 秒送りのコマンドを外さない。「前のトラック」を足さない。
- `skipToNext` の規則（共有仕様 §2.12）を変えない。Coordinator の公開操作を 19 より増やさない。
- `Podcast/Playback/` のほかのファイルと `AVPlayerEngine.swift` を変えない。

## 特性テスト（baseline）
I-S3b3 完了時点の全件。とくに `MediaPlayerNowPlayingTests`（3）・I-S3b1 の T-T7d・`GrepOracleTests`（10）。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test …`（README のコマンド）→ 全 green。
- 完了条件のコマンドを `ios/` で実行し、結果を PR 説明に貼る。

## 規模（見込み）
- production ≈ 35 行: port 3・adapter ≈ 12・Coordinator ≈ 18・Preview 1。
- test ≈ 110 行: T-T7h ≈ 80・T-T7i ≈ 25・spy ≈ 5。
- 合計 ≈ 145 行。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs へ返すもの: 共有仕様 §2.12 の準拠状況（iOS の入口あり）。Spec 冒頭の追記の `NowPlayingCenter` 5 操作は 6 操作に、`RemoteCommand` は 8 種になる。目視 (3) の結果。
