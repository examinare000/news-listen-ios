import XCTest
@testable import NewsListenApp

/// 構造検査の純関数（`ArchitectureScan`）に、手で作った `SourceFile` の fixture を渡して検出力を示す。
/// 違反のある fixture は検出され（RED の対照）、違反の無い版は通る（GREEN の対照）。
/// fixture は許可リストを通さない。path の決まり:
/// application は `Fixture/Application/*.swift`、adapter は `Networking/Fixture*.swift`、
/// domain は `Fixture/Domain/*.swift`、合成 root は `NewsListenAppApp.swift`。
final class ArchitectureFixtureTests: XCTestCase {

    // MARK: - 部品

    private func source(_ path: String, _ lines: String...) -> SourceFile {
        SourceFile(path: path, text: lines.joined(separator: "\n"))
    }

    private func lineNumber(of fragment: String, in file: SourceFile) -> Int {
        (file.lines.firstIndex { $0.contains(fragment) } ?? -1) + 1
    }

    private func counts(_ declared: [DeclaredOperation]) -> [String: Int] {
        var result: [String: Int] = [:]
        for declaration in declared { result[declaration.file, default: 0] += 1 }
        return result
    }

    // MARK: - adapter の fixture

    private let adapterPath = "Networking/FixtureGateway.swift"
    private let applicationUsePath = "Fixture/Application/UseCase.swift"
    private let rootPath = "NewsListenAppApp.swift"

    private var adapterFiles: [SourceFile] {
        [
            source(
                adapterPath,
                "final class FixtureGateway {}",
                "struct FixtureDTO: Codable {}",
                "struct FixtureValue {}",
                "struct FixtureStub: FixturePort {}",
                "struct FixtureLate {}",
                "extension FixtureLate: FixturePort {}",
                "private final class FixtureDelegate {}",
                "extension FixtureGateway {",
                "    static func live() -> FixtureGateway { .init() }",
                "    static func maybe() -> FixtureGateway? { .init() }",
                "}"
            ),
            source(
                "Fixture/Application/Aliases.swift",
                "protocol FixturePort {}",
                "typealias Gateway = FixtureGateway"
            ),
        ]
    }

    private func hits(applicationLines: [String], extra: [SourceFile] = []) -> [ScanHit] {
        let files = adapterFiles + extra + [SourceFile(path: applicationUsePath, text: applicationLines.joined(separator: "\n"))]
        let inventory = ArchitectureScan.adapterInventory(files)
        return ArchitectureScan.adapterConstructionHits(files, inventory: inventory)
    }

    private func hitsOutsideAdapter(_ files: [SourceFile]) -> [ScanHit] {
        let all = adapterFiles + files
        let inventory = ArchitectureScan.adapterInventory(all)
        return ArchitectureScan.adapterConstructionHits(all, inventory: inventory).filter { $0.path != adapterPath }
    }

    // MARK: - ios-check-01: 層の割当

    func testLayerAssignmentReportsUnclassifiedAndOverlappedPaths() {
        let paths = ArchitectureScan.productionSources().map(\.path)
        let before = ArchitectureScan.layerAssignment(paths: paths)
        XCTAssertTrue(before.unclassified.isEmpty, "足す前は未分類 0: \(before.unclassified)")
        XCTAssertTrue(before.overlapped.isEmpty, "足す前は重複 0: \(before.overlapped)")

        let after = ArchitectureScan.layerAssignment(paths: paths + ["Misc/NewThing.swift", "Podcast/Playback/NewView.swift"])
        XCTAssertEqual(after.unclassified, ["Misc/NewThing.swift"])
        XCTAssertEqual(after.overlapped, ["Podcast/Playback/NewView.swift"])
    }

    // MARK: - ios-check-01: adapter の分類

    func testAdapterInventoryClassifiesDeclarationsWithoutLiteralTypeNames() {
        let inventory = ArchitectureScan.adapterInventory(adapterFiles)

        XCTAssertEqual(inventory.concrete, ["FixtureGateway", "FixtureStub", "FixtureLate"])
        XCTAssertTrue(inventory.dto.contains("FixtureDTO"))
        XCTAssertTrue(inventory.pureValue.contains("FixtureValue"))
        XCTAssertTrue(inventory.excludedPrivate.contains("FixtureDelegate"))
        XCTAssertEqual(inventory.aliases, ["Gateway": "FixtureGateway"])
        XCTAssertTrue(inventory.factories.isSuperset(of: [
            AdapterFactory(type: "FixtureGateway", name: "live"),
            AdapterFactory(type: "FixtureGateway", name: "maybe"),
        ]))
    }

    // MARK: - ios-check-01: adapter の生成境界

    func testAdapterConstructionIsDetectedInApplicationForEveryConstructionForm() {
        let forms: [(label: String, lines: [String])] = [
            ("初期化子", ["let g = FixtureGateway()"]),
            ("typealias 経由", ["let g = Gateway()"]),
            ("static factory 経由", ["let g = FixtureGateway.live()"]),
            ("closure の中の生成", ["let make: () -> FixtureGateway = { FixtureGateway() }"]),
            ("型を書いた代入の .init", ["let g: FixtureGateway = .init()"]),
            ("optional を返す factory 関数の本体", [
                "enum Factory {",
                "    static func make() -> FixtureGateway? {",
                "        .init()",
                "    }",
                "}",
            ]),
            ("computed var の本体", [
                "enum Holder {",
                "    static var g: FixtureGateway {",
                "        .init()",
                "    }",
                "}",
            ]),
            ("closure の implicit member", ["let make: () -> FixtureGateway = { .init() }"]),
            ("型を書いた代入の factory", ["let g: FixtureGateway = .live()"]),
        ]
        for form in forms {
            let found = hits(applicationLines: form.lines).filter { $0.path == applicationUsePath }
            XCTAssertFalse(found.isEmpty, "application の生成が検出されない: \(form.label)")
        }
    }

    func testAdapterConstructionIsAllowedInCompositionRoot() {
        let violating = ["let g = FixtureGateway()"]
        XCTAssertFalse(
            hits(applicationLines: violating).filter { $0.path == applicationUsePath }.isEmpty,
            "正の対照: 同じ行が application では検出される"
        )
        let allowed = hitsOutsideAdapter([source(rootPath, violating[0])])
        XCTAssertTrue(allowed.isEmpty, "合成 root の生成は検出されない: \(allowed.map(\.path))")
    }

    func testAdapterConstructionIsAllowedInsideDebugBlock() {
        XCTAssertFalse(
            hits(applicationLines: ["let g = FixtureGateway()"]).filter { $0.path == applicationUsePath }.isEmpty,
            "正の対照: 同じ行が #if DEBUG の外では検出される"
        )
        let inDebug = hits(applicationLines: ["#if DEBUG", "let g = FixtureGateway()", "#endif"]).filter { $0.path == applicationUsePath }
        XCTAssertTrue(inDebug.isEmpty, "#if DEBUG の中の生成は検出されない: \(inDebug.map(\.text))")
    }

    func testConstructionTargetsAreChosenByLayerNotByViolation() {
        let root = source(rootPath, "let g = FixtureGateway()")
        let violating = source(applicationUsePath, "let g = FixtureGateway()")
        let clean = source(applicationUsePath, "let g = 1")

        let withViolation = Set(ArchitectureScan.constructionTargets(adapterFiles + [root, violating]))
        let withoutViolation = Set(ArchitectureScan.constructionTargets(adapterFiles + [root, clean]))

        XCTAssertTrue(withViolation.contains(applicationUsePath), "違反のあるファイルが対象から外れている")
        XCTAssertFalse(withViolation.contains(rootPath), "合成 root が対象に入っている")
        XCTAssertEqual(withViolation, withoutViolation, "違反の有無で対象が変わっている")
    }

    // MARK: - ios-check-01: port / read model の登録

    func testPortDefiningFilesIncludeProtocolsAndFunctionTypeStructsInAnyIndentOrAttributeForm() {
        let protocolFile = source("Fixture/Application/PortProtocol.swift", "protocol FixturePort {}")
        let gatewayFile = source(
            "Fixture/Application/GatewayPort.swift",
            "struct FixtureGatewayPort {",
            "    let fetch: () async throws -> Int",
            "    let save: @Sendable (Int) -> Void",
            "    let observe: ((Int) -> Void)?",
            "}"
        )
        let pairFile = source(
            "Fixture/Application/Pair.swift",
            "struct FixturePair {",
            "    let p: (Int, Int)",
            "    let f: () -> Void",
            "}"
        )
        let mixedFile = source(
            "Fixture/Application/Mixed.swift",
            "struct FixtureMixed {",
            "    let fetch: () -> Int",
            "    let name: String",
            "}"
        )
        let actorFile = source(
            "Fixture/Application/ActorPort.swift",
            "@MainActor struct FixtureActorPort {",
            "    let run: () -> Void",
            "}"
        )
        let expected: Set<String> = [protocolFile.path, gatewayFile.path, actorFile.path]

        let found = ArchitectureScan.portDefiningFiles([protocolFile, gatewayFile, pairFile, mixedFile, actorFile])

        XCTAssertEqual(found, expected, "関数型でない let が混ざる struct を port として数えている、または port を落としている")
        XCTAssertEqual(ArchitectureScan.registrationDiff(derived: found, registered: expected), RegistrationDiff(unregistered: [], stale: []))
        XCTAssertEqual(
            ArchitectureScan.registrationDiff(derived: found, registered: expected.union([pairFile.path])),
            RegistrationDiff(unregistered: [], stale: [pairFile.path]),
            "protocol を持たない path の登録は、実体の無い登録として返る"
        )
        XCTAssertEqual(
            ArchitectureScan.registrationDiff(derived: found, registered: []).unregistered,
            expected,
            "未登録の port のファイルが登録漏れとして返る"
        )
    }

    func testReadModelFilesAreTheFilesWhoseLedgerRowsAreAllReadModel() {
        let readModelPath = "Fixture/Application/EpisodeRow.swift"
        let mixedPath = "Fixture/Application/Mixed.swift"
        let ledger: [OperationRow] = [
            (file: readModelPath, type: "EpisodeRow", name: "title", kind: .readModel),
            (file: mixedPath, type: "Mixed", name: "title", kind: .readModel),
            (file: mixedPath, type: "Mixed", name: "load()", kind: .command("ios-cmd-account-02")),
        ]

        let found = ArchitectureScan.readModelFiles(ledger: ledger)

        XCTAssertEqual(found, [readModelPath])
        XCTAssertEqual(ArchitectureScan.registrationDiff(derived: found, registered: []).unregistered, [readModelPath])
        XCTAssertEqual(ArchitectureScan.registrationDiff(derived: found, registered: [readModelPath]), RegistrationDiff(unregistered: [], stale: []))
    }

    // MARK: - ios-check-15 (a): 公開宣言の抽出

    func testPublicDeclarationsCountMembersByOwnerTypeAndRejectUnsupportedForms() {
        let outer = source(
            "Fixture/Application/Outer.swift",
            "struct Outer {",
            "    private(set) var a: Int",
            "    private var b: Int",
            "    fileprivate let c: Int",
            "    @Published private(set) var d = 0",
            "    case e",
            "    nonisolated func f()",
            "    init(x: Int,",
            "         y: (Int, Int) -> Void = { _, _ in })",
            "    struct Inner {",
            "        var g: Int",
            "        func h()",
            "    }",
            "    func k() {",
            "        let local = 1",
            "    }",
            "    let m = 1, n = 2",
            "    package func p()",
            "    nonisolated(unsafe) var q = 0",
            "    func k2() {",
            "        struct Local {",
            "            var z: Int",
            "        }",
            "        if let w = Optional(1) { }",
            "    }",
            "}"
        )
        let topLevel = source("Fixture/Application/TopLevel.swift", "func topLevel()")

        let result = ArchitectureScan.publicDeclarations([outer, topLevel])

        let expectedDeclared: Set<DeclaredOperation> = [
            DeclaredOperation(file: outer.path, type: "Outer", name: "a"),
            DeclaredOperation(file: outer.path, type: "Outer", name: "d"),
            DeclaredOperation(file: outer.path, type: "Outer", name: "f()"),
            DeclaredOperation(file: outer.path, type: "Outer", name: "init(x:y:)"),
            DeclaredOperation(file: outer.path, type: "Outer.Inner", name: "g"),
            DeclaredOperation(file: outer.path, type: "Outer.Inner", name: "h()"),
            DeclaredOperation(file: outer.path, type: "Outer", name: "k()"),
            DeclaredOperation(file: outer.path, type: "Outer", name: "k2()"),
        ]
        XCTAssertEqual(Set(result.declared), expectedDeclared)
        XCTAssertEqual(result.declared.count, expectedDeclared.count, "同じ宣言が重複して数えられている")

        let expectedUnsupported: Set<UnsupportedDeclaration> = [
            UnsupportedDeclaration(path: outer.path, line: lineNumber(of: "let m = 1, n = 2", in: outer), reason: .multipleInOneLine),
            UnsupportedDeclaration(path: outer.path, line: lineNumber(of: "package func p()", in: outer), reason: .unsupportedModifier),
            UnsupportedDeclaration(path: outer.path, line: lineNumber(of: "nonisolated(unsafe) var q", in: outer), reason: .unsupportedModifier),
            UnsupportedDeclaration(path: topLevel.path, line: 1, reason: .topLevel),
        ]
        XCTAssertEqual(Set(result.unsupported), expectedUnsupported, "関数の中の `if let` を unsupported に入れていないこと、未対応の形を落とさないこと")
    }

    // MARK: - ios-check-15 (a): 台帳との照合

    private let opsPath = "Fixture/Application/Ops.swift"
    private let opsSpecIDs: Set<String> = ["ios-query-account-01", "ios-cmd-account-02", "ios-cmd-account-03"]

    private func opsLedger(
        doIt: OperationKind = .command("ios-cmd-account-02"),
        other: OperationKind = .command("ios-cmd-account-03"),
        omitting omitted: String? = nil
    ) -> [OperationRow] {
        let rows: [OperationRow] = [
            (file: opsPath, type: "Ops", name: "state", kind: .query("ios-query-account-01")),
            (file: opsPath, type: "Ops", name: "doIt()", kind: doIt),
            (file: opsPath, type: "Ops", name: "other()", kind: other),
        ]
        return rows.filter { $0.name != omitted }
    }

    private func mismatchKinds(code extraLines: [String] = [], without removed: String? = nil, ledger: [OperationRow]) -> Set<LedgerMismatchKind> {
        var lines = [
            "struct Ops {",
            "    var state: Int",
            "    func doIt()",
            "    func other()",
        ]
        if let removed { lines.removeAll { $0.contains(removed) } }
        lines += extraLines
        lines.append("}")
        let declared = ArchitectureScan.publicDeclarations([SourceFile(path: opsPath, text: lines.joined(separator: "\n"))]).declared
        return Set(ArchitectureScan.ledgerMismatches(declared: declared, ledger: ledger, specIDs: opsSpecIDs).map(\.kind))
    }

    func testLedgerMatchesCodeWhenNothingChanged() {
        XCTAssertEqual(mismatchKinds(ledger: opsLedger()), [], "変えていない対照は不一致 0")
        XCTAssertEqual(ArchitectureScan.publicDeclarations([source(opsPath, "struct Ops {", "    var state: Int", "    func doIt()", "    func other()", "}")]).declared.count, 3)
    }

    func testLedgerReportsPublicDeclarationMissingFromLedger() {
        XCTAssertEqual(mismatchKinds(code: ["    func extraCommand()"], ledger: opsLedger()), [.notInLedger])
        XCTAssertEqual(mismatchKinds(code: ["    private(set) var extra: Int"], ledger: opsLedger()), [.notInLedger], "private(set) の宣言も母集団に含む")
        XCTAssertEqual(mismatchKinds(ledger: opsLedger(omitting: "state")), [.notInLedger], "台帳から行を消すと宣言が台帳に無い")
    }

    func testLedgerReportsLedgerRowMissingFromCode() {
        XCTAssertEqual(mismatchKinds(without: "func other()", ledger: opsLedger()), [.notInCode])
    }

    func testLedgerReportsOperationIDsOutsideTargetArchitectureSection5() {
        XCTAssertEqual(mismatchKinds(ledger: opsLedger(doIt: .command("ios-cmd-account-99"))), [.unknownSpecID])
    }

    func testLedgerReportsKindAndIDPrefixMismatch() {
        XCTAssertEqual(mismatchKinds(ledger: opsLedger(other: .command("ios-query-account-01"))), [.kindPrefixMismatch])
    }

    // MARK: - ios-check-15 (b): 台帳の query と verifies

    private let queryID = "ios-query-account-01"

    private var queryLedger: [OperationRow] {
        [(file: "AppState.swift", type: "AppState", name: "session", kind: .query(queryID))]
    }

    private func uncovered(_ testFile: SourceFile) -> [String: [ScanHit]] {
        ArchitectureScan.uncoveredQueryRows(
            ledger: queryLedger,
            testFiles: [testFile],
            doubleTypeNames: RecordingPorts.doubleTypeNames
        )
    }

    func testQueryWithoutVerifiesCommentIsReportedAsUncovered() {
        let found = uncovered(source("Fixture/NoComment.swift", "import XCTest", "final class A: XCTestCase {}"))
        XCTAssertEqual(found[queryID]?.count, 1)
        XCTAssertEqual(found[queryID]?.first?.path, "AppState.swift")
    }

    func testQueryWithVerifiesCommentButNoRecordingDoubleIsReportedAsUncovered() {
        let found = uncovered(source("Fixture/NoDouble.swift", "// verifies: \(queryID)", "import XCTest", "final class B: XCTestCase {}"))
        XCTAssertEqual(found[queryID]?.count, 1)
    }

    func testVerifiesCommentInsideFunctionBodyDoesNotCover() {
        let found = uncovered(source(
            "Fixture/Late.swift",
            "import XCTest",
            "final class C: XCTestCase {",
            "    func test() {",
            "        let s = \"// verifies: \(queryID)\"",
            "        _ = RecordingSessionStore()",
            "    }",
            "}"
        ))
        XCTAssertEqual(found[queryID]?.count, 1)
    }

    func testQueryCoveredByHeaderCommentAndRecordingDoubleIsNotReported() {
        let found = uncovered(source(
            "Fixture/Covered.swift",
            "// verifies: \(queryID)",
            "import XCTest",
            "final class D: XCTestCase {",
            "    func test() { _ = RecordingSessionStore() }",
            "}"
        ))
        XCTAssertNil(found[queryID])
    }

    // MARK: - ios-check-15: 読み書きの混在の追跡

    private let mixedOperations: [(file: String, type: String, name: String)] = [
        (file: "Fixture/Application/AppStateFixture.swift", type: "AppState", name: "refreshPreferences()"),
        (file: "Fixture/Application/AppStateFixture.swift", type: "AppState", name: "refreshListeningStreak()"),
        (file: "Fixture/Application/AppStateFixture.swift", type: "AppState", name: "refreshOnboardingStatus()"),
    ]

    private func mixedHits(_ memberLines: [String]) -> [ScanHit] {
        let file = SourceFile(
            path: "Fixture/Application/AppStateFixture.swift",
            text: (["struct AppState {"] + memberLines + ["}"]).joined(separator: "\n")
        )
        let declared = ArchitectureScan.publicDeclarations([file]).declared
        return ArchitectureScan.readWriteMixedHits(declared: declared, operations: mixedOperations)
    }

    func testReadWriteMixedOperationsAreCountedFromCodeNotFromLiterals() {
        let all = ["    func refreshPreferences()", "    func refreshListeningStreak()", "    func refreshOnboardingStatus()"]
        XCTAssertEqual(mixedHits(all).count, 3)
        XCTAssertEqual(mixedHits(Array(all.dropFirst())).count, 2, "宣言を消すと件数が減る（literal どうしの比較ではない）")
    }

    // MARK: - ios-check-16: 生成境界の型列挙

    private let validatedFixturePath = "Fixture/Domain/ValidatedFixture.swift"

    private func validatedFixtureText() -> String {
        let text = SourceGrep.content(of: SourceGrep.testRoot.appendingPathComponent("ValidatedFixture.swift"))
        XCTAssertFalse(text.isEmpty, "ValidatedFixture.swift を読めない")
        return text
    }

    private func verdict(of text: String, path: String? = nil) -> ValidatedVerdict? {
        let file = SourceFile(path: path ?? validatedFixturePath, text: text)
        return ArchitectureScan.validatedTypeVerdicts([file], types: ["ValidatedFixture"])["ValidatedFixture"]
    }

    private func replacing(_ text: String, _ target: String, with replacement: String) -> String {
        XCTAssertTrue(text.contains(target), "変異の対象が本文に無い: \(target)")
        return text.replacingOccurrences(of: target, with: replacement)
    }

    func testValidatedFixtureIsGreenEvenWithComputedVar() {
        let verdict = verdict(of: validatedFixtureText())
        XCTAssertEqual(verdict?.outcome, .green, "原本は green（理由: \(String(describing: verdict?.reasons))）")
        XCTAssertEqual(verdict?.reasons, [])
    }

    func testValidatedFixtureMutationsAreRedForTheirOwnReason() {
        let original = validatedFixtureText()
        let wrapped = "struct Wrapper {\n" + original.components(separatedBy: "\n").map { "    " + $0 }.joined(separator: "\n") + "\n}"
        let mutations: [(label: String, text: String, path: String?, reason: ValidatedReason)] = [
            ("let を var にする", replacing(original, "    let name: String", with: "    var name: String"), nil, .storedVar),
            ("didSet つきの var を足す", replacing(original, "    let count: Int", with: "    let count: Int\n    var x: Int = 0 { didSet { } }"), nil, .storedVar),
            ("closure で初期化する var を足す", replacing(original, "    let count: Int", with: "    let count: Int\n    var y: [Int] = { [1] }()"), nil, .storedVar),
            ("private init を素の init にする", replacing(original, "    private init(", with: "    init("), nil, .uncheckedInit),
            ("private init を public init にする", replacing(original, "    private init(", with: "    public init("), nil, .uncheckedInit),
            ("private init を package init にする", replacing(original, "    private init(", with: "    package init("), nil, .uncheckedInit),
            ("let を private(set) var にする", replacing(original, "    let name: String", with: "    private(set) var name: String"), nil, .storedVar),
            ("let を public var にする", replacing(original, "    let name: String", with: "    public var name: String"), nil, .storedVar),
            ("init を削る", replacing(original, "    private init(name: String, count: Int) {", with: "    private func build(name: String, count: Int) {"), nil, .uncheckedInit),
            ("struct を enum にする", replacing(original, "struct ValidatedFixture {", with: "enum ValidatedFixture {"), nil, .notDomainStruct),
            ("domain の外の path にする", original, "Models/ValidatedFixture.swift", .notDomainStruct),
            ("public struct にする", replacing(original, "struct ValidatedFixture {", with: "public struct ValidatedFixture {"), nil, .unsupportedForm),
            ("別の型の中に入れる", wrapped, nil, .unsupportedForm),
        ]
        for mutation in mutations {
            let result = verdict(of: mutation.text, path: mutation.path)
            XCTAssertEqual(result?.outcome, .red, "red にならない: \(mutation.label)")
            XCTAssertTrue(result?.reasons.contains(mutation.reason) ?? false, "理由が違う: \(mutation.label) \(String(describing: result?.reasons))")
        }
    }

    func testValidatedFixtureIsSkippedWhenOnlyReferencedAndGreenWhenExtensionAddsInit() {
        XCTAssertEqual(verdict(of: "let value: ValidatedFixture? = nil")?.outcome, .skip, "宣言が無い型だけが skip")

        let withExtension = validatedFixtureText() + "\nextension ValidatedFixture {\n    init(raw: String) {\n        self.init(name: raw, count: 0)\n    }\n}\n"
        XCTAssertEqual(verdict(of: withExtension)?.outcome, .green, "extension の init は本体の外")
    }

    func testInitDeclarationCountCountsOnlyBodyInits() {
        let verdicts = ArchitectureScan.validatedTypeVerdicts(ArchitectureScan.productionSources(), types: ["PlaybackQueue", "PlayableEpisode"])
        XCTAssertEqual(verdicts["PlaybackQueue"]?.initDeclarationCount, 1)
        XCTAssertEqual(verdicts["PlayableEpisode"]?.initDeclarationCount, 1)

        let withoutInit = replacing(validatedFixtureText(), "    private init(name: String, count: Int) {", with: "    private func build(name: String, count: Int) {")
        XCTAssertEqual(verdict(of: withoutInit)?.initDeclarationCount, 0, "init を消した型は 0")
    }

    // MARK: - ios-check-08: domain のテストの登録漏れ

    private let domainOnlyPath = "Fixture/DomainOnlyTests.swift"

    private func unregistered(_ tests: [SourceFile], registered: Set<String> = ArchitectureManifest.domainTestFiles) -> Set<String> {
        let declaring = source("Fixture/Declares.swift", "enum ArchitectureManifest {}")
        return Set(ArchitectureScan.unregisteredDomainTests(
            production: ArchitectureScan.productionSources(),
            tests: tests + [declaring],
            registered: registered
        ))
    }

    func testDomainOnlyTestFileMustBeRegistered() {
        let domainOnly = source(
            domainOnlyPath,
            "import XCTest",
            "@testable import NewsListenApp",
            "final class DomainOnlyTests: XCTestCase {",
            "    func test() { _ = PlayableEpisode.self }",
            "}"
        )
        XCTAssertEqual(unregistered([domainOnly]), [domainOnlyPath])
        XCTAssertEqual(unregistered([domainOnly], registered: ArchitectureManifest.domainTestFiles.union([domainOnlyPath])), [], "登録すると返らない")
    }

    func testTestFilesNotReferencingOnlyDomainTypesAreNotReported() {
        let combine = source(
            "Fixture/CombineTests.swift",
            "import XCTest",
            "import Combine",
            "@testable import NewsListenApp",
            "final class CombineTests: XCTestCase {",
            "    func test() { _ = PlayableEpisode.self }",
            "}"
        )
        let mixedLayers = source(
            "Fixture/MixedLayerTests.swift",
            "import XCTest",
            "@testable import NewsListenApp",
            "final class MixedLayerTests: XCTestCase {",
            "    func test() { _ = PlayableEpisode.self; _ = Podcast.self }",
            "}"
        )
        let testTargetOnly = source(
            "Fixture/TestTargetOnlyTests.swift",
            "import XCTest",
            "final class TestTargetOnlyTests: XCTestCase {",
            "    func test() { _ = ArchitectureManifest.domainTestFiles }",
            "}"
        )
        XCTAssertEqual(unregistered([combine, mixedLayers, testTargetOnly]), [])
        XCTAssertEqual(
            unregistered([source(domainOnlyPath, "import XCTest", "final class DomainOnlyTests: XCTestCase {", "    func test() { _ = PlayableEpisode.self }", "}")]),
            [domainOnlyPath],
            "正の対照: 同じ参照だけの組は返る"
        )
    }
}
