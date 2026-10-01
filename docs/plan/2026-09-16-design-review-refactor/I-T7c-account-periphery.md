## iOS リファクタ I-T7c: Account の周辺（login・表示名とパスワード・端末のセッション・Passkey・管理者）の application・リードモデル・gateway

## 概要
ログイン（パスワード・Passkey）、表示名とパスワードの変更、端末のセッションの一覧と失効、Passkey の登録と削除、管理者のユーザー管理を、各 ViewModel から application の use case（`Authentication`・`PasskeySignIn`・`AccountProfile`・`DeviceSessions`・`PasskeyEnrollment`・`UserAdministration`）へ移す。ViewModel は入力の下書きと画面の状態だけを持ち、`APIClient` と通信のデータモデルを持たない。404・409 の冪等の意味と「自分の行ではロールの変更と削除を出さない」を application に置く。I-T5 が残した一時の変換（ログインの VM が応答を `LoginReceipt` にする・管理画面の `AuthUser`）を消す。**画面の構成と文言は変えない**。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.3（TA-M-AC の application・リードモデル・データモデル・変換の行、TA-C-AC-1・5〜9、TA-Q-AC-2、TA-R-AC-5〜7、port と adapter）・§4 TA-D12 の恒久の許可リスト（入力の下書き 6 個）・§7 TA-V3 の TA-R-AC-5・6・§8.2 の I-T7c 行。**検証モード（再設計しない）**。

応える要求: `F-ACC-04`〜`F-ACC-07`・`F-PKY-01`〜`F-PKY-03`（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-S4・I-S5・I-T5 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**（I-S4 が `AccountProfile`（表示名とパスワードの分）と `AccountGateway+Live.swift` を入れている。I-S5 が `AuthUser.userId` → `SubjectKey` をつないでいる。I-T5 が `Subject`・`Role`・`LoginReceipt` を入れている）。I-S5 は backend の B-S5b を待つので、本 slice も B-S5b の後になる。
- コマンドの実行場所: `ios/`。最初に `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Auth/Application/AccountProfile.swift`（rc=0）と `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Auth/Domain/Subject.swift`（rc=0）。
- 確定済み（再提案しない）: TA-D12 の恒久の許可リスト 6 個（`LoginViewModel.username`・`password`、`AdminUsersViewModel.newUsername`・`newPassword`・`newDisplayName`・`newRole`）、ロールは enum にしない（I-38）、ADR-101（パスワードは I-S4 の `PasswordPolicy`）。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-S4・I-S5・I-T5 の後の実物で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| ViewModel の公開面 | `LoginViewModel`（67 行。`@Published var` 3: `username`・`password`・`errorMessage`）、`SessionsViewModel`（79 行。`sessions: [SessionItem]`・`errorMessage`・`revokedOthersCount`。`revokeSession` の 404 は成功 `:57`）、`PasskeyRegistrationViewModel`（79 行。409 `:70`）、`PasskeyCredentialsViewModel`（59 行。`credentials: [PasskeyCredentialItem]`。404 `:52`）、`PasskeyLoginViewModel`（76 行）、`AdminUsersViewModel`（92 行。`users: [AuthUser]`・下書き 4・`errorMessage`。`toggleRole` `:82`） | `for f in Auth/LoginViewModel Sessions/SessionsViewModel Passkey/PasskeyRegistrationViewModel Passkey/PasskeyCredentialsViewModel Passkey/PasskeyLoginViewModel Admin/AdminUsersViewModel; do grep -n 'func \|@Published' NewsListenApp/NewsListenApp/$f.swift; done` |
| 通信のデータモデルの置き場 | `Sessions/SessionModels.swift`（`SessionItem`・`SessionsAPIResponse`・`RevokeSessionsAPIResponse` の 3 つ `Codable`）、`Passkey/PasskeyModels.swift`（`Codable` 3 つ: `PasskeyOptionsAPIResponse`・`PasskeyCredentialItem`・`PasskeyCredentialsAPIResponse`。非 `Codable` 4 つ: `PasskeyRegistrationOptions`・`PasskeyAssertionOptions`・`PasskeyRegistrationCredential`・`PasskeyAssertionCredential` = port の値） | `grep -n '^struct' NewsListenApp/NewsListenApp/Sessions/SessionModels.swift NewsListenApp/NewsListenApp/Passkey/PasskeyModels.swift` |
| Passkey の port と OS の実装 | `Passkey/PasskeyAuthorizationProviding.swift`（protocol。`createCredential`・`assertCredential`）、`Passkey/ASAuthorizationPasskeyProvider.swift`・`PasskeyOptionsDecoder.swift`・`PasskeyCredentialEncoder.swift` | `ls NewsListenApp/NewsListenApp/Passkey` |
| `ASAuthorizationPasskeyProvider()` の生成 | `Settings/AccountSettingsView.swift:42`・`Auth/LoginView.swift:28`（I-T1 の TA-D13 の許可リストにある 2 行） | `grep -rn 'ASAuthorizationPasskeyProvider()' NewsListenApp/NewsListenApp --include='*.swift'` |
| `"admin"` / `"user"` の literal | `Admin/AdminUsersViewModel.swift:23,61,84`・`Admin/AdminUsersView.swift:31,32`（I-T5 の後の残り 5 行） | `grep -rn '"admin"\|"user"' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v PasskeyOptionsDecoder \| grep -v ':[0-9]*:[[:space:]]*//'` |
| `SessionStore` の宣言 | `Networking/SessionStore.swift:13`（protocol と `KeychainSessionStore` が同じファイル） | `grep -n 'protocol\|class' NewsListenApp/NewsListenApp/Networking/SessionStore.swift` |
| I-S4 が入れた `AccountProfile` と gateway | `Auth/Application/AccountProfile.swift`・`Networking/Gateways/AccountGateway+Live.swift`（表示名とパスワードの分） | `ls NewsListenApp/NewsListenApp/Auth/Application NewsListenApp/NewsListenApp/Networking/Gateways` |
| 既存テスト | `LoginViewModelTests` 4・`SessionsViewModelTests` 2・`PasskeyRegistrationViewModelTests`・`PasskeyCredentialsViewModelTests`・`PasskeyLoginViewModelTests`・`PasskeyPureLayerTests`・I-S4 の `AdminUsersViewModel` の特性テスト | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ）
**新規（production。TA Spec §8.2）**: `Auth/Application/Authentication.swift`（`Authentication`・`LoginReceipt` を `AppState.swift` から移す）、`Auth/Application/SessionStore.swift`（`SessionStore` protocol を `Networking/SessionStore.swift` から移す = `portFiles`）、`Sessions/Application/DeviceSessions.swift`（`DeviceSession` を含む）、`Passkey/Application/PasskeyEnrollment.swift`（`PasskeyCredential` を含む）、`Passkey/Application/PasskeySignIn.swift`、`Passkey/Application/PasskeyAuthorization.swift`（`PasskeyAuthorizationProviding` と port の値 4 つを移す = `portFiles`）、`Admin/Application/UserAdministration.swift`（`ManagedUser` を含む）。
**拡張（I-S4 が作ったもの）**: `Auth/Application/AccountProfile.swift`（I-S4 の表示名・パスワードの 2 操作のまま。変更は無いか、`Subject` の receipt の型合わせだけ）、`Networking/Gateways/AccountGateway+Live.swift`（認証・セッション・Passkey・管理の closure を足す）。
**移動**: `Passkey/ASAuthorizationPasskeyProvider.swift`・`PasskeyOptionsDecoder.swift`・`PasskeyCredentialEncoder.swift` → `Passkey/Platform/`。`Sessions/SessionModels.swift` → `Models/SessionModels.swift`、`Passkey/PasskeyModels.swift` の `Codable` 3 つ → `Models/PasskeyModels.swift`（非 `Codable` 4 つは `Passkey/Application/PasskeyAuthorization.swift`）。
**変更**: ViewModel 6 本（`LoginViewModel`・`SessionsViewModel`・`PasskeyRegistrationViewModel`・`PasskeyCredentialsViewModel`・`PasskeyLoginViewModel`・`AdminUsersViewModel`）と View（`Auth/LoginView.swift`・`Settings/AccountSettingsView.swift`・`Admin/AdminUsersView.swift`）、`AppState.swift`（`LoginReceipt` の宣言を外す）、`Networking/SessionStore.swift`（protocol を外し `KeychainSessionStore` だけ）、`NewsListenAppApp.swift`（use case を作って View に渡す。`ASAuthorizationPasskeyProvider()` の生成を合成 root へ）。
**変更（test）**: 既存の VM テストの Given、`ArchitectureManifest.swift`（`portFiles` の path、`readModelFiles` に `DeviceSession`・`PasskeyCredential`・`ManagedUser` のファイルは use case と同居するので入れず、struct の形は完了条件 6 の grep で固定）。**新規（test）**: use case ごとの契約テスト。

**対象外**: 画面の構成・文言、パスワードの規則（I-S4）、`AuthSession` の遷移（I-T5）、Keychain の service 名、`AppState` の起動時の連鎖（I-T12）。

## 宣言（名前は TA Spec §5.3 のとおり。ここに無い公開メンバーを足さない）
```swift
// Auth/Application/Authentication.swift
struct LoginReceipt: Equatable { let token: String; let subject: Subject }       // AppState.swift から移動（中身不変）
@MainActor final class Authentication { init(gateway: AccountGateway); func login(username: String, password: String) async throws -> LoginReceipt }   // TA-C-AC-1
// Passkey/Application/PasskeySignIn.swift
@MainActor final class PasskeySignIn { init(gateway: AccountGateway, provider: PasskeyAuthorizationProviding); func signIn() async throws -> LoginReceipt }  // TA-C-AC-1（取消は投げる）
// Sessions/Application/DeviceSessions.swift
struct DeviceSession: Identifiable, Equatable { let id: String; let deviceLabel: String; let createdAt: String; let lastUsedAt: String?; let isCurrent: Bool }
@MainActor final class DeviceSessions { func list() async throws -> [DeviceSession]; func revoke(id: String) async throws; func revokeOthers() async throws -> Int }   // TA-Q-AC-2・TA-C-AC-7（404 は成功。TA-R-AC-6）
// Passkey/Application/PasskeyEnrollment.swift
struct PasskeyCredential: Identifiable, Equatable { … }   // field は PasskeyCredentialItem の表示に使う値を写す
@MainActor final class PasskeyEnrollment { func credentials() async throws -> [PasskeyCredential]; func register() async throws; func delete(id: String) async throws }   // TA-C-AC-8（404 は成功・409 の扱いは現行どおり。TA-R-AC-6）
// Admin/Application/UserAdministration.swift
struct ManagedUser: Identifiable, Equatable { let username: String; let displayName: String; let role: Role; let canChangeRoleOrDelete: Bool; var id: String { username } }  // TA-R-AC-7: 自分の行は false
@MainActor final class UserAdministration {
    init(gateway: AccountGateway, currentUsername: @escaping () -> String?)
    func users() async throws -> [ManagedUser]                                                   // TA-Q-AC-2
    func create(username: String, password: String, displayName: String, role: Role) async throws // TA-C-AC-9（policyViolation は PasswordPolicy。I-S4）
    func delete(username: String) async throws; func setRole(username: String, role: Role) async throws
}
```
- `DeviceSession`・`PasskeyCredential` の field の型は通信のデータモデルの現行の型に合わせる（TA Spec §5.3 の field 名のとおり）。
- command の後の一覧の取り直し（`SessionsViewModel.swift:74`・`AdminUsersViewModel.swift:62,74,87`）は ViewModel が query を続けて呼ぶ形のまま（TA Spec §5.3。command は一覧を返さない）。
- `AdminUsersViewModel.toggleRole` の「次のロール」の決定（`user.isAdmin ? "user" : "admin"`）は `Role` の定数で書く（`role.isAdmin ? .user : .admin`）。`newRole` は TA-D12 の恒久の許可リストの名前のまま、型を `String` から変えるかは変えない（`Role.user.rawValue` を初期値にする。View の Picker の tag も `Role.user.rawValue`・`Role.admin.rawValue`）。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| ロールの判定・主体の値 | domain（I-T5。変えない） |
| ログイン・Passkey の手順・失効と削除の冪等（404・409）・自分の行の可否 | application: `Auth/Application/`・`Sessions/Application/`・`Passkey/Application/`・`Admin/Application/` |
| OS の Passkey の実装と、wire ⇄ OS の型の変換 | adapter: `Passkey/Platform/` |
| 通信 → リードモデル・`LoginReceipt` | adapter: `Networking/Gateways/AccountGateway+Live.swift`・`Models/` の extension |
| 入力の下書き・文言・読み込み中 | presentation: ViewModel（下書きは TA-D12 の 6 個だけ） |

## 移行の中間状態
- I-T5 の一時の経路 3 つ（ログイン VM の変換・管理画面の `AuthUser`・`LoginReceipt` の置き場）を**消す**。
- 許可リスト（TP10）の増減: TA-D4・TA-D6 の `Auth/`・`Sessions/`・`Passkey/`・`Admin/`・`Settings/AccountSettingsView.swift` の `APIClient`・`DTO` の行、TA-D12 の `Admin`・`Auth`・`Passkey`・`Sessions` の分（恒久の 6 個だけが残る）、TA-D13 の `ASAuthorizationPasskeyProvider()` 2 行、TA-V3 の TA-R-AC-5（`Admin/` 5 行）・TA-R-AC-6（`Passkey/` 2・`Sessions/` 1）を消す。

## 変わる挙動
無い。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-C-AC-1 | **T-TA-C-AC-1** | `login` の receipt が `LoginReceipt`（token と `Subject`。`key` は I-S5 の `SubjectKey`）。失敗は `ApiFailure`。Passkey の取消は投げる（VM が現行どおり握る） |
| TA-C-AC-5・6 | I-S4 の `AccountProfile` のテスト | 不変で green |
| TA-C-AC-7・TA-R-AC-6 | **T-TA-C-AC-7** | `revoke` の 404 は成功。`revokeOthers` の receipt は件数 |
| TA-C-AC-8・TA-R-AC-6 | **T-TA-C-AC-8** | 削除の 404 は成功。登録の 409 は現行の VM と同じ扱い |
| TA-C-AC-9・TA-R-AC-7 | **T-TA-C-AC-9** | 自分の行は `canChangeRoleOrDelete == false`。未知のロールの行もそのまま出る |
| TA-Q-AC-2・TA-V8 | **T-TA-Q-AC-2** | `list()`・`credentials()`・`users()` の後、書込（`POST`/`PATCH`/`DELETE`）が 0 件 |
| TA-V6（AC） | **T-TA-V6-AC-periphery** | 返した配列を書き換えても次の query が変わらない |
| TA-V5（TA-D12） | `ArchitectureOracleTests` | ViewModel の `private(set)` の無い `@Published var` が、`Admin`・`Auth`・`Passkey`・`Sessions` で恒久の 6 個だけ |

## 完了条件
1. 上のテストが green。既存テストが全件 green で件数が減らない。
2. ViewModel 6 本が通信を知らない: `grep -rnw "APIClient\|AuthUser\|LoginResponse\|SessionItem\|PasskeyCredentialItem\|UserListResponse" NewsListenApp/NewsListenApp/Auth/LoginViewModel.swift NewsListenApp/NewsListenApp/Sessions/SessionsViewModel.swift NewsListenApp/NewsListenApp/Passkey/*ViewModel.swift NewsListenApp/NewsListenApp/Admin/AdminUsersViewModel.swift | grep -v '^[^:]*:[0-9]*:[[:space:]]*//'` が 0 件。
3. 通信のデータモデルが `Models/` だけ: `ls NewsListenApp/NewsListenApp/Sessions/SessionModels.swift NewsListenApp/NewsListenApp/Passkey/PasskeyModels.swift` が両方「無い」。`grep -rlE '^\s*(struct|enum)\s+\w+[^{]*:\s*[^{]*Codable' NewsListenApp/NewsListenApp --include='*.swift' | grep -v '^NewsListenApp/NewsListenApp/\(Models\|Observability\)/'` が 0 件。
4. `ApiFailure.notFound`・`.conflict` の catch が application にだけ: `grep -rn 'notFound(subject: \.\(credential\|session\))\|catch ApiFailure.conflict' NewsListenApp/NewsListenApp --include='*.swift' | grep -v Networking/ | grep -v FailureMessages` が `Sessions/Application/`・`Passkey/Application/`・`Settings/Application/SourceSubscriptions.swift`（I-T7b）の行だけ。
5. ロールの literal が 0: `grep -rn '"admin"\|"user"' NewsListenApp/NewsListenApp --include='*.swift' | grep -v PasskeyOptionsDecoder | grep -v ':[0-9]*:[[:space:]]*//'` が `Auth/Domain/Subject.swift` の 2 行だけ。
6. リードモデルが `struct`・`let`: `DeviceSession`・`PasskeyCredential`・`ManagedUser`・`LoginReceipt` の宣言の本体に `var `（computed の `var id` を除く）・`class`・`mutating` が無い（`sed -n '/^struct <名前>/,/^}/p' <file> | grep -v 'var id' | grep -c 'var \|class \|mutating '` → 0、4 型とも）。
7. Passkey の OS の実装が `Platform/` に閉じる: `grep -rn "^import AuthenticationServices" NewsListenApp/NewsListenApp --include='*.swift' | grep -v "/Platform/"` が 0 件。`ASAuthorizationPasskeyProvider()` の生成が `NewsListenAppApp.swift` だけ。
8. `ArchitectureOracleTests` が green。TA-D12 の ViewModel の分が恒久の 6 個と一致し、ほかの許可リストの行が `Admin/`・`Auth/`・`Passkey/`・`Sessions/`・`Settings/AccountSettingsView.swift` の path で 0。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜8 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- シミュレータの目視: パスワードと Passkey のログイン、端末のセッションの失効、Passkey の登録と削除、管理画面の作成・削除・ロールの切替（自分の行に操作が出ない）。
- commit は use case ごと（「Authentication と PasskeySignIn」「DeviceSessions」「PasskeyEnrollment と Platform への移動」「UserAdministration」「通信のデータモデルの移動」「所属表」）。

## 禁止事項 / scope 外
- 画面の構成・文言を変えない。ロールを enum にしない。TA-D12 の恒久の許可リストを増やさない。
- command に一覧を返させない（失効の件数の receipt は可。ADR-110 決定 5）。
- `AuthSession` の遷移・`completeLogin` の手順を変えない。Keychain の service 名を変えない。
- パスワードの検査を足さない（ADR-101 の長さだけ。I-S4）。

## 種別
適用 slice。判断待ちに依存しない（ただし前提の I-S5 が backend B-S5b を待つ）。

## 規模（見込み。TA Spec §8.1: 300 / 300）
- production ≈ 300 行（use case 6 本 ≈ 220・gateway ≈ 60・VM の削減 ≈ −120・移動のヘッダ ≈ 20・View ≈ 30）。test ≈ 300 行。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TA Spec §8.2 の I-T7c 行の「新規: `Auth/Application/AccountProfile.swift`」は I-S4 が先に作る（§8.3 の I-S4 の補正 3）ので「拡張」と読み替えたこと。README の I-T7c 行を完了へ。
