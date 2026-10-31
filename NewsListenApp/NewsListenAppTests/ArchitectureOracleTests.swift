import XCTest
@testable import NewsListenApp

/// 層の所属表（`ArchitectureManifest`）と依存方向の規則 ios-dep-* を、ソースを読んで検査する oracle。
/// `GrepOracleTests` と同じ方式（`SourceGrep` でコメント行を除いた行を集める）で、現状の違反は
/// `ArchitectureManifest.allowlist` の `(規則キー, path, 行数)` に固定する。許可リストの比較は**等号だけ**で、
/// 増えても減っても落ちる（減らした slice が同じ PR で一覧を減らす）。
///
/// 規則キー: ios-dep-02・ios-dep-03・ios-dep-04・ios-dep-05・ios-dep-06・ios-dep-08・ios-dep-11・ios-dep-12・ios-dep-13 と、ios-check-04 の 13 群（`ios-rule-…`）。
/// ios-dep-04・ios-dep-06 は検査が 2 つに分かれる（DTO の分は ios-test-059、それ以外は ios-test-064）ので、
/// DTO の分だけ `<規則 ID>/DTO` と書く。ios-dep-01・ios-dep-07・ios-dep-10 は 0 件が契約で、許可リストに行を持たない。
/// ios-dep-14（既存の検査を保つ）は ios-test-070 で検査する（`ci.yml:47` の grep を XCTest に入れたもの）。
final class ArchitectureOracleTests: XCTestCase {

    // MARK: - 走査の土台

    private var production: [URL] {
        SourceGrep.swiftFiles().sorted { SourceGrep.relativePath($0) < SourceGrep.relativePath($1) }
    }

    private var productionSources: [SourceFile] { ArchitectureScan.productionSources() }

    private func sources(inLayer layer: ArchitectureLayer) -> [SourceFile] {
        productionSources.filter { ArchitectureManifest.layer(of: $0.path) == layer }
    }

    private func filesInLayer(_ layer: ArchitectureLayer) -> [URL] {
        production.filter { ArchitectureManifest.layer(of: SourceGrep.relativePath($0)) == layer }
    }

    private func files(atRelativePaths paths: Set<String>) -> [URL] {
        production.filter { paths.contains(SourceGrep.relativePath($0)) }
    }

    /// presentation で `import SwiftUI` を持ち、`*ViewModel.swift` でないファイル。
    private var viewFiles: [URL] {
        filesInLayer(.presentation).filter { url in
            !url.lastPathComponent.hasSuffix("ViewModel.swift")
                && SourceGrep.content(of: url).components(separatedBy: "\n").contains { $0.hasPrefix("import SwiftUI") }
        }
    }

    private var viewModelFiles: [URL] {
        filesInLayer(.presentation).filter { $0.lastPathComponent.hasSuffix("ViewModel.swift") }
    }

    private var compositionRootFiles: [URL] { filesInLayer(.compositionRoot) }

    private var adapterFiles: [URL] { filesInLayer(.adapter) }

    private var nonAdapterFiles: [URL] {
        production.filter { ArchitectureManifest.layer(of: SourceGrep.relativePath($0)) != .adapter }
    }

    private var dtoNames: Set<String> { ArchitectureManifest.dtoTypeNames(in: adapterFiles) }

    /// adapter の層のファイルの宣言から導いた具象型（literal の型名表に依らない）。
    private var adapterConcrete: Set<String> { ArchitectureScan.adapterInventory(productionSources).concrete }

    private func relativePaths(_ files: [URL]) -> Set<String> { Set(files.map(SourceGrep.relativePath)) }

    /// 型名・属性名を単語境界で照合する正規表現（`@AppStorage` は属性として照合）。
    private func wordPattern(_ names: Set<String>) -> String {
        guard !names.isEmpty else { return #"(?!)"# }
        let alternatives = names.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return #"\b("# + alternatives + #")\b"#
    }

    private func constructionPattern(_ names: Set<String>) -> String {
        names.isEmpty ? #"(?!)"# : #"\b("# + names.sorted().joined(separator: "|") + #")\("#
    }

    private var uiFacilityPatterns: [String] {
        let typeNames = ArchitectureManifest.uiFacility.subtracting(["@AppStorage"])
        return [wordPattern(typeNames), #"@AppStorage\b"#]
    }

    /// パターンの和集合のどれかに当たれば true の照合器。不正な正規表現は黙って空振りさせず throw する。
    private func matcher(_ patterns: [String]) throws -> (String) -> Bool {
        let regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
        return { line in
            let range = NSRange(line.startIndex..., in: line)
            return regexes.contains { $0.firstMatch(in: line, range: range) != nil }
        }
    }

    // MARK: 数え上げ

    /// 行ごとに照合する。`excludeComments`: コメント行（先頭の空白の後が `//`）を除く（`SourceGrep.matchingLines` は除かないので自前で除く）。
    /// `excludeConditional`: `#if DEBUG` と `#Preview` の中を除く。結果は path・行の順。
    private func collectHits(
        in files: [URL],
        excludeComments: Bool = true,
        excludeConditional: Bool = false,
        where isHit: (String) -> Bool
    ) -> [ScanHit] {
        var hits: [ScanHit] = []
        for file in files {
            let path = SourceGrep.relativePath(file)
            let lines = SourceGrep.content(of: file).components(separatedBy: "\n")
            let skipped = excludeConditional ? ArchitectureScan.debugAndPreviewExcludedLines(lines) : []
            for (offset, line) in lines.enumerated() {
                if excludeComments && SourceGrep.isCommentLine(line) { continue }
                if skipped.contains(offset) { continue }
                if isHit(line) { hits.append(ScanHit(path: path, line: offset + 1, text: line)) }
            }
        }
        return hits.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    private func lineCounts(_ hits: [ScanHit]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for hit in hits { counts[hit.path, default: 0] += 1 }
        return counts
    }

    private func describe(_ hits: [ScanHit]) -> String {
        hits.map { "\($0.path):\($0.line): \($0.text.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    // MARK: 前提の assert（読み取り失敗・空の集合で合格しない）

    private func assertNonEmptyContents(_ files: [URL], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(files.isEmpty, "\(label): 量化する集合が空", file: file, line: line)
        let empty = files.filter { SourceGrep.content(of: $0).isEmpty }.map(SourceGrep.relativePath)
        XCTAssertTrue(empty.isEmpty, "\(label): 読み取りに失敗した（空の）ファイル: \(empty)", file: file, line: line)
    }

    private func assertContains(_ files: [URL], _ known: [String], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let paths = relativePaths(files)
        for name in known {
            XCTAssertTrue(paths.contains(name), "\(label): 既知のファイルが集合に無い: \(name)", file: file, line: line)
        }
    }

    private func assertContainsHit(_ hits: [ScanHit], path: String, fragment: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            hits.contains { $0.path == path && $0.text.contains(fragment) },
            "\(label): 正の対照が除外の前の集合に無い: \(path) の `\(fragment)`",
            file: file, line: line
        )
    }

    // MARK: 許可リストとの比較

    /// 規則キー `rule` について、実測の `path → 行数`（> 0 のみ）と許可リストの `rule` の行が**等しい**ことを要求する。
    /// 一覧の行数が 0 以下の行は、写像の比較とは別に fail させる。比較は等号だけ。
    private func assertAllowlistMatches(
        rule: String,
        measured hits: [ScanHit],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let measured = lineCounts(hits)
        let entries = ArchitectureManifest.allowlist.filter { $0.rule == rule }
        var allowed: [String: Int] = [:]
        for entry in entries { allowed[entry.path, default: 0] += entry.lines }
        var problems: [String] = []
        for entry in entries where entry.lines <= 0 {
            problems.append("[\(rule)] \(entry.path): 一覧の行数が 0 以下（\(entry.lines)）")
        }
        for path in Set(measured.keys).union(allowed.keys).sorted() {
            let actual = measured[path] ?? 0
            let listed = allowed[path] ?? 0
            if actual != listed {
                problems.append("[\(rule)] \(path): 実測=\(actual) 一覧=\(listed) 差(実測-一覧)=\(actual - listed)")
            }
        }
        if !problems.isEmpty {
            let snippet = measured.keys.sorted().map { "(\"\(rule)\", \"\($0)\", \(measured[$0] ?? 0))," }.joined(separator: "\n")
            XCTFail("許可リストと実測が一致しない:\n" + problems.joined(separator: "\n") + "\n実測から作る一覧:\n" + snippet, file: file, line: line)
        }
    }

    private func assertNoHits(_ hits: [ScanHit], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(hits.isEmpty, "\(label) は 0 件であること。違反:\n\(describe(hits))", file: file, line: line)
    }

    // MARK: ios-check-04 の群

    private struct LiteralGroup {
        let key: String
        let pattern: String
        let isCanonical: (String, ArchitectureLayer?) -> Bool
        let excludesPath: (String) -> Bool
        let controlPath: String
        let controlFragment: String
    }

    private var literalGroups: [LiteralGroup] {
        func exact(_ paths: String...) -> (String, ArchitectureLayer?) -> Bool { { path, _ in paths.contains(path) } }
        let never: (String) -> Bool = { _ in false }
        return [
            LiteralGroup(key: "ios-rule-catalog-01・ios-rule-catalog-02", pattern: #""(completed|processing|failed|partial_failed)""#,
                         isCanonical: exact("Models/Podcast+Episode.swift"), excludesPath: never,
                         controlPath: "Models/Podcast+Episode.swift", controlFragment: #"case "processing":"#),
            LiteralGroup(key: "ios-rule-catalog-03", pattern: #"==\s*"featured""#,
                         isCanonical: exact("Catalog/Domain/EpisodeContent.swift"), excludesPath: never,
                         controlPath: "Catalog/Domain/EpisodeContent.swift", controlFragment: #"sourceKind == "featured""#),
            LiteralGroup(key: "ios-rule-playback-05", pattern: #"max\(0,\s*(\w+\.)?currentTime\b|min\(\s*(\w+\.)?duration\s*,"#,
                         isCanonical: { path, _ in path.hasPrefix("Podcast/Playback/Domain/") }, excludesPath: never,
                         controlPath: "Podcast/Playback/Domain/PlaybackRules.swift", controlFragment: "min(duration, lowerBounded)"),
            LiteralGroup(key: "ios-rule-playback-04", pattern: #"\[\s*(0\.5\s*,\s*)?0\.75\s*,\s*1\.0\s*,\s*1\.25"#,
                         isCanonical: exact("Podcast/PlaybackConstants.swift", "Podcast/Playback/Domain/PlaybackConstants.swift"), excludesPath: never,
                         controlPath: "Settings/SettingsView.swift", controlFragment: "playbackSpeeds"),
            LiteralGroup(key: "ios-rule-account-01", pattern: #"\.count\s*(>=|<)\s*[0-9]+"#,
                         isCanonical: exact("Auth/Domain/PasswordPolicy.swift"), excludesPath: never,
                         controlPath: "Settings/AccountSettingsView.swift", controlFragment: "newPassword.count >= 8"),
            LiteralGroup(key: "ios-rule-account-05", pattern: #""(admin|user)""#,
                         isCanonical: exact("Auth/Domain/Subject.swift"), excludesPath: { $0 == "Passkey/PasskeyOptionsDecoder.swift" },
                         controlPath: "Admin/AdminUsersViewModel.swift", controlFragment: #""user" : "admin""#),
            LiteralGroup(key: "ios-rule-account-06・ios-rule-curation-04・ios-rule-sources-02・ios-rule-learning-08", pattern: #"catch\s+ApiFailure\.(notFound\(subject|conflict\b)"#,
                         isCanonical: { path, layer in layer == .application || path.hasPrefix("Networking/") }, excludesPath: never,
                         controlPath: "AppState.swift", controlFragment: "catch ApiFailure.notFound(subject: .streak)"),
            LiteralGroup(key: "ios-rule-prefs-01", pattern: #""(toeic_600|toeic_900|ielts_55|ielts_7|eiken_2|eiken_p1)""#,
                         isCanonical: exact("Shared/Domain/DifficultyLevel.swift"), excludesPath: never,
                         controlPath: "Utilities/DifficultyLabel.swift", controlFragment: #"case "toeic_600":"#),
            LiteralGroup(key: "ios-rule-prefs-02", pattern: #"\[3,\s*5,\s*7,\s*10\]"#,
                         isCanonical: exact("Settings/Domain/WeeklyGoalTarget.swift"), excludesPath: never,
                         controlPath: "Settings/PreferenceRegistry.swift", controlFragment: "[3, 5, 7, 10].contains"),
            LiteralGroup(key: "ios-rule-prefs-03", pattern: #""(absolute|relative)""#,
                         isCanonical: exact("Settings/Domain/TimeFormat.swift"), excludesPath: never,
                         controlPath: "Settings/SettingsView.swift", controlFragment: #".tag("absolute")"#),
            LiteralGroup(key: "ios-rule-curation-03", pattern: #"\blimit\s*==\s*0\b"#,
                         isCanonical: exact("Feed/Domain/GenerationAllowance.swift"), excludesPath: never,
                         controlPath: "Settings/SettingsView.swift", controlFragment: "quota.limit == 0"),
            LiteralGroup(key: "ios-rule-learning-07", pattern: #">=\s*0\.5\b"#,
                         isCanonical: exact("Learning/Domain/QuizAttempt.swift"), excludesPath: never,
                         controlPath: "Podcast/QuizSheetView.swift", controlFragment: "correctRate >= 0.5"),
        ]
    }

    private let vocabularyKey = "ios-rule-learning-05"
    private let vocabularyCanonicalPath = "Learning/Domain/VocabularyTest.swift"

    /// `ios-rule-learning-05`: 日付の切り出し `String(<識別子の連鎖>.prefix(10))` の部分文字列だけを取り除き、
    /// 残りに `.prefix(10)` があれば数える（同じ行の出題の上限の式を見落とさない）。
    private func vocabularyLimitLineIsViolation(_ line: String) -> Bool {
        let datePattern = #"String\(\s*[A-Za-z_][\w.]*\.prefix\(10\)\s*\)"#
        let stripped = line.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        return stripped.range(of: #"\.prefix\(10\)"#, options: .regularExpression) != nil
    }

    /// 許可リストの規則キー（一致を検査するもの）。(規則キー, path) の構造の整合に使う。
    private var knownRuleKeys: Set<String> {
        let partKeys: Set<String> = [
            "ios-dep-02", "ios-dep-03", "ios-dep-04", "ios-dep-04/DTO", "ios-dep-05", "ios-dep-06", "ios-dep-06/DTO", "ios-dep-08", "ios-dep-11", "ios-dep-12", "ios-dep-13",
        ]
        let ledgerQueryKeys = Set(ArchitectureManifest.operationLedger.compactMap { row -> String? in
            if case .query(let id) = row.kind { return "ios-check-15/verifies/" + id }
            return nil
        })
        let derivedKeys: Set<String> = ["ios-check-16", "ios-check-15/read-write"]
        return partKeys.union(literalGroups.map(\.key)).union([vocabularyKey]).union(derivedKeys).union(ledgerQueryKeys)
    }

    // MARK: - ios-check-01

    // verifies: ios-check-01（ios-dep-10）
    func testIosTest053_everyProductionFileBelongsToExactlyOneLayer() throws {
        // 正の対照: 規則 (3) と (5) の両方に当たる合成の path は 2 層、どれにも当たらない path は 0 層。
        XCTAssertEqual(ArchitectureManifest.matchedLayers(of: "Podcast/Playback/DummyView.swift"), [.application, .presentation])
        XCTAssertEqual(ArchitectureManifest.matchedLayers(of: "Misc/Dummy.swift"), [])
        XCTAssertNil(ArchitectureManifest.layer(of: "Podcast/Playback/DummyView.swift"))
        XCTAssertNil(ArchitectureManifest.layer(of: "Misc/Dummy.swift"))
        // 負の対照: 同じ規則の複数パターン（`*View.swift` と `*Sheet*.swift`）は 1 層に数える。明示の行は規則を上書きする。
        XCTAssertEqual(ArchitectureManifest.matchedLayers(of: "Podcast/QuizSheetView.swift"), [.presentation])
        XCTAssertEqual(ArchitectureManifest.layer(of: "Models/FeaturedCategory.swift"), .domain)

        let all = production
        assertNonEmptyContents(all, "production")
        assertContains(all, ["AppState.swift", "NewsListenAppApp.swift", "Podcast/QuizSheetView.swift"], "production")

        let paths = relativePaths(all)
        let explicitMissing = ArchitectureManifest.explicitLayers.keys.filter { !paths.contains($0) }.sorted()
        XCTAssertTrue(explicitMissing.isEmpty, "明示の行の path が production に無い: \(explicitMissing)")

        let assignment = ArchitectureScan.layerAssignment(paths: all.map(SourceGrep.relativePath))
        XCTAssertTrue(assignment.unclassified.isEmpty, "どの規則にも当たらないファイル: \(assignment.unclassified)")
        XCTAssertTrue(assignment.overlapped.isEmpty, "2 つ以上の規則に当たるファイル: \(assignment.overlapped)")
        // 正の対照: 純関数の経路でも、重複する path を足すと重複として返る（空の集合で合格しない）。
        let withDuplicate = ArchitectureScan.layerAssignment(paths: all.map(SourceGrep.relativePath) + ["Podcast/Playback/DummyView.swift"])
        XCTAssertEqual(withDuplicate.overlapped, ["Podcast/Playback/DummyView.swift"])
        XCTAssertTrue(withDuplicate.unclassified.isEmpty)

        // 許可リストの構造の整合（行数の値は読まない。値は規則キーを検査するテストだけが見る）。
        let known = knownRuleKeys
        let forbiddenKeys: Set<String> = ["ios-dep-01", "ios-dep-07", "ios-dep-10"]
        var seen: Set<String> = []
        for entry in ArchitectureManifest.allowlist {
            XCTAssertTrue(known.contains(entry.rule), "未知の規則キー: \(entry.rule)（\(entry.path)）")
            XCTAssertFalse(forbiddenKeys.contains(entry.rule), "0 件が契約の規則に許可リストの行がある: \(entry.rule)（\(entry.path)）")
            XCTAssertTrue(paths.contains(entry.path), "許可リストの path が production に無い: \(entry.path)")
            XCTAssertTrue(seen.insert(entry.rule + "\u{0}" + entry.path).inserted, "(規則キー, path) が重複: \(entry.rule) \(entry.path)")
        }
    }

    // verifies: ios-check-01（ios-dep-01）
    func testIosTest054_domainImportsOnlyFoundationAndNamesNoAdapterOrPersistence() throws {
        let patterns = [
            #"^\s*import\s+(?!Foundation\b)\w+"#,
            #"\b(Codable|Decodable|Encodable|CodingKeys?|UserDefaults|ObservableObject|URLSession|FileManager)\b"#,
            #"@Published\b"#,
            wordPattern(adapterConcrete),
        ]
        let isViolation = try matcher(patterns)
        // 正の対照: 禁止の import・属性に当たる。負の対照: Foundation の import と `CodingKeysFoo` に当たらない。
        XCTAssertTrue(isViolation("import UIKit"))
        XCTAssertTrue(isViolation("    @Published var x = 0"))
        XCTAssertTrue(isViolation("let c = APIClient()"))
        XCTAssertFalse(isViolation("import Foundation"))
        XCTAssertFalse(isViolation("struct CodingKeysFoo {}"))

        let domain = filesInLayer(.domain)
        assertNonEmptyContents(domain, "domain")
        assertContains(domain, ["Podcast/Playback/Domain/PlaybackQueue.swift", "Catalog/Domain/TranscriptTiming.swift"], "domain")
        assertNoHits(collectHits(in: domain, where: isViolation), "ios-dep-01（domain の import と型名）")
    }

    // verifies: ios-check-01（ios-dep-03）
    func testIosTest055_applicationDependsOnlyOnAllowedFrameworksAndNames() throws {
        let patterns = [
            #"^\s*import\s+(?!(Foundation|Combine|os)\b)\w+"#,
            wordPattern(adapterConcrete),
        ] + uiFacilityPatterns + [wordPattern(dtoNames)]
        let isViolation = try matcher(patterns)
        // 負の対照: 許可された import に当たらない。
        XCTAssertFalse(isViolation("import Combine"))
        XCTAssertFalse(isViolation("import os"))
        XCTAssertTrue(isViolation("import SwiftUI"))

        let application = filesInLayer(.application)
        assertNonEmptyContents(application, "application")
        assertContains(application, ["AppState.swift"], "application")
        let hits = collectHits(in: application, where: isViolation)
        assertContainsHit(hits, path: "AppState.swift", fragment: "KeychainSessionStore()", "ios-dep-03")
        assertAllowlistMatches(rule: "ios-dep-03", measured: hits)
    }

    // verifies: ios-check-01（ios-dep-07）
    func testIosTest056_adapterNamesNoViewModelOrAppStateAndNoSwiftUI() throws {
        let isViolation = try matcher([
            #"\b[A-Za-z_]\w*ViewModel\b"#,
            #"\bAppState\b"#,
            #"^\s*import\s+SwiftUI\b"#,
        ])
        XCTAssertTrue(isViolation("    let vm: FeedViewModel"))
        XCTAssertTrue(isViolation("import SwiftUI"))
        XCTAssertFalse(isViolation("import Foundation"))

        let adapter = adapterFiles
        assertNonEmptyContents(adapter, "adapter")
        assertContains(adapter, ["Observability/CrashReporter.swift", "Networking/APIClient.swift"], "adapter")
        // 実ファイルの対照: コメント除外の前の集合に CrashReporter のコメント行（`AppState` を含む）があり、除外の後には無い。
        let withComments = collectHits(in: adapter, excludeComments: false, where: isViolation)
        XCTAssertTrue(
            withComments.contains { $0.path == "Observability/CrashReporter.swift" && SourceGrep.isCommentLine($0.text) },
            "コメント行の対照が除外の前の集合に無い"
        )
        assertNoHits(collectHits(in: adapter, where: isViolation), "ios-dep-07（adapter の ViewModel・AppState・SwiftUI）")
    }

    // verifies: ios-check-01（ios-dep-13）
    func testIosTest057_adapterConcreteIsConstructedOnlyInCompositionRootOrDebug() throws {
        // 合成テキスト: `#if DEBUG` と `#Preview` の中は数えず、`#if canImport` の `#else` の後と DEBUG の `#else` 側は数える。
        let synthetic = """
        #if DEBUG
        let a = APIClient()
        #Preview {
            let b = APIClient()
        }
        #if canImport(UIKit)
        let c = APIClient()
        #endif
        #else
        let d = APIClient()
        #endif
        #if canImport(UIKit)
        let e = 1
        #else
        let f = APIClient()
        #endif
        #Preview("x") {
            Text("y")
            let g = APIClient()
        }
        let h = APIClient()
        """
        let syntheticFiles = [SourceFile(path: "Fixture/Application/Synthetic.swift", text: synthetic)]
        let syntheticInventory = AdapterInventory(concrete: ["APIClient"], dto: [], pureValue: [], excludedPrivate: [], aliases: [:], factories: [])
        let syntheticHits = ArchitectureScan.adapterConstructionHits(syntheticFiles, inventory: syntheticInventory)
        XCTAssertEqual(syntheticHits.map(\.text), ["let d = APIClient()", "let f = APIClient()", "let h = APIClient()"])

        let sources = productionSources
        assertNonEmptyContents(production, "production")
        let inventory = ArchitectureScan.adapterInventory(sources)
        XCTAssertFalse(inventory.concrete.isEmpty, "導出した具象型が空では生成を検出できない")
        let hits = ArchitectureScan.adapterConstructionHits(sources, inventory: inventory)

        // 実ファイルの対照: 除外の前の集合に LearningView の Preview の行がある。
        let isConstruction = try matcher([constructionPattern(inventory.concrete)])
        let targets = production.filter { ArchitectureManifest.layer(of: SourceGrep.relativePath($0)) != .compositionRoot }
        let beforeExclusion = collectHits(in: targets, where: isConstruction)
        XCTAssertTrue(beforeExclusion.contains { $0.path == "Learning/LearningView.swift" }, "LearningView の Preview の行が除外の前の集合に無い")
        // 負の対照: コメント除外の前の集合に `///` で始まり生成の形を含む行があり、除外の後には同じファイルの `///` の行が無い。
        let withComments = collectHits(in: targets, excludeComments: false, where: isConstruction)
        XCTAssertTrue(
            withComments.contains { $0.path == "AppState.swift" && $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("///") && $0.text.contains("AudioCacheManager()") },
            "doc コメントの対照が除外の前の集合に無い"
        )
        XCTAssertFalse(
            hits.contains { $0.path == "AppState.swift" && $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("///") },
            "doc コメントが数えられている"
        )
        assertAllowlistMatches(rule: "ios-dep-13", measured: hits)
    }

    // MARK: - ios-check-03

    // verifies: ios-check-03（ios-dep-02）
    func testIosTest058_domainNamesNoDTO() throws {
        let isDTO = try matcher([wordPattern(dtoNames)])
        let domain = filesInLayer(.domain)
        assertNonEmptyContents(domain, "domain")
        let hits = collectHits(in: domain, where: isDTO)
        XCTAssertTrue(hits.contains { $0.path == "Models/FeaturedCategory.swift" }, "FeaturedCategory の DTO の行が集合に無い")
        assertAllowlistMatches(rule: "ios-dep-02", measured: hits)
    }

    // verifies: ios-check-03（ios-dep-04・ios-dep-06 の DTO の分）
    func testIosTest059_presentationNamesNoDTO() throws {
        let names = dtoNames
        XCTAssertEqual(names.count, 39, "DTO は 39 個（ios-slice-foundation-01 で葉の値型 4 つが domain へ）")
        let isDTO = try matcher([wordPattern(names)])
        // 負の対照: 単語境界で照合する（`Podcast` が `PodcastViewModel` に当たらない）。
        let podcastOnly = try matcher([wordPattern(["Podcast"])])
        XCTAssertTrue(podcastOnly("let p: Podcast"))
        XCTAssertFalse(podcastOnly("let vm = PodcastViewModel()"))

        let views = viewFiles
        let viewModels = viewModelFiles
        assertNonEmptyContents(views, "View ファイル")
        assertNonEmptyContents(viewModels, "ViewModel ファイル")
        let viewHits = collectHits(in: views, where: isDTO)
        let viewModelHits = collectHits(in: viewModels, where: isDTO)
        XCTAssertTrue(viewHits.contains { $0.path == "Podcast/PodcastView.swift" }, "View の DTO の行が集合に無い")
        XCTAssertTrue(viewModelHits.contains { $0.path == "Podcast/PodcastViewModel.swift" }, "ViewModel の DTO の行が集合に無い")
        assertAllowlistMatches(rule: "ios-dep-04/DTO", measured: viewHits)
        assertAllowlistMatches(rule: "ios-dep-06/DTO", measured: viewModelHits)
    }

    // verifies: ios-check-03（ios-dep-08）
    func testIosTest060_codableAppearsOnlyInAdapter() throws {
        let isCodable = try matcher([#"\b(Codable|Decodable|Encodable|CodingKeys?|JSONDecoder|JSONEncoder)\b"#])
        let targets = nonAdapterFiles
        assertNonEmptyContents(targets, "adapter 以外")
        // 正の対照: 判定の式は adapter 外に書かれた生成の行に当たる（許可リストが空でも、この式が検出力を持つことを示す）。
        XCTAssertTrue(isCodable("let decoder = JSONDecoder()"), "Codable の判定の式が JSONDecoder の行に当たらない")
        XCTAssertFalse(isCodable("let decoded = decodeSomething()"))
        let hits = collectHits(in: targets, where: isCodable)
        assertAllowlistMatches(rule: "ios-dep-08", measured: hits)
    }

    // verifies: ios-check-03（ios-dep-11）
    func testIosTest061_portDeclarationsNameNoFrameworkOrDTO() throws {
        let patterns = [
            wordPattern(dtoNames),
            #"\bAV[A-Z]\w*"#,
            #"\bMP[A-Z]\w*"#,
            #"\bUI[A-Z]\w*"#,
            #"\bURLRequest\b"#,
            #"\bHTTPURLResponse\b"#,
            #"\[String:\s*Any\]"#,
        ]
        let isViolation = try matcher(patterns)
        // 負の対照: `UInt` は `UI*` に、`NAVItem` は `AV*` に当たらない。
        XCTAssertFalse(isViolation("let n: UInt"))
        XCTAssertFalse(isViolation("let item: NAVItem"))
        XCTAssertTrue(isViolation("let player: AVPlayer"))
        // 正の対照: port が MediaPlayer の辞書や framework の型を取る宣言は違反として検出される。
        XCTAssertTrue(isViolation("func update(_ info: [String: Any])"))
        XCTAssertTrue(isViolation("let c: MPNowPlayingInfoCenter"))

        let ports = files(atRelativePaths: ArchitectureManifest.portFiles)
        XCTAssertEqual(ports.count, ArchitectureManifest.portFiles.count, "portFiles の path が production に無い")
        assertNonEmptyContents(ports, "portFiles")
        let hits = collectHits(in: ports, where: isViolation)
        XCTAssertTrue(ports.contains { SourceGrep.relativePath($0) == "Podcast/Playback/NowPlayingCenter.swift" }, "実ソースの走査対象に NowPlayingCenter が入っていない")
        assertAllowlistMatches(rule: "ios-dep-11", measured: hits)
    }

    // MARK: - ios-check-04

    // verifies: ios-check-04（群ごとの規則キー: ios-rule-catalog-01・ios-rule-catalog-02 ほか 13 群）
    func testIosTest062_ruleLiteralsLiveOnlyInTheirCanonicalPlace() throws {
        let all = production
        assertNonEmptyContents(all, "production")

        // ios-rule-learning-05 の日付の除外は一致の単位（合成の対照）。
        XCTAssertTrue(vocabularyLimitLineIsViolation("let firstTen = Array(items.prefix(10)); let label = String(items.count)"))
        XCTAssertFalse(vocabularyLimitLineIsViolation("Text(String(item.registeredAt.prefix(10)))"))
        XCTAssertTrue(vocabularyLimitLineIsViolation("return String(article.publishedAt.prefix(10)) + Array(xs.prefix(10)).description"))

        // 負の対照（ios-rule-playback-05）: 添字の丸めは「現在位置・総時間」の式に当たらない。
        let playbackClamp = try matcher([literalGroups.first { $0.key == "ios-rule-playback-05" }!.pattern])
        XCTAssertFalse(playbackClamp("let a = max(0, elapsed)"))
        XCTAssertFalse(playbackClamp("let b = min(index, articles.count)"))
        XCTAssertTrue(playbackClamp("seek(to: max(0, vm.currentTime - 15))"))

        for group in literalGroups {
            let isLiteral = try matcher([group.pattern])
            let candidates = collectHits(in: all, excludeConditional: true, where: isLiteral)
            let beforeExclusion = collectHits(in: all, where: isLiteral)
            assertContainsHit(beforeExclusion, path: group.controlPath, fragment: group.controlFragment, group.key)
            let outside = candidates.filter { hit in
                !group.isCanonical(hit.path, ArchitectureManifest.layer(of: hit.path)) && !group.excludesPath(hit.path)
            }
            assertAllowlistMatches(rule: group.key, measured: outside)
        }

        // ios-rule-learning-05: 日付の切り出しを一致の単位で除く。除外の前は日付の行も含み、除外の後は出題の上限の式だけが残る。
        let isPrefix = try matcher([#"\.prefix\(10\)"#])
        let beforeExclusion = collectHits(in: all, where: isPrefix)
        XCTAssertTrue(beforeExclusion.contains { $0.path == "Settings/AccountSettingsView.swift" }, "日付の切り出しの行が除外の前の集合に無い")
        let violations = collectHits(in: all, excludeConditional: true, where: vocabularyLimitLineIsViolation)
            .filter { $0.path != vocabularyCanonicalPath }
        XCTAssertTrue(violations.contains { $0.path == "Models/VocabularyModels.swift" && $0.text.contains("Array(items.prefix(10))") }, "出題の上限の式が集合に無い")
        XCTAssertFalse(violations.contains { $0.path == "Settings/AccountSettingsView.swift" }, "日付の切り出しが数えられている")
        assertAllowlistMatches(rule: vocabularyKey, measured: violations)
    }

    // MARK: - ios-check-05

    // verifies: ios-check-05（ios-dep-05）
    func testIosTest063_viewsDoNotAssignViewModelOrAppState() throws {
        let owner = #"\b(viewModel|vm|appState|[A-Za-z_]\w*ViewModel)\??(\.[A-Za-z_]\w*)+"#
        let isAssignment = try matcher([owner + #"\s*=(?!=)"#, owner + #"\.toggle\(\)"#])
        // 正の対照: 代入と toggle に当たる。負の対照: 比較・不等号・複合代入は代入でない。
        XCTAssertTrue(isAssignment("    viewModel.errorMessage = nil"))
        XCTAssertTrue(isAssignment("    vm.isLoading.toggle()"))
        XCTAssertFalse(isAssignment("    if viewModel.errorMessage == nil {"))
        XCTAssertFalse(isAssignment("    if appState.x != y {"))
        XCTAssertFalse(isAssignment("    count += 1"))

        let targets = viewFiles + compositionRootFiles
        assertNonEmptyContents(targets, "View ファイル＋合成 root")
        assertContains(targets, ["NewsListenAppApp.swift", "Settings/SettingsView.swift"], "View ファイル＋合成 root")
        let hits = collectHits(in: targets, where: isAssignment)
        assertContainsHit(hits, path: "NewsListenAppApp.swift", fragment: "appState.selectedPodcastId = nil", "ios-dep-05")
        assertAllowlistMatches(rule: "ios-dep-05", measured: hits)
    }

    // verifies: ios-check-05（ios-dep-04・ios-dep-06 の DTO を除く分）
    func testIosTest064_presentationDoesNotKnowAdapters() throws {
        let views = viewFiles
        let viewModels = viewModelFiles
        assertNonEmptyContents(views, "View ファイル")
        assertNonEmptyContents(viewModels, "ViewModel ファイル")
        assertContains(views, ["Settings/SettingsView.swift"], "View ファイル")
        assertContains(viewModels, ["Feed/FeedViewModel.swift"], "ViewModel ファイル")

        let viewMatcher = try matcher([#"\bAPIClient\b"#, #"\bApiFailure\b"#, #"\bUserDefaults\b"#, #"@AppStorage\b"#])
        let viewModelMatcher = try matcher(
            [#"\bAPIClient\b"#, wordPattern(adapterConcrete)] + uiFacilityPatterns + [#"^\s*import\s+(UIKit|SwiftUI)\b"#]
        )
        let viewHits = collectHits(in: views, where: viewMatcher)
        let viewModelHits = collectHits(in: viewModels, where: viewModelMatcher)
        assertContainsHit(viewHits, path: "Settings/SettingsView.swift", fragment: "@AppStorage", "ios-dep-04")
        assertAllowlistMatches(rule: "ios-dep-04", measured: viewHits)
        assertAllowlistMatches(rule: "ios-dep-06", measured: viewModelHits)
    }

    // MARK: - ios-check-06

    // verifies: ios-check-06（ios-dep-12）
    func testIosTest065_writablePublishedIsOnlyDraftAllowlist() throws {
        let published = try NSRegularExpression(pattern: #"@Published\s+var\s+(\w+)"#)
        func publishedName(_ line: String) -> String? {
            guard !line.contains("private(set)") else { return nil }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = published.firstMatch(in: line, range: range), let nameRange = Range(match.range(at: 1), in: line) else { return nil }
            return String(line[nameRange])
        }
        XCTAssertEqual(publishedName("    @Published var title = \"\""), "title")
        XCTAssertNil(publishedName("    @Published private(set) var title = \"\""))

        let application = filesInLayer(.application)
        let viewModels = viewModelFiles
        assertNonEmptyContents(application, "application")
        assertNonEmptyContents(viewModels, "ViewModel ファイル")

        // 入力の下書き 6 個が実在する。
        for draft in ArchitectureManifest.publishedDraftAllowlist {
            let url = viewModels.first { SourceGrep.relativePath($0) == draft.file }
            XCTAssertNotNil(url, "下書きのファイルが ViewModel ファイルに無い: \(draft.file)")
            let present = url.map { file in
                SourceGrep.content(of: file).components(separatedBy: "\n").contains { publishedName($0) == draft.name }
            } ?? false
            XCTAssertTrue(present, "下書きの `@Published var \(draft.name)` が無い: \(draft.file)")
        }

        let drafts = Set(ArchitectureManifest.publishedDraftAllowlist.map { $0.file + "\u{0}" + $0.name })
        let applicationHits = collectHits(in: application) { publishedName($0) != nil }
        let viewModelHits = viewModels.flatMap { url -> [ScanHit] in
            let path = SourceGrep.relativePath(url)
            return collectHits(in: [url]) { line in
                guard let name = publishedName(line) else { return false }
                return !drafts.contains(path + "\u{0}" + name)
            }
        }
        XCTAssertTrue(applicationHits.contains { $0.path == "AppState.swift" }, "AppState の @Published が集合に無い")
        assertAllowlistMatches(rule: "ios-dep-12", measured: applicationHits + viewModelHits)
    }

    // verifies: ios-check-06（ios-dep-09）
    func testIosTest066_readModelFilesMatchNowPlayingAndEpisodeRow() {
        XCTAssertEqual(
            ArchitectureManifest.readModelFiles,
            ["Podcast/Playback/NowPlaying.swift", "Catalog/Application/EpisodeRow.swift"])
    }

    // MARK: - ios-check-08

    // verifies: ios-check-08
    func testIosTest068_domainTestsUseNoIO() throws {
        let isIO = try matcher([#"\b(URLSession|UserDefaults|FileManager|MockURLSession)\b"#, #"^\s*import\s+UIKit\b"#])
        XCTAssertTrue(isIO("let s = URLSession.shared"))
        XCTAssertTrue(isIO("import UIKit"))
        XCTAssertFalse(isIO("import XCTest"))

        let urls = ArchitectureManifest.domainTestFiles.sorted().map { SourceGrep.testRoot.appendingPathComponent($0) }
        XCTAssertEqual(urls.count, ArchitectureManifest.domainTestFiles.count)
        for url in urls {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "domain のテストファイルが無い: \(url.lastPathComponent)")
        }
        assertNonEmptyContents(urls, "domainTestFiles")
        assertNoHits(collectHits(in: urls, where: isIO), "ios-check-08（domain のテストの I/O）")
    }

    // MARK: - ios-check-10

    // verifies: ios-check-10（ios-dep-14。ci.yml の `statusCode ==|httpError(` の grep と同じ判定。コメント行は除かない）
    func testIosTest070_noHTTPStatusComparisonOutsideNetworking() throws {
        let isStatusCheck = try matcher([#"statusCode ==|httpError\("#])
        XCTAssertTrue(isStatusCheck("if http.statusCode == 401 {"))
        XCTAssertTrue(isStatusCheck("throw httpError(code)"))
        XCTAssertFalse(isStatusCheck("switch http.statusCode {"))
        XCTAssertFalse(isStatusCheck("let r = Response(statusCode: 200)"))

        let all = production
        assertNonEmptyContents(all, "production")
        let endpoint = all.first { SourceGrep.relativePath($0) == "Networking/APIEndpoint.swift" }
        XCTAssertNotNil(endpoint, "Networking/APIEndpoint.swift が無い")
        XCTAssertTrue(endpoint.map { SourceGrep.content(of: $0).contains("enum APIEndpoint") } ?? false)

        let outside = collectHits(in: all, excludeComments: false, where: isStatusCheck).filter { !$0.path.hasPrefix("Networking/") }
        assertNoHits(outside, "ios-check-10（Networking/ の外の HTTP ステータス比較）")
    }

    // MARK: - 導出した集合の検査（production を純関数へ渡す）

    private var applicationSources: [SourceFile] { sources(inLayer: .application) }

    private let applicationFileCounts: [(path: String, count: Int)] = [
        ("AppState.swift", 41),
        ("Auth/SubjectCleanup.swift", 5),
        ("Podcast/Playback/AudioEngine.swift", 7),
        ("Podcast/Playback/NowPlayingCenter.swift", 14),
        ("Podcast/Playback/PlaybackLifecycle.swift", 1),
        ("Podcast/Playback/PlayerPresentation.swift", 0),
        ("Passkey/PasskeyAuthorizationProviding.swift", 2),
        ("Podcast/Playback/PlaybackSession.swift", 11),
        ("Podcast/Playback/PlaybackCoordinator.swift", 27),
        ("Podcast/Playback/PlaybackCoordinator+Preview.swift", 1),
        ("Podcast/Playback/NowPlaying.swift", 21),
        ("Podcast/Playback/PositionReporter.swift", 5),
        ("Podcast/Playback/OfflineLibrary.swift", 15),
        ("Podcast/Playback/OfflineDownloads.swift", 7),
        ("Catalog/Application/EpisodeCatalog.swift", 6),
        ("Catalog/Application/EpisodeRow.swift", 7),
    ]

    private func kindCounts(_ ledger: [OperationRow]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for row in ledger {
            switch row.kind {
            case .command: counts["command", default: 0] += 1
            case .query: counts["query", default: 0] += 1
            case .port: counts["port", default: 0] += 1
            case .internal: counts["internal", default: 0] += 1
            case .readModel: counts["readModel", default: 0] += 1
            case .factory: counts["factory", default: 0] += 1
            }
        }
        return counts
    }

    // verifies: ios-check-01（ios-dep-13 の母集団）
    func testIosCheck01_adapterInventoryIsDerivedFromAdapterDeclarations() {
        let inventory = ArchitectureScan.adapterInventory(productionSources)
        // 正の対照: 既知 9 型は分母ではなく、導出した集合に含まれることの確認にだけ使う。
        let known: Set<String> = [
            "APIClient", "KeychainSessionStore", "AudioCacheManager", "MediaPlayerNowPlaying",
            "AVPlayerEngine", "NetworkMonitor", "PreferenceRegistry", "CrashReporter",
            "ASAuthorizationPasskeyProvider",
        ]
        let summary = "concrete=\(inventory.concrete.count) dto=\(inventory.dto.count) pureValue=\(inventory.pureValue.count) excludedPrivate=\(inventory.excludedPrivate.count)\nconcrete: \(inventory.concrete.sorted())"

        XCTAssertEqual(inventory.concrete.count, 11, summary)
        XCTAssertTrue(inventory.concrete.isSuperset(of: known.union(["InMemorySessionStore", "StubNetworkMonitor"])), summary)
        XCTAssertTrue(inventory.excludedPrivate.isSuperset(of: ["PasskeyRegistrationDelegate", "PasskeyAssertionDelegate"]), summary)
        XCTAssertEqual(inventory.dto, dtoNames, summary)
        XCTAssertEqual(inventory.dto.count, 39, summary)
        XCTAssertTrue(inventory.aliases.isEmpty, summary)
        XCTAssertTrue(inventory.factories.isEmpty, summary)
        XCTAssertTrue(inventory.concrete.intersection(inventory.dto).isEmpty, "concrete と dto は重ならない")
    }

    // verifies: ios-check-01（ios-dep-11 の port のファイル）
    func testIosCheck01_portDefiningFilesMatchPortFiles() {
        let derived = ArchitectureScan.portDefiningFiles(productionSources)
        XCTAssertFalse(derived.isEmpty, "導出した port のファイルが空")
        XCTAssertEqual(
            ArchitectureScan.registrationDiff(derived: derived, registered: ArchitectureManifest.portFiles),
            RegistrationDiff(unregistered: [], stale: [])
        )
    }

    // verifies: ios-check-01（ios-dep-09 の read model のファイル）
    func testIosCheck01_readModelFilesMatchLedger() {
        let derived = ArchitectureScan.readModelFiles(ledger: ArchitectureManifest.operationLedger)
        XCTAssertEqual(
            ArchitectureScan.registrationDiff(derived: derived, registered: ArchitectureManifest.readModelFiles),
            RegistrationDiff(unregistered: [], stale: [])
        )
    }

    // verifies: ios-check-15 (a)
    func testIosCheck15_applicationPublicDeclarationsAreCountedAndSupported() {
        let application = applicationSources
        XCTAssertEqual(application.count, applicationFileCounts.count, "application の層のファイルの数")

        let result = ArchitectureScan.publicDeclarations(application)

        var perFile: [String: Int] = [:]
        for declaration in result.declared { perFile[declaration.file, default: 0] += 1 }
        for expected in applicationFileCounts {
            XCTAssertEqual(perFile[expected.path] ?? 0, expected.count, expected.path)
        }
        XCTAssertEqual(result.declared.count, 170)
        XCTAssertTrue(result.unsupported.isEmpty, "未対応の宣言: \(result.unsupported)")
    }

    // verifies: ios-check-15 (a)
    func testIosCheck15_ledgerMatchesApplicationPublicDeclarations() {
        let ledger = ArchitectureManifest.operationLedger
        let declared = ArchitectureScan.publicDeclarations(applicationSources).declared

        let mismatches = ArchitectureScan.ledgerMismatches(declared: declared, ledger: ledger, specIDs: ArchitectureManifest.specOperationIDs)

        XCTAssertEqual(declared.count, 170)
        XCTAssertEqual(ledger.count, 170)
        XCTAssertTrue(mismatches.isEmpty, "台帳と実コードの不一致:\n\(mismatches.map { "\($0.kind) \($0.file) \($0.type).\($0.name)" }.joined(separator: "\n"))")
        XCTAssertEqual(
            kindCounts(ledger),
            ["command": 39, "query": 36, "port": 24, "internal": 24, "readModel": 38, "factory": 9]
        )
        let ledgerIDs = Set(ledger.compactMap { row -> String? in
            switch row.kind {
            case .command(let id), .query(let id): return id
            default: return nil
            }
        })
        XCTAssertTrue(ledgerIDs.isSubset(of: ArchitectureManifest.specOperationIDs), "TA Spec §5 に無い ID: \(ledgerIDs.subtracting(ArchitectureManifest.specOperationIDs).sorted())")
    }

    // verifies: ios-check-15 (a)
    func testIosCheck15_specOperationIDsMatchTargetArchitectureSection5() {
        let ids = ArchitectureManifest.specOperationIDs
        XCTAssertEqual(ids.count, 75)
        XCTAssertEqual(ids.filter { $0.hasPrefix("ios-cmd-") }.count, 53)
        XCTAssertEqual(ids.filter { $0.hasPrefix("ios-query-") }.count, 22)
        XCTAssertTrue(ids.isSuperset(of: ["ios-query-account-03", "ios-cmd-account-10", "ios-cmd-account-11"]))
    }

    // verifies: ios-check-15 (b)
    func testIosCheck15_everyLedgerQueryIsVerifiedByATestUsingRecordingDoubles() {
        let ledger = ArchitectureManifest.operationLedger
        let queryIDs = Set(ledger.compactMap { row -> String? in
            if case .query(let id) = row.kind { return id }
            return nil
        })
        XCTAssertEqual(queryIDs.count, 13, "台帳の query ID は 13 個")

        let uncovered = ArchitectureScan.uncoveredQueryRows(
            ledger: ledger,
            testFiles: ArchitectureScan.testSources(),
            doubleTypeNames: RecordingPorts.doubleTypeNames
        )

        XCTAssertEqual(uncovered.count, 5, "受けられていない query ID は 5 個: \(uncovered.keys.sorted())")
        XCTAssertNil(uncovered["ios-query-account-01"], "本 slice で契約テストを書く query は受けられている")
        let prefix = "ios-check-15/verifies/"
        let allowedIDs = Set(ArchitectureManifest.allowlist.filter { $0.rule.hasPrefix(prefix) }.map { String($0.rule.dropFirst(prefix.count)) })
        for id in Set(uncovered.keys).union(allowedIDs).sorted() {
            assertAllowlistMatches(rule: prefix + id, measured: uncovered[id] ?? [])
        }
    }

    // verifies: ios-check-15（読み書きの混在の追跡）
    func testIosCheck15_readWriteMixedOperationsAreTracked() {
        let declared = ArchitectureScan.publicDeclarations(applicationSources).declared

        let hits = ArchitectureScan.readWriteMixedHits(declared: declared, operations: ArchitectureManifest.readWriteMixedOperations)

        XCTAssertEqual(hits.count, 3)
        assertAllowlistMatches(rule: "ios-check-15/read-write", measured: hits)
        func ledgerKind(of name: String) -> OperationKind? {
            ArchitectureManifest.operationLedger.first { $0.name == name }?.kind
        }
        XCTAssertEqual(ledgerKind(of: "refreshPreferences()"), .command("ios-cmd-prefs-04"))
        XCTAssertEqual(ledgerKind(of: "refreshListeningStreak()"), .command("ios-cmd-learning-05"))
        XCTAssertEqual(ledgerKind(of: "refreshOnboardingStatus()"), .query("ios-query-sources-02"))
    }

    // verifies: ios-check-16
    func testIosCheck16_validatedDomainTypesAreSkippedOrRedWithAllowlist() {
        XCTAssertEqual(ArchitectureManifest.validatedDomainTypes.count, 10)

        let verdicts = ArchitectureScan.validatedTypeVerdicts(productionSources, types: ArchitectureManifest.validatedDomainTypes)

        let red = verdicts.filter { $0.value.outcome == .red }
        let skipped = verdicts.filter { $0.value.outcome == .skip }
        let green = verdicts.filter { $0.value.outcome == .green }
        XCTAssertEqual(Set(red.keys), ["ArticleOpenMode", "FeaturedCategory"])
        XCTAssertEqual(skipped.count, 6, "skip: \(skipped.keys.sorted())")
        XCTAssertEqual(Set(green.keys), ["PlayableEpisode", "SubjectKey"])
        XCTAssertEqual(verdicts.count, 10)
        XCTAssertNil(red["PlayableEpisode"])
        XCTAssertEqual(green["PlayableEpisode"]?.initDeclarationCount, 1)
        XCTAssertTrue(red["ArticleOpenMode"]?.reasons.contains(.notDomainStruct) ?? false)
        XCTAssertTrue(red["FeaturedCategory"]?.reasons.contains(.notDomainStruct) ?? false)
        assertAllowlistMatches(rule: "ios-check-16", measured: red.values.compactMap(\.declaration))
    }

    // verifies: ios-check-08
    func testIosCheck08_noDomainOnlyTestFileIsUnregistered() {
        let production = productionSources
        let tests = ArchitectureScan.testSources()

        let unregistered = ArchitectureScan.unregisteredDomainTests(production: production, tests: tests, registered: ArchitectureManifest.domainTestFiles)
        let domainOnly = ArchitectureScan.unregisteredDomainTests(production: production, tests: tests, registered: [])

        XCTAssertEqual(unregistered, [], "登録漏れ")
        XCTAssertEqual(Set(domainOnly), ["TranscriptTimingTests.swift", "EpisodeContentTests.swift", "PlayableEpisodeTests.swift", "PlaybackRulesTests.swift", "SubjectTests.swift"], "domain だけを参照するテストファイル")
    }
}
