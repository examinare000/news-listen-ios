import Foundation

/// 構造検査の純関数。ファイル一覧と内容を受け取り、状態を持たない。
extension ArchitectureScan {

    // MARK: - 層の割当

    static func layerAssignment(paths: [String]) -> LayerAssignment {
        var unclassified: Set<String> = []
        var overlapped: Set<String> = []
        for path in Set(paths) {
            let count = ArchitectureManifest.matchedLayers(of: path).count
            if count == 0 { unclassified.insert(path) } else if count >= 2 { overlapped.insert(path) }
        }
        return LayerAssignment(unclassified: unclassified.sorted(), overlapped: overlapped.sorted())
    }

    // MARK: - adapter の分類

    private static let typealiasRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:public|internal|private|fileprivate)\s+)*typealias\s+(\w+)\s*=\s*([\w.]+)\s*$"#
    )

    /// 宣言の名前の後ろにある継承句の型名（`: A, B where …` の `A`・`B`）。
    private static func inheritedNames(of line: String, after name: String) -> [String] {
        let code = SwiftLines.codeOnly(line)
        guard let nameRange = code.range(of: name) else { return [] }
        var rest = String(code[nameRange.upperBound...])
        if rest.hasPrefix("<") {
            var depth = 0
            var end = rest.startIndex
            for index in rest.indices {
                if rest[index] == "<" { depth += 1 } else if rest[index] == ">" { depth -= 1 }
                end = rest.index(after: index)
                if depth == 0 { break }
            }
            rest = String(rest[end...])
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix(":") else { return [] }
        rest.removeFirst()
        if let brace = rest.firstIndex(of: "{") { rest = String(rest[..<brace]) }
        if let whereRange = rest.range(of: " where ") { rest = String(rest[..<whereRange.lowerBound]) }
        return SwiftLines.splitTopLevel(rest, separator: ",").compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let word = trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
            return word.isEmpty ? nil : String(word.split(separator: ".").last ?? word)
        }
    }

    static func adapterInventory(_ files: [SourceFile]) -> AdapterInventory {
        var protocolNames: Set<String> = []
        var extensionConformances: [String: Set<String>] = [:]
        for file in files {
            for line in file.lines {
                guard let declaration = SwiftLines.typeDeclaration(line) else { continue }
                if declaration.keyword == "protocol" {
                    protocolNames.insert(declaration.name)
                } else if declaration.keyword == "extension" {
                    extensionConformances[declaration.name, default: []].formUnion(inheritedNames(of: line, after: declaration.name))
                }
            }
        }

        var dto: Set<String> = []
        var concrete: Set<String> = []
        var pureValue: Set<String> = []
        var excludedPrivate: Set<String> = []
        var candidates: [(name: String, keyword: String, isPrivate: Bool, inherited: [String])] = []
        let adapterFiles = files.filter { ArchitectureManifest.layer(of: $0.path) == .adapter }
        for file in adapterFiles {
            for line in file.lines {
                if SourceGrep.isCommentLine(line) { continue }
                let range = NSRange(line.startIndex..., in: line)
                if let match = ArchitectureManifest.dtoDeclarationRegex.firstMatch(in: line, range: range), let nameRange = Range(match.range(at: 2), in: line) {
                    dto.insert(String(line[nameRange]))
                    continue
                }
                guard let declaration = SwiftLines.typeDeclaration(line),
                      ["struct", "enum", "class", "actor"].contains(declaration.keyword) else { continue }
                let isPrivate = declaration.modifiers.contains("private") || declaration.modifiers.contains("fileprivate")
                candidates.append((declaration.name, declaration.keyword, isPrivate, inheritedNames(of: line, after: declaration.name)))
            }
        }
        for candidate in candidates where !dto.contains(candidate.name) {
            if candidate.isPrivate {
                excludedPrivate.insert(candidate.name)
            } else if candidate.keyword == "class" || candidate.keyword == "actor" {
                concrete.insert(candidate.name)
            } else {
                let conforming = Set(candidate.inherited).union(extensionConformances[candidate.name] ?? [])
                if !conforming.isDisjoint(with: protocolNames) { concrete.insert(candidate.name) } else { pureValue.insert(candidate.name) }
            }
        }
        concrete.subtract(dto)
        pureValue.subtract(concrete)

        var aliases: [String: String] = [:]
        for file in files {
            for line in file.lines {
                let code = SwiftLines.codeOnly(line)
                guard let match = typealiasRegex.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)),
                      let aliasRange = Range(match.range(at: 1), in: code),
                      let targetRange = Range(match.range(at: 2), in: code) else { continue }
                let target = String(code[targetRange])
                if concrete.contains(target) { aliases[String(code[aliasRange])] = target }
            }
        }

        var factories: Set<AdapterFactory> = []
        for file in adapterFiles {
            let lines = file.lines
            for (index, line) in lines.enumerated() {
                if SwiftLines.isBlankOrComment(line) { continue }
                guard let member = SwiftLines.parseMember(line), member.modifiers.contains("static"),
                      ["func", "let", "var"].contains(member.keyword) else { continue }
                guard case .type(let chain) = SwiftLines.owner(ofMemberAt: index, in: lines),
                      let owner = chain.split(separator: ".").last.map(String.init), concrete.contains(owner) else { continue }
                let produced: String?
                if member.keyword == "func" {
                    produced = SwiftLines.funcReturnType(member.rest)
                } else {
                    produced = SwiftLines.annotatedType(of: member.rest)
                }
                guard let produced, [owner, owner + "?", "Self", "Self?"].contains(produced) else { continue }
                let name = String(SwiftLines.declarationName(member, at: index, in: lines).prefix { $0 != "(" })
                factories.insert(AdapterFactory(type: owner, name: name))
            }
        }
        return AdapterInventory(concrete: concrete, dto: dto, pureValue: pureValue, excludedPrivate: excludedPrivate, aliases: aliases, factories: factories)
    }

    // MARK: - adapter の生成

    static func constructionTargets(_ files: [SourceFile]) -> [String] {
        files.filter { ArchitectureManifest.layer(of: $0.path) != .compositionRoot }.map(\.path).sorted()
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func adapterConstructionHits(_ files: [SourceFile], inventory: AdapterInventory) -> [ScanHit] {
        let names = inventory.concrete.union(inventory.aliases.keys)
        guard !names.isEmpty else { return [] }
        let targets = Set(constructionTargets(files))
        let alternatives = names.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let initializer = regex(#"\b("# + alternatives + #")\("#)
        let explicitInit = regex(#"\b("# + alternatives + #")\.init\b"#)
        let factoryRegexes = inventory.factories.map {
            regex(#"\b"# + NSRegularExpression.escapedPattern(for: $0.type) + #"\."# + NSRegularExpression.escapedPattern(for: $0.name) + #"\b"#)
        }
        func factoryNames(of name: String) -> [String] {
            let resolved = inventory.aliases[name] ?? name
            return inventory.factories.filter { $0.type == resolved }.map(\.name).sorted()
        }
        func memberAlternatives(of name: String) -> String {
            (["init"] + factoryNames(of: name)).map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        }
        let assignments: [(name: String, regex: NSRegularExpression)] = names.sorted().map {
            ($0, regex(#":\s*"# + NSRegularExpression.escapedPattern(for: $0) + #"\??\s*=\s*\.("# + memberAlternatives(of: $0) + #")\b"#))
        }
        let implicitMembers: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues: names.map {
            ($0, regex(#"(^|[^\w.])\.("# + memberAlternatives(of: $0) + #")\b"#))
        })

        var hits: [ScanHit] = []
        for file in files where targets.contains(file.path) {
            let lines = file.lines
            let excluded = debugAndPreviewExcludedLines(lines)
            var hitLines: Set<Int> = []
            func record(_ index: Int) {
                if SourceGrep.isCommentLine(lines[index]) || excluded.contains(index) { return }
                hitLines.insert(index)
            }
            for (index, line) in lines.enumerated() {
                if matches(initializer, line) || matches(explicitInit, line) || factoryRegexes.contains(where: { matches($0, line) })
                    || assignments.contains(where: { matches($0.regex, line) }) {
                    record(index)
                }
                guard !SwiftLines.isBlankOrComment(line), let member = SwiftLines.parseMember(line) else { continue }
                guard let producedName = producedConcreteName(of: member, names: names) else { continue }
                guard let pattern = implicitMembers[producedName], let range = bodyRange(of: index, in: lines) else { continue }
                for position in range {
                    let text = position == index ? String(lines[position].split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().joined(separator: "{")) : lines[position]
                    if matches(pattern, text) { record(position) }
                }
            }
            for position in hitLines.sorted() {
                hits.append(ScanHit(path: file.path, line: position + 1, text: lines[position]))
            }
        }
        return hits.sorted { ($0.path, $0.line) < ($1.path, $1.line) }
    }

    /// 本体を調べる宣言（concrete か `concrete?` を返す `func`・computed `var`・closure 型の `let`/`var`）が返す型名。
    private static func producedConcreteName(of member: SwiftLines.Member, names: Set<String>) -> String? {
        func matched(_ type: String?) -> String? {
            guard let type else { return nil }
            let bare = type.hasSuffix("?") ? String(type.dropLast()) : type
            return names.contains(bare) ? bare : nil
        }
        let code = member.rest
        switch member.keyword {
        case "func":
            return matched(SwiftLines.funcReturnType(code))
        case "var", "let":
            guard code.contains("{"), let type = SwiftLines.annotatedType(of: code) else { return nil }
            let characters = Array(code)
            let braceIndex = characters.firstIndex(of: "{") ?? characters.count
            let assignmentIndex = SwiftLines.topLevelAssignmentIndex(characters)
            if let direct = matched(type) {
                // computed var: `=` が最初の `{` より前に無い。
                if member.keyword == "var", assignmentIndex == nil || assignmentIndex! > braceIndex { return direct }
                return nil
            }
            return matched(SwiftLines.functionReturnType(type))
        default:
            return nil
        }
    }

    // MARK: - port / read model

    static func portDefiningFiles(_ files: [SourceFile]) -> Set<String> {
        var result: Set<String> = []
        for file in files where ArchitectureManifest.layer(of: file.path) == .application {
            let lines = file.lines
            for (index, line) in lines.enumerated() {
                guard let declaration = SwiftLines.typeDeclaration(line) else { continue }
                if declaration.keyword == "protocol" {
                    result.insert(file.path)
                } else if declaration.keyword == "struct", isFunctionTypeStruct(startingAt: index, in: lines) {
                    result.insert(file.path)
                }
            }
        }
        return result
    }

    private static func isFunctionTypeStruct(startingAt index: Int, in lines: [String]) -> Bool {
        guard let range = bodyRange(of: index, in: lines), range.upperBound > range.lowerBound else { return false }
        let memberIndent = SwiftLines.indent(of: lines[index]) + 4
        var storedLets: [String] = []
        for position in (range.lowerBound + 1)...range.upperBound {
            let line = lines[position]
            guard !SwiftLines.isBlankOrComment(line), SwiftLines.indent(of: line) == memberIndent,
                  let member = SwiftLines.parseMember(line), member.keyword == "let" else { continue }
            storedLets.append(SwiftLines.annotatedType(of: member.rest) ?? "")
        }
        return !storedLets.isEmpty && storedLets.allSatisfy { SwiftLines.isFunctionType($0) }
    }

    static func readModelFiles(ledger: [OperationRow]) -> Set<String> {
        var kindsByFile: [String: [OperationKind]] = [:]
        for row in ledger { kindsByFile[row.file, default: []].append(row.kind) }
        return Set(kindsByFile.filter { entry in entry.value.allSatisfy { $0 == .readModel } }.keys)
    }

    // MARK: - 公開宣言

    static func publicDeclarations(_ files: [SourceFile]) -> PublicDeclarations {
        var declared: [DeclaredOperation] = []
        var unsupported: [UnsupportedDeclaration] = []
        for file in files {
            let lines = file.lines
            for (index, line) in lines.enumerated() {
                if SwiftLines.isBlankOrComment(line) { continue }
                let indent = SwiftLines.indent(of: line)
                guard indent % 4 == 0, let member = SwiftLines.parseMember(line) else { continue }
                // 1. local: すぐ外側の行が型の宣言でない。
                if let enclosing = SwiftLines.enclosingLine(of: index, in: lines), SwiftLines.typeDeclaration(lines[enclosing]) == nil { continue }
                // 2. 除外: private / fileprivate（`(set)` の無いもの）。
                if member.modifiers.contains("private") || member.modifiers.contains("fileprivate") { continue }
                // 3. 未知の修飾子。
                if member.modifiers.contains(where: { !SwiftLines.knownModifiers.contains($0) }) {
                    unsupported.append(UnsupportedDeclaration(path: file.path, line: index + 1, reason: .unsupportedModifier))
                    continue
                }
                // 4. ファイル直下。
                if indent == 0 {
                    unsupported.append(UnsupportedDeclaration(path: file.path, line: index + 1, reason: .topLevel))
                    continue
                }
                // 5. 所属の型。
                switch SwiftLines.owner(ofMemberAt: index, in: lines) {
                case .local:
                    continue
                case .unknown:
                    unsupported.append(UnsupportedDeclaration(path: file.path, line: index + 1, reason: .unknownOwner))
                case .type(let type):
                    // 6. 1 行に複数の宣言。
                    if (member.keyword == "var" || member.keyword == "let"), SwiftLines.splitTopLevel(member.rest, separator: ",").count > 1 {
                        unsupported.append(UnsupportedDeclaration(path: file.path, line: index + 1, reason: .multipleInOneLine))
                    } else {
                        declared.append(DeclaredOperation(file: file.path, type: type, name: SwiftLines.declarationName(member, at: index, in: lines)))
                    }
                }
            }
        }
        return PublicDeclarations(declared: declared, unsupported: unsupported)
    }

    // MARK: - 台帳

    static func ledgerMismatches(declared: [DeclaredOperation], ledger: [OperationRow], specIDs: Set<String>) -> [LedgerMismatch] {
        var declaredCounts: [DeclaredOperation: Int] = [:]
        for operation in declared { declaredCounts[operation, default: 0] += 1 }
        var ledgerCounts: [DeclaredOperation: Int] = [:]
        for row in ledger { ledgerCounts[DeclaredOperation(file: row.file, type: row.type, name: row.name), default: 0] += 1 }

        var mismatches: [LedgerMismatch] = []
        for key in Set(declaredCounts.keys).union(ledgerCounts.keys) {
            let inCode = declaredCounts[key] ?? 0
            let inLedger = ledgerCounts[key] ?? 0
            if inCode > inLedger {
                mismatches += Array(repeating: LedgerMismatch(kind: .notInLedger, file: key.file, type: key.type, name: key.name), count: inCode - inLedger)
            } else if inLedger > inCode {
                mismatches += Array(repeating: LedgerMismatch(kind: .notInCode, file: key.file, type: key.type, name: key.name), count: inLedger - inCode)
            }
        }
        for row in ledger {
            let identifier: String
            let expectedPrefix: String
            switch row.kind {
            case .command(let id): identifier = id; expectedPrefix = "ios-cmd-"
            case .query(let id): identifier = id; expectedPrefix = "ios-query-"
            default: continue
            }
            if !specIDs.contains(identifier) {
                mismatches.append(LedgerMismatch(kind: .unknownSpecID, file: row.file, type: row.type, name: row.name))
            }
            if !identifier.hasPrefix(expectedPrefix) {
                mismatches.append(LedgerMismatch(kind: .kindPrefixMismatch, file: row.file, type: row.type, name: row.name))
            }
        }
        return mismatches.sorted { ($0.file, $0.type, $0.name, "\($0.kind)") < ($1.file, $1.type, $1.name, "\($1.kind)") }
    }

    private static let operationIDRegex = try! NSRegularExpression(pattern: #"ios-[a-z]+-[a-z]+-\d+"#)

    /// ファイル冒頭（最初の「空行・コメント行・import 行・属性行」以外の行より前）の `// verifies:` に書かれた ID。
    private static func headerVerifiedIDs(_ file: SourceFile) -> Set<String> {
        var ids: Set<String> = []
        for line in file.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("//") {
                guard let marker = trimmed.range(of: "verifies:") else { continue }
                let tail = String(trimmed[marker.upperBound...])
                for match in operationIDRegex.matches(in: tail, range: NSRange(tail.startIndex..., in: tail)) {
                    if let range = Range(match.range, in: tail) { ids.insert(String(tail[range])) }
                }
                continue
            }
            if trimmed.hasPrefix("import ") || trimmed.hasPrefix("@testable import ") || SwiftLines.isAttributeOnly(line) { continue }
            break
        }
        return ids
    }

    static func uncoveredQueryRows(ledger: [OperationRow], testFiles: [SourceFile], doubleTypeNames: Set<String>) -> [String: [ScanHit]] {
        guard !doubleTypeNames.isEmpty else { return queryRows(in: ledger, notIn: []) }
        let doublePattern = regex(#"\b("# + doubleTypeNames.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + #")\b"#)
        var covered: Set<String> = []
        for file in testFiles {
            let ids = headerVerifiedIDs(file)
            if ids.isEmpty { continue }
            let referencesDouble = file.lines.contains { !SourceGrep.isCommentLine($0) && matches(doublePattern, $0) }
            if referencesDouble { covered.formUnion(ids) }
        }
        return queryRows(in: ledger, notIn: covered)
    }

    private static func queryRows(in ledger: [OperationRow], notIn covered: Set<String>) -> [String: [ScanHit]] {
        var result: [String: [ScanHit]] = [:]
        for (index, row) in ledger.enumerated() {
            guard case .query(let id) = row.kind, !covered.contains(id) else { continue }
            result[id, default: []].append(ScanHit(path: row.file, line: index + 1, text: "\(row.type).\(row.name)"))
        }
        return result
    }

    static func readWriteMixedHits(declared: [DeclaredOperation], operations: [(file: String, type: String, name: String)]) -> [ScanHit] {
        let present = Set(declared)
        return operations
            .filter { present.contains(DeclaredOperation(file: $0.file, type: $0.type, name: $0.name)) }
            .map { ScanHit(path: $0.file, line: 0, text: "\($0.type).\($0.name)") }
    }

    // MARK: - 生成境界の型

    static func validatedTypeVerdicts(_ files: [SourceFile], types: Set<String>) -> [String: ValidatedVerdict] {
        var verdicts: [String: ValidatedVerdict] = [:]
        for type in types {
            verdicts[type] = validatedVerdict(of: type, in: files)
        }
        return verdicts
    }

    private static func validatedVerdict(of type: String, in files: [SourceFile]) -> ValidatedVerdict {
        let escaped = NSRegularExpression.escapedPattern(for: type)
        let strict = regex(#"^(struct|enum|final class|class|actor) "# + escaped + #"\b"#)
        let broad = regex(
            #"^\s*(@\w+(\([^)]*\))?\s+)*((public|internal|open|fileprivate|private|final|indirect)\s+)*(struct|enum|class|actor|protocol|typealias)\s+"# + escaped + #"\b"#
        )
        var broadHits: [(file: SourceFile, index: Int)] = []
        var strictHits: [(file: SourceFile, index: Int, keyword: String)] = []
        for file in files {
            for (index, line) in file.lines.enumerated() {
                if SourceGrep.isCommentLine(line) { continue }
                if matches(broad, line) { broadHits.append((file, index)) }
                if let match = strict.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) {
                    strictHits.append((file, index, String(line[range])))
                }
            }
        }
        guard let firstBroad = broadHits.first else {
            return ValidatedVerdict(outcome: .skip, reasons: [], declaration: nil, initDeclarationCount: 0)
        }
        func hit(_ file: SourceFile, _ index: Int) -> ScanHit {
            ScanHit(path: file.path, line: index + 1, text: file.lines[index])
        }
        guard let declaration = strictHits.first else {
            return ValidatedVerdict(outcome: .red, reasons: [.unsupportedForm], declaration: hit(firstBroad.file, firstBroad.index), initDeclarationCount: 0)
        }

        var reasons: Set<ValidatedReason> = []
        if strictHits.count > 1 { reasons.insert(.duplicateDeclaration) }
        if declaration.keyword != "struct" || ArchitectureManifest.layer(of: declaration.file.path) != .domain { reasons.insert(.notDomainStruct) }

        let lines = declaration.file.lines
        var initCount = 0
        if let range = bodyRange(of: declaration.index, in: lines) {
            if range.contains(where: { lines[$0].contains("\t") }) { reasons.insert(.unsupportedIndent) }
            if range.upperBound > range.lowerBound {
                for position in (range.lowerBound + 1)...range.upperBound where SwiftLines.indent(of: lines[position]) == 4 && !SwiftLines.isBlankOrComment(lines[position]) {
                    guard let member = SwiftLines.parseMember(lines[position]) else { continue }
                    switch member.keyword {
                    case "init", "init?", "init!":
                        initCount += 1
                        let modifiers = member.modifiers
                        let privateForm = modifiers == ["private"] && (member.keyword == "init" || member.keyword == "init?")
                        let failableForm = (modifiers.isEmpty || modifiers == ["public"] || modifiers == ["internal"]) && member.keyword == "init?"
                        if !privateForm && !failableForm { reasons.insert(.uncheckedInit) }
                    case "var", "let":
                        if member.modifiers.contains(where: { !SwiftLines.knownModifiers.contains($0) }) { reasons.insert(.unsupportedModifier) }
                        let isTypeLevel = member.modifiers.contains("static") || member.modifiers.contains("class")
                        if member.keyword == "var", !isTypeLevel, isStoredVar(member, at: position, in: lines) { reasons.insert(.storedVar) }
                    default:
                        break
                    }
                }
            }
        } else {
            reasons.insert(.unsupportedForm)
        }
        if initCount == 0 { reasons.insert(.uncheckedInit) }

        return ValidatedVerdict(
            outcome: reasons.isEmpty ? .green : .red,
            reasons: reasons,
            declaration: reasons.isEmpty ? nil : hit(declaration.file, declaration.index),
            initDeclarationCount: initCount
        )
    }

    /// 格納の `var` か。fail-closed: computed とみなすのは、最初の `{` より前に深さ 0 の `=` が無く、
    /// かつ `{` の直後（同じ行に何も無ければ次の空でない行の先頭）が `didSet`・`willSet` でないときだけ。
    private static func isStoredVar(_ member: SwiftLines.Member, at index: Int, in lines: [String]) -> Bool {
        let characters = Array(member.rest)
        guard let brace = characters.firstIndex(of: "{") else { return true }
        if let assignment = SwiftLines.topLevelAssignmentIndex(characters), assignment < brace { return true }
        var after = String(characters[(brace + 1)...]).trimmingCharacters(in: .whitespaces)
        var next = index + 1
        while after.isEmpty, next < lines.count {
            after = SwiftLines.codeOnly(lines[next]).trimmingCharacters(in: .whitespaces)
            next += 1
        }
        return after.hasPrefix("didSet") || after.hasPrefix("willSet")
    }

    // MARK: - domain のテストの登録漏れ

    private static let declaredTypeRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|open|fileprivate|private|package|final|indirect)\s+)*(?:struct|enum|class|actor|protocol)\s+(\w+)"#
    )

    private static let productionTypeRegex = try! NSRegularExpression(
        pattern: #"^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|open|fileprivate|private|package|final|indirect)\s+)*(?:struct|enum|class|actor|protocol)\s+(\w+)"#
    )

    private static let importRegex = try! NSRegularExpression(pattern: #"^\s*(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)"#)

    private static let identifierRegex = try! NSRegularExpression(pattern: #"\b[A-Za-z_]\w*\b"#)

    private static func captured(_ regex: NSRegularExpression, in line: String) -> String? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[range])
    }

    static func unregisteredDomainTests(production: [SourceFile], tests: [SourceFile], registered: Set<String>) -> [String] {
        var layersByName: [String: Set<ArchitectureLayer?>] = [:]
        for file in production {
            let layer = ArchitectureManifest.layer(of: file.path)
            for line in file.lines where !SourceGrep.isCommentLine(line) {
                if let name = captured(productionTypeRegex, in: line) { layersByName[name, default: []].insert(layer) }
            }
        }
        var testDeclared: Set<String> = []
        for file in tests {
            for line in file.lines where !SourceGrep.isCommentLine(line) {
                if let name = captured(declaredTypeRegex, in: line) { testDeclared.insert(name) }
            }
        }
        for name in testDeclared { layersByName[name] = nil }

        let allowedImports: Set<String> = ["Foundation", "XCTest", "NewsListenApp"]
        var result: [String] = []
        for file in tests where !registered.contains(file.path) {
            var referenced: Set<String> = []
            var modules: Set<String> = []
            for line in file.lines where !SourceGrep.isCommentLine(line) {
                if let module = captured(importRegex, in: line) { modules.insert(module) }
                for match in identifierRegex.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    if let range = Range(match.range, in: line), layersByName[String(line[range])] != nil { referenced.insert(String(line[range])) }
                }
            }
            guard !referenced.isEmpty, modules.isSubset(of: allowedImports) else { continue }
            let layers = referenced.flatMap { layersByName[$0] ?? [] }
            if layers.allSatisfy({ $0 == .domain }) { result.append(file.path) }
        }
        return result.sorted()
    }
}
