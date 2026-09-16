## iOS リファクタ S1: 失敗の意味（ApiFailure・FailureMessages）

## 概要
2026-09-16 の iOS 設計レビューで RF10（status 数値の直接比較）・LF6（`APIError.httpError(statusCode)` の数値露出）と判定された箇所を閉じる。正本は user 承認済みの Implementation Spec `docs/design/2026-09-16-implementation-spec-playback-domain-model.md`（§3.5 Platform・§4 CI-T12/T13・§6 S1 行）。本タスクは**承認済み指示書に従う実装**であり、analyze_order は検証モード（新規設計をしない）。generate_spec の spec.md は Spec の該当契約（CI-T12 / T13）の抜粋で足り、契約 ID は Spec のものを再利用する。

Spec §8 着手順 1（S2〜S4 に依存しない。最初に実施）。

## 前提・着手条件
- Selection Gate 依存なし（共有仕様 §6.7 の SG-X1〜X5 は本 slice に無関係）。
- `docs/trial-log/` を最初に読み、棄却済み案を再試行しない（本 slice に直接関係する記録は無いが、着手前の確認義務は変わらない）。
- ベースライン: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project NewsListenApp/NewsListenApp.xcodeproj -scheme NewsListenApp -destination 'platform=iOS Simulator,id=<UDID>' -only-testing:NewsListenAppTests` が 509 tests green であることを確認してから着手する。

## 対象（ios サブモジュールのみ。ファイル単位）
1. **`ApiFailure` の導入（CI-T12）**: `Networking/APIClient.swift` の `validateResponse` を、既存 `APIError` から `ApiFailure = network(URLError) | unauthorized | forbidden | notFound(subject: NotFoundSubject) | conflict | rateLimited(retryAfter: Int?) | validation | server(status) | decoding | unknown(status)`（Spec §3.5）へ変換する形に変更する。非 `HTTPURLResponse` は `network` として失敗にする（fail-open を閉じる。CI-A02）。`notFound.subject` は endpoint メソッドが付与する（`streak / quota / quiz` = 機能未提供、`credential / session / star` = 冪等削除成功。既存 404 の 2 意味を分ける）。`downloadAudio` はヘッダ非付与の方針を保ちつつ同じ `validateResponse` を通す（既存動作を変えない）。
2. **`FailureMessages`（1 関数）**: `Networking/FailureMessages.swift`（新規）に `message(for: ApiFailure, context:)` を 1 つ作り、日本語文言をここへ集約する。`localizedDescription` の英語文言の露出を消す。
3. **10 消費者の置換（CI-T13）**: レビュー実測の HTTP status 数値分岐 10 箇所を `ApiFailure` の値で分岐する形へ書き換える。`AppState.swift:263`(404) / `SettingsViewModel.swift:163`(404) / `AccountSettingsView.swift:327`(400) / `PasskeyCredentialsViewModel.swift:52`(404) / `LoginViewModel.swift:59`(401) / `PasskeyRegistrationViewModel.swift:70`(409) / `StarredViewModel.swift:108`(404) / `SessionsViewModel.swift:57`(404) / `QuizSheetView.swift:199`(404、View) / `OnboardingSourcesViewModel.swift:66`(409)。
4. **`MockURLSession` の拡張**: `URLError` を返すモードと、非 `HTTPURLResponse`（例: `URLResponse`）を返すモードを追加する（CI-T12 の RED に必要）。

## 契約（CI-T → T-T の表）
| CI | 内容 | T-T |
|---|---|---|
| CI-T12 | 失敗は `ApiFailure` のみ（分母 = `APIEndpoint` の全 case を `Networking/APIEndpoint.swift` で数える）。`notFound.subject` は endpoint ごと。非 `HTTPURLResponse` は `network`。`rateLimited` は `retryAfter` を持つ | T-T12: 既存 `APIClientTests` 34 件を `ApiFailure` へ移植。`MockURLSession` に URLError / 非 HTTP 応答モードを追加した RED を含む |
| CI-T13 | VM / View に `statusCode ==` / `httpError(` の数値比較が無い | T-T13: `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include=*.swift` が `Networking/` 以外で 0 件（CI で実行） |

## 特性テスト（baseline。着手前に green を確認）
`APIClientTests`（34）・`AuthAPIClientTests`（8）・各 VM テスト（Feed 40 / Starred 15 / Settings 26 / Login 4 / Passkey 13 / Onboarding 5）。

## 手順（TDD 順序）
1. baseline: 上記特性テストと `xcodebuild test -only-testing:NewsListenAppTests` の 509 green を記録する。
2. T-T12 → RED（`ApiFailure` 型・`MockURLSession` の URLError / 非 HTTP モードを先に追加し、`validateResponse` は未変更のまま失敗させる）→ `validateResponse` を `ApiFailure` へ変換する実装 → GREEN。
3. TP1 を導入する: 既存 `APIError` を `ApiFailure` から生成して throw する互換層を残し、10 消費者を 1 箇所ずつ `ApiFailure` 直読みへ置換する間のブリッジにする。
4. `FailureMessages.swift` の `message(for:context:)` を追加し、日本語文言をここへ移す。
5. T-T13 → RED（grep が 10 箇所を検出する状態を確認）→ 10 消費者を `ApiFailure` の値による分岐へ 1 箇所ずつ置換 → grep が 0 件になったら GREEN。
6. 置換完了後、10 消費者に `APIError` の参照が残っていないことを確認し、TP1 の削除条件（`Networking/` 以外に `APIError` の参照が 0）が満たされることを確認する。TP1 自体の削除は本 slice で行ってよい（削除条件が本 slice 内で満たされるため）。
7. 1 slice = 1 PR 目安。契約ごとの commit を分ける（`ApiFailure` 導入 → `FailureMessages` → 消費者置換）。

## 完了条件
- `xcodebuild test -only-testing:NewsListenAppTests` が全 green（509 + 新規分）。
- T-T12 / T-T13 が `verifies: CI-T12/T13` をテスト名またはコメントに持つ。
- `grep -rn 'statusCode ==\|httpError(' NewsListenApp/NewsListenApp --include=*.swift` が `Networking/` 以外で 0 件（T-T13 の grep oracle）。
- `Networking/` 以外に `APIError` の参照が 0（TP1 の削除条件を満たし、TP1 を削除済み）。
- `localizedDescription` の英語文言が VM / View から露出していない。

## 禁止事項 / scope 外
- `AuthSession` union・`SubjectCleanup`（S2）、`AudioEngine` port（S3a/S3b）、`PasswordPolicy`（S4）は行わない。
- Spec に無い業務条件（新しい `ApiFailure` case・404 の意味の新設）を足さない。
- HTTP 網羅 Error 階層（RO5）は作らない。`ApiFailure` は Spec §3.5 の列挙のみ。
- 仕様にない文言変更をしない（`message(for:context:)` は既存文言を移すだけで新規文言を作らない。文言差異が発生する場合は実装を止めて報告する）。

## 参照
- Spec: `docs/design/2026-09-16-implementation-spec-playback-domain-model.md` §3.5・§4（CI-T12/T13）・§6（S1）
- レビュー: `docs/research-reports/2026-09-16-code-design-review.md` §8（RF10, LF6, Q7）
- 検証: `docs/research-reports/2026-09-16-code-design-review/verification-run.md` §1・§7
