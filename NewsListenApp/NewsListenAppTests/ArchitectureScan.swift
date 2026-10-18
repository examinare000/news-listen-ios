import Foundation

/// 構造検査（`ArchitectureOracleTests`）の入力 1 本。`path` は production なら `NewsListenApp/` から、
/// テスト側なら `NewsListenAppTests/` からの相対。層は `ArchitectureManifest.layer(of:)` で path から引く。
struct SourceFile {
    let path: String
    let text: String

    var lines: [String] { text.components(separatedBy: "\n") }
}

/// 違反候補の 1 行。許可リストとの比較は path ごとの件数の等号で行う。
struct ScanHit {
    let path: String
    let line: Int
    let text: String
}

struct LayerAssignment: Equatable {
    let unclassified: [String]
    let overlapped: [String]
}

struct AdapterFactory: Hashable {
    let type: String
    let name: String
}

/// adapter の層のファイルの宣言を分類した結果。literal の型名表には依らない。
struct AdapterInventory {
    var concrete: Set<String>
    var dto: Set<String>
    var pureValue: Set<String>
    var excludedPrivate: Set<String>
    /// typealias の別名 → 実体（実体が concrete のものだけ）。
    var aliases: [String: String]
    var factories: Set<AdapterFactory>
}

struct DeclaredOperation: Hashable {
    let file: String
    let type: String
    let name: String
}

enum UnsupportedReason: String {
    case topLevel = "ファイル直下"
    case unknownOwner = "所属の型が不明"
    case multipleInOneLine = "1 行に複数の宣言"
    case unsupportedModifier = "未対応の修飾子"
}

struct UnsupportedDeclaration: Hashable {
    let path: String
    let line: Int
    let reason: UnsupportedReason
}

struct PublicDeclarations {
    let declared: [DeclaredOperation]
    let unsupported: [UnsupportedDeclaration]
}

enum LedgerMismatchKind: Hashable {
    case notInLedger
    case notInCode
    case unknownSpecID
    case kindPrefixMismatch
}

struct LedgerMismatch: Hashable {
    let kind: LedgerMismatchKind
    let file: String
    let type: String
    let name: String
}

enum ValidatedReason: Hashable {
    case unsupportedForm
    case duplicateDeclaration
    case notDomainStruct
    case uncheckedInit
    case storedVar
    case unsupportedModifier
    case unsupportedIndent
}

struct ValidatedVerdict {
    enum Outcome: Equatable {
        case skip
        case red
        case green
    }

    let outcome: Outcome
    let reasons: Set<ValidatedReason>
    /// red のとき、宣言の行（許可リストの比較に使う）。
    let declaration: ScanHit?
    /// 本体の宣言の行のうち keyword が `init`・`init?`・`init!` のものの数。
    let initDeclarationCount: Int
}

struct RegistrationDiff: Equatable {
    /// 導出した集合にあって、登録に無い。
    let unregistered: Set<String>
    /// 登録にあって、導出した集合に無い。
    let stale: Set<String>
}

/// ファイル一覧と内容を受け取る純関数の集まり。production を読む入口は `productionSources()` の 1 つ、
/// テスト側を読む入口は `testSources()` の 1 つに限る。fixture のテストは `SourceFile` を手で作って同じ関数へ渡す。
enum ArchitectureScan {

    // MARK: - 入口

    static func productionSources() -> [SourceFile] {
        SourceGrep.swiftFiles()
            .map { SourceFile(path: SourceGrep.relativePath($0), text: SourceGrep.content(of: $0)) }
            .sorted { $0.path < $1.path }
    }

    static func testSources() -> [SourceFile] {
        let root = SourceGrep.testRoot
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var sources: [SourceFile] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = String(url.path.dropFirst(root.path.count + 1))
            sources.append(SourceFile(path: path, text: SourceGrep.content(of: url)))
        }
        return sources.sorted { $0.path < $1.path }
    }

    // MARK: - 共有の補助

    /// 宣言の行 `start`（0 始まり）から、最初に開く `{` に対応する `}` までの行の範囲。
    /// 文字列 literal とコメントの中の括弧は数えない。`{` が開かない、または閉じないときは nil。
    static func bodyRange(of start: Int, in lines: [String]) -> ClosedRange<Int>? {
        guard lines.indices.contains(start) else { return nil }
        var depth = 0
        var opened = false
        var inBlockComment = false
        var inMultilineString = false
        for index in start..<lines.count {
            let characters = Array(lines[index])
            var inString = false
            var cursor = 0
            func isTripleQuote(at position: Int) -> Bool {
                position + 2 < characters.count && characters[position] == "\"" && characters[position + 1] == "\"" && characters[position + 2] == "\""
            }
            while cursor < characters.count {
                let character = characters[cursor]
                let next: Character? = cursor + 1 < characters.count ? characters[cursor + 1] : nil
                if inBlockComment {
                    if character == "*", next == "/" { inBlockComment = false; cursor += 2 } else { cursor += 1 }
                    continue
                }
                if inMultilineString {
                    if character == "\\" { cursor += 2; continue }
                    if isTripleQuote(at: cursor) { inMultilineString = false; cursor += 3 } else { cursor += 1 }
                    continue
                }
                if inString {
                    if character == "\\" { cursor += 2; continue }
                    if character == "\"" { inString = false }
                    cursor += 1
                    continue
                }
                if character == "/", next == "/" { break }
                if character == "/", next == "*" { inBlockComment = true; cursor += 2; continue }
                if character == "\"" {
                    if isTripleQuote(at: cursor) { inMultilineString = true; cursor += 3 } else { inString = true; cursor += 1 }
                    continue
                }
                if character == "{" {
                    depth += 1
                    opened = true
                } else if character == "}" {
                    depth -= 1
                    if opened && depth == 0 { return start...index }
                }
                cursor += 1
            }
        }
        return nil
    }

    /// `#if DEBUG` の枝の中と `#Preview` ブロックの中の行（0 始まりの添字）。
    /// 全種類の `#if` の深さを追う（`#if canImport(UIKit)` などで範囲を取り違えない）。
    /// `#if DEBUG` の `#else` 側と、DEBUG 以外の条件の枝は除外しない。
    static func debugAndPreviewExcludedLines(_ lines: [String]) -> Set<Int> {
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

    static func conditionText(_ directiveLine: String, directive: String) -> String {
        var rest = String(directiveLine.dropFirst(directive.count))
        if let comment = rest.range(of: "//") { rest = String(rest[..<comment.lowerBound]) }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// 導出した集合と登録済みの集合の差。登録漏れと、実体の無い登録を別々に返す。
    static func registrationDiff(derived: Set<String>, registered: Set<String>) -> RegistrationDiff {
        RegistrationDiff(unregistered: derived.subtracting(registered), stale: registered.subtracting(derived))
    }

}
