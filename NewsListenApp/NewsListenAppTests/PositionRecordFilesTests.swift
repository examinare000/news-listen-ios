import XCTest
@testable import NewsListenApp

/// `PositionRecordFiles`（adapter）を一時ディレクトリの実ファイルで確かめる。
@MainActor
final class PositionRecordFilesTests: XCTestCase {

    private var directory: URL!
    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        // 作成前の（まだ無い）ディレクトリを渡し、`write` が作ることも確かめる。
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("position-record-files-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func record(_ subject: SubjectKey, _ id: String, _ seconds: Double, sent: Bool = false) -> PositionRecord {
        PositionRecord(subject: subject, episodeId: id, seconds: seconds, recordedAt: recordedAt, isSent: sent)
    }

    private func fileURL(_ subject: SubjectKey) -> URL {
        directory.appendingPathComponent("\(subject.rawValue).json")
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func placeRaw(_ text: String, for subject: SubjectKey) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL(subject))
    }

    /// 保存済みの JSON から、キー名に `needle`（大文字小文字を問わない）を含む項目を全階層で取り除く。
    private func stripKeys(containing needles: [String], in subject: SubjectKey) throws {
        func strip(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, child) in dictionary where !needles.contains(where: { key.lowercased().contains($0) }) {
                    result[key] = strip(child)
                }
                return result
            }
            if let array = value as? [Any] { return array.map(strip) }
            return value
        }
        let data = try Data(contentsOf: fileURL(subject))
        let object = try JSONSerialization.jsonObject(with: data)
        try JSONSerialization.data(withJSONObject: strip(object)).write(to: fileURL(subject))
    }

    // verifies: ios-dec-133（旧い記録・読めない記録は返さない）
    // kills: 版の無いファイルを読む／時刻の無い記録を返す／壊れた JSON で throw する
    func testReadIgnoresFilesWithoutVersionOrRecordsWithoutTime() throws {
        let files = PositionRecordFiles(directory: directory)

        // 対照: 正しく書いたファイルは読める（往復）。
        try files.write([record(subjectA, "e", 12.5)], for: subjectA)
        XCTAssertEqual(files.read(subjectA).map(\.episodeId), ["e"])

        // 版の無い JSON・配列だけの JSON・壊れた JSON は空。
        try placeRaw(#"{"records":[{"episodeId":"e","seconds":1.0,"isSent":false}]}"#, for: subjectB)
        XCTAssertTrue(files.read(subjectB).isEmpty)
        try placeRaw(#"[{"episodeId":"e","seconds":1.0}]"#, for: subjectB)
        XCTAssertTrue(files.read(subjectB).isEmpty)
        try placeRaw("not json", for: subjectB)
        XCTAssertTrue(files.read(subjectB).isEmpty)

        // 版つきのファイルから時刻の項目だけを取り除くと、その記録は捨てる。
        try stripKeys(containing: ["recorded", "time"], in: subjectA)
        XCTAssertTrue(files.read(subjectA).isEmpty, "時刻の無い記録は返さない")

        // 旧い形のファイルで組んだ PositionRecords の未送信も空。
        let records = PositionRecords(store: .live(files: files))
        records.bind(subject: subjectA)
        XCTAssertTrue(records.unsent().isEmpty)
    }

    // verifies: ios-dec-133（主体ごとのファイル・原子的な書込・回収）
    // kills: 別主体のファイルを消す／keeping を消す／無いファイルの削除で throw する／path traversal
    func testReclaimKeepsOnlyTheNamedSubjectFile() throws {
        let files = PositionRecordFiles(directory: directory)
        let a = record(subjectA, "e", 10, sent: false)
        let b = record(subjectB, "f", 20, sent: true)
        try files.write([a], for: subjectA)
        try files.write([b], for: subjectB)

        XCTAssertEqual(files.read(subjectA), [a], "書いた値がそのまま読める（往復）")
        XCTAssertEqual(files.read(subjectB), [b])
        XCTAssertEqual(try names(), ["user-a.json", "user-b.json"], "ファイル名は主体キーだけ")

        try files.reclaim(keeping: subjectA)
        XCTAssertEqual(try names(), ["user-a.json"])

        try files.removeSubject(subjectA)
        XCTAssertEqual(try names(), [])
        XCTAssertNoThrow(try files.removeSubject(subjectA), "無いファイルの削除は成功する")

        try files.write([a], for: subjectA)
        try files.write([b], for: subjectB)
        try files.reclaim(keeping: nil)
        XCTAssertEqual(try names(), [], "keeping が nil なら全部消す")
    }
}
