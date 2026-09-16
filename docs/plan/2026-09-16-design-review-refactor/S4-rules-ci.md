## iOS リファクタ S4: 業務ルール単一所有（PasswordPolicy）・CI ゲート

## 概要
パスワード規則を 1 policy に集約し、`AccountSettingsView` の業務ロジックを VM へ移し、CI を `make test` 経由へ揃える。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§3.3 PasswordPolicy・§4 CI-T16・§6 S4 行）。パスワード値域は Spec 本文の記載ではなく `docs/adr/101-password-policy-cross-client-unification.md` の確定値を正本とする。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。generate_spec の spec.md は Spec の該当契約（CI-T16）と ADR-101 の契約表の抜粋で足りる。

Spec §8 着手順 4（最終 slice）。S3b の merge 後に着手する。

## 前提・着手条件
- 依存: S3b が merge 済み。
- **パスワード値域は 12〜20 文字**（`docs/adr/101-password-policy-cross-client-unification.md` 決定）。Spec 本文 §3.3 の「8〜20」は web / iOS レビューの仮決定であり、backend レビュー（SG-PW）が 12〜20 で差し戻した確定前の値のため採らない。境界値テストは 11/12/20/21 とする。
- 文字種規則（4 文字種中 3 種）・ブロックリスト・username 非包含は backend 側の検証であり、iOS の事前検証には**長さ規則のみ**を実装する（ADR-101「web / iOS / android は表示と事前検証だけを 1 policy に持ち、値は backend の契約表から写す」）。文字種等の追加検証は Spec に無い業務条件のため足さない。
- `docs/trial-log/` を最初に読み、棄却済み案を再試行しない。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`Auth/PasswordPolicy.swift`（新規、1 実装）**: `validate(password) → Result` で **12〜20 文字**の長さ規則のみを検証する。
2. **`AccountSettingsViewModel`（新規）**: `AccountSettingsView.swift:305-333` の `saveProfile` / `changePassword` を View から移す。View は状態を描くだけにする。
3. **`AdminUsersViewModel.swift:47`・`AdminUsersView.swift:28`**: 文言をこの policy から導出する形に置換する（現状テスト 0 のため、置換前に特性テストを追加する）。
4. **`Settings/SettingsView.swift:50`**: 設定画面の既定速度 Picker が独自配列（5 段）を持つのを `PlaybackConstants.speeds`（8 段）参照に置換する（SG-X5 確定・共有仕様 §6.6。web / Android で保存した 1.75・2.5 を iOS の設定でも表示・選択できるようにする）。
5. **`.github/workflows/ci.yml`**: `xcodebuild test`（`name=` 動的選択の独自経路）を `make test` 呼出へ揃える。`scripts/test.sh` に `SIMULATOR` の動的選択と `CODE_SIGNING_*` の吸収を追加し、`make test` が CI 環境でも実行できるようにする。

## 契約（CI-T → T-T の表）
| CI | 内容 | T-T |
|---|---|---|
| CI-T16 | 12〜20 文字。`AccountSettingsViewModel` と `AdminUsersViewModel` が同じ policy を呼ぶ | T-T16（境界値 11/12/20/21） |

## 特性テスト（baseline。着手前に green を確認）
`AdminUsersViewModel` はテスト参照 0（`docs/research-reports/2026-09-16-code-design-review/verification-run.md` §8 実測）のため、置換前に現行の文言・挙動を固定する特性テストを先に追加する。`AccountSettingsView` の `saveProfile` / `changePassword` は現行 View テスト（存在すれば）を特性テストとする。

## 手順（TDD 順序）
1. baseline: `AdminUsersViewModel` の特性テストを新規追加し（現行の文言・分岐を固定）、`xcodebuild test -only-testing:NewsListenAppTests` の green を記録する。
2. T-T16 → RED（`PasswordPolicy.validate` 未実装でコンパイル/テスト失敗）→ `Auth/PasswordPolicy.swift`（12〜20）を実装 → GREEN。
3. `AccountSettingsViewModel` を新設し、`saveProfile` / `changePassword` を View から移す。移動前後で View テスト（あれば）が green のままであることを確認する。
4. `AdminUsersViewModel` を policy 参照に置換し、S4 冒頭で追加した特性テストが green のままであることを確認する。
5. `ci.yml` を `make test` 呼出へ変更し、`scripts/test.sh` に `SIMULATOR` 動的選択・`CODE_SIGNING_*` 吸収を追加する。CI 上で `make test` が通ることを確認する（ローカルでは `verification-run.md` の注記どおり `make test` が実行できない環境があるため、CI 実行結果で確認する）。
6. 1 slice = 1 PR。commit は「PasswordPolicy」「AccountSettingsViewModel」「AdminUsersViewModel 置換」「CI ゲート」の単位で分ける。

## 完了条件
- `xcodebuild test -only-testing:NewsListenAppTests` が全 green。
- T-T16 が `verifies: CI-T16` をテスト名またはコメントに持ち、境界値 11/12/20/21 を含む。
- `AccountSettingsView.swift` に業務ロジック（`saveProfile` / `changePassword` の実処理）が残っていない。
- `AdminUsersViewModel` と `AccountSettingsViewModel` が同一の `PasswordPolicy` インスタンス/型を参照する。
- 設定画面の既定速度 Picker の選択肢が `PlaybackConstants.speeds` と同一（独自配列が残っていない）。
- CI（`.github/workflows/ci.yml`）が `make test` を呼び出し、grep oracle（T-T7b / T-T13）を含む既存テストスイートが CI 上で実行される。

## 禁止事項 / scope 外
- lint（swiftlint/swiftformat）・カバレッジ計測・XCUITest の導入は行わない（レビュー・Spec とも未導入判断のまま）。
- パスワードの文字種規則・ブロックリスト・username 非包含チェックを iOS 側に追加しない（backend 検証のみ。ADR-101）。
- `error_message` 4 値の文言写像（ADR-102）は本 slice のスコープ外（iOS 次サイクル RO-c）。
- Spec に無い業務条件（パスワード値域以外の新規検証）を足さない。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §3.3・§4（CI-T16）・§6（S4 行）
- ADR: `docs/adr/101-password-policy-cross-client-unification.md`（**12〜20 が正本**）
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（SG-B2, Q9）
- 検証: `docs/research-reports/2026-09-16-code-design-review/verification-run.md` §8（AdminUsersViewModel テスト参照 0）・§9（ci.yml の現行経路）
