import Foundation

/// 行単位の Swift 宣言の認識。`ArchitectureScan` の検査関数が共有する。
/// 構文解析器ではない。order と TA Spec が名指しする形と、実 repo にある書き方だけを扱う。
/// 判定できない形は、呼び出し側が fail-closed（unsupported か red）にする。
enum SwiftLines {

    /// 宣言の keyword の前にある語を分けたもの。
    struct Member {
        let attributes: [String]
        /// 属性以外の語（既知・未知の修飾子を問わない）。
        let modifiers: [String]
        /// `func`・`var`・`let`・`subscript`・`init`・`init?`・`init!`。
        let keyword: String
        /// keyword の後ろ（行末まで。行末コメントを除く）。
        let rest: String
    }

    struct TypeDeclaration {
        let keyword: String
        let name: String
        let modifiers: [String]
    }

    enum Owner: Equatable {
        case local
        case unknown
        case type(String)
    }

    static let knownModifiers: Set<String> = [
        "public", "internal", "open", "private", "fileprivate", "static", "class", "final", "override",
        "mutating", "nonmutating", "nonisolated", "lazy", "weak", "unowned", "dynamic", "required",
        "convenience", "private(set)", "fileprivate(set)", "internal(set)", "public(set)",
    ]

    // MARK: - 行の性質

    static func indent(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("//")
    }

    private static let attributeOnlyRegex = try! NSRegularExpression(pattern: #"^\s*(@\w+(\([^)]*\))?\s*)+$"#)

    static func isAttributeOnly(_ line: String) -> Bool {
        attributeOnlyRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// 文字列 literal の外にある行末コメント（`//`）を除いた行。
    static func codeOnly(_ line: String) -> String {
        let characters = Array(line)
        var inString = false
        var cursor = 0
        while cursor < characters.count {
            let character = characters[cursor]
            if inString {
                if character == "\\" { cursor += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "/", cursor + 1 < characters.count, characters[cursor + 1] == "/" {
                return String(characters[..<cursor])
            }
            cursor += 1
        }
        return line
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// `open` の位置の `(` に対応する `)` の添字。文字列 literal の中は数えない。
    static func matchingParen(_ characters: [Character], from open: Int) -> Int? {
        guard open < characters.count, characters[open] == "(" else { return nil }
        var depth = 0
        var inString = false
        var cursor = open
        while cursor < characters.count {
            let character = characters[cursor]
            if inString {
                if character == "\\" { cursor += 2; continue }
                if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    // MARK: - 宣言の接頭辞

    /// 属性・修飾子の列の後に `func`・`var`・`let`・`subscript`・`init` が来る行を `Member` にする。
    /// 行頭の空白は読み飛ばす。それ以外の形（式・文・型の宣言）は nil。
    static func parseMember(_ raw: String) -> Member? {
        let characters = Array(codeOnly(raw))
        var cursor = 0
        func skipSpaces() { while cursor < characters.count, characters[cursor] == " " || characters[cursor] == "\t" { cursor += 1 } }
        skipSpaces()
        var attributes: [String] = []
        var modifiers: [String] = []
        while cursor < characters.count {
            if characters[cursor] == "@" {
                var end = cursor + 1
                while end < characters.count, isWordCharacter(characters[end]) || characters[end] == "." { end += 1 }
                if end < characters.count, characters[end] == "(" {
                    guard let close = matchingParen(characters, from: end) else { return nil }
                    end = close + 1
                }
                attributes.append(String(characters[cursor..<end]))
                cursor = end
                skipSpaces()
                continue
            }
            var end = cursor
            while end < characters.count, isWordCharacter(characters[end]) { end += 1 }
            if end == cursor { return nil }
            let word = String(characters[cursor..<end])
            switch word {
            case "func", "var", "let", "subscript":
                return Member(attributes: attributes, modifiers: modifiers, keyword: word, rest: String(characters[end...]))
            case "init":
                var keyword = "init"
                var after = end
                if after < characters.count, characters[after] == "?" || characters[after] == "!" {
                    keyword += String(characters[after])
                    after += 1
                }
                return Member(attributes: attributes, modifiers: modifiers, keyword: keyword, rest: String(characters[after...]))
            default:
                break
            }
            if end < characters.count, characters[end] == "(" {
                guard let close = matchingParen(characters, from: end) else { return nil }
                modifiers.append(String(characters[cursor...close]))
                cursor = close + 1
            } else {
                modifiers.append(word)
                cursor = end
            }
            skipSpaces()
        }
        return nil
    }

    private static let typeDeclarationRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*((?:(?:public|internal|open|fileprivate|private|package|final|indirect)\s+)*)(struct|enum|class|actor|protocol|extension)\s+([\w.]+)"#
    )

    /// 属性・修飾子つきの型の宣言（`extension` を含む）。コメント行と、`class func` のような member は nil。
    static func typeDeclaration(_ line: String) -> TypeDeclaration? {
        if isBlankOrComment(line) { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = typeDeclarationRegex.firstMatch(in: line, range: range),
              let modifiersRange = Range(match.range(at: 1), in: line),
              let keywordRange = Range(match.range(at: 2), in: line),
              let nameRange = Range(match.range(at: 3), in: line) else { return nil }
        let name = String(line[nameRange])
        if ["func", "var", "let", "init", "subscript", "case"].contains(name) { return nil }
        let modifiers = line[modifiersRange].split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return TypeDeclaration(keyword: String(line[keywordRange]), name: name, modifiers: modifiers)
    }

    // MARK: - 囲む型

    /// 宣言の行から上へ、空行・コメント行・`#` で始まる行・`}` で始まる行・属性だけの行を飛ばし、
    /// 字下げがより小さい最初の行（0 始まりの添字）。
    static func enclosingLine(of index: Int, in lines: [String]) -> Int? {
        let own = indent(of: lines[index])
        var cursor = index - 1
        while cursor >= 0 {
            let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("}") || isAttributeOnly(lines[cursor]) {
                cursor -= 1
                continue
            }
            if indent(of: lines[cursor]) < own { return cursor }
            cursor -= 1
        }
        return nil
    }

    /// member の所属の型。囲む行をたどり、全部が型の宣言なら `Outer.Inner`。途中に型でない行があれば local。
    static func owner(ofMemberAt index: Int, in lines: [String]) -> Owner {
        var names: [String] = []
        var current = index
        while true {
            guard let enclosing = enclosingLine(of: current, in: lines) else {
                if names.isEmpty { return .unknown }
                return indent(of: lines[current]) == 0 ? .type(names.reversed().joined(separator: ".")) : .unknown
            }
            guard let declaration = typeDeclaration(lines[enclosing]) else { return .local }
            names.append(declaration.name)
            if indent(of: lines[enclosing]) == 0 { return .type(names.reversed().joined(separator: ".")) }
            current = enclosing
        }
    }

    // MARK: - 名前と型

    /// 宣言の名前。var・let は名前だけ。func・init・subscript は `名前(ラベル:ラベル:)`。
    /// 引数リストが複数行にわたる場合は、続く行を足して括弧の対応が取れるまで読む。
    static func declarationName(_ member: Member, at index: Int, in lines: [String]) -> String {
        let rest = member.rest.trimmingCharacters(in: .whitespaces)
        switch member.keyword {
        case "var", "let":
            let name = rest.prefix { $0 == "`" || isWordCharacter($0) }
            return String(name).replacingOccurrences(of: "`", with: "")
        case "init", "init?", "init!":
            return member.keyword + parameterList(startingWith: rest, at: index, in: lines)
        case "subscript":
            return "subscript" + parameterList(startingWith: rest, at: index, in: lines)
        default:
            let name = rest.prefix { $0 == "`" || isWordCharacter($0) }
            let base = String(name).replacingOccurrences(of: "`", with: "")
            let afterName = String(rest.dropFirst(name.count))
            return (base.isEmpty ? funcOperatorName(rest) : base) + parameterList(startingWith: afterName, at: index, in: lines)
        }
    }

    private static func funcOperatorName(_ rest: String) -> String {
        String(rest.prefix { !$0.isWhitespace && $0 != "(" && $0 != "<" })
    }

    private static func parameterList(startingWith text: String, at index: Int, in lines: [String]) -> String {
        var combined = Array(text)
        var next = index + 1
        guard let open = combined.firstIndex(of: "(") else { return "()" }
        while matchingParen(combined, from: open) == nil, next < lines.count {
            combined.append(" ")
            combined.append(contentsOf: Array(codeOnly(lines[next])))
            next += 1
        }
        guard let close = matchingParen(combined, from: open) else { return "()" }
        let inner = String(combined[(open + 1)..<close])
        let labels = splitTopLevel(inner, separator: ",").compactMap(parameterLabel)
        return "(" + labels.map { $0 + ":" }.joined() + ")"
    }

    private static let labelRegex = try! NSRegularExpression(pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(\w+)"#)

    private static func parameterLabel(_ piece: String) -> String? {
        let range = NSRange(piece.startIndex..., in: piece)
        guard let match = labelRegex.firstMatch(in: piece, range: range), let labelRange = Range(match.range(at: 1), in: piece) else { return nil }
        return String(piece[labelRange])
    }

    /// 深さ 0（`(`・`[`・`{`・`<` の外。`->` の `>` は数えない。文字列 literal の中は数えない）の `separator` で分ける。
    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var previous: Character = " "
        var skipNext = false
        for character in text {
            if skipNext { current.append(character); skipNext = false; previous = character; continue }
            if inString {
                if character == "\\" { skipNext = true } else if character == "\"" { inString = false }
                current.append(character)
                previous = character
                continue
            }
            switch character {
            case "\"": inString = true
            case "(", "[", "{", "<": depth += 1
            case ")", "]", "}": depth -= 1
            case ">": if previous != "-" { depth -= 1 }
            default: break
            }
            if character == separator, depth == 0 {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        pieces.append(current)
        return pieces
    }

    /// 深さ 0 の代入の `=` の添字（`==`・`!=`・`<=`・`>=` の `=` は数えない）。
    static func topLevelAssignmentIndex(_ characters: [Character]) -> Int? {
        var depth = 0
        var inString = false
        var cursor = 0
        while cursor < characters.count {
            let character = characters[cursor]
            if inString {
                if character == "\\" { cursor += 2; continue }
                if character == "\"" { inString = false }
                cursor += 1
                continue
            }
            switch character {
            case "\"": inString = true
            case "(", "[", "<": depth += 1
            case ")", "]": depth -= 1
            case ">": if cursor == 0 || characters[cursor - 1] != "-" { depth -= 1 }
            case "=":
                let previous: Character = cursor > 0 ? characters[cursor - 1] : " "
                let next: Character = cursor + 1 < characters.count ? characters[cursor + 1] : " "
                if depth == 0, !"=!<>".contains(previous), next != "=" { return cursor }
            default: break
            }
            cursor += 1
        }
        return nil
    }

    /// `name: Type = …` の `Type`。`:` の後から、深さ 0 の `=`・`{` か行末まで。
    static func annotatedType(of rest: String) -> String? {
        let characters = Array(rest)
        guard let colon = characters.firstIndex(of: ":") else { return nil }
        var depth = 0
        var inString = false
        var end = characters.count
        var cursor = colon + 1
        while cursor < characters.count {
            let character = characters[cursor]
            if inString {
                if character == "\\" { cursor += 2; continue }
                if character == "\"" { inString = false }
                cursor += 1
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "(" || character == "[" || character == "<" {
                depth += 1
            } else if character == ")" || character == "]" {
                depth -= 1
            } else if character == ">" {
                if characters[cursor - 1] != "-" { depth -= 1 }
            } else if depth == 0, character == "{" {
                end = cursor
                break
            } else if depth == 0, character == "=" {
                let previous = characters[cursor - 1]
                let next: Character = cursor + 1 < characters.count ? characters[cursor + 1] : " "
                if !"=!<>".contains(previous), next != "=" {
                    end = cursor
                    break
                }
            }
            cursor += 1
        }
        return String(characters[(colon + 1)..<end]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 関数型

    private static let leadingAttributeRegex = try! NSRegularExpression(pattern: #"^@\w+(?:\([^)]*\))?\s*"#)

    private static func strippingAttributes(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespaces)
        while result.hasPrefix("@") {
            let range = NSRange(result.startIndex..., in: result)
            guard let match = leadingAttributeRegex.firstMatch(in: result, range: range), let matched = Range(match.range, in: result) else { break }
            result = String(result[matched.upperBound...])
        }
        return result
    }

    /// 型の文字列から、全体を包む `(…)?` を外す（1 回だけ）。
    private static func strippingOptionalParentheses(_ text: String) -> String {
        let characters = Array(text)
        guard characters.first == "(", let close = matchingParen(characters, from: 0) else { return text }
        let tail = String(characters[(close + 1)...]).trimmingCharacters(in: .whitespaces)
        guard tail == "?" else { return text }
        return strippingAttributes(String(characters[1..<close]))
    }

    /// 先頭の属性を剥がし、全体が `(…)?` なら 1 回外した型が、`(…)` の後（`async`・`throws`・`rethrows` を飛ばす）に
    /// `->` が続く関数型かどうか。
    static func isFunctionType(_ typeText: String) -> Bool {
        let stripped = strippingOptionalParentheses(strippingAttributes(typeText))
        let characters = Array(stripped)
        guard characters.first == "(", let close = matchingParen(characters, from: 0) else { return false }
        var tail = String(characters[(close + 1)...]).trimmingCharacters(in: .whitespaces)
        var progressed = true
        while progressed {
            progressed = false
            for keyword in ["async", "rethrows", "throws"] where tail.hasPrefix(keyword) {
                let after = tail.dropFirst(keyword.count)
                if let first = after.first, isWordCharacter(first) { continue }
                tail = String(after).trimmingCharacters(in: .whitespaces)
                if keyword == "throws", tail.hasPrefix("("), let typedClose = matchingParen(Array(tail), from: 0) {
                    tail = String(Array(tail)[(typedClose + 1)...]).trimmingCharacters(in: .whitespaces)
                }
                progressed = true
            }
        }
        return tail.hasPrefix("->")
    }

    /// 関数型の戻り値の型（最後の深さ 0 の `->` の後ろ）。関数型でなければ nil。
    static func functionReturnType(_ typeText: String) -> String? {
        guard isFunctionType(typeText) else { return nil }
        let stripped = strippingOptionalParentheses(strippingAttributes(typeText))
        let pieces = stripped.components(separatedBy: "->")
        guard pieces.count >= 2, let last = pieces.last else { return nil }
        return last.trimmingCharacters(in: .whitespaces)
    }

    /// `func` の行の戻り値の型。`->` が無ければ nil。
    static func funcReturnType(_ rest: String) -> String? {
        var text = rest
        if let brace = text.firstIndex(of: "{") { text = String(text[..<brace]) }
        if let whereRange = text.range(of: " where ") { text = String(text[..<whereRange.lowerBound]) }
        guard let arrow = text.range(of: "->", options: .backwards) else { return nil }
        let candidate = String(text[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        return candidate.isEmpty ? nil : candidate
    }
}
