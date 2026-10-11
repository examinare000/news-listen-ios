import Foundation

enum SourceGrep {
    /// `App/` = `ios/NewsListenApp/NewsListenApp`（このテストファイルの 2 階層上 + `NewsListenApp`）。
    static let appRoot: URL = {
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent() // NewsListenAppTests/
            .deletingLastPathComponent() // NewsListenApp/ (プロジェクトルート)
            .appendingPathComponent("NewsListenApp") // App ターゲットルート
    }()

    /// `NewsListenAppTests/`（テストターゲットのルート。T-G02 がテストファイルを読むために使う）。
    static let testRoot: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// 先頭の空白の後が `//`（`///` を含む）の行。O-* と同じ「コメント行」の定義。
    static func isCommentLine(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

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
