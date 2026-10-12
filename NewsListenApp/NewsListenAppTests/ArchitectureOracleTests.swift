import XCTest
@testable import NewsListenApp

/// 層の所属表（`ArchitectureManifest`）と依存方向の規則 TA-D* を、ソースを読んで検査する oracle。
/// `GrepOracleTests` と同じ方式（`SourceGrep` でコメント行を除いた行を集める）で、現状の違反は
/// `ArchitectureManifest.allowlist` の `(規則キー, path, 行数)` に固定する。許可リストの比較は**等号だけ**で、
/// 増えても減っても落ちる（減らした slice が同じ PR で一覧を減らす）。
///
/// 規則キー: TA-D2・D3・D4・D5・D6・D8・D11・D12・D13 と、TA-V3 の 13 群（`TA-R-…`）。
/// TA-D4・D6 は検査が 2 つに分かれる（DTO の分は T-TA-V2b、それ以外は T-TA-V4b）ので、
/// DTO の分だけ `<規則 ID>/DTO` と書く。TA-D1・D7・D10 は 0 件が契約で、許可リストに行を持たない。
/// TA-D14（既存の検査を保つ）は T-TA-V9 で検査する（`ci.yml:47` の grep を XCTest に入れたもの）。
final class ArchitectureOracleTests: XCTestCase {

    // MARK: - 走査の土台

    private struct Hit {
        let path: String
        let line: Int
        let text: String
    }

    private var production: [URL] {
        SourceGrep.swiftFiles().sorted { SourceGrep.relativePath($0) < SourceGrep.relativePath($1) }
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

    // MARK: 条件コンパイルと #Preview の除外（TA-D13 と TA-V3 だけで使う）

    /// `#if DEBUG` の枝の中と `#Preview` ブロックの中の行（0 始まりの添字）。
    /// 全種類の `#if` の深さを追う（`#if canImport(UIKit)` などで範囲を取り違えない）。
    /// `#if DEBUG` の `#else` 側と、DEBUG 以外の条件の枝は除外しない。
    private func debugAndPreviewExcludedLines(_ lines: [String]) -> Set<Int> {
        var excluded: Set<Int> = []
        var stack: [Bool] = []
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") || trimmed == "#if" {
                stack.append(conditionText(trimmed, directive: "#if") == "DEBUG")
            } else if trimmed.hasPrefix("#elseif") {
                if !stack.isEmpty { stack[stack.count - 1] = conditionText(trimmed, directive: "#elseif") == "DEBUG" }
            } else if trimmed.hasPrefix("#else") {
                if !stack.isEmpty { stack[stack.count - 1] = false }
            } else if trimmed.hasPrefix("#endif") {
                if !stack.isEmpty { stack.removeLast() }
            }
            if stack.contains(true) { excluded.insert(index) }
            if trimmed.hasPrefix("#Preview") {
                var depth = 0
                var opened = false
                var cursor = index
                scan: while cursor < lines.count {
                    excluded.insert(cursor)
                    for character in lines[cursor] {
                        if character == "{" { depth += 1; opened = true }
                        if character == "}" { depth -= 1 }
                    }
                    if opened && depth <= 0 { break scan }
                    cursor += 1
                }
                index = max(index, cursor)
            }
            index += 1
        }
        return excluded
    }

    private func conditionText(_ directiveLine: String, directive: String) -> String {
        var rest = String(directiveLine.dropFirst(directive.count))
        if let comment = rest.range(of: "//") { rest = String(rest[..<comment.lowerBound]) }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    // MARK: 数え上げ

    /// 行ごとに照合する。`excludeComments`: コメント行（先頭の空白の後が `//`）を除く（`SourceGrep.matchingLines` は除かないので自前で除く）。
    /// `excludeConditional`: `#if DEBUG` と `#Preview` の中を除く。結果は path・行の順。
    private func collectHits(
        in files: [URL],
        excludeComments: Bool = true,
        excludeConditional: Bool = false,
        where isHit: (String) -> Bool
    ) -> [Hit] {
        var hits: [Hit] = []
        for file in files {
            let path = SourceGrep.relativePath(file)
            let lines = SourceGrep.content(of: file).components(separatedBy: "\n")
            let skipped = excludeConditional ? debugAndPreviewExcludedLines(lines) : []
            for (offset, line) in lines.enumerated() {
                if excludeComments && SourceGrep.isCommentLine(line) { continue }
                if skipped.contains(offset) { continue }
                if isHit(line) { hits.append(Hit(path: path, line: offset + 1, text: line)) }
            }
        }
        return hits.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    private func lineCounts(_ hits: [Hit]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for hit in hits { counts[hit.path, default: 0] += 1 }
        return counts
    }

    private func describe(_ hits: [Hit]) -> String {
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

    private func assertContainsHit(_ hits: [Hit], path: String, fragment: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
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
        measured hits: [Hit],
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

    private func assertNoHits(_ hits: [Hit], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(hits.isEmpty, "\(label) は 0 件であること。違反:\n\(describe(hits))", file: file, line: line)
    }

    // MARK: TA-V3 の群

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
            LiteralGroup(key: "TA-R-CT-1・2", pattern: #""(completed|processing|failed|partial_failed)""#,
                         isCanonical: exact("Models/Podcast+Episode.swift"), excludesPath: never,
                         controlPath: "Podcast/PodcastRowView.swift", controlFragment: #"case "processing":"#),
            LiteralGroup(key: "TA-R-CT-3", pattern: #"==\s*"featured""#,
                         isCanonical: exact("Catalog/Domain/EpisodeContent.swift"), excludesPath: never,
                         controlPath: "Catalog/Domain/EpisodeContent.swift", controlFragment: #"sourceKind == "featured""#),
            LiteralGroup(key: "TA-R-PB-5", pattern: #"max\(0,\s*(\w+\.)?currentTime\b|min\(\s*(\w+\.)?duration\s*,"#,
                         isCanonical: { path, _ in path.hasPrefix("Podcast/Playback/Domain/") }, excludesPath: never,
                         controlPath: "Podcast/AudioPlayerView.swift", controlFragment: "max(0, vm.currentTime"),
            LiteralGroup(key: "TA-R-PB-4", pattern: #"\[\s*(0\.5\s*,\s*)?0\.75\s*,\s*1\.0\s*,\s*1\.25"#,
                         isCanonical: exact("Podcast/PlaybackConstants.swift", "Podcast/Playback/Domain/PlaybackConstants.swift"), excludesPath: never,
                         controlPath: "Settings/SettingsView.swift", controlFragment: "playbackSpeeds"),
            LiteralGroup(key: "TA-R-AC-1", pattern: #"\.count\s*(>=|<)\s*[0-9]+"#,
                         isCanonical: exact("Auth/Domain/PasswordPolicy.swift"), excludesPath: never,
                         controlPath: "Settings/AccountSettingsView.swift", controlFragment: "newPassword.count >= 8"),
            LiteralGroup(key: "TA-R-AC-5", pattern: #""(admin|user)""#,
                         isCanonical: exact("Auth/Domain/Subject.swift"), excludesPath: { $0 == "Passkey/PasskeyOptionsDecoder.swift" },
                         controlPath: "Models/AuthModels.swift", controlFragment: #"role == "admin""#),
            LiteralGroup(key: "TA-R-AC-6・TA-R-CU-4・TA-R-SO-2・TA-R-LC-2", pattern: #"catch\s+ApiFailure\.(notFound\(subject|conflict\b)"#,
                         isCanonical: { path, layer in layer == .application || path.hasPrefix("Networking/") }, excludesPath: never,
                         controlPath: "AppState.swift", controlFragment: "catch ApiFailure.notFound(subject: .streak)"),
            LiteralGroup(key: "TA-R-PF-1", pattern: #""(toeic_600|toeic_900|ielts_55|ielts_7|eiken_2|eiken_p1)""#,
                         isCanonical: exact("Shared/Domain/DifficultyLevel.swift"), excludesPath: never,
                         controlPath: "Utilities/DifficultyLabel.swift", controlFragment: #"case "toeic_600":"#),
            LiteralGroup(key: "TA-R-PF-2", pattern: #"\[3,\s*5,\s*7,\s*10\]"#,
                         isCanonical: exact("Settings/Domain/WeeklyGoalTarget.swift"), excludesPath: never,
                         controlPath: "Settings/PreferenceRegistry.swift", controlFragment: "[3, 5, 7, 10].contains"),
            LiteralGroup(key: "TA-R-PF-3", pattern: #""(absolute|relative)""#,
                         isCanonical: exact("Settings/Domain/TimeFormat.swift"), excludesPath: never,
                         controlPath: "Settings/SettingsView.swift", controlFragment: #".tag("absolute")"#),
            LiteralGroup(key: "TA-R-CU-3", pattern: #"\blimit\s*==\s*0\b"#,
                         isCanonical: exact("Feed/Domain/GenerationAllowance.swift"), excludesPath: never,
                         controlPath: "Settings/SettingsView.swift", controlFragment: "quota.limit == 0"),
            LiteralGroup(key: "TA-R-LC-1", pattern: #">=\s*0\.5\b"#,
                         isCanonical: exact("Learning/Domain/QuizAttempt.swift"), excludesPath: never,
                         controlPath: "Podcast/QuizSheetView.swift", controlFragment: "correctRate >= 0.5"),
        ]
    }

    private let vocabularyKey = "TA-R-LV-1"
    private let vocabularyCanonicalPath = "Learning/Domain/VocabularyTest.swift"

    /// `TA-R-LV-1`: 日付の切り出し `String(<識別子の連鎖>.prefix(10))` の部分文字列だけを取り除き、
    /// 残りに `.prefix(10)` があれば数える（同じ行の出題の上限の式を見落とさない）。
    private func vocabularyLimitLineIsViolation(_ line: String) -> Bool {
        let datePattern = #"String\(\s*[A-Za-z_][\w.]*\.prefix\(10\)\s*\)"#
        let stripped = line.replacingOccurrences(of: datePattern, with: "", options: .regularExpression)
        return stripped.range(of: #"\.prefix\(10\)"#, options: .regularExpression) != nil
    }

    /// 許可リストの規則キー（一致を検査するもの）。(規則キー, path) の構造の整合に使う。
    private var knownRuleKeys: Set<String> {
        let partKeys: Set<String> = [
            "TA-D2", "TA-D3", "TA-D4", "TA-D4/DTO", "TA-D5", "TA-D6", "TA-D6/DTO", "TA-D8", "TA-D11", "TA-D12", "TA-D13",
        ]
        return partKeys.union(literalGroups.map(\.key)).union([vocabularyKey])
    }

    // MARK: - TA-V1

    // verifies: TA-V1（TA-D10）
    func testTA_V1a_everyProductionFileBelongsToExactlyOneLayer() throws {
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

        let ungoverned = all.map(SourceGrep.relativePath).filter { ArchitectureManifest.explicitLayers[$0] == nil }
        let unmatched = ungoverned.filter { ArchitectureManifest.matchedLayers(of: $0).isEmpty }
        let overlapped = ungoverned.filter { ArchitectureManifest.matchedLayers(of: $0).count >= 2 }
        XCTAssertTrue(unmatched.isEmpty, "どの規則にも当たらないファイル: \(unmatched)")
        XCTAssertTrue(overlapped.isEmpty, "2 つ以上の規則に当たるファイル: \(overlapped)")

        // 許可リストの構造の整合（行数の値は読まない。値は規則キーを検査するテストだけが見る）。
        let known = knownRuleKeys
        let forbiddenKeys: Set<String> = ["TA-D1", "TA-D7", "TA-D10"]
        var seen: Set<String> = []
        for entry in ArchitectureManifest.allowlist {
            XCTAssertTrue(known.contains(entry.rule), "未知の規則キー: \(entry.rule)（\(entry.path)）")
            XCTAssertFalse(forbiddenKeys.contains(entry.rule), "0 件が契約の規則に許可リストの行がある: \(entry.rule)（\(entry.path)）")
            XCTAssertTrue(paths.contains(entry.path), "許可リストの path が production に無い: \(entry.path)")
            XCTAssertTrue(seen.insert(entry.rule + "\u{0}" + entry.path).inserted, "(規則キー, path) が重複: \(entry.rule) \(entry.path)")
        }
    }

    // verifies: TA-V1（TA-D1）
    func testTA_V1b_domainImportsOnlyFoundationAndNamesNoAdapterOrPersistence() throws {
        let patterns = [
            #"^\s*import\s+(?!Foundation\b)\w+"#,
            #"\b(Codable|Decodable|Encodable|CodingKeys?|UserDefaults|ObservableObject|URLSession|FileManager)\b"#,
            #"@Published\b"#,
            wordPattern(ArchitectureManifest.adapterConcrete),
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
        assertNoHits(collectHits(in: domain, where: isViolation), "TA-D1（domain の import と型名）")
    }

    // verifies: TA-V1（TA-D3）
    func testTA_V1c_applicationDependsOnlyOnAllowedFrameworksAndNames() throws {
        let patterns = [
            #"^\s*import\s+(?!(Foundation|Combine|os)\b)\w+"#,
            wordPattern(ArchitectureManifest.adapterConcrete),
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
        assertContainsHit(hits, path: "AppState.swift", fragment: "KeychainSessionStore()", "TA-D3")
        assertAllowlistMatches(rule: "TA-D3", measured: hits)
    }

    // verifies: TA-V1（TA-D7）
    func testTA_V1d_adapterNamesNoViewModelOrAppStateAndNoSwiftUI() throws {
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
        assertNoHits(collectHits(in: adapter, where: isViolation), "TA-D7（adapter の ViewModel・AppState・SwiftUI）")
    }

    // verifies: TA-V1（TA-D13）
    func testTA_V1e_adapterConcreteIsConstructedOnlyInCompositionRootOrDebug() throws {
        let isConstruction = try matcher([constructionPattern(ArchitectureManifest.adapterConcrete)])

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
        let lines = synthetic.components(separatedBy: "\n")
        let skipped = debugAndPreviewExcludedLines(lines)
        let counted = lines.enumerated().filter { !skipped.contains($0.offset) && isConstruction($0.element) }.map { $0.element }
        XCTAssertEqual(counted, ["let d = APIClient()", "let f = APIClient()", "let h = APIClient()"])

        let targets = production.filter { ArchitectureManifest.layer(of: SourceGrep.relativePath($0)) != .compositionRoot }
        assertNonEmptyContents(targets, "compositionRoot 以外")
        // 実ファイルの対照: 除外の前の集合に LearningView の Preview の行がある。
        let beforeExclusion = collectHits(in: targets, where: isConstruction)
        XCTAssertTrue(beforeExclusion.contains { $0.path == "Learning/LearningView.swift" }, "LearningView の Preview の行が除外の前の集合に無い")
        // 負の対照: コメント除外の前の集合に `///` で始まり生成の形を含む行があり、除外の後には同じファイルの `///` の行が無い。
        let withComments = collectHits(in: targets, excludeComments: false, where: isConstruction)
        XCTAssertTrue(
            withComments.contains { $0.path == "Podcast/PodcastViewModel.swift" && $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("///") && $0.text.contains("AudioCacheManager()") },
            "doc コメントの対照が除外の前の集合に無い"
        )
        let afterExclusion = collectHits(in: targets, excludeConditional: true, where: isConstruction)
        XCTAssertFalse(
            afterExclusion.contains { $0.path == "Podcast/PodcastViewModel.swift" && $0.text.trimmingCharacters(in: .whitespaces).hasPrefix("///") },
            "doc コメントが数えられている"
        )
        assertAllowlistMatches(rule: "TA-D13", measured: afterExclusion)
    }

    // MARK: - TA-V2

    // verifies: TA-V2（TA-D2）
    func testTA_V2a_domainNamesNoDTO() throws {
        let isDTO = try matcher([wordPattern(dtoNames)])
        let domain = filesInLayer(.domain)
        assertNonEmptyContents(domain, "domain")
        let hits = collectHits(in: domain, where: isDTO)
        XCTAssertTrue(hits.contains { $0.path == "Models/FeaturedCategory.swift" }, "FeaturedCategory の DTO の行が集合に無い")
        assertAllowlistMatches(rule: "TA-D2", measured: hits)
    }

    // verifies: TA-V2（TA-D4・TA-D6 の DTO の分）
    func testTA_V2b_presentationNamesNoDTO() throws {
        let names = dtoNames
        XCTAssertEqual(names.count, 39, "DTO は 39 個（I-T2a で葉の値型 4 つが domain へ）")
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
        assertAllowlistMatches(rule: "TA-D4/DTO", measured: viewHits)
        assertAllowlistMatches(rule: "TA-D6/DTO", measured: viewModelHits)
    }

    // verifies: TA-V2（TA-D8）
    func testTA_V2c_codableAppearsOnlyInAdapter() throws {
        let isCodable = try matcher([#"\b(Codable|Decodable|Encodable|CodingKeys?|JSONDecoder|JSONEncoder)\b"#])
        let targets = nonAdapterFiles
        assertNonEmptyContents(targets, "adapter 以外")
        let hits = collectHits(in: targets, where: isCodable)
        XCTAssertTrue(hits.contains { $0.path == "DesignSystem/PreviewSupport.swift" }, "PreviewSupport の Codable の行が集合に無い")
        assertAllowlistMatches(rule: "TA-D8", measured: hits)
    }

    // verifies: TA-V2（TA-D11）
    func testTA_V2d_portDeclarationsNameNoFrameworkOrDTO() throws {
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

        let ports = files(atRelativePaths: ArchitectureManifest.portFiles)
        XCTAssertEqual(ports.count, ArchitectureManifest.portFiles.count, "portFiles の path が production に無い")
        assertNonEmptyContents(ports, "portFiles")
        let hits = collectHits(in: ports, where: isViolation)
        assertContainsHit(hits, path: "Podcast/Platform/NowPlayingCenter.swift", fragment: "[String: Any]", "TA-D11")
        assertAllowlistMatches(rule: "TA-D11", measured: hits)
    }

    // MARK: - TA-V3

    // verifies: TA-V3（群ごとの規則キー: TA-R-CT-1・2 ほか 13 群）
    func testTA_V3_ruleLiteralsLiveOnlyInTheirCanonicalPlace() throws {
        let all = production
        assertNonEmptyContents(all, "production")

        // TA-R-LV-1 の日付の除外は一致の単位（合成の対照）。
        XCTAssertTrue(vocabularyLimitLineIsViolation("let firstTen = Array(items.prefix(10)); let label = String(items.count)"))
        XCTAssertFalse(vocabularyLimitLineIsViolation("Text(String(item.registeredAt.prefix(10)))"))
        XCTAssertTrue(vocabularyLimitLineIsViolation("return String(article.publishedAt.prefix(10)) + Array(xs.prefix(10)).description"))

        // 負の対照（TA-R-PB-5）: 添字の丸めは「現在位置・総時間」の式に当たらない。
        let playbackClamp = try matcher([literalGroups.first { $0.key == "TA-R-PB-5" }!.pattern])
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

        // TA-R-LV-1: 日付の切り出しを一致の単位で除く。除外の前は日付の行も含み、除外の後は出題の上限の式だけが残る。
        let isPrefix = try matcher([#"\.prefix\(10\)"#])
        let beforeExclusion = collectHits(in: all, where: isPrefix)
        XCTAssertTrue(beforeExclusion.contains { $0.path == "Settings/AccountSettingsView.swift" }, "日付の切り出しの行が除外の前の集合に無い")
        let violations = collectHits(in: all, excludeConditional: true, where: vocabularyLimitLineIsViolation)
            .filter { $0.path != vocabularyCanonicalPath }
        XCTAssertTrue(violations.contains { $0.path == "Models/VocabularyModels.swift" && $0.text.contains("Array(items.prefix(10))") }, "出題の上限の式が集合に無い")
        XCTAssertFalse(violations.contains { $0.path == "Settings/AccountSettingsView.swift" }, "日付の切り出しが数えられている")
        assertAllowlistMatches(rule: vocabularyKey, measured: violations)
    }

    // MARK: - TA-V4

    // verifies: TA-V4（TA-D5）
    func testTA_V4a_viewsDoNotAssignViewModelOrAppState() throws {
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
        assertContainsHit(hits, path: "NewsListenAppApp.swift", fragment: "appState.selectedPodcastId = nil", "TA-D5")
        assertAllowlistMatches(rule: "TA-D5", measured: hits)
    }

    // verifies: TA-V4（TA-D4・TA-D6 の DTO を除く分）
    func testTA_V4b_presentationDoesNotKnowAdapters() throws {
        let views = viewFiles
        let viewModels = viewModelFiles
        assertNonEmptyContents(views, "View ファイル")
        assertNonEmptyContents(viewModels, "ViewModel ファイル")
        assertContains(views, ["Settings/SettingsView.swift"], "View ファイル")
        assertContains(viewModels, ["Feed/FeedViewModel.swift"], "ViewModel ファイル")

        let viewMatcher = try matcher([#"\bAPIClient\b"#, #"\bApiFailure\b"#, #"\bUserDefaults\b"#, #"@AppStorage\b"#])
        let viewModelMatcher = try matcher(
            [#"\bAPIClient\b"#, wordPattern(ArchitectureManifest.adapterConcrete)] + uiFacilityPatterns + [#"^\s*import\s+(UIKit|SwiftUI)\b"#]
        )
        let viewHits = collectHits(in: views, where: viewMatcher)
        let viewModelHits = collectHits(in: viewModels, where: viewModelMatcher)
        assertContainsHit(viewHits, path: "Settings/SettingsView.swift", fragment: "@AppStorage", "TA-D4")
        assertAllowlistMatches(rule: "TA-D4", measured: viewHits)
        assertAllowlistMatches(rule: "TA-D6", measured: viewModelHits)
    }

    // MARK: - TA-V5

    // verifies: TA-V5（TA-D12）
    func testTA_V5a_writablePublishedIsOnlyDraftAllowlist() throws {
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
        let viewModelHits = viewModels.flatMap { url -> [Hit] in
            let path = SourceGrep.relativePath(url)
            return collectHits(in: [url]) { line in
                guard let name = publishedName(line) else { return false }
                return !drafts.contains(path + "\u{0}" + name)
            }
        }
        XCTAssertTrue(applicationHits.contains { $0.path == "AppState.swift" }, "AppState の @Published が集合に無い")
        assertAllowlistMatches(rule: "TA-D12", measured: applicationHits + viewModelHits)
    }

    // verifies: TA-V5（TA-D9）
    func testTA_V5b_readModelFilesAreEmptyForNow() {
        // 初版は対象 0 本。リードモデルを足す slice で、この assert を各ファイルの検査へ改める。
        XCTAssertTrue(ArchitectureManifest.readModelFiles.isEmpty)
    }

    // MARK: - TA-V7

    // verifies: TA-V7
    func testTA_V7_domainTestsUseNoIO() throws {
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
        assertNoHits(collectHits(in: urls, where: isIO), "TA-V7（domain のテストの I/O）")
    }

    // MARK: - TA-V9

    // verifies: TA-V9（TA-D14。ci.yml の `statusCode ==|httpError(` の grep と同じ判定。コメント行は除かない）
    func testTA_V9_noHTTPStatusComparisonOutsideNetworking() throws {
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
        assertNoHits(outside, "TA-V9（Networking/ の外の HTTP ステータス比較）")
    }
}
