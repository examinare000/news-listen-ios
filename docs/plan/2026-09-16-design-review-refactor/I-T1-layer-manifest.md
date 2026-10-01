## iOS リファクタ I-T1: 層の所属表と依存方向の検査（現状の違反を許可リストに固定する）

## 概要
production の全 Swift ファイルを 5 つの層（composition root / domain / application / adapter / presentation）のどれか 1 つへ割り当てる**所属表**をテストコードに置き、依存の規則 TA-D1〜TA-D14 をソースを読む検査（既存 `GrepOracleTests` と同じ方式）として入れる。現状の違反は `(規則 ID, path, 行数)` の**許可リスト**に固定し、増えたら落ち、減ったら同じ PR で一覧を減らす。**production は 1 行も変えない**（test だけの slice）。以後の全 slice がこの検査を oracle にする（ADR-110 決定 10）。

正本は iOS Spec `docs/design/2026-09-30-implementation-spec-target-architecture.md`（以下「TA Spec」）§3.1（判定の単位・所属表の規則）・§4（型名の集合・規則 TA-D1〜D14・TA-D12 の恒久の許可リスト）・§7（TA-V1〜V5・V7・V9 と TA-V3 の式）・§8.2 の I-T1 行、親 docs `design/architecture.md` §8、ADR-110 決定 7・10。**検証モード（再設計しない）**。新しい規則 ID・検査 ID を作らない。

応える要求: PRD `NFR-09`・`NFR-10`（TA Spec §2）、`architecture.md` §2 の AQ-7（向きに反する依存で CI が落ちる）と、AQ-1〜AQ-6 の検査の土台（TA Spec §9.1）。導出 I-35（TA Spec §10.1）。

## 前提・着手条件
- 依存: なし（TA Spec §8.1 の順 1）。ただし親 docs plan「実装の停止と再開ゲート」の 1〜3 が満たされていること（TA Spec と ADR-110 が main、user の再開指示）。
- ios の `main` が I-S3a の成果（`Podcast/Playback/AudioEngine.swift`・`Podcast/Platform/` 3 本）を含むこと: `git cat-file -e origin/main:NewsListenApp/NewsListenApp/Podcast/Playback/AudioEngine.swift`（rc=0）。
- コマンドの実行場所: 検査コマンドはすべて **`ios/`（submodule のルート）** で実行する。takt の worktree ルート（親リポ）で実行すると grep は「ファイルなし」になり 0 件に見える。
- `docs/trial-log/`（ios・親）を最初に読む。

## 着手前の前提点検（投入の直前に数え直す。値が違えば order を直してから投入する）
TA Spec §4 の「現状の違反」は 2026-09-30 の机上集計で、XCTest の検査としては走らせていない（TA Spec §11）。本 slice は**実測した値を許可リストに固定し、TA Spec §4 の表との差を PR 説明に書いて返す**。投入前に次を確かめる（2026-10-01 実測。revision `ef9e559`）。

| 項目 | 2026-10-01 の実測 | 数え直すコマンド（`ios/` で） |
|---|---|---|
| production の Swift ファイル数 | 91 | `find NewsListenApp/NewsListenApp -name '*.swift' \| wc -l` |
| production の行数 | 12,058 | `find NewsListenApp/NewsListenApp -name '*.swift' -exec cat {} + \| wc -l` |
| テストファイル数・`func test` の件数 | 51・661 | `find NewsListenApp/NewsListenAppTests -name '*.swift' \| wc -l`、`grep -rh 'func test' NewsListenApp/NewsListenAppTests --include='*.swift' \| wc -l` |
| `DTO`（adapter の層で `Codable`/`Decodable`/`Encodable` 適合を宣言する型） | 43（`Models/` 36・`Passkey/PasskeyModels.swift` 3・`Sessions/SessionModels.swift` 3・`Observability/ClientErrorPayload.swift` 1） | `grep -rnE '^\s*(struct\|enum\|final class\|class)\s+\w+[^{]*:\s*[^{]*(Codable\|Decodable\|Encodable)' NewsListenApp/NewsListenApp/Models NewsListenApp/NewsListenApp/Passkey/PasskeyModels.swift NewsListenApp/NewsListenApp/Sessions/SessionModels.swift NewsListenApp/NewsListenApp/Observability/ClientErrorPayload.swift \| wc -l` |
| View ファイル（presentation で `import SwiftUI`・`*ViewModel.swift` でない・合成 root を除く） | 28 | `grep -rl '^import SwiftUI' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v 'ViewModel.swift$' \| grep -v NewsListenAppApp.swift \| wc -l` |
| ViewModel ファイル | 13 | `find NewsListenApp/NewsListenApp -name '*ViewModel.swift' \| wc -l` |
| `Podcast/Playback/` の import | `AudioEngine.swift:9 import Foundation` の 1 行 | `grep -rn '^import' NewsListenApp/NewsListenApp/Podcast/Playback/` |
| TA-D12: `AppState.swift` の `@Published var`（`private(set)` なし） | 10（`@Published` 全体は 13） | `grep -c '@Published var' NewsListenApp/NewsListenApp/AppState.swift` |
| TA-D12: ViewModel 13 本の `@Published var` の合計 | 38（Podcast 9・Feed 7・Admin 5・Settings 4・Starred 3・Login 3・Sessions 2・Onboarding 2・Passkey 3 本に 1 ずつ・Learning 2 本は 0） | `for f in $(find NewsListenApp/NewsListenApp -name '*ViewModel.swift'); do grep -c '@Published var' $f; done \| paste -sd+ \| bc` |
| TA-D13: 合成 root 以外での `AdapterConcrete` の生成（コメント行を除く） | **16 行**。TA Spec §4 の 14 行（`AppState.swift` 5・`Podcast/PodcastViewModel.swift` 4・`Settings/SettingsViewModel.swift` 2・`Feed/FeedViewModel.swift` 1・`Starred/StarredViewModel.swift` 1・`Observability/CrashReporter.swift` 1）に加え、**`Settings/AccountSettingsView.swift:42`・`Auth/LoginView.swift:28` の `ASAuthorizationPasskeyProvider()` 2 行**（`#if DEBUG` の外）が TA Spec の表に無い。Preview の 5 行（`Learning/LearningView.swift:301,308`・`Learning/VocabularyTestView.swift:279,287`・`DesignSystem/PreviewSupport.swift:142`）は `#if DEBUG` の中 | `grep -rnE '(APIClient\|KeychainSessionStore\|AudioCacheManager\|MediaPlayerNowPlaying\|AVPlayerEngine\|NetworkMonitor\|PreferenceRegistry\|CrashReporter\|ASAuthorizationPasskeyProvider)\(' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v ':[0-9]*:[[:space:]]*//' \| grep -v NewsListenAppApp.swift` |
| TA-D11: port ファイルの `[String: Any]` | `Podcast/Platform/NowPlayingCenter.swift:59` の 1 行 | `grep -n 'String: Any' NewsListenApp/NewsListenApp/Podcast/Platform/NowPlayingCenter.swift` |
| TA-D8: adapter 以外の `Codable` 系 | `DesignSystem/PreviewSupport.swift` 2・`Podcast/QuizSheetView.swift` 1（Preview の fixture） | `grep -rn 'JSONDecoder\|JSONEncoder\|Codable\|Decodable\|Encodable\|CodingKey' NewsListenApp/NewsListenApp --include='*.swift' \| grep -v '^NewsListenApp/NewsListenApp/\(Models\|Networking\|Observability\|Passkey/PasskeyModels\|Sessions/SessionModels\|Settings/PreferenceRegistry\|Push/PushSupport\)' \| grep -v ':[0-9]*:[[:space:]]*//'` |
| `GrepOracleTests` の件数と `SourceGrep` の置き場 | 10 件。`private enum SourceGrep` は `GrepOracleTests.swift:16-93` | `grep -c 'func test' NewsListenApp/NewsListenAppTests/GrepOracleTests.swift`、`grep -n 'enum SourceGrep' 同ファイル` |
| `ci.yml` の grep の step | `.github/workflows/ci.yml:47`（`statusCode ==\|httpError(`） | `grep -n 'statusCode' .github/workflows/ci.yml` |

TA-D2〜D6・D12 の行数（TA Spec §4 の表）は、本 slice の検査を書いた時点で XCTest が数える。**机上の値と違っても止めない**（許可リストは実測で固定し、差を PR 説明と TA Spec §4 の訂正として返す。TA Spec §11「§4 の現状の違反の数」）。ただし **TA-D1・D7・D10 が 0 でない**、または **TA-D12 の恒久の許可リスト 6 個（`LoginViewModel.username`・`password`、`AdminUsersViewModel.newUsername`・`newPassword`・`newDisplayName`・`newRole`）に無い名前が ViewModel の下書きとして要る**と分かったときは、実装を止めて報告する（規則そのものの前提が崩れている）。

## 対象（ios サブモジュールのみ。test だけ）
**新規（test 3 本）**

| ファイル | 中身 |
|---|---|
| `NewsListenAppTests/SourceGrepSupport.swift` | `GrepOracleTests` の `private enum SourceGrep`（`appRoot`・`testRoot`・`isCommentLine`・`swiftFiles`・`relativePath`・`content`・`matchingLines`・`matchedSubstrings`・`occurrenceCount`・`lineCount`）を file-level の `enum SourceGrep` として取り出し、テストターゲット内で共有する。関数の名前・意味・「コメント行（先頭の空白の後が `//`）は数えない」の定義を変えない |
| `NewsListenAppTests/ArchitectureManifest.swift` | 所属表と集合（下の「宣言」） |
| `NewsListenAppTests/ArchitectureOracleTests.swift` | TA-V1〜V5・V7・V9 の検査（下の「検査」） |

**変更（test 1 本）**: `NewsListenAppTests/GrepOracleTests.swift` — `private enum SourceGrep` の宣言を削除し、`SourceGrepSupport.swift` の `SourceGrep` を参照する。10 件の test 関数の本文と期待値は変えない（`nonCommentHits`・`platformTypePattern` などの private helper は `GrepOracleTests` に残す）。

**production の変更は 0**: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 0 行。`project.pbxproj` は synchronized group なので、テストファイルの追加で変わらない。

## 宣言（`ArchitectureManifest`。ここに無い集合を足さない）
```swift
enum ArchitectureLayer: String, CaseIterable { case compositionRoot, domain, application, adapter, presentation }

enum ArchitectureManifest {
    /// TA Spec §3.1 の所属表。5 つの規則を**全部**評価し、当たった規則の層で決める（順に当てて最初で止めない）。
    static let layerRules: [(pattern: String, layer: ArchitectureLayer)]   // 正規表現（相対 path に対して）
    /// 明示の行（完全一致の path → 層）。layerRules の結果を上書きする。混在ファイルと、規則に当たらないファイルを割り当てる。
    static let explicitLayers: [String: ArchitectureLayer]
    /// リードモデルのファイル（TA-D9 の対象）。初版は空。I-S3b1 で `Podcast/Playback/NowPlaying.swift` が入る。
    static let readModelFiles: Set<String>
    /// port を定義するファイル（TA-D11 の対象）。初版は 4 本。
    static let portFiles: Set<String>
    /// domain の型だけを対象にするテストファイル（TA-V7 の対象）。初版は `TranscriptTimingTests.swift`・`PlaybackQueueTests.swift`・`PlaybackQueueConformanceTests.swift`（domain の初版 4 本を対象にするテスト）。
    static let domainTestFiles: Set<String>
    /// TA-D12 の恒久の許可リスト（入力の下書き 6 個。TA Spec §4）。
    static let publishedDraftAllowlist: [(file: String, name: String)]
    /// 一時経路 TP10: 現状の違反の許可リスト。`(規則 ID, path, 行数)`。実測と一致することを要求する。
    static let allowlist: [(rule: String, path: String, lines: Int)]
    /// 型名の集合（TA Spec §4）。`DTO` は adapter のファイルの宣言から毎回作る（定数にしない）。
    static let adapterConcrete: Set<String>   // 9 個
    static let uiFacility: Set<String>        // 6 個（`@AppStorage` は属性として照合）
    static func dtoTypeNames(in files: [URL]) -> Set<String>
    /// 明示の行にあればその層。無ければ layerRules のうち当たった規則の層の集合（0 個・1 個・2 個以上）。
    static func matchedLayers(of relativePath: String) -> Set<ArchitectureLayer>
    /// matchedLayers がちょうど 1 つのときだけその層。0 個・2 個以上は nil（T-TA-V1a が落とす）。
    static func layer(of relativePath: String) -> ArchitectureLayer?
}
```
- `layerRules` の初版は TA Spec §3.1 の 5 行のとおり: (1) `NewsListenAppApp.swift` → compositionRoot、(2) `**/Domain/**` → domain、(3) `**/Application/**`・`Podcast/Playback/*.swift`（直下）・`AppState.swift`・`Auth/SubjectCleanup.swift` → application、(4) `Networking/**`・`Models/**`・`**/Platform/**`・`Observability/**`・`Settings/PreferenceRegistry.swift`・`Push/PushSupport.swift` → adapter、(5) `*View.swift`・`*ViewModel.swift`・`*Sheet*.swift`・`*Card.swift`・`DesignSystem/**`・`Utilities/**`・`Shared/Presentation/**`・`Push/AppDelegate.swift`・`Feed/SafariView.swift` → presentation。
- 混在ファイル（TA Spec §3.2 の「現状の層と混在」）は、そのファイルが目標で残る層に割り当て、規則に反する行を `allowlist` に載せる（TA Spec §3.1 の最後の項）。初版の domain は 4 本（`Podcast/PlaybackQueue.swift`・`Podcast/PlaybackConstants.swift`・`Podcast/TranscriptTiming.swift`・`Models/FeaturedCategory.swift`）だが、規則 (2)〜(4) では `Podcast/PlaybackQueue.swift` 等は当たらず `Models/FeaturedCategory.swift` は adapter に当たる。**初版の所属表は、これら 4 本を明示の行（`explicitLayers`）で domain に割り当てる**（明示の行は `layerRules` の結果を上書きする。I-T2a・I-T7b で `Domain/` へ移した時点でその行を消す）。TA Spec §4 の「初版は 4 本」がこの扱いを前提にしている。
- `portFiles` の初版: `Podcast/Playback/AudioEngine.swift`・`Podcast/Platform/NowPlayingCenter.swift`・`Podcast/PlaybackLifecycle.swift`・`Passkey/PasskeyAuthorizationProviding.swift`（TA-D11）。`Podcast/PlaybackLifecycle.swift`・`Podcast/PlayerPresentation.swift`・`Podcast/Platform/NowPlayingCenter.swift`・`Passkey/PasskeyAuthorizationProviding.swift` は application（TA Spec §4 TA-D3 の「初版は 7 本」）で、これも明示の行で割り当てる（I-T2b・I-T7c で移す）。
- **5 規則のどれにも当たらない 6 本**も明示の行で adapter に割り当てる: `Podcast/NowPlayingInfo.swift`（adapter の補助。I-T2b で `Podcast/Platform/` へ。TA Spec §3.2）、`Passkey/PasskeyModels.swift`・`Sessions/SessionModels.swift`（通信のデータモデル。上の前提点検の `DTO` 43 個はこの 2 本を adapter として数えている。I-T7b・I-T7c で `Models/` へ）、`Passkey/PasskeyOptionsDecoder.swift`・`Passkey/PasskeyCredentialEncoder.swift`・`Passkey/ASAuthorizationPasskeyProvider.swift`（wire ⇄ OS の変換と OS の実装。I-T7c で `Passkey/Platform/` へ。TA Spec §3.2・§5.3）。移した時点で規則 (4) に当たるので、その行を消す。
- 明示の行は初版で 14 本（domain 4・application 4・adapter 6）。2026-10-01 実測（ios main `ef9e559`。`find NewsListenApp/NewsListenApp -name '*.swift' | wc -l` = 91 本に、TA Spec §3.1 の 5 規則の path の glob を全部当てて数えた。T-TA-V1a と同じ判定）: 5 規則のどれにも当たらない 6 本（上の adapter の 6 本）、2 つ以上に当たる 0 本、明示の行の 8 本（domain 4・application 4）のうち規則にも当たるのは `Models/FeaturedCategory.swift`（adapter）と `Podcast/Platform/NowPlayingCenter.swift`（adapter）の 2 本で、明示の行が上書きする。
- `allowlist` には、規則ごとに path と**行数**を書く（例: `("TA-D4", "Settings/SettingsView.swift", 2)`）。行番号は書かない（行番号は後の slice で動く）。

## 検査（`ArchitectureOracleTests`。テスト名またはコメントに `verifies: TA-V*` と、規則 ID `TA-D*` を持つ）
書き方は `GrepOracleTests` に合わせる: `SourceGrep.matchingLines(pattern:in:)` でコメント行を除いた行を集め、**正の対照**（パターンが該当の文字列に一致する。除外の前の集合に既知の行が含まれる）と**負の対照**（adapter の型名や `==` に一致しない）を各テストの中に持つ（`testG03` と同じ形）。

| 検査 | テスト（RED → GREEN） | 量化する集合 | 期待値 |
|---|---|---|---|
| TA-V1 | **T-TA-V1a**（TA-D10）: production の全 Swift ファイルについて、明示の行に無いものは 5 規則を全部評価し（順に当てて最初で止めない）、「どの規則にも当たらないファイル」と「2 つ以上の規則に当たるファイル（明示の行で上書きしたものを除く）」を数え、どちらも 0 であることを主張する（違えば path を列挙して落とす）。正の対照: 規則 (3) と (5) の両方に当たる合成の path（例 `Podcast/Playback/DummyView.swift`）が「2 つ以上」に数えられ、規則に当たらない合成の path（例 `Misc/Dummy.swift`）が「当たらない」に数えられること。初版の期待値は、明示の行 14 本を入れた後で、当たらない 0・2 つ以上 0（明示の行が無いと当たらない 6・2 つ以上 0）。**T-TA-V1b**（TA-D1）: domain のファイルの `import` が `Foundation` だけで、`Codable`・`Decodable`・`Encodable`・`CodingKey`・`UserDefaults`・`ObservableObject`・`@Published`・`URLSession`・`FileManager`・`AdapterConcrete` の型名が無い。**T-TA-V1c**（TA-D3）: application のファイルの `import` が `Foundation`・`Combine`・`os` の中にあり、`AdapterConcrete`・`UIFacility`・`DTO` の型名の行数が許可リストと一致する。**T-TA-V1d**（TA-D7）: adapter のファイルに `*ViewModel`・`AppState` の型名が無く、`import SwiftUI` が無い。**T-TA-V1e**（TA-D13）: 合成 root 以外での `AdapterConcrete` の生成（`<型名>(`）の行数が許可リストと一致する。`#if DEBUG` … `#endif` と `#Preview` の中は数えない（`#if DEBUG` の入れ子は深さで追う） | production の 91 ファイル（層ごとの部分集合） | TA-D1・D7・D10 は 0。TA-D3・D13 は許可リストと**一致**（多くても少なくても落ちる） |
| TA-V2 | **T-TA-V2a**（TA-D2）: domain のファイルに `DTO` の型名が無い（許可リストと一致）。**T-TA-V2b**（TA-D4・D6 の `DTO` の分）: View ファイル・ViewModel ファイルの `DTO` の型名の行数が許可リストと一致。**T-TA-V2c**（TA-D8）: adapter 以外のファイルに `Codable`・`Decodable`・`Encodable`・`CodingKey`・`JSONDecoder`・`JSONEncoder` が無い（許可リストと一致）。**T-TA-V2d**（TA-D11）: `portFiles` の宣言に `DTO`・`AV*`・`MP*`・`UI*`・`URLRequest`・`HTTPURLResponse`・`[String: Any]` が無い（許可リストと一致）。`DTO` の集合は `dtoTypeNames(in:)` で毎回作り、テストの中で「43 個」であることも確かめる（TA Spec §4。I-T2a で 39 個になる） | domain・application・presentation のファイル × `DTO`、`portFiles` | 許可リストと一致 |
| TA-V3 | **T-TA-V3**: TA Spec §7「TA-V3 の式」の 13 群（TA-R-CT-1・2 / CT-3 / PB-5 / PB-4 / AC-1 / AC-5 / AC-6・CU-4・SO-2・LC-2 / PF-1 / PF-2 / PF-3 / CU-3 / LC-1 / LV-1）を、群ごとの正規表現と「正本の置き場」で表駆動する。正本の置き場の外の一致の行数が許可リストと一致する。式と除外（`Passkey/PasskeyOptionsDecoder.swift`、`AppState.swift:382` の `notFound`、日付の `prefix(10)`、Preview の `#if DEBUG`）は TA Spec §7 の表のとおり | 13 群 × production の全ファイル | 許可リストと一致 |
| TA-V4 | **T-TA-V4a**（TA-D5）: View ファイルと合成 root で、`viewModel`・`vm`・`appState`・`<名前>ViewModel` に続く `.<プロパティ> = `（`==` を除く）と `.toggle()` の行数が許可リストと一致する。**T-TA-V4b**（TA-D4 の `APIClient`・`ApiFailure`・`UserDefaults`・`@AppStorage` の分、TA-D6 の `APIClient`・`AdapterConcrete`・`UIFacility`・`import UIKit`・`import SwiftUI` の分）: 行数が許可リストと一致する | View ファイル 28 本・ViewModel ファイル 13 本・合成 root | 許可リストと一致 |
| TA-V5 | **T-TA-V5a**（TA-D12）: application のファイルの `private(set)` の無い `@Published var` の数が許可リストと一致する（目標 0）。ViewModel ファイルの `private(set)` の無い `@Published var` は、`publishedDraftAllowlist` の 6 個と、許可リスト（残り 32 個）の合計と一致する。**T-TA-V5b**（TA-D9）: `readModelFiles` の各ファイルに `class`・`actor`・`@Published`・`mutating`・格納プロパティの `var`（`{` の無い `var`）が無く、プロパティの型に `DTO` と `ObservableObject` 適合型が無い。初版は対象 0 本なので「集合が空である」ことを `XCTExpectFailure` ではなく **`readModelFiles.isEmpty` を明示の assert** で固定し、I-S3b1 で非空に改める | application の全ファイル・ViewModel 13 本・`readModelFiles` | 一致 |
| TA-V7 | **T-TA-V7**: `domainTestFiles` の各ファイルに `URLSession`・`UserDefaults`・`FileManager`・`MockURLSession`・`import UIKit` が無い | `domainTestFiles`（初版 3 本） | 0 件 |
| TA-V9 | **T-TA-V9**: `ci.yml:47` の grep（`statusCode ==\|httpError(` が `Networking/` の外に 0 件 = T-T13）を XCTest に入れる（`GrepOracleTests` の O-* と同じ形）。`GrepOracleTests` の 10 件は無変更で green | production の全ファイル | 0 件 |

- 許可リストの検査は「実測の行数 == 一覧の行数」で、**一覧に無い path の違反は 0 件**を要求する。落ちたときのメッセージに、規則 ID・path・実測と一覧の差を出す。
- `#if DEBUG` の扱い: TA-D13 と TA-V3 の Preview の分だけ除外し、ほかの規則は `#if DEBUG` の中も数える（TA Spec §4 の各行の「現状の違反」が Preview の行を含めて数えているため。例: TA-D5 の「Preview の 6」）。
- 型名の照合は単語境界（`\b`）で行う（`OfflineLibrary` が `clearOfflineLibrary` に、`NowPlaying` が `NowPlayingCenter` に部分一致しないように。I-S3b1 の完了条件 5 と同じ注意）。

## 移行の中間状態
- **TP10（許可リスト）を導入する**。owner: user／導入: I-T1／削除: I-T12（空にし、空であることを検査する）。以後の slice は、自分が消す規則違反の分だけ一覧を減らす（減らし忘れは落ちる）。
- 初版の所属表の「明示の行」（`Podcast/PlaybackQueue.swift` 等 4 本を domain、`Podcast/PlaybackLifecycle.swift` 等 4 本を application、規則に当たらない `Podcast/NowPlayingInfo.swift` 等 6 本を adapter に割り当てる行）は、I-T2a・I-T2b・I-T7b・I-T7c で該当ファイルを目標の path へ移した時点で消す。

## 変わる挙動
無い（production は 0 行）。

## 契約と検査
green にする: TA-V1〜V5・V7・V9（許可リストと一致）。TA-D1・D7・D10 は 0。既存の `GrepOracleTests`（10）と全既存テスト（661）は無変更で green（TA-V11）。

## 完了条件
1. `ArchitectureOracleTests` の T-TA-V1a〜V1e・V2a〜V2d・V3・V4a・V4b・V5a・V5b・V7・V9 が green で、テスト名またはコメントに `verifies: TA-V*` を持つ。
2. production の変更が 0: `git diff --name-only origin/main -- NewsListenApp/NewsListenApp` が 0 行（コミット後に実行）。
3. 追加した test が 3 本だけ: `git diff --diff-filter=A --name-only origin/main -- NewsListenApp/NewsListenAppTests` が**ちょうど 3 行**（`ArchitectureManifest.swift`・`ArchitectureOracleTests.swift`・`SourceGrepSupport.swift`）。変更した test が 1 本だけ: `git diff --diff-filter=M --name-only origin/main -- NewsListenApp/NewsListenAppTests` が**ちょうど 1 行**（`GrepOracleTests.swift`）。
4. `SourceGrep` の定義が 1 箇所: `grep -rn "enum SourceGrep" NewsListenApp/NewsListenAppTests` が `SourceGrepSupport.swift` の 1 行。`grep -c "private enum SourceGrep" NewsListenApp/NewsListenAppTests/GrepOracleTests.swift` → 0。
5. `GrepOracleTests` の件数が 10 のまま: `grep -c "func test" NewsListenApp/NewsListenAppTests/GrepOracleTests.swift` → 10。全体の `func test` が 661 ＋ 新規（≥ 15）。
6. 許可リストの形: `grep -c '("TA-D' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` ≥ 1 で、各行が `(規則 ID, path, 行数)` の 3 つ組。行番号を含む要素が無い（`grep -n ':[0-9]' 同ファイル` の一致が path の中に無い）。
7. TA-D1・D7・D10 の検査に許可リストの行が無い: `grep -c '"TA-D1"\|"TA-D7"\|"TA-D10"' NewsListenApp/NewsListenAppTests/ArchitectureManifest.swift` → 0。
8. PR 説明に「TA Spec §4 の机上の値と実測の差」の表（規則 ID・Spec の値・実測・差の理由）を載せる。差が無い規則も「差なし」と書く。TA-D13 の `ASAuthorizationPasskeyProvider()` 2 行（上の前提点検）を含む。

## 検証
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make test`（`SIMULATOR='<機種名>'` で機種を指定できる。`scripts/test.sh` が `-only-testing:NewsListenAppTests` を付ける）→ 全 green（既存 661 ＋ 新規）。
- 正の対照: 許可リストの任意の 1 行の行数を 1 減らして走らせると、その規則の検査だけが落ちる（PR 説明に 1 例を書く）。負の対照: 増やしても落ちる。
- 完了条件 2〜7 のコマンドを `ios/` で実行し、結果を PR 説明に貼る。

## 禁止事項 / scope 外
- production を変えない（違反を直さない。直すのは後の slice）。lint（swiftlint / swiftformat）を導入しない。
- 規則 ID（TA-D1〜D14）・検査 ID（TA-V1〜V12）・許可リストの形（3 つ組）を変えない。規則を足さない・緩めない（TA Spec §4 に無い規則を作らない）。
- `GrepOracleTests` の期待値を変えない（TA-D14）。
- `#if DEBUG` の除外を TA-D13 と TA-V3 の Preview の分の外へ広げない。

## 種別
適用 slice。判断待ちに依存しない。

## 規模（見込み。TA Spec §8.1: production 0 / test 350）
- test ≈ 350 行: `ArchitectureManifest.swift` ≈ 120（所属表・集合・許可リスト ≈ 60 行）、`ArchitectureOracleTests.swift` ≈ 220、`SourceGrepSupport.swift` ≈ 80（移動）、`GrepOracleTests.swift` −80。

## 記録
- `docs/trial-log/` に棄却・方針転換があれば追記する。
- 親 docs・TA Spec へ返すもの: TA Spec §4 の「現状の違反」の表を実測で訂正する（PR 説明の差の表をそのまま渡す。とくに TA-D13 の 16 行）。TA Spec §9.3「production の 91 ファイルが所属表に当たる」を「検査として走る」へ。README の I-T1 行を完了へ。
