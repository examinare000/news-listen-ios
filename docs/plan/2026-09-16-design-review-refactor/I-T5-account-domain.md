## iOS リファクタ I-T5: Account の domain の型（`Subject`・`Role`・`SubjectKey`・`AuthSession`）と、`AuthSession` から通信のデータモデルを外す

## 概要
`AuthSession.authenticated` が持つ値を通信のデータモデル `AuthUser` から domain の `Subject` に替え、ロールの判定（`isAdmin`）と主体キーの検査（`SubjectKey`）を `Auth/Domain/` に置く。`AuthSession`・`CleanupIncomplete`・`SubjectCleanupFailedPart` の宣言も `Auth/Domain/` へ移す。通信 → domain の変換 `AuthUser.toSubject()` は `Models/AuthModels+Subject.swift`。**状態の 4 つ・遷移・失効の検知（CI-T14）・後始末の順序は変えない**。`user_id` の中身（`SubjectKey` に値が入る経路）は I-S5。

正本は TA Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md` §5.3（TA-M-AC の domain 行と変換行、TA-Q-AC-1、TA-R-AC-2・4・5、TA-V6 の AC）・§7 TA-V3 の TA-R-AC-5・§8.2 の I-T5 行、導出 I-38（TA Spec §10.1。ロールは enum にしない）、再生 Spec §3.3（CI-T14・T15）、ADR-104 決定 15・16（`user_id`）。**検証モード（再設計しない）**。

応える要求: `F-ACC-01`〜`F-ACC-03`、AQ-1（TA Spec §9.2）。

## 前提・着手条件
- 依存: **I-S3b3 の ios PR が main に merge 済み、かつ親リポのポインタが進んでいる**。I-T4 と並行可（`NewsListenAppApp.swift` を両方が触るので、後から merge する側が rebase する）。
- コマンドの実行場所: `ios/`。
- 確定済み（再提案しない）: ロールの enum 化は行わない（再生 Spec の gate M2。I-38 は「値を落とさない値型 `Role`」）、主体キーの形式 `^[A-Za-z0-9_-]+$` と欠落・不正時の扱い（ADR-104 決定 16。SG-B6）、`SubjectStamp` からトークンを取り出す経路は作らない（O-9〜O-13）。
- `docs/trial-log/` を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。2026-10-01 実測。revision `ef9e559`。I-S4 が先に入っていれば `AccountSettingsViewModel` 側で数え直す）

| 項目 | 実測 | コマンド（`ios/` で） |
|---|---|---|
| `AuthSession` の宣言 | `AppState.swift:33-42`（`authenticated(AuthUser)`・`unavailable(ApiFailure)`） | `grep -n 'enum AuthSession\|case authenticated\|case unavailable' NewsListenApp/NewsListenApp/AppState.swift` |
| `AuthUser` と `isAdmin` | `Models/AuthModels.swift:12-31`（`username`・`role`・`displayName`。`isAdmin` は `:24`、`role == "admin"`） | `grep -n 'struct AuthUser\|isAdmin\|CodingKeys' NewsListenApp/NewsListenApp/Models/AuthModels.swift` |
| `currentUser` の読み手（`AppState.swift` 以外） | 5 行: `Settings/AccountSettingsView.swift:50,71,81`・`Settings/SettingsView.swift:205`・`Admin/AdminUsersView.swift:52` | `grep -rn 'currentUser' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v AppState.swift` |
| `isAdmin` の読み手 | `AccountSettingsView.swift:71`・`SettingsView.swift:205`・`AdminUsersViewModel.swift:84`・`AdminUsersView.swift:53` | `grep -rn 'isAdmin' NewsListenApp/NewsListenApp --include='*.swift'` |
| `"admin"` / `"user"` の literal（`PasskeyOptionsDecoder` を除く） | 6 行: `Admin/AdminUsersViewModel.swift:23,61,84`・`Admin/AdminUsersView.swift:31,32`・`Models/AuthModels.swift:24` | `grep -rn '"admin"\|"user"' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v PasskeyOptionsDecoder \| grep -v ':[0-9]*:[[:space:]]*//'` |
| `completeLogin` の入口と呼び手 | `AppState.swift:220` `completeLogin(_ response: LoginResponse)`。呼び手は `NewsListenAppApp.swift:61`（`LoginView(onSuccess:)` → `LoginViewModel.swift:27,57`・`PasskeyLoginViewModel.swift:25`） | `grep -rn 'completeLogin(\|onSuccess' NewsListenApp/NewsListenApp --include='*.swift'` |
| `updateCurrentUser` | `AppState.swift:232` `updateCurrentUser(_ user: AuthUser, capturedAt:)`。呼び手は `AccountSettingsView.swift`（I-S4 の後は `AccountSettingsViewModel`） | `grep -rn 'updateCurrentUser' NewsListenApp/NewsListenApp --include='*.swift'` |
| `CleanupIncomplete`・`SubjectCleanupFailedPart` | `Auth/SubjectCleanup.swift:13-22` | `grep -n '^enum\|^struct' NewsListenApp/NewsListenApp/Auth/SubjectCleanup.swift` |
| `user_id` / `userId` の出現 | 0 | `grep -rn 'user_id\|userId' NewsListenApp/NewsListenApp --include='*.swift' \| wc -l` |
| 既存テスト | `AppStateAuthTests` 38・`SubjectCleanupTests` 17・`LoginViewModelTests` 4・`GrepOracleTests` 10（O-8 が `appState.completeLogin(` 1・`appState.updateCurrentUser(` 1 を固定） | `grep -c 'func test' …` |

## 対象（ios サブモジュールのみ）
**新規（production 4 本）**

| ファイル | 層 | 中身 |
|---|---|---|
| `Auth/Domain/Subject.swift` | domain | `Subject`・`Role`・`SubjectKey` |
| `Auth/Domain/AuthSession.swift` | domain | `AuthSession`（`AppState.swift:33-42` から移動。`authenticated(Subject)`） |
| `Auth/Domain/CleanupIncomplete.swift` | domain | `CleanupIncomplete`・`SubjectCleanupFailedPart`（`Auth/SubjectCleanup.swift:13-22` から移動。中身不変） |
| `Models/AuthModels+Subject.swift` | adapter | `AuthUser.toSubject()`（`key` は I-S5 まで `nil`） |

**変更（production 6 本）**: `AppState.swift`（`AuthSession` の宣言を消す。`currentSubject: Subject?` に改名（`currentUser` を消す）。`completeLogin(_ receipt: LoginReceipt)`。`updateCurrentUser` → `updateCurrentSubject(_ subject: Subject, capturedAt:)`）、`Auth/SubjectCleanup.swift`（2 型の宣言を消す。中身不変）、`Settings/AccountSettingsView.swift`・`Settings/SettingsView.swift`（`currentSubject` の読出。`isAdmin` は `subject.role.isAdmin`）、`Auth/LoginViewModel.swift`・`Passkey/PasskeyLoginViewModel.swift`（`onSuccess: (LoginReceipt) -> Void`。応答を `LoginReceipt(token:subject:)` に変換して渡す = 一時の変換。I-T7c で application へ移す）。`NewsListenAppApp.swift:61` の `LoginView(…) { appState.completeLogin($0) }` は型が変わるだけで文は同じ（O-8 の出現数 1 を保つ）。`Admin/AdminUsersView.swift:52-53` の `appState.currentUser?.username` は `currentSubject?.username` に、`user.isAdmin`（`AuthUser` の一覧）は I-T7c まで `AuthUser.toSubject().role.isAdmin` で読む（`AuthUser.isAdmin` を消すため）。

**変更（test）**: `AppStateAuthTests`・`SubjectCleanupTests`・`LoginViewModelTests`（Given の `AuthUser` → `Subject`／`LoginResponse` → `LoginReceipt`。Then 不変）、`AppStateTestSupport.swift`（fixture）、`ArchitectureManifest.swift`（許可リストの TA-D3 の `AppState.swift` の `DTO` の行数を減らす。TA-V3 の TA-R-AC-5 から `Models/AuthModels.swift` 1 を消す）。**新規（test）**: `SubjectTests.swift`（`domainTestFiles` に登録）。

**対象外**: `user_id` の受け取りと `SubjectKey` に値が入る経路（I-S5）、管理画面の一覧のリードモデル `ManagedUser`（I-T7c。一覧は `AuthUser` のまま）、`Authentication` use case（I-T7c）、`Admin/AdminUsersViewModel.swift:23,61,84` の `"user"` / `"admin"` の literal（`Role.user.rawValue` 等へ替えるのは I-T7c）。

## 宣言（ここに無い公開メンバーを足さない）
```swift
// Auth/Domain/Subject.swift
struct Role: Equatable { let rawValue: String; static let admin = Role(rawValue: "admin"); static let user = Role(rawValue: "user"); var isAdmin: Bool { self == .admin } }   // 生の値を保つ（未知の値を落とさない。I-38）
struct SubjectKey: Equatable {
    let rawValue: String
    init?(_ raw: String?)          // `^[A-Za-z0-9_-]+$` に合わなければ nil（TA-R-AC-4。SG-B6）
}
struct Subject: Equatable { let username: String; let displayName: String; let role: Role; let key: SubjectKey? }   // key は I-S5 まで常に nil
// Auth/Domain/AuthSession.swift
enum AuthSession: Equatable { case resolving, authenticated(Subject), anonymous, unavailable(ApiFailure) }
// AppState.swift（Account の application）
struct LoginReceipt: Equatable { let token: String; let subject: Subject }        // TA-C-AC-1 の receipt（宣言は AppState.swift。I-T7c で Auth/Application/Authentication.swift へ）
@MainActor final class AppState: ObservableObject {
    @Published private(set) var session: AuthSession
    var currentSubject: Subject? { get }                        // TA-Q-AC-1（旧 currentUser）
    func completeLogin(_ receipt: LoginReceipt)                 // TA-C-AC-2
    func updateCurrentSubject(_ subject: Subject, capturedAt stamp: SubjectStamp)   // 旧 updateCurrentUser。主体ガードは不変
    …（ほかは不変）
}
// Models/AuthModels+Subject.swift（adapter）
extension AuthUser { func toSubject() -> Subject }              // Role(rawValue: role)、key: nil（I-S5 で userId から SubjectKey を作る）
```
- `Role` は `struct`（`enum` にしない。I-38）。`isAdmin` の式（`role == "admin"`）の正本はここ。`AuthUser.isAdmin` は消す。
- `SubjectKey.init?` の正規表現は 1 箇所（TA-R-AC-4）。I-S5 の補正 4 が `AuthUser.userId` → `SubjectKey` の経路をここへつなぐ。
- `AppState.session` の遷移・失効の検知（`handle(failure:sentToken:)`）・`refreshAuth`・`logout`・`retryResolve`・後始末の順序は変えない。`refreshAuth` の `fetchMe()` の応答 `AuthUser` は `toSubject()` で `Subject` にして `authenticated` に入れる。

## 変更の責務
| 責務 | 層・置き場 |
|---|---|
| 認証の状態の union・主体の値・ロールの判定・主体キーの検査 | domain: `Auth/Domain/` |
| 遷移・失効の検知・後始末（不変） | application: `AppState.swift`・`Auth/SubjectCleanup.swift` |
| 通信 → domain | adapter: `Models/AuthModels+Subject.swift` |
| ログイン応答 → `LoginReceipt`（一時） | presentation（`LoginViewModel`・`PasskeyLoginViewModel`。I-T7c で application へ） |

## 移行の中間状態
| 経路 | owner | 導入 | 削除の条件（slice） |
|---|---|---|---|
| ログインの ViewModel が応答を `LoginReceipt` に変換して `completeLogin` に渡す | user | 本 slice | I-T7c（`Authentication.login` が receipt を返す） |
| 管理画面の一覧が `AuthUser` のまま（`toSubject().role.isAdmin` で読む） | user | 本 slice | I-T7c（`ManagedUser`） |
| `LoginReceipt` の宣言が `AppState.swift` にある | user | 本 slice | I-T7c（`Auth/Application/Authentication.swift` へ） |

許可リスト（TP10）の増減: TA-D3 の `AppState.swift` の `DTO` の行数を減らす（`AuthUser`・`LoginResponse` の分。`Preferences`・`ListeningStreak`・`OnboardingStatusResponse` の分は I-T6・I-T10・I-T7b）。TA-V3 の TA-R-AC-5 の `Models/AuthModels.swift` 1 を消す（残り `Admin/` の 5 行は I-T7c）。TA-D4・TA-D6 の `DTO` の行（`AuthUser` を読む View・VM）を実測で減らす。

## 変わる挙動
無い。未知のロールの表示（一覧にそのまま出る）も同じ（`Role` が生の値を保つ）。

## 契約と検査
| ID | テスト | 内容 |
|---|---|---|
| TA-R-AC-5 | **T-TA-R-AC-5**（`SubjectTests`） | `Role("admin").isAdmin` true、`"user"`・`"ADMIN"`・`"owner"`（未知）は false で、`rawValue` は保たれる |
| TA-R-AC-4 | **T-TA-R-AC-4**（`SubjectTests`） | `SubjectKey("abc_-1")` あり、`nil`・`""`・`"a b"`・`"日本"`・`"a/b"` は nil |
| 変換 | **T-AuthUser-toSubject** | `username`・`displayName`・`role` が写り、`key` は nil |
| CI-T14（不変） | `AppStateAuthTests`（38） | Given の置き換えで Then 不変（4 状態・401 だけが破棄・検知点 1 箇所） |
| TA-V6（AC） | **T-TA-V6-AC** | `currentSubject` の写しを持っても `session` が変わらない（値型）。`SubjectStamp` からトークンを取り出せない（既存 O-9〜O-13 が保つ） |
| TA-V1・V2・V3・V7 | `ArchitectureOracleTests` | `Auth/Domain/` が domain に当たり TA-D1・D2 が 0。`SubjectTests` が `domainTestFiles` にあり TA-V7 が 0 |
| TA-V11 | 全既存テスト | `SubjectCleanupTests` 17・`LoginViewModelTests` 4・`GrepOracleTests` 10（O-8 の出現数不変）が green |

## 完了条件
1. 上のテストが green。既存テストが全件 green で件数が減らない。
2. 変更した production が上の 10 本（新規 4 ＋ 変更 6）だけ: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 10 行（`NewsListenAppApp.swift` は文が同じなら差分なし。差分が出た場合は 11 行で、理由を PR 説明に書く）。
3. `AuthSession` の宣言が 1 箇所: `grep -rn "^enum AuthSession" NewsListenApp/NewsListenApp --include='*.swift'` が `Auth/Domain/AuthSession.swift` の 1 行。`grep -rn "authenticated(AuthUser)\|authenticated(let user)" NewsListenApp/NewsListenApp --include='*.swift'` が 0 件。
4. ロールの判定が 1 箇所: `grep -rn 'role == "admin"\|isAdmin: Bool' NewsListenApp/NewsListenApp --include='*.swift' | grep -v ':[0-9]*:[[:space:]]*//'` が `Auth/Domain/Subject.swift` の行だけ。`grep -n "isAdmin" NewsListenApp/NewsListenApp/Models/AuthModels.swift` が 0 件。TA-V3 の TA-R-AC-5 の一致が `Admin/AdminUsersViewModel.swift` 3・`Admin/AdminUsersView.swift` 2 の 5 行（許可リストと一致。I-T7c で 0）。
5. 主体キーの検査が 1 箇所: `grep -rn "A-Za-z0-9_-" NewsListenApp/NewsListenApp --include='*.swift'` が `Auth/Domain/Subject.swift` の 1 行。
6. `currentUser` が無い: `grep -rn "currentUser\b" NewsListenApp/NewsListenApp --include='*.swift'` が 0 件。`grep -rn "currentSubject" NewsListenApp/NewsListenApp --include='*.swift' | grep -v AppState.swift` が 5 行以上（前提点検の読み手 5 行の付け替え）。`GrepOracleTests` の O-8 が `appState.updateCurrentUser(` → `appState.updateCurrentSubject(` に名前を改めて 1 のまま（期待値の名前だけを直す。件数は不変。TA-D14 の「slice の表が明記したとき」に当たる）。
7. domain が通信のデータモデルを知らない: `grep -rnw "AuthUser\|LoginResponse\|Codable\|Decodable\|Encodable\|CodingKey" NewsListenApp/NewsListenApp/Auth/Domain | grep -v ':[0-9]*:[[:space:]]*//'` が 0 件。`grep -rn "^import" NewsListenApp/NewsListenApp/Auth/Domain` が `Foundation` だけ。
8. `ArchitectureOracleTests` が green で、許可リストの TA-D3 の `AppState.swift` の `DTO` の行数が前提点検の値（5）から減っている（PR 説明に前後の値）。
9. `user_id` / `userId` の出現が 0 のまま（I-S5 の前提を崩さない）: `grep -rn 'user_id\|userId' NewsListenApp/NewsListenApp --include='*.swift' | wc -l` → 0。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test` → 全 green。
- 完了条件 2〜9 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。
- commit は「Subject・Role・SubjectKey（テスト）」「AuthSession と CleanupIncomplete の移動」「AppState と読み手の付け替え」「ログイン VM の一時の変換」「所属表」の単位。

## 禁止事項 / scope 外
- `Role` を `enum` にしない。未知のロールを落とさない。
- `AuthSession` の状態を増減しない。遷移・失効の検知・後始末の順序を変えない。`SubjectStamp` からトークンを取り出す経路を作らない。
- `AuthUser` に `userId` を足さない（I-S5）。`UserListResponse` を変えない。
- `Authentication`・`AccountProfile`・`ManagedUser` を作らない（I-T7c）。`Admin/` の `"admin"` / `"user"` の literal を消さない（I-T7c）。
- `Auth/Domain/` に `Codable`・`APIClient`・`KeychainSessionStore` を書かない。

## 種別
適用 slice。判断待ちに依存しない（`user_id` の形式の `_`（TA Spec §10.4 の §6 の 7）は backend の判断待ちだが、変わっても `SubjectKey` の 1 箇所が追随する。本 slice は止めない）。

## 規模（見込み。TA Spec §8.1: 150 / 200。2026-10-01 実測の基点: `AppState.swift` 557・`AuthModels.swift` 48・`SubjectCleanup.swift` 55）
- production ≈ 150 行: `Subject.swift` ≈ 45・`AuthSession.swift` ≈ 15（移動）・`CleanupIncomplete.swift` ≈ 15（移動）・`AuthModels+Subject.swift` ≈ 15・`AppState.swift` ≈ 20（−12）・View 3 本 ≈ 8・ログイン VM 2 本 ≈ 10。
- test ≈ 200 行: `SubjectTests` ≈ 60・`AppStateAuthTests` の Given ≈ 80・`SubjectCleanupTests`・`LoginViewModelTests` ≈ 30・fixture ≈ 20・所属表 ≈ 10。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: `LoginReceipt` の宣言の置き場（一時）。`design/ios-design.md` §4（`AuthSession` の値が `Subject`）。README の I-T5 行を完了へ。I-S4・I-S5 の着手条件（`Subject`・`SubjectKey` がある）が成立したことを README に記す。
