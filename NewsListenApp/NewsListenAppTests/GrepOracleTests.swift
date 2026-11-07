import XCTest
@testable import NewsListenApp

/// spec.md §5.7 の grep oracle（O-1〜O-13）を、シェルではなく XCTest 内から直接ソースを
/// 読んで再現する「配線テスト」。手作業の grep 実行に依存せず自動テストとして
/// `xcodebuild test` の分子に数える（spec §5.6 coverage の 36/38 自動テスト分子の一部）。
///
/// 対応関係:
/// - T-T14-15（ios-contract-20.13）: O-1・O-2
/// - T-T14-24（ios-contract-20.19）: O-8・O-9・O-11・O-12・O-13
/// - T-T15-12（ios-contract-21.9）: O-6・O-7
/// - T-T17-06（ios-contract-23.6）: O-3・O-4・O-5
final class GrepOracleTests: XCTestCase {

    // MARK: - T-T14-15（ios-contract-20.13）: O-1・O-2

    // verifies: ios-contract-20.13
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

    // MARK: - T-T14-24（ios-contract-20.19）: O-8・O-9・O-11・O-12・O-13

    // verifies: ios-contract-20.19
    func testTT14_24_externalWriteGuardsAreWiredBeforeFirstAwait() {
        let files = SourceGrep.swiftFiles()

        // O-8: AppState の外から AppState を書く・呼ぶ箇所の全数（名前集合と件数）。
        let o8Matches = SourceGrep.matchedSubstrings(pattern: #"appState\??\.[A-Za-z]+( = |\()"#, in: files)
        var o8Counts: [String: Int] = [:]
        for match in o8Matches { o8Counts[match, default: 0] += 1 }
        let expectedO8: [String: Int] = [
            "appState.completeLogin(": 1,
            "appState.didRegisterDeviceToken(": 2,
            "appState.handleNotificationPodcastId(": 2,
            "appState.logout(": 1,
            "appState.refreshAuth(": 1,
            "appState.registerDownloads(": 1,
            "appState.registerPlaybackLifecycle(": 1,
            "appState.retryResolve(": 1,
            "appState.selectedPodcastId = ": 1,
            "appState.updateCurrentSubject(": 1,
        ]
        XCTAssertEqual(o8Counts, expectedO8, "主体ガード表 §3.1 の外部行と一致しない（表に無い書き手があれば RJ-5 により表を先に直す）")
        XCTAssertNil(o8Counts["appState.currentUser = "], "currentUser への直接代入は無くなるべき（computed 化）")

        let settingsViewURL = SourceGrep.appRoot.appendingPathComponent("Settings/SettingsView.swift")
        let preferencesStoreURL = SourceGrep.appRoot.appendingPathComponent("Settings/Application/PreferencesStore.swift")
        let accountSettingsViewModelURL = SourceGrep.appRoot.appendingPathComponent("Settings/AccountSettingsViewModel.swift")

        // O-9: revert 3 行すべてが同じ行で isCurrentSubject(stamp) を持つ（巻き戻しは PreferencesStore に移った）。
        let oldValueLines = SourceGrep.content(of: preferencesStoreURL).components(separatedBy: "\n").filter { $0.contains("= oldValue") }
        XCTAssertEqual(oldValueLines.count, 3, "revert 行数は 3 のままであるべき")
        let unguardedReverts = oldValueLines.filter { !$0.contains("isCurrentSubject(stamp)") }
        XCTAssertTrue(unguardedReverts.isEmpty, "revert は isCurrentSubject(stamp) を同じ行に持つべき: \(unguardedReverts)")

        // O-11: subjectStamp の出現数（捕捉の文の数と同じ）。
        XCTAssertEqual(SourceGrep.occurrenceCount(of: "subjectStamp", in: settingsViewURL), 0, "View は stamp を捕捉しない")
        XCTAssertEqual(SourceGrep.lineCount(containing: "let stamp = subjectStamp()", in: preferencesStoreURL), 4, "set 3 ＋ refreshFromServer 1")
        XCTAssertEqual(SourceGrep.occurrenceCount(of: "subjectStamp", in: accountSettingsViewModelURL), 1)

        // O-12: stamp の捕捉が、各書き手の最初の await より前にある。
        let storeTokens = orderedTokens(
            startPattern: #"func set(DefaultDifficulty|DefaultPlaybackSpeed|WeeklyGoal)\("#,
            captureText: "let stamp = subjectStamp()",
            in: preferencesStoreURL,
            startWord: "set"
        )
        let storeMatches = orderedMatches(tokens: storeTokens, startWord: "set")
        XCTAssertEqual(storeMatches.filter { $0 == "set let stamp await" }.count, 3)
        XCTAssertEqual(storeMatches.filter { $0 == "set await" }.count, 0, "捕捉を欠く区間が残っている")

        let accountTokens = orderedTokens(
            startPattern: #"func saveProfile\("#,
            captureText: "let stamp = appState.subjectStamp",
            in: accountSettingsViewModelURL,
            startWord: "func saveProfile"
        )
        let accountMatches = orderedMatches(tokens: accountTokens, startWord: "func saveProfile")
        XCTAssertEqual(accountMatches.filter { $0 == "func saveProfile let stamp await" }.count, 1)
        XCTAssertEqual(accountMatches.filter { $0 == "func saveProfile await" }.count, 0)

        // O-13: capturedAt: に渡すのが捕捉した stamp。
        XCTAssertEqual(SourceGrep.lineCount(containing: "capturedAt: stamp)", in: settingsViewURL), 0, "書き手は PreferencesStore に移り、capturedAt: は無くなった")
        XCTAssertEqual(SourceGrep.lineCount(containing: "capturedAt:", in: preferencesStoreURL), 0)
        XCTAssertEqual(SourceGrep.lineCount(containing: "capturedAt: stamp)", in: accountSettingsViewModelURL), 1)
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

    // MARK: - T-T15-12（ios-contract-21.9）: O-6・O-7

    // verifies: ios-contract-21.9
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

    // MARK: - T-T17-06（ios-contract-23.6）: O-3・O-4・O-5

    // verifies: ios-contract-23.6
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

    // MARK: - ios-slice-playback-01: Platform adapter の導入（T-G01〜T-G05・T-G08。spec §7.7 / SG-1b）

    /// SG-1b で訂正した AV / MP の型参照パターン。`AVPlayer` は型名 `AVPlayerEngine` に一致させない
    /// （`AVPlayer` の後ろが英字でないか、`AVPlayerItem`、または行末）。
    private static let platformTypePattern =
        #"AVPlayer(Item|[^A-Za-z]|$)|AVAudioSession|MPNowPlayingInfoCenter|MPRemoteCommandCenter"#

    private func nonCommentHits(pattern: String, in files: [URL]) -> [(path: String, line: Int, text: String)] {
        SourceGrep.matchingLines(pattern: pattern, in: files).filter { !SourceGrep.isCommentLine($0.text) }
    }

    // verifies: CI-G1（T-G01）
    func testG01_viewModelDoesNotImportAVFoundationOrMediaPlayer() {
        let vm = SourceGrep.appRoot.appendingPathComponent("Podcast/PodcastViewModel.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vm.path), "走査対象の VM が存在する")

        let hits = SourceGrep.matchingLines(pattern: #"^import (AVFoundation|MediaPlayer)\b"#, in: [vm])

        XCTAssertTrue(hits.isEmpty, "PodcastViewModel は AVFoundation / MediaPlayer を import しない: \(hits)")
    }

    // verifies: CI-G2（T-G02）
    func testG02_podcastViewModelTestsDoNotUseAVFoundationTypesOrVmPlayer() {
        let tests = SourceGrep.testRoot.appendingPathComponent("PodcastViewModelTests.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tests.path), "走査対象のテストファイルが存在する")

        let typeHits = nonCommentHits(pattern: #"AVPlayer|AVPlayerItem|CMTime|vm\.player"#, in: [tests])
        let importHits = SourceGrep.matchingLines(pattern: #"^import AVFoundation\b"#, in: [tests])

        XCTAssertTrue(typeHits.isEmpty, "AVFoundation 型・vm.player の参照が残っている: \(typeHits)")
        XCTAssertTrue(importHits.isEmpty, "import AVFoundation が残っている: \(importHits)")
    }

    // verifies: CI-G3（T-G03）
    func testG03_platformTypeReferencesExistOnlyInsidePlatformAndTheHelperWithControls() throws {
        let regex = try NSRegularExpression(pattern: Self.platformTypePattern)
        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }

        // ① 正の対照: パターンは AV / MP の型参照に一致する。
        XCTAssertTrue(matches("player = AVPlayer(playerItem: item)"))
        XCTAssertTrue(matches("AVPlayerItem(url: url)"))
        XCTAssertTrue(matches("options: AVAudioSession.InterruptionOptions"))
        // ② 負の対照: adapter の型名には一致しない（C-3）。
        XCTAssertFalse(matches("AVPlayerEngine()"))
        XCTAssertFalse(matches("let e: AVPlayerEngine"))

        // ③ 除外を適用する前の実ソースの結果に、純粋ヘルパと adapter の行が含まれる（走査が効いている確認）。
        let all = nonCommentHits(pattern: Self.platformTypePattern, in: SourceGrep.swiftFiles())
        XCTAssertTrue(all.contains { $0.path == "Podcast/Platform/NowPlayingInfo.swift" })
        XCTAssertTrue(all.contains { $0.path == "Podcast/Platform/AVPlayerEngine.swift" })

        // ④ 除外（Platform 配下）を適用した後は 0 件。
        let outside = all.filter { !$0.path.hasPrefix("Podcast/Platform/") }
        XCTAssertTrue(outside.isEmpty, "Platform の外に AV / MP の型参照がある: \(outside)")
    }

    // verifies: CI-G4（T-G04）
    func testG04_avPlayerIsCreatedInExactlyOnePlace() {
        let hits = nonCommentHits(pattern: #"AVPlayer\("#, in: SourceGrep.swiftFiles())

        XCTAssertEqual(hits.map { $0.path }, ["Podcast/Platform/AVPlayerEngine.swift"], "AVPlayer( の生成は adapter の 1 箇所だけ: \(hits)")
    }

    // verifies: CI-G5（T-G05）
    func testG05_playbackDirectoryExistsAndImportsNoPlatformFrameworks() {
        // ① ディレクトリが無いと走査 0 件で素通りするので、port の存在を先に確かめる（W-3）。
        let port = SourceGrep.appRoot.appendingPathComponent("Podcast/Playback/AudioEngine.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: port.path), "AudioEngine port が Podcast/Playback/ に存在する")

        // ② Playback/ 配下は Platform / UI のフレームワークを import しない。
        let playbackFiles = SourceGrep.swiftFiles().filter { SourceGrep.relativePath($0).hasPrefix("Podcast/Playback/") }
        XCTAssertFalse(playbackFiles.isEmpty)
        let hits = SourceGrep.matchingLines(pattern: #"^import (AVFoundation|MediaPlayer|UIKit|SwiftUI)\b"#, in: playbackFiles)
        XCTAssertTrue(hits.isEmpty, "Podcast/Playback/ が Platform / UI を import している: \(hits)")
    }

    // verifies: CI-G8, CI-R1（T-G08。SG-1(a)）
    func testG08_mediaPlayerNowPlayingIsCreatedOnlyAtTheDocumentedPlaces() {
        let hits = nonCommentHits(pattern: #"MediaPlayerNowPlaying\("#, in: SourceGrep.swiftFiles())
        var counts: [String: Int] = [:]
        for hit in hits { counts[hit.path, default: 0] += 1 }

        // App の 1 個（合成 root）と、AppState の既定引数（Preview とテスト用）だけ。facade は既定引数で作らない。
        XCTAssertEqual(counts, [
            "NewsListenAppApp.swift": 1,
            "AppState.swift": 1,
        ], "MediaPlayerNowPlaying( の生成箇所が想定と違う: \(hits)")
    }

    // MARK: - ios-slice-learning-03: 継続の application と音の置き場（T-W1〜T-W5）
    //
    // 音と SwiftUI の配線は XCTest から観測できない。振る舞いの代わりに配線の退行だけを字面で見る。

    private func appFile(_ relativePath: String) -> URL {
        SourceGrep.appRoot.appendingPathComponent(relativePath)
    }

    /// コメント行を除いた、パターンに当たる行。ファイルが無いときは空（呼出側で存在を確かめる）。
    private func codeHits(_ pattern: String, in relativePath: String) -> [(path: String, line: Int, text: String)] {
        nonCommentHits(pattern: pattern, in: [appFile(relativePath)])
    }

    private func assertFileExists(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: appFile(relativePath).path), "\(relativePath) が存在する", file: file, line: line)
    }

    /// `marker` を含む最初の非コメント行から、波括弧が閉じるまでの本体の文字列（見つからなければ nil）。
    private func braceBody(startingAt marker: String, in relativePath: String) -> String? {
        let lines = SourceGrep.content(of: appFile(relativePath)).components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(marker) && !SourceGrep.isCommentLine($0) }) else { return nil }
        var depth = 0
        var opened = false
        var collected: [String] = []
        for line in lines[start...] {
            collected.append(line)
            for character in line {
                if character == "{" { depth += 1; opened = true }
                if character == "}" { depth -= 1 }
            }
            if opened && depth <= 0 { break }
        }
        return collected.joined(separator: "\n")
    }

    // verifies: CI-25（T-W1）
    func testW1_streakRefreshOfAllCallersGoesThroughOneCelebratingFunction() {
        let root = "NewsListenAppApp.swift"
        let settings = "Settings/SettingsView.swift"
        assertFileExists(root)
        assertFileExists(settings)

        XCTAssertEqual(
            codeHits(#"refreshStreak: \{ await Self\.refreshStreakAndCelebrate\(engagementStore\) \}"#, in: root).count, 1,
            "ContentView へ渡す closure は合成 root の 1 つの関数だけを呼ぶ")
        XCTAssertEqual(codeHits(#"onCompletionRecorded: refreshStreak\b"#, in: root).count, 1, "完聴後の更新も同じ closure")
        XCTAssertEqual(
            codeHits(#"(^|[^.A-Za-z])await refreshStreak\(\)"#, in: root).count, 2,
            "起動の .task と scenePhase .active の 2 か所")
        XCTAssertEqual(
            codeHits(#"(^|[^.A-Za-z])await refreshStreak\(\)"#, in: settings).count, 2,
            "設定画面の .task と再試行の 2 か所")
        XCTAssertEqual(codeHits(#"engagement\.refreshStreak"#, in: settings).count, 0, "設定画面は store を直接呼ばない")

        let body = braceBody(startingAt: "func refreshStreakAndCelebrate", in: root)
        XCTAssertNotNil(body, "refreshStreakAndCelebrate が合成 root にある")
        XCTAssertNotNil(body?.range(of: #"if [^\n]*increased"#, options: .regularExpression), "増えたときだけ鳴らす")
        XCTAssertNotNil(body?.range(of: #"play\(\.streakUp\)"#, options: .regularExpression), "上昇音を鳴らす")
    }

    // verifies: CI-26（T-W2）
    func testW2_achievementSoundIsPlayedOnlyForNonEmptyNewValueOfNewlyUnlocked() {
        let view = "Learning/LearningView.swift"
        assertFileExists(view)

        let body = braceBody(startingAt: "onChange(of: viewModel.newlyUnlocked)", in: view)

        XCTAssertNotNil(body, "newlyUnlocked の変化を見る .onChange がある")
        XCTAssertNotNil(body?.range(of: #"isEmpty"#, options: .regularExpression), "閉じて空になったときは鳴らさない")
        XCTAssertNotNil(body?.range(of: #"play\(\.achievement\)"#, options: .regularExpression), "解錠音を鳴らす")
    }

    // verifies: CI-27（T-W3）
    func testW3_presentationReadsEngagementStoreWithTheSameDisplayConditions() {
        let toolbar = "DesignSystem/Components/DSStreakToolbar.swift"
        let settings = "Settings/SettingsView.swift"
        let learning = "Learning/LearningView.swift"
        for path in [toolbar, settings, learning] { assertFileExists(path) }

        XCTAssertEqual(codeHits(#"@ObservedObject var engagement\b"#, in: toolbar).count, 1)
        XCTAssertGreaterThanOrEqual(codeHits(#"streak\.isShown"#, in: toolbar).count, 1)

        XCTAssertEqual(codeHits(#"@ObservedObject private var engagement\b"#, in: settings).count, 1)
        XCTAssertGreaterThanOrEqual(codeHits(#"lastListenedDay"#, in: settings).count, 1)

        XCTAssertEqual(codeHits(#"@EnvironmentObject private var engagement\b"#, in: learning).count, 1)
        for needle in [
            #"engagement\.streak \?\? dashboard\.streak"#, #"dashboard\.weekly\b"#, #"weeklyHistory"#, #"monthlyListeningDays"#,
            #"quizTrend\.suffix\(3\)"#, #"firstEntries"#, #"\.term\b"#, #"\.meaning\b"#, #"registeredAt\.prefix\(10\)"#,
        ] {
            XCTAssertGreaterThanOrEqual(codeHits(needle, in: learning).count, 1, "LearningView が \(needle) を読む")
        }
        XCTAssertEqual(codeHits(#"firstTerms"#, in: learning).count, 0, "登録語彙の節は firstEntries を描く（firstTerms ではない）")
    }

    // verifies: CI-27（T-W4）。`\(…)` は補間で、変数名に依らず任意の文字列で受ける。
    func testW4_userVisibleWordingIsUnchangedPerFile() {
        let interpolation = #"\\\([^"]*\)"#
        let expectations: [(path: String, patterns: [String])] = [
            ("DesignSystem/Components/DSStreakToolbar.swift", [
                "\"\(interpolation)日連続\"",
                "聴取ストリーク \(interpolation)日連続",
            ]),
            ("Settings/SettingsView.swift", [
                "\"\(interpolation)日連続\"",
                "まだ聴取記録がありません",
                "最終聴取日: \(interpolation)",
                "本日聴取済み",
                "聴取ストリークの取得に失敗しました",
            ]),
            ("Learning/LearningView.swift", [
                "\"\(interpolation) 日連続\"",
                "今週 \(interpolation)/目標 \(interpolation) 本",
                "\(interpolation)本、目標\(interpolation)本",
                "今週の学習目標進捗",
                "目標: \(interpolation) → 実績: \(interpolation)",
                "目標\(interpolation)本、実績\(interpolation)本",
                "完聴エピソード数: \(interpolation) 本",
                "習得語彙数: \(interpolation) 語",
                "現在のレベル: \(interpolation)",
                "出題エピソード数: \(interpolation) 本",
                "平均正答率: %\\.1f%%",
                "平均正答率: 未確定",
                "解錠: \(interpolation)",
                "\"\(interpolation) 語\"",
                "\"\(interpolation) 日\"",
            ]),
        ]
        for (path, patterns) in expectations {
            assertFileExists(path)
            for pattern in patterns {
                XCTAssertGreaterThanOrEqual(codeHits(pattern, in: path).count, 1, "\(path) の文言が変わった: \(pattern)")
            }
        }
    }

    // verifies: CI-15（T-W5）。値では等価で LearningViewModelTests から観測できないので、配線で固定する。
    func testW5_viewModelMarksAllUnlockedIdsNotOnlyUnseenOnes() {
        let viewModel = "Learning/LearningViewModel.swift"
        assertFileExists(viewModel)

        let hits = codeHits(#"markAchievementsSeen\([^)]*achievements\.map\(\\\.id\)"#, in: viewModel)

        XCTAssertEqual(hits.count, 1, "解錠済みの全 id（achievements.map(\\.id)）を既読として渡す")
    }
}
