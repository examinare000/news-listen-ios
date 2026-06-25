import XCTest
@testable import NewsListenApp

final class RelativeTimeFormatterTests: XCTestCase {

    // MARK: - Future (diff < 0)

    func testFutureDateReturnsImminent() {
        let future = Date(timeIntervalSinceNow: 60)
        let result = formatRelativeTime("2099-12-31T23:59:59Z", now: future)
        XCTAssertEqual(result, "もうすぐ")
    }

    // MARK: - Just now (< 60 seconds)

    func testZeroSecondsReturnsJustNow() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = now.ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "たった今")
    }

    func testFiftyNineSecondsReturnsJustNow() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - 59).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "たった今")
    }

    func testSixtySecondsReturnsOneMinuteAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - 60).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "1分前")
    }

    // MARK: - Minutes (60s ~ 59m59s)

    func testOneMinuteAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - 60).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "1分前")
    }

    func testThirtyMinutesAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (30 * 60)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "30分前")
    }

    func testFiftyNineMinutesAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (59 * 60 + 59)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "59分前")
    }

    // MARK: - Hours (1h ~ 23h59m59s)

    func testSixtyMinutesReturnsOneHourAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - 3600).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "1時間前")
    }

    func testTwoHoursAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (2 * 3600)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "2時間前")
    }

    func testTwentyThreeHoursAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (23 * 3600 + 59 * 60 + 59)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "23時間前")
    }

    // MARK: - Days (1d ~ 29d23h59m59s)

    func testTwentyFourHoursReturnOneDayAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - 86400).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "1日前")
    }

    func testSevenDaysAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (7 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "7日前")
    }

    func testTwentyNineDaysAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (29 * 86400 + 23 * 3600 + 59 * 60 + 59)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "29日前")
    }

    // MARK: - Months (30d ~ 364d23h59m59s)

    func testThirtyDaysReturnsOneMonthAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (30 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "1か月前")
    }

    func testSixtyDaysReturnsTwoMonthsAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (60 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "2か月前")
    }

    func testThreeSixtyFourDaysReturnsElevenMonthsAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (334 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "11か月前")
    }

    // 360-364日（月=12・年=0 の境界）。年を先に丸めると "0年前" になる退行を防ぐ。
    func testThreeSixtyDaysReturnsTwelveMonthsAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (360 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "12か月前")
    }

    // MARK: - Years (365d+)

    func testThreeSixtyFiveDaysReturnsOneYearAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (365 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "1年前")
    }

    func testSevenThirtyDaysReturnsTwoYearsAgo() {
        let now = Date(timeIntervalSince1970: 1700000000)
        let iso = Date(timeIntervalSince1970: 1700000000 - (730 * 86400)).ISO8601String()
        let result = formatRelativeTime(iso, now: now)
        XCTAssertEqual(result, "2年前")
    }

    // MARK: - Invalid string

    func testInvalidISO8601StringReturnsEmptyString() {
        let result = formatRelativeTime("not-a-date", now: Date())
        XCTAssertEqual(result, "")
    }

    func testEmptyStringReturnsEmptyString() {
        let result = formatRelativeTime("", now: Date())
        XCTAssertEqual(result, "")
    }

    func testMalformedDateReturnsEmptyString() {
        let result = formatRelativeTime("2023/11/15", now: Date())
        XCTAssertEqual(result, "")
    }
}

// MARK: - Test helper function

func formatRelativeTime(_ isoString: String, now: Date = Date()) -> String {
    RelativeTimeFormatter.format(isoString, now: now)
}

// MARK: - Helper extension for tests

extension Date {
    func ISO8601String() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
