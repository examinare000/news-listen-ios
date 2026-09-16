## iOS リファクタ S2: 失効境界（AuthSession・SubjectCleanup・PreferenceRegistry）

## 概要
2026-09-16 の iOS 設計レビューで constraint 違反・完全性欠落と判定された認証状態・主体離脱・設定レジストリを、再生ドメイン本体（S3）に先立って閉じる。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§3.3 Account・§3.4 Preferences・§4 CI-T14/T15/T17・§6 S2 行）。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。generate_spec の spec.md は Spec の該当契約（CI-T14/T15/T17）の抜粋で足り、契約 ID は Spec のものを再利用する。

Spec §8 着手順 2。S1 の merge 後に着手する（`ApiFailure` を `handle(failure:)` が読むため）。

## 前提・着手条件
- 依存: S1 が merge 済みで `ApiFailure` が使えること。
- SG-X3（cleanup 完了待ち）は「待たない」で確定（共有仕様 §6.5）。`authenticated → anonymous` の遷移を消去完了で止めない。
- `docs/trial-log/` を最初に読み、棄却済み案を再試行しない。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`AuthSession` union（CI-T14）**: `AppState.swift`。判別共用体 `resolving | authenticated(user) | anonymous | unavailable(failure)` を導入する。`resolving` で `fetchMe` が `unauthorized` なら `anonymous`、それ以外の `ApiFailure` なら `unavailable(failure)`（**トークンは保持**）。`authenticated` で `logout` または任意 API 呼出の `unauthorized` なら `anonymous`（失効）。`unavailable` からの再試行は `resolving` へ戻る。
2. **失効検知 1 箇所**: `AppState.handle(failure:)` に、`ApiFailure.unauthorized` を受けて `anonymous` へ遷移させる処理を 1 箇所へ集約する。各 VM は `ApiFailure.unauthorized` を文言化せず、遷移は `AppState` に委ねる。
3. **`refreshAuth` の失敗分類**: `unauthorized`（401 相当）のときだけトークンを破棄する。通信断・5xx・decode 失敗は `unavailable` としてトークンを保持し、再試行導線を出す。
4. **`SubjectCleanup`（`Auth/SubjectCleanup.swift`、新規）**: `authenticated → anonymous` の全遷移（logout・失効の両方）の事後条件として、(1) `sessionStore.token = nil`、(2) `OfflineLibrary.clearAll()`、(3) `PlaybackCoordinator.stopForLogout()`（本 slice では composition root 節どおり **現行 `PodcastViewModel` が `PlaybackLifecycle` port を暫定実装**する。TP4）、(4) 主体依存 UserDefaults の削除（§3.4 registry で `subjectScoped: true` の key）、(5) `currentUser = nil` の順で実行する。各手順は独立に試み、1 つが失敗しても残りを実行する。消去失敗は `CleanupIncomplete` として観測可能に返し、認証状態の遷移自体は止めない（SG-X3 確定）。
5. **`PreferenceRegistry`（`Settings/PreferenceRegistry.swift`、新規）**: `AppState.swift:40-47` の `Keys`・`DSFeedback.swift:27-28`・`LearningEngagement.swift:147` に散在する設定宣言を `{ key, scope: local | server, subjectScoped: Bool, codec, default }` の 1 registry に集約する。`subjectScoped: true` の集合 = 実績既読（`seenAchievementIds`）・週目標（`weeklyGoalEpisodes`）・既定難易度（`defaultDifficulty`）・既定速度（`defaultPlaybackSpeed`）のローカルコピー。`articleOpenMode` / `timeFormat` / `sfxEnabled` / `hapticsEnabled` は `subjectScoped: false`（端末設定として残す）。`AppState` の `didSet → UserDefaults` 直書きは registry の `set` に置換する。`SubjectCleanup` は `subjectScoped == true` の key だけを消す。
6. **`NowPlayingCenter` port（clear の最小）**: logout でクリアする入口として `NowPlayingCenter.clear()` を `SubjectCleanup` から呼べるようにする。本 slice では port と最小の clear 呼出のみを用意し、`update` / `registerCommands` 等の他操作の port 化は S3b で行う。

## 契約（CI-T → T-T の表）
| CI | 内容 | T-T |
|---|---|---|
| CI-T14 | `AuthSession` は 4 状態のみ。`fetchMe` の `unauthorized` 以外は `unavailable`（トークン保持）。実行中の任意 API の `unauthorized` で `anonymous` へ | T-T14: `MockURLSession` の URLError モードで `unavailable`、401 で `anonymous` になることを `AppStateAuthTests` へ追加 |
| CI-T15 | `authenticated → anonymous`（logout・失効の両方）の事後に `OfflineLibrary.usage() == 0`、`nowPlaying()` nil、`NowPlayingCenter.clear` 呼出 1 回、`subjectScoped` key が UserDefaults に無い。消去失敗は `CleanupIncomplete` | T-T15: `FileStore` / `NowPlayingCenter` double ＋ UserDefaults suite。準拠テスト SL-01〜SL-05（`docs/design/shared-playback-spec.md` §4.4）の行 ID をテスト名に含める |
| CI-T17 | registry 外 key・列挙外値は拒否／既定へ。`subjectScoped` の集合が §3.4 と一致 | T-T17: `PreferenceRegistry` の get/set と `subjectScopedKeys` の突合 |

## 特性テスト（baseline。着手前に green を確認）
`AppStateAuthTests`（8）・`AppStatePreferencesTests`（3）・`AppStateDefaultsTests`（1）・`AudioCacheManagerTests`（13）・`LearningEngagementModelTests`（`seenAchievementIds` 系）。

## 手順（TDD 順序）
1. baseline: 上記特性テストと `xcodebuild test -only-testing:NewsListenAppTests` の green を記録する。
2. T-T14 → RED（`AuthSession` union を先に定義し、既存 `AppState` の状態プロパティとの対応が壊れる状態を確認）→ `resolving`/`fetchMe`/`refreshAuth` の実装 → GREEN。
3. `PreferenceRegistry` を新規追加し、T-T17 → RED → 実装 → GREEN。`AppState.swift:40-47` の `Keys` を registry 呼出に置換する。
4. `SubjectCleanup` を新規追加し、T-T15 → RED（SL-01〜SL-05 の行 ID を含むテスト名で double を注入）→ 実装 → GREEN。この時点では `PlaybackCoordinator` が存在しないため、TP4（現行 `PodcastViewModel` の `PlaybackLifecycle` 暫定実装: `stopPlayback()` + NowPlaying クリア + `queue` 初期化）を導入する。owner: user、導入: S2、削除条件: S3b で `PlaybackCoordinator` が `PlaybackLifecycle` を実装した時点。
5. `handle(failure:)` に失効検知を集約し、既存の分散した 401 判定（S1 で置換済みの `ApiFailure` 値）を 1 箇所へまとめる。
6. TP2 を導入する: `OfflineLibrary` の合成 root 単一インスタンス化は S3b の対象のため、本 slice では `SettingsViewModel` 側の既定引数生成をそのまま残す。owner: user、導入: S2、削除条件: S3b で `OfflineLibrary` 注入完了。
7. 1 slice = 1 PR 目安。契約ごとの commit を分ける（`AuthSession` → `PreferenceRegistry` → `SubjectCleanup`）。

## 完了条件
- `xcodebuild test -only-testing:NewsListenAppTests` が全 green。
- T-T14 / T-T15 / T-T17 が `verifies: CI-T14/T15/T17` をテスト名またはコメントに持つ。T-T15 のテスト名に SL-01〜SL-05 の行 ID を含む。
- TP2・TP4 が導入され、owner・導入日・削除条件がコード上のコメントまたは PR 説明に明記されている。
- `subjectScoped` の集合が Spec §3.4 の表（defaultDifficulty / defaultPlaybackSpeed / weeklyGoalEpisodes / seenAchievementIds のみ true）と一致する。

## 禁止事項 / scope 外
- `PlaybackCoordinator` 本体・`PlaybackSession`・`PlaybackQueue` の dedupe gate（S3b）は作らない。
- `AudioEngine` port（S3a/S3b）は行わない。
- token provider 注入（RO: SG-A7 default）は作らない。失効遷移で client 再生成する既存方式を維持する。
- Spec に無い業務条件（新しい `subjectScoped` key・新しい消去対象）を足さない。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §2（composition root）・§3.3・§3.4・§4（CI-T14/T15/T17）・§6（S2）
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（SG-A5/SG4, SG-C5, Q1, Q5）
- 親 docs: `docs/design/shared-playback-spec.md` §4.4（SL-01〜SL-05）・§6.5・§6.7（SG-X3）
