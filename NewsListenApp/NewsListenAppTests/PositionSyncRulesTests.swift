import XCTest
@testable import NewsListenApp

/// 位置の記録の domain 規則（新しさの比較・取り込みの判定・記録の正規化）。domain の型だけを使う。
final class PositionSyncRulesTests: XCTestCase {

    private let t = Date(timeIntervalSince1970: 1_700_000_000)
    private var u: Date { t.addingTimeInterval(1) }

    // verifies: ios-rule-playback-09（時刻の無い値は最古・同時刻は新しくない）
    // kills: 同時刻を新しいとみなす／時刻なしを新しいとみなす／両方 nil を新しいとみなす
    func testIsNewerTreatsMissingTimeAsOldestAndEqualTimesAsNotNewer() {
        XCTAssertTrue(PositionSyncRules.isNewer(u, than: t))
        XCTAssertFalse(PositionSyncRules.isNewer(t, than: u))
        XCTAssertFalse(PositionSyncRules.isNewer(t, than: t))
        XCTAssertTrue(PositionSyncRules.isNewer(t, than: nil))
        XCTAssertFalse(PositionSyncRules.isNewer(nil, than: t))
        XCTAssertFalse(PositionSyncRules.isNewer(nil, than: nil))

        // 記録の生成は負の位置を 0 に、時刻をミリ秒へ切り捨てる。
        let record = PositionRecord(
            subject: subjectA, episodeId: "e", seconds: -1,
            recordedAt: Date(timeIntervalSince1970: 1.2345), isSent: false)
        XCTAssertEqual(record.seconds, 0)
        XCTAssertEqual(record.recordedAt.timeIntervalSince1970, 1.234, accuracy: 0.0001)
        let sent = record.markedSent()
        XCTAssertTrue(sent.isSent)
        XCTAssertEqual(sent.subject, record.subject)
        XCTAssertEqual(sent.episodeId, record.episodeId)
        XCTAssertEqual(sent.seconds, record.seconds)
        XCTAssertEqual(sent.recordedAt, record.recordedAt)
        XCTAssertFalse(record.isSent, "元の記録は変えない")
    }

    // verifies: ios-rule-playback-09（応答の取り込みは、記録があり応答が厳密に新しいときだけ）, shared-sync-06
    // kills: 同時刻・古い・時刻なしの応答で置き換える／記録の無いエピソードに応答を取り込む
    func testShouldAbsorbOnlyForStrictlyNewerResponseOverAnExistingRecord() {
        let record = PositionRecord(subject: subjectA, episodeId: "e", seconds: 10, recordedAt: t, isSent: true)
        let oneMillisecond: TimeInterval = 0.001

        XCTAssertTrue(PositionSyncRules.shouldAbsorb(
            RecordedPosition(seconds: 20, recordedAt: t.addingTimeInterval(oneMillisecond)), over: record))
        XCTAssertFalse(PositionSyncRules.shouldAbsorb(RecordedPosition(seconds: 20, recordedAt: t), over: record))
        XCTAssertFalse(PositionSyncRules.shouldAbsorb(
            RecordedPosition(seconds: 20, recordedAt: t.addingTimeInterval(-oneMillisecond)), over: record))
        XCTAssertFalse(PositionSyncRules.shouldAbsorb(RecordedPosition(seconds: 20, recordedAt: nil), over: record))
        XCTAssertFalse(PositionSyncRules.shouldAbsorb(RecordedPosition(seconds: 20, recordedAt: u), over: nil))
    }

    // verifies: shared-dec-32, shared-resume-08, shared-resume-09, shared-resume-11
    // kills: 端末の記録が新しいのにサーバーの値を選ぶ／同時刻でサーバーの値を選ぶ／サーバーが新しいのに端末の記録を選ぶ
    func testCandidatePrefersTheDeviceRecordWhenNewerOrEqualAndTheServerWhenNewer() {
        let record = PositionRecord(subject: subjectA, episodeId: "e", seconds: 100, recordedAt: u, isSent: false)
        let device = RecordedPosition(seconds: 100, recordedAt: record.recordedAt)

        XCTAssertEqual(
            PositionSyncRules.candidate(device: record, server: RecordedPosition(seconds: 30, recordedAt: t)), device,
            "端末の記録の方が新しい")
        XCTAssertEqual(
            PositionSyncRules.candidate(device: record, server: RecordedPosition(seconds: 30, recordedAt: u)), device,
            "同時刻は端末の記録（端末を変えない）")
        let newer = RecordedPosition(seconds: 30, recordedAt: u.addingTimeInterval(1))
        XCTAssertEqual(PositionSyncRules.candidate(device: record, server: newer), newer, "対照: サーバーが新しければサーバー")
    }

    // verifies: shared-dec-32, shared-resume-10, shared-resume-12
    // kills: 時刻の無いサーバーの値を新しいとみなす／端末の記録が無いのに nil や 0 を返す／記録が無いとき時刻を落とす
    func testCandidateTreatsAMissingServerTimeAsOldestAndAMissingRecordAsServer() {
        let record = PositionRecord(subject: subjectA, episodeId: "e", seconds: 100, recordedAt: u, isSent: false)

        XCTAssertEqual(
            PositionSyncRules.candidate(device: record, server: RecordedPosition(seconds: 30, recordedAt: nil)),
            RecordedPosition(seconds: 100, recordedAt: record.recordedAt),
            "時刻の無いサーバーの値は最古なので端末の記録")
        let untimed = RecordedPosition(seconds: 30, recordedAt: nil)
        XCTAssertEqual(PositionSyncRules.candidate(device: nil, server: untimed), untimed, "記録が無ければ時刻なしでもサーバー")
        let timed = RecordedPosition(seconds: 30, recordedAt: t)
        XCTAssertEqual(PositionSyncRules.candidate(device: nil, server: timed), timed, "記録が無ければサーバー（時刻も保つ）")
    }

    // MARK: - 記録時刻の読み（parse）

    /// `2026-11-17T01:02:03Z` の epoch 秒。
    private let baseEpochSeconds: Int64 = 1_794_877_323

    private func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // verifies: shared-sync-09, shared-dec-35
    // kills: 小数を四捨五入する／小数の桁数に上限を付ける／特定の桁数だけを拒む／小数 0 桁を読まない
    func testParseAcceptsZeroToNineFractionDigitsAndTruncatesToMilliseconds() {
        // (小数部, 期待するミリ秒の端数)。`9…9` の境界は、四捨五入すると次の秒へ繰り上がる。
        let cases: [(fraction: String, milliseconds: Int64)] = [
            ("", 0),
            ("1", 100),
            ("12", 120),
            ("123", 123),
            ("1239", 123),
            ("12345", 123), ("99999", 999),
            ("123456", 123), ("999999", 999),
            ("1234567", 123), ("9999999", 999),
            ("12345678", 123), ("99999999", 999),
            ("123456789", 123), ("999999999", 999),
        ]
        for (fraction, milliseconds) in cases {
            let input = "2026-11-17T01:02:03" + (fraction.isEmpty ? "" : "." + fraction) + "Z"
            guard let date = PositionSyncRules.parse(input) else {
                XCTFail("読めるはずの値が nil: \(input)")
                continue
            }
            XCTAssertEqual(epochMilliseconds(date), baseEpochSeconds * 1000 + milliseconds, input)
        }
    }

    // verifies: shared-sync-09, shared-dec-35
    // kills: offset の符号を逆にする／offset の分の部分を換算しない／+00:00・-00:00 を Z と違う値にする
    func testParseAppliesOffsets() {
        let cases: [(input: String, expected: Int64)] = [
            ("2026-11-17T10:00:00.500Z", 1_794_909_600_500),
            ("2026-11-17T10:00:00.500+00:00", 1_794_909_600_500),
            ("2026-11-17T10:00:00.500-00:00", 1_794_909_600_500),
            ("2026-11-17T10:00:00.500+09:00", 1_794_877_200_500),
            ("2026-11-17T10:00:00.500-05:30", 1_794_929_400_500),
        ]
        for (input, expected) in cases {
            guard let date = PositionSyncRules.parse(input) else {
                XCTFail("読めるはずの値が nil: \(input)")
                continue
            }
            XCTAssertEqual(epochMilliseconds(date), expected, input)
        }
    }

    // verifies: shared-sync-09, shared-dec-35
    // kills: 読めない値で epoch 0 などの既定値を返す／暦に無い日を読む／末尾の余りや区切りの違いを読む
    func testParseReturnsNilForUnreadableValues() {
        let unreadable: [String?] = [
            nil,
            "",
            "not-a-date",
            "2026-11-17",
            "2026-11-17T01:02:03",
            "2026-11-17T01:02:03.Z",
            "2026-11-17 01:02:03Z",
            "2026-11-17T1:02:03Z",
            "2026-11-17T01:02:03+0900",
            "2026-02-30T00:00:00Z",
            "2026-11-31T00:00:00Z",
            "2026-11-17T01:02:03Zx",
        ]
        for input in unreadable {
            XCTAssertNil(PositionSyncRules.parse(input), "読めない値は nil のはず: \(input ?? "nil")")
        }

        // 対照: 通常の値と、暦にあるうるう日は読む。
        XCTAssertEqual(
            PositionSyncRules.parse("2026-11-17T01:02:03Z").map(epochMilliseconds), baseEpochSeconds * 1000)
        XCTAssertEqual(
            PositionSyncRules.parse("2028-02-29T00:00:00Z").map(epochMilliseconds), 1_835_395_200_000)
    }
}
