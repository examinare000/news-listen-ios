import XCTest
@testable import NewsListenApp

/// クロスプラットフォーム共有仕様（docs/design/shared-playback-spec.md §4.2）の
/// 正本テストケース表 shared-reltime-01〜shared-reltime-15・shared-reltime-16・shared-reltime-17 の準拠テスト。
///
/// `formatRelativeTime(_:now:)` と `Date.ISO8601String()` は RelativeTimeFormatterTests.swift
/// で定義済みのテストヘルパー（同一ターゲット内で共有）を再利用する。
/// 既存の RelativeTimeFormatterTests.swift は変更・削除せず、本ファイルと併存させる。
final class RelativeTimeConformanceTests: XCTestCase {

    private let base: TimeInterval = 1_700_000_000

    // MARK: - shared-reltime-01: 未来（diff < 0）

    func testRT01_futureReturnsImminent() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base + 60).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "もうすぐ")
    }

    // MARK: - shared-reltime-02〜shared-reltime-04: たった今（< 60 秒）

    func testRT02_threeSecondsReturnsJustNow() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - 3).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "たった今")
    }

    func testRT03_thirtySecondsReturnsJustNow() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - 30).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "たった今")
    }

    func testRT04_fiftyNineSecondsReturnsJustNow() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - 59).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "たった今")
    }

    // MARK: - shared-reltime-05・shared-reltime-06: 分

    func testRT05_sixtySecondsReturnsOneMinuteAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - 60).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "1分前")
    }

    func testRT06_fiftyNineMinutesReturnsFiftyNineMinutesAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (59 * 60)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "59分前")
    }

    // MARK: - shared-reltime-07・shared-reltime-08: 時間

    func testRT07_sixtyMinutesReturnsOneHourAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (60 * 60)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "1時間前")
    }

    func testRT08_twentyThreeHoursReturnsTwentyThreeHoursAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (23 * 3600)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "23時間前")
    }

    // MARK: - shared-reltime-09・shared-reltime-10: 日

    func testRT09_twentyFourHoursReturnsOneDayAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (24 * 3600)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "1日前")
    }

    func testRT10_twentyNineDaysReturnsTwentyNineDaysAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (29 * 86400)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "29日前")
    }

    // MARK: - shared-reltime-11〜shared-reltime-14: か月（年判定より先に月へフォールバックする境界を含む）

    func testRT11_thirtyDaysReturnsOneMonthAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (30 * 86400)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "1か月前")
    }

    func testRT12_threeFiftyNineDaysReturnsElevenMonthsAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (359 * 86400)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "11か月前")
    }

    func testRT13_threeSixtyDaysReturnsTwelveMonthsAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (360 * 86400)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "12か月前")
    }

    func testRT14_threeSixtyFourDaysReturnsTwelveMonthsAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (364 * 86400)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "12か月前")
    }

    // MARK: - shared-reltime-15: 年（年判定が月判定に優先）

    func testRT15_threeSixtyFiveDaysReturnsOneYearAgo() {
        let now = Date(timeIntervalSince1970: base)
        let iso = Date(timeIntervalSince1970: base - (365 * 86400)).ISO8601String()
        XCTAssertEqual(formatRelativeTime(iso, now: now), "1年前")
    }

    // MARK: - shared-reltime-16・shared-reltime-17: プラットフォームアダプタ挙動（§3.3、iOS = ISO8601 文字列パース）

    func testRTA01_emptyInputReturnsEmptyString() {
        XCTAssertEqual(formatRelativeTime("", now: Date()), "")
    }

    func testRTA02_unparsableInputReturnsEmptyString() {
        XCTAssertEqual(formatRelativeTime("not-a-date", now: Date()), "")
    }
}
