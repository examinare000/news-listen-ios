import XCTest
@testable import NewsListenApp

/// 共有仕様の対象 26 行が、テストメソッドの名前から引けることを固定する（ios-dec-185）。
/// 名前に行 ID を含むメソッドが 1 本も無い行があれば、その行 ID を並べて落ちる。
final class SharedRowIdCoverageTests: XCTestCase {

    private let expectedRowIDs: Set<String> = [
        "shared-queue-05", "shared-queue-06", "shared-queue-11", "shared-queue-12", "shared-queue-17",
        "shared-queue-18", "shared-queue-21", "shared-queue-22", "shared-queue-23", "shared-queue-24",
        "shared-queue-27", "shared-queue-29", "shared-queue-30", "shared-queue-31", "shared-queue-33",
        "shared-session-02", "shared-session-03", "shared-session-06", "shared-session-09",
        "shared-sync-01", "shared-sync-02", "shared-sync-03", "shared-sync-04", "shared-sync-06",
        "shared-sync-08", "shared-sync-15"
    ]

    private let thisFileName = "SharedRowIdCoverageTests.swift"

    func testSharedRowIdsOfTheTwentySixRowsAreDeclaredByTestNames() {
        let all = ArchitectureScan.testSources()
        // 合成の例を持つこのファイル自身は、実在のテスト名の集計に含めない。
        let scanned = all.filter { $0.path != thisFileName }
        XCTAssertFalse(scanned.isEmpty, "走査対象のテストソースが 0 件")
        XCTAssertEqual(all.count - scanned.count, 1, "このファイルの自己除外がちょうど 1 件に働いていない（path の形がずれている）")

        let observed = scanned.reduce(into: Set<String>()) { $0.formUnion(ArchitectureScan.sharedRowIDs(declaredIn: $1)) }
        XCTAssertFalse(observed.isDisjoint(with: expectedRowIDs), "26 行のどの行 ID もテスト名から読めない")
        let missing = expectedRowIDs.subtracting(observed).sorted()
        XCTAssertTrue(missing.isEmpty, "名前に行 ID を含むテストが無い行: \(missing.joined(separator: ", "))")

        let queueFile = SourceFile(
            path: "PlaybackQueueConformanceTests.swift",
            text: SourceGrep.content(of: SourceGrep.testRoot.appendingPathComponent("PlaybackQueueConformanceTests.swift"))
        )
        XCTAssertTrue(
            ArchitectureScan.sharedRowIDs(declaredIn: queueFile).contains("shared-queue-01"),
            "実在のキューのテストファイルから shared-queue-01 が読めない"
        )

        func ids(_ lines: [String]) -> Set<String> {
            ArchitectureScan.sharedRowIDs(declaredIn: SourceFile(path: "Synthetic.swift", text: lines.joined(separator: "\n")))
        }
        let declaration = ["    func testSharedSync99_x() {}"]
        XCTAssertEqual(ids(declaration), ["shared-sync-99"])
        XCTAssertEqual(ids(declaration), ids(declaration), "同じ入力から毎回同じ集合が返る")
        XCTAssertEqual(ids(["    func testQ07_x() {}"]), ["shared-queue-07"])
        XCTAssertEqual(ids(["    func testSharedQueue33_x() {}"]), ["shared-queue-33"])
        XCTAssertEqual(ids(["    func testSharedSession02() {}"]), ["shared-session-02"])

        let rejected: [String: [String]] = [
            "行コメント": ["    // func testSharedSync99_commented() {}"],
            "行末コメント": ["    let a = 1 // func testSharedSync99_trailing()"],
            "単一行の文字列": ["    let s = \"func testSharedSync99_inString()\""],
            "宣言でない行": ["    let b = testSharedSync99_notADeclaration()"],
            "verifies 注記": ["    // verifies: shared-sync-99"],
            "複数行の文字列": ["    let s = \"\"\"", "    func testSharedSync99_inMultilineString() {}", "    \"\"\""],
            "番号が 3 桁": ["    func testQ123_x() {}"],
            "番号の後が英字": ["    func testQAB() {}"]
        ]
        for (label, lines) in rejected {
            XCTAssertEqual(ids(lines), [], "\(label)から行 ID を読んではいけない")
        }
    }
}
