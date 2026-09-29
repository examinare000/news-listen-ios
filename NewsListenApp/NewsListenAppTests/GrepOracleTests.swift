import XCTest
@testable import NewsListenApp

/// spec.md §5.7 の grep oracle（O-1〜O-13）を、シェルではなく XCTest 内から直接ソースを
/// 読んで再現する「配線テスト」。手作業の grep 実行に依存せず自動テストとして
/// `xcodebuild test` の分子に数える（spec §5.6 coverage の 36/38 自動テスト分子の一部）。
///
/// 対応関係:
/// - T-T14-15（CI-T14.13）: O-1・O-2
/// - T-T14-24（CI-T14.19）: O-8・O-9・O-11・O-12・O-13
/// - T-T15-12（CI-T15.9）: O-6・O-7
/// - T-T17-06（CI-T17.6）: O-3・O-4・O-5
final class GrepOracleTests: XCTestCase {

    // MARK: - ソース走査ヘルパー

    private enum SourceGrep {
        /// `App/` = `ios/NewsListenApp/NewsListenApp`（このテストファイルの 2 階層上 + `NewsListenApp`）。
        static let appRoot: URL = {
            let thisFile = URL(fileURLWithPath: #filePath)
            return thisFile
                .deletingLastPathComponent() // NewsListenAppTests/
                .deletingLastPathComponent() // NewsListenApp/ (プロジェクトルート)
                .appendingPathComponent("NewsListenApp") // App ターゲットルート
        }()

        static func swiftFiles(excluding excludedBasenames: Set<String> = []) -> [URL] {
            guard let enumerator = FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) else { return [] }
            var results: [URL] = []
            for case let url as URL in enumerator {
                guard url.pathExtension == "swift", !excludedBasenames.contains(url.lastPathComponent) else { continue }
                results.append(url)
            }
            return results
        }

        static func relativePath(_ url: URL) -> String {
            let root = appRoot.path
            var path = url.path
            if path.hasPrefix(root) { path.removeFirst(root.count) }
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }

        static func content(of url: URL) -> String {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        /// `grep -nE` 相当: 各行を独立に照合し、ヒットした (相対パス, 行番号, 行内容) を返す。
        static func matchingLines(pattern: String, in files: [URL]) -> [(path: String, line: Int, text: String)] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            var results: [(String, Int, String)] = []
            for file in files {
                let lines = content(of: file).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        results.append((relativePath(file), index + 1, line))
                    }
                }
            }
            return results
        }

        /// `grep -o` 相当: ファイル横断でパターンにマッチした全部分文字列を出現順に返す。
        static func matchedSubstrings(pattern: String, in files: [URL]) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            var out: [String] = []
            for file in files {
                let text = content(of: file)
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                    if let m = match { out.append(ns.substring(with: m.range)) }
                }
            }
            return out
        }

        static func occurrenceCount(of needle: String, in url: URL) -> Int {
            content(of: url).components(separatedBy: needle).count - 1
        }

        static func lineCount(containing needle: String, in url: URL) -> Int {
            content(of: url).components(separatedBy: "\n").filter { $0.contains(needle) }.count
        }
    }

    // MARK: - T-T14-15（CI-T14.13）: O-1・O-2

    // verifies: CI-T14.13
    func testTT14_15_unauthorizedDetectionIsCentralizedAndAuthStatusIsRemoved() {
        let files = SourceGrep.swiftFiles()

        // O-1: `.unauthorized` を扱うコード行は Networking/・AppState.swift・Auth/LoginViewModel.swift のみ。
        let unauthorizedHits = SourceGrep.matchingLines(pattern: #"^\s*([^/\s].*)?\.unauthorized"#, in: files)
        let allowedPrefixes = ["Networking/", "AppState.swift", "Auth/LoginViewModel.swift"]
        let unauthorizedViolations = unauthorizedHits.filter { hit in !allowedPrefixes.contains { hit.path.hasPrefix($0) } }
        XCTAssertTrue(unauthorizedViolations.isEmpty, "許可範囲外で .unauthorized を扱っている: \(unauthorizedViolations)")

        // O-2: `authStatus` / `AuthStatus` のコード行は 0 件（AuthSession への一本化で廃止）。
        let staleAuthStatusHits = SourceGrep.matchingLines(pattern: #"^\s*([^/\s].*)?(authStatus|AuthStatus)"#, in: files)
        XCTAssertTrue(staleAuthStatusHits.isEmpty, "authStatus/AuthStatus が残存している: \(staleAuthStatusHits)")
    }

    // MARK: - T-T14-24（CI-T14.19）: O-8・O-9・O-11・O-12・O-13

    // verifies: CI-T14.19
    func testTT14_24_externalWriteGuardsAreWiredBeforeFirstAwait() {
        let files = SourceGrep.swiftFiles()

        // O-8: AppState の外から AppState を書く・呼ぶ箇所の全数（名前集合と件数）。
        let o8Matches = SourceGrep.matchedSubstrings(pattern: #"appState\??\.[A-Za-z]+( = |\()"#, in: files)
        var o8Counts: [String: Int] = [:]
        for match in o8Matches { o8Counts[match, default: 0] += 1 }
        let expectedO8: [String: Int] = [
            "appState.completeLogin(": 1,
            "appState.completeOnboarding(": 1,
            "appState.confirmWeeklyGoalSync(": 1,
            "appState.defaultDifficulty = ": 1,
            "appState.defaultPlaybackSpeed = ": 1,
            "appState.didRegisterDeviceToken(": 2,
            "appState.handleNotificationPodcastId(": 2,
            "appState.isCurrentSubject(": 3,
            "appState.logout(": 1,
            "appState.refreshAuth(": 1,
            "appState.refreshListeningStreak(": 5,
            "appState.refreshOnboardingStatus(": 1,
            "appState.refreshPreferences(": 1,
            "appState.registerPlaybackLifecycle(": 1,
            "appState.retryResolve(": 1,
            "appState.selectedPodcastId = ": 1,
            "appState.updateCurrentUser(": 1,
            "appState.weeklyGoalEpisodes = ": 1,
        ]
        XCTAssertEqual(o8Counts, expectedO8, "主体ガード表 §3.1 の外部行と一致しない（表に無い書き手があれば RJ-5 により表を先に直す）")
        XCTAssertNil(o8Counts["appState.currentUser = "], "currentUser への直接代入は無くなるべき（computed 化）")

        let settingsViewURL = SourceGrep.appRoot.appendingPathComponent("Settings/SettingsView.swift")
        let accountSettingsViewURL = SourceGrep.appRoot.appendingPathComponent("Settings/AccountSettingsView.swift")

        // O-9: revert 3 行すべてが同じ行で isCurrentSubject(stamp) を持つ。
        let oldValueLines = SourceGrep.content(of: settingsViewURL).components(separatedBy: "\n").filter { $0.contains("= oldValue") }
        XCTAssertEqual(oldValueLines.count, 3, "revert 行数は 3 のままであるべき")
        let unguardedReverts = oldValueLines.filter { !$0.contains("isCurrentSubject(stamp)") }
        XCTAssertTrue(unguardedReverts.isEmpty, "revert は isCurrentSubject(stamp) を同じ行に持つべき: \(unguardedReverts)")

        // O-11: subjectStamp の出現数（捕捉の文の数と同じ）。
        XCTAssertEqual(SourceGrep.occurrenceCount(of: "subjectStamp", in: settingsViewURL), 3)
        XCTAssertEqual(SourceGrep.occurrenceCount(of: "subjectStamp", in: accountSettingsViewURL), 1)

        // O-12: stamp の捕捉が、各書き手の最初の await より前にある。
        let settingsTokens = orderedTokens(
            startPattern: #"onChange\(of: appState\."#,
            captureText: "let stamp = appState.subjectStamp",
            in: settingsViewURL,
            startWord: "onChange"
        )
        let settingsMatches = orderedMatches(tokens: settingsTokens, startWord: "onChange")
        XCTAssertEqual(settingsMatches.filter { $0 == "onChange let stamp await" }.count, 3)
        XCTAssertEqual(settingsMatches.filter { $0 == "onChange await" }.count, 0, "捕捉を欠く区間が残っている")

        let accountTokens = orderedTokens(
            startPattern: #"func saveProfile\(\)"#,
            captureText: "let stamp = appState.subjectStamp",
            in: accountSettingsViewURL,
            startWord: "func saveProfile"
        )
        let accountMatches = orderedMatches(tokens: accountTokens, startWord: "func saveProfile")
        XCTAssertEqual(accountMatches.filter { $0 == "func saveProfile let stamp await" }.count, 1)
        XCTAssertEqual(accountMatches.filter { $0 == "func saveProfile await" }.count, 0)

        // O-13: capturedAt: に渡すのが捕捉した stamp。
        XCTAssertEqual(SourceGrep.lineCount(containing: "capturedAt: stamp)", in: settingsViewURL), 1)
        XCTAssertEqual(SourceGrep.lineCount(containing: "capturedAt: stamp)", in: accountSettingsViewURL), 1)
    }

    /// O-12 の「開始行 → 捕捉の文 → 最初の await」の順序判定に使うトークン列を作る
    /// （spec §5.7 のコマンドを shell に頼らず再現する）。コメント行は除外する。
    private func orderedTokens(startPattern: String, captureText: String, in url: URL, startWord: String) -> [String] {
        guard let startRegex = try? NSRegularExpression(pattern: startPattern) else { return [] }
        let awaitRegex = try! NSRegularExpression(pattern: #"(^|[^A-Za-z0-9_])await([^A-Za-z0-9_]|$)"#)
        var tokens: [String] = []
        for line in SourceGrep.content(of: url).components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            if startRegex.firstMatch(in: line, range: range) != nil { tokens.append(startWord) }
            if line.contains(captureText) { tokens.append("let stamp") }
            if awaitRegex.firstMatch(in: line, range: range) != nil { tokens.append("await") }
        }
        return tokens
    }

    /// トークン列を空白区切りの文字列にして `<startWord> (let stamp )?await` にマッチする
    /// 部分文字列をすべて取り出す（`grep -oE` 相当）。
    private func orderedMatches(tokens: [String], startWord: String) -> [String] {
        let joined = tokens.joined(separator: " ")
        let pattern = "\(NSRegularExpression.escapedPattern(for: startWord)) (let stamp )?await"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = joined as NSString
        return regex.matches(in: joined, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    // MARK: - T-T15-12（CI-T15.9）: O-6・O-7

    // verifies: CI-T15.9
    func testTT15_12_platformPortsAreIsolatedAndWired() {
        let boundaryFiles = [
            SourceGrep.appRoot.appendingPathComponent("AppState.swift"),
            SourceGrep.appRoot.appendingPathComponent("Auth/SubjectCleanup.swift"),
        ]
        let o6Hits = SourceGrep.matchingLines(pattern: "import MediaPlayer|PodcastViewModel", in: boundaryFiles)
        XCTAssertTrue(o6Hits.isEmpty, "AppState / SubjectCleanup は MediaPlayer・PodcastViewModel を参照しないべき: \(o6Hits)")

        let appAppURL = SourceGrep.appRoot.appendingPathComponent("NewsListenAppApp.swift")
        let o7Hits = SourceGrep.matchingLines(pattern: "registerPlaybackLifecycle", in: [appAppURL])
        XCTAssertFalse(o7Hits.isEmpty, "registerPlaybackLifecycle の配線が無い")
    }

    // MARK: - T-T17-06（CI-T17.6）: O-3・O-4・O-5

    // verifies: CI-T17.6
    func testTT17_06_preferenceKeysAreDeclaredOnlyInRegistry() {
        let files = SourceGrep.swiftFiles(excluding: ["Preferences.swift", "APIClient.swift"])
        let keyPattern = [
            #""default_difficulty""#, #""default_playback_speed""#, #""weekly_goal_episodes""#,
            #""seen_achievement_ids""#, #""article_open_mode""#, #""time_format""#,
            #""sfx_enabled""#, #""haptics_enabled""#,
        ].joined(separator: "|")

        let o3Hits = SourceGrep.matchingLines(pattern: keyPattern, in: files)
        let nonRegistryO3 = o3Hits.filter { $0.path != "Settings/PreferenceRegistry.swift" }
        XCTAssertTrue(nonRegistryO3.isEmpty, "registry 外で key 文字列を宣言している: \(nonRegistryO3)")

        let allFiles = SourceGrep.swiftFiles()
        let o4Hits = SourceGrep.matchingLines(pattern: #"PreferenceSetting\("#, in: allFiles)
        let nonRegistryO4 = o4Hits.filter { $0.path != "Settings/PreferenceRegistry.swift" }
        XCTAssertTrue(nonRegistryO4.isEmpty, "PreferenceSetting( の構築が registry 外にある: \(nonRegistryO4)")

        let appStateURL = SourceGrep.appRoot.appendingPathComponent("AppState.swift")
        let o5Hits = SourceGrep.matchingLines(pattern: #"^\s*([^/\s].*)?UserDefaults"#, in: [appStateURL])
        XCTAssertTrue(o5Hits.isEmpty, "AppState.swift が UserDefaults を直接扱っている（registry 経由にすべき）: \(o5Hits)")
    }
}
