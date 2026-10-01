## iOS リファクタ I-S4: 業務ルール単一所有（PasswordPolicy）・CI ゲート

## 2026-10-01 目標アーキテクチャ（ADR-110・Spec §8.3）による補正
正本: 親 docs `adr/110-refactor-target-domain-centered-onion-cqrs.md`、iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`（以下「TA Spec」）§8.3 の I-S4 の表（補正 1〜6）。パスワードの値域（ADR-101 の 12〜20）・CI の方針・既定速度の 8 段（SG-X5）は変えていない。
- 補正 1: 前提に I-T5 を足した（表示名の更新の結果が `Subject` になる）。
- 補正 2: `PasswordPolicy` の置き場を `Auth/Domain/PasswordPolicy.swift` にした。規則の正本はここで、値（12・20）は ADR-101 の契約表から写す。入力欄の案内文とエラーの文言（4 箇所）は policy の値から作る（TA-R-AC-1・TA-D1）。
- 補正 3: `AccountSettingsViewModel` は presentation。`APIClient` を持たず、application の `AccountProfile`（`Auth/Application/AccountProfile.swift`。gateway は closure）を呼ぶ。`AccountProfile` と `Networking/Gateways/AccountGateway+Live.swift`（表示名とパスワードの分）を新規の対象に足した（TA-D6）。
- 補正 4: 入力の下書き（表示名・現在のパスワード・新しいパスワード）は View の `@State` のままにし、command の引数で渡す。書き込める `@Published` を足さない（TA-D12）。
- 補正 5: 速度の Picker が参照する `PlaybackConstants` の path は `Podcast/Playback/Domain/`（I-T2a）。難易度・週の目標・時刻表記の値域は本 slice では触らない（I-T6）。
- 補正 6: 完了条件の「grep oracle（T-T7b / T-T13）が CI 上で実行される」は、T-T13 が XCTest に入っていること（I-T1 の T-TA-V9）を前提にした。`ci.yml` の `statusCode ==` / `httpError(` の grep の step は**残す**（消すと決めた決定が無い。検査は XCTest と CI の step の両方で走る）。
- 着手前の前提点検の節を足し、検証コマンドを ios README の現行の形式（`make test`）にした。

## 概要
パスワード規則を 1 policy に集約し、`AccountSettingsView` の業務ロジックを ViewModel と application（`AccountProfile`）へ移し、CI を `make test` 経由へ揃える。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§3.3 PasswordPolicy・§4 CI-T16・§6 S4 行）と、型の置き場・依存の向きは TA Spec §5.3（TA-M-AC・TA-C-AC-5・6・TA-R-AC-1）・§5.4（TA-R-PB-4）。パスワード値域は Spec 本文の記載ではなく `docs/adr/101-password-policy-cross-client-unification.md` の確定値を正本とする。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。generate_spec の spec.md は Spec の該当契約（CI-T16）と ADR-101 の契約表の抜粋で足りる。

応える要求: ADR-101、`F-SET-04`、TA-R-AC-1・TA-R-PB-4（TA Spec §9.2）。

Spec §8 着手順 4（親 plan の I-S4）。I-S3b3 と I-T5 の merge 後に着手する。I-S5（主体別キャッシュ）とは変更ファイルが重ならないため **並行投入可**（README「投入順」）。

## 前提・着手条件
- 依存: **I-S3b3 と I-T5 の submodule PR が main に merge 済み、かつ親リポ `news-listen` のポインタが進んでいる**（`git -C <親> submodule status` で `ios` に `+` が無い）。I-T5 が `Subject`・`AppState.updateCurrentSubject(_:capturedAt:)` を入れていること。I-T1 の `ArchitectureOracleTests`（T-TA-V9 を含む）が green。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Auth/Domain/Subject.swift`（rc=0）。
- **パスワード値域は 12〜20 文字**（`docs/adr/101-password-policy-cross-client-unification.md` 決定）。Spec 本文 §3.3 の「8〜20」は web / iOS レビューの仮決定であり、backend レビュー（SG-PW）が 12〜20 で差し戻した確定前の値のため採らない。境界値テストは 11/12/20/21 とする。
- 特性テスト `AdminUsersViewModel` 追加は本 slice 冒頭で行う（本 slice 内の baseline）。
- 文字種規則（4 文字種中 3 種）・ブロックリスト・username 非包含は backend 側の検証であり、iOS の事前検証には**長さ規則のみ**を実装する（ADR-101「web / iOS / android は表示と事前検証だけを 1 policy に持ち、値は backend の契約表から写す」）。文字種等の追加検証は Spec に無い業務条件のため足さない。
- `docs/trial-log/` を最初に読み、棄却済み案を再試行しない。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-S3b3・I-T5 の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| 「8 文字以上」の検査 | 2 行: `Settings/AccountSettingsView.swift:321`・`Admin/AdminUsersViewModel.swift:47`（TA-V3 の TA-R-AC-1） | `grep -rn 'count >= [0-9]\|count < [0-9]' NewsListenApp/NewsListenApp --include='*.swift'` |
| 文言 | 4 箇所: `AccountSettingsView.swift:63,322`・`AdminUsersViewModel.swift:48`・`Admin/AdminUsersView.swift:28` | `grep -rn '8文字\|8 文字' NewsListenApp/NewsListenApp --include='*.swift'` |
| View の業務ロジック | `AccountSettingsView.swift:307-336`（`saveProfile`: stamp の捕捉 → `client.updateProfile` → `appState.updateCurrentSubject`（I-T5 の後の名前）／`changePassword`: 長さの検査 → `client.changePassword` → 文言 3 種。`catch ApiFailure`（`:331`）が TA-D4 の `ApiFailure` 1 行） | `sed -n 300,337p NewsListenApp/NewsListenApp/Settings/AccountSettingsView.swift` |
| 速度の Picker | `Settings/SettingsView.swift:50` `playbackSpeeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]`。`PlaybackConstants.speeds`（8 段）は I-T2a の後 `Podcast/Playback/Domain/PlaybackConstants.swift` | `grep -rn 'playbackSpeeds\|static let speeds' NewsListenApp/NewsListenApp --include='*.swift'` |
| `ci.yml` | `:38-50` の grep の step（CI-T13）、`:61-` の `xcodebuild test`（`name=` の動的選択の独自経路） | `grep -n 'name:\|xcodebuild\|statusCode' .github/workflows/ci.yml` |
| `AdminUsersViewModel` のテスト | 0 件（2026-10-01 実測: `NewsListenAppTests/` に `AdminUsersViewModelTests.swift` が無い） | `ls NewsListenApp/NewsListenAppTests \| grep -i admin` |

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`Auth/Domain/PasswordPolicy.swift`（新規、domain、1 実装）**: `validate(password) → Result` で **12〜20 文字**の長さ規則のみを検証する。最小・最大の値（12・20）を公開し、案内文と文言はこの値から作る（文言の組み立ては presentation。値の正本は policy）。
2. **`Auth/Application/AccountProfile.swift`（新規、application）**: `updateDisplayName(_:) async throws -> Subject`（TA-C-AC-5。receipt = 確定した `Subject`）と `changePassword(current:new:) async throws`（TA-C-AC-6。失敗は `policyViolation`・`currentPasswordRejected`・`ApiFailure`。`PasswordPolicy` を先に呼ぶ）。gateway は closure の束 `AccountGateway`（宣言は同じファイル。`portFiles` に登録）。主体ガード（stamp の捕捉と `isCurrentSubject`）は呼ぶ側（ViewModel → `AppState.updateCurrentSubject(_:capturedAt:)`）のまま。
3. **`Networking/Gateways/AccountGateway+Live.swift`（新規、adapter）**: `AccountGateway.live(apiClient:)`（`updateProfile`・`changePassword` の 2 つ。応答の `AuthUser` は `toSubject()`。I-T7c が残りの closure を足す）。
4. **`Settings/AccountSettingsViewModel.swift`（新規、presentation）**: `AccountSettingsView.swift:305-336` の `saveProfile` / `changePassword` を View から移す。`APIClient` を持たず `AccountProfile` を呼ぶ。公開する状態は `@Published private(set)`（文言・送信中）だけ。入力の下書き（表示名・現在のパスワード・新しいパスワード）は View の `@State` のまま、command の引数で渡す（TA-D12。恒久の許可リストを増やさない）。文言は現行と同じ。
5. **`Settings/AccountSettingsView.swift`**: 状態を描くだけにする。`@StateObject` で VM を持つ。`ApiFailure` を書かない。案内文（`:63`）は policy の値から作る。
6. **`Admin/AdminUsersViewModel.swift:47-48`・`Admin/AdminUsersView.swift:28`**: 長さの検査を `PasswordPolicy` に、文言を policy の値から導出する形に置換する（現状テスト 0 のため、置換前に特性テストを追加する）。`AdminUsersViewModel` の `APIClient` と `AuthUser` は I-T7c まで残る。
7. **`Settings/SettingsView.swift:50`**: 設定画面の既定速度 Picker が独自配列（`[Double]` 5 段）を持つのを `PlaybackConstants.speeds`（`Podcast/Playback/Domain/PlaybackConstants.swift`。`[Float]` 8 段）参照に置換する（SG-X5 確定・共有仕様 §6.6。web / Android で保存した 1.75・2.5 を iOS の設定でも表示・選択できるようにする）。`appState.defaultPlaybackSpeed` は `Double` のため `PlaybackConstants.speeds.map(Double.init)` で写す（値の正本は `PlaybackConstants` の 1 箇所。独自配列を残さない）。難易度・週の目標・時刻表記の値域は触らない（I-T6）。
8. **`.github/workflows/ci.yml`**: `xcodebuild test`（`name=` 動的選択の独自経路）を `make test` 呼出へ揃える。`statusCode ==` / `httpError(` の grep の step（`:38-50`）は残す。`scripts/test.sh` に `SIMULATOR` の動的選択と `CODE_SIGNING_*` の吸収を追加し、`make test` が CI 環境でも実行できるようにする。
9. **test**: `ArchitectureManifest.swift`（`portFiles` に `Auth/Application/AccountProfile.swift`、`domainTestFiles` に `PasswordPolicyTests.swift`。許可リストから TA-V3 の TA-R-AC-1 2 行・TA-R-PB-4 1 行、TA-D4 の `AccountSettingsView` の `APIClient`・`ApiFailure` の行を消す）。

**対象外**: `Authentication`・`DeviceSessions`・`PasskeyEnrollment`・`UserAdministration`（I-T7c）、`AdminUsersViewModel` の `APIClient`（I-T7c）、`PreferencesStore`（I-T6）。

## 変更の責務（TA Spec §5.3）
| 責務 | 層・置き場 |
|---|---|
| パスワードの長さの規則（TA-R-AC-1） | domain: `Auth/Domain/PasswordPolicy.swift` |
| 表示名とパスワードの変更の手順・失敗の意味 | application: `Auth/Application/AccountProfile.swift` |
| 通信 → `Subject` | adapter: `Networking/Gateways/AccountGateway+Live.swift` |
| 文言・送信中・入力の下書き（View の `@State`） | presentation: `AccountSettingsViewModel`・View |

## 移行の中間状態
- 許可リスト（TP10）の増減は上の対象 9。新しい一時経路は無い。

## 変わる挙動
| ID | 変わる挙動 | 現行 |
|---|---|---|
| ADR-101（CI-T16） | パスワードの事前検査が 12〜20 文字になり、案内文と文言が新しい値を示す | 8 文字以上 |
| SG-X5（共有仕様 §6.6・PS-08） | 設定の既定速度の選択肢が 8 段（0.5〜2.5）になる | 5 段 |

## 契約（CI-T → T-T の表）
| CI | 内容 | T-T |
|---|---|---|
| CI-T16 | 12〜20 文字。`AccountSettingsViewModel`（`AccountProfile` 経由）と `AdminUsersViewModel` が同じ policy を呼ぶ | T-T16（境界値 11/12/20/21。`PasswordPolicyTests` は domain のテスト） |
| TA-C-AC-5・6 | `AccountProfile` の receipt と失敗の意味。`MockURLSession` で `PATCH /auth/me`（表示名）・`POST /auth/password` の呼出と失敗文言を固定する | T-TA-C-AC-5・6 |

## 特性テスト（baseline。着手前に green を確認）
`AdminUsersViewModel` はテスト参照 0（`docs/research-reports/2026-09-16-code-design-review/verification-run.md` §8 実測。2026-10-01 再実測も 0）のため、置換前に現行の文言・挙動を固定する特性テストを先に追加する。`AccountSettingsView` の `saveProfile` / `changePassword` は **View テストが無い**（2026-09-23 実測: `NewsListenAppTests/` に `AccountSettings*` 無し）。View に private で閉じているため移動前の pin は書けず、`AccountProfile`・`AccountSettingsViewModel` 新設時に `MockURLSession` で「`PATCH /auth/me`（表示名）・`POST /auth/password` の呼出と失敗文言」を固定するテストを先に書き、View からの移動後にそのテストと build green で判定する。

## 手順（TDD 順序）
1. baseline: `AdminUsersViewModel` の特性テストを新規追加し（現行の文言・分岐を固定）、`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` の green を記録する。
2. T-T16 → RED（`PasswordPolicy.validate` 未実装でコンパイル/テスト失敗）→ `Auth/Domain/PasswordPolicy.swift`（12〜20）を実装 → GREEN。
3. `AccountProfile` と `AccountSettingsViewModel` のテスト（上記）→ RED → 新設し、`saveProfile` / `changePassword` を View から移す → GREEN。View は `@StateObject` で VM を持ち状態を描くだけにする。
4. `AdminUsersViewModel` を policy 参照に置換し、S4 冒頭で追加した特性テストが green のままであることを確認する（文言の数値だけが ADR-101 の値に変わる行は、変わる挙動の表の行として Then を改める）。
5. 速度の Picker を `PlaybackConstants.speeds` 参照に置換する。
6. `ci.yml` を `make test` 呼出へ変更し、`scripts/test.sh` に `SIMULATOR` 動的選択・`CODE_SIGNING_*` 吸収を追加する。CI 上で `make test` が通ることを確認する。
7. 1 slice = 1 PR。commit は「PasswordPolicy」「AccountProfile と AccountSettingsViewModel」「AdminUsersViewModel 置換」「速度の Picker」「CI ゲート」「所属表」の単位で分ける。
8. 記録: `docs/trial-log/` に棄却・方針転換があれば追記。親 docs `design/ios-design.md` §4（パスワード規則）・§11.3（I-S4 行）は本 slice 完了時に現状記述へ書き換える。

## 完了条件
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` が全 green。
- T-T16 が `verifies: CI-T16` をテスト名またはコメントに持ち、境界値 11/12/20/21 を含む。
- 長さの検査が 1 箇所: `grep -rn 'count >= [0-9]\|count < [0-9]\|count > [0-9]\|count <= [0-9]' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が `Auth/Domain/PasswordPolicy.swift` の行だけ（正の対照: 2026-10-01 実測 2 行）。`grep -rn '8文字\|8 文字\|12\|20' NewsListenApp/NewsListenApp/Settings/AccountSettingsView.swift NewsListenApp/NewsListenApp/Admin/AdminUsersView.swift NewsListenApp/NewsListenApp/Admin/AdminUsersViewModel.swift | grep '文字'` が 0 件（文言の数値は policy の値から作る）。
- `AccountSettingsView.swift` に業務ロジックが無い: `grep -n 'client\.\|APIClient\|ApiFailure\|count >=' NewsListenApp/NewsListenApp/Settings/AccountSettingsView.swift` が 0 件（Passkey と端末のセッションの子 View の生成 `:38-46` の `apiClient` 引数は I-T7c まで残る。完了条件の grep は `apiClient:` の引数を数えない: `grep -n 'client\.' …` で判定する）。
- `AccountSettingsViewModel` が通信を知らない: `grep -n 'APIClient\|AuthUser\|import UIKit\|import SwiftUI' NewsListenApp/NewsListenApp/Settings/AccountSettingsViewModel.swift` が 0 件。`grep -c '@Published var' 同ファイル` → 0。
- `AdminUsersViewModel` と `AccountProfile` が同一の `PasswordPolicy` 型を参照する: `grep -rln 'PasswordPolicy' NewsListenApp/NewsListenApp --include='*.swift'` に両方が含まれる。
- 設定画面の既定速度 Picker の選択肢が `PlaybackConstants.speeds` と同一: `grep -n 'playbackSpeeds\|0.75, 1.0' NewsListenApp/NewsListenApp/Settings/SettingsView.swift` が 0 件。
- CI（`.github/workflows/ci.yml`）が `make test` を呼び出し、grep oracle（T-T7b は I-S3b2 以降 `GrepOracleTests` に、T-T13 は I-T1 の T-TA-V9）を含む既存テストスイートが CI 上で実行される。`ci.yml` の `statusCode ==` / `httpError(` の grep の step が残っている（`grep -c 'statusCode ==' .github/workflows/ci.yml` → 1）。
- `ArchitectureOracleTests` が green で、許可リストから対象 9 の行が消えている（PR 説明に前後）。

## 禁止事項 / scope 外
- lint（swiftlint/swiftformat）・カバレッジ計測・XCUITest の導入は行わない（レビュー・Spec とも未導入判断のまま）。
- パスワードの文字種規則・ブロックリスト・username 非包含チェックを iOS 側に追加しない（backend 検証のみ。ADR-101）。
- `error_message` 4 値の文言写像（ADR-102）は本 slice のスコープ外（iOS 次サイクル RO-c）。
- Spec に無い業務条件（パスワード値域以外の新規検証）を足さない。
- 入力の下書きを ViewModel の `@Published var` にしない（TA-D12）。`AccountSettingsViewModel` に `APIClient` と通信のデータモデルを持ち込まない（TA-D6）。
- 難易度・週の目標・時刻表記の値域に触らない（I-T6）。`ci.yml` の grep の step を消さない。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み）
- production ≈ 220 行（`PasswordPolicy` ≈ 25・`AccountProfile` ≈ 50・gateway ≈ 25・`AccountSettingsViewModel` ≈ 70・View の削減 ≈ −40・Admin ≈ 10・速度の Picker ≈ 3・`ci.yml`・`scripts/test.sh` ≈ 30）。test ≈ 250 行（`AdminUsersViewModel` の特性 ≈ 80・`PasswordPolicyTests` ≈ 30・`AccountProfile`・VM ≈ 120・所属表 ≈ 10）。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §3.3・§4（CI-T16）・§6（S4 行 = I-S4）、TA Spec §5.3・§5.4・§8.3
- 親 docs: `docs/design/ios-design.md` §4・§11.3（I-S4 行）、`docs/design/shared-playback-spec.md` §6.6・§6.7（SG-X5）
- ADR: `docs/adr/101-password-policy-cross-client-unification.md`（**12〜20 が正本**）、`docs/adr/110-refactor-target-domain-centered-onion-cqrs.md`
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（SG-B2, Q9）
- 検証: `docs/research-reports/2026-09-16-code-design-review/verification-run.md` §8（AdminUsersViewModel テスト参照 0）・§9（ci.yml の現行経路）
