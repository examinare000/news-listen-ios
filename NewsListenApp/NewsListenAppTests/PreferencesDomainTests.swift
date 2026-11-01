import XCTest
@testable import NewsListenApp

/// 設定の値域・既定値を持つ domain の値型（`DifficultyLevel`・`WeeklyGoalTarget`・`TimeFormat`・`ArticleOpenMode`・
/// `PreferenceCatalog`）のテスト。domain だけを参照する（ios-check-08 の対象）。
final class PreferencesDomainTests: XCTestCase {

    // MARK: - DifficultyLevel（ios-test-048・ios-test-118）

    // verifies: ios-rule-prefs-01
    func testDifficultyLevelAcceptsOnlySixCodes() {
        let codes = ["toeic_600", "toeic_900", "ielts_55", "ielts_7", "eiken_2", "eiken_p1"]
        for code in codes {
            XCTAssertEqual(DifficultyLevel(code: code)?.code, code, "\(code) は受理される")
        }
        for bad in ["x", "", "TOEIC_600", "toeic_600 ", "toeic"] {
            XCTAssertNil(DifficultyLevel(code: bad), "'\(bad)' は nil")
        }
    }

    // verifies: ios-rule-prefs-01
    func testDifficultyLevelAllCasesOrderAndDefault() {
        XCTAssertEqual(
            DifficultyLevel.allCases.map(\.code),
            ["toeic_600", "toeic_900", "ielts_55", "ielts_7", "eiken_2", "eiken_p1"]
        )
        XCTAssertEqual(DifficultyLevel.default, .toeic600)
    }

    // MARK: - WeeklyGoalTarget（ios-test-121。旧 SettingsViewModelTests.testSyncWeeklyGoalValidation の移動先）

    // verifies: ios-rule-prefs-02
    func testWeeklyGoalTargetAcceptsOnlyFourValues() {
        for episodes in [3, 5, 7, 10] {
            XCTAssertEqual(WeeklyGoalTarget(episodes: episodes)?.episodes, episodes)
        }
        for bad in [0, 4, 11, -1, 999] {
            XCTAssertNil(WeeklyGoalTarget(episodes: bad), "\(bad) は nil")
        }
        XCTAssertEqual(WeeklyGoalTarget.allCases.map(\.episodes), [3, 5, 7, 10])
        XCTAssertEqual(WeeklyGoalTarget.default.episodes, 3)
    }

    // MARK: - TimeFormat・ArticleOpenMode（ios-test-122）

    // verifies: ios-rule-prefs-03
    func testTimeFormatAcceptsOnlyTwoValues() {
        XCTAssertEqual(TimeFormat(rawValue: "absolute"), .absolute)
        XCTAssertEqual(TimeFormat(rawValue: "relative"), .relative)
        XCTAssertNil(TimeFormat(rawValue: "x"))
        XCTAssertNil(TimeFormat(rawValue: ""))
        XCTAssertEqual(TimeFormat.allCases, [.absolute, .relative])
        XCTAssertEqual(TimeFormat.default, .absolute)
    }

    // verifies: ios-rule-prefs-03
    func testArticleOpenModeAcceptsOnlyTwoValuesAndKeepsLabels() {
        XCTAssertEqual(ArticleOpenMode(rawValue: "in_app"), .inApp)
        XCTAssertEqual(ArticleOpenMode(rawValue: "external"), .external)
        XCTAssertNil(ArticleOpenMode(rawValue: "x"))
        XCTAssertEqual(ArticleOpenMode.allCases, [.inApp, .external])
        XCTAssertEqual(ArticleOpenMode.inApp.id, "in_app")
        XCTAssertEqual(ArticleOpenMode.external.id, "external")
        XCTAssertEqual(ArticleOpenMode.inApp.label, "アプリ内 Safari")
        XCTAssertEqual(ArticleOpenMode.external.label, "外部 Safari")
    }

    // MARK: - PreferenceCatalog

    // verifies: ios-rule-prefs-04
    func testPreferenceCatalogClassification() {
        XCTAssertEqual(
            PreferenceCatalog.subjectScoped,
            [.defaultDifficulty, .defaultPlaybackSpeed, .weeklyGoal, .seenAchievements]
        )
        XCTAssertEqual(
            PreferenceCatalog.serverSynced,
            [.defaultDifficulty, .defaultPlaybackSpeed, .weeklyGoal]
        )
        XCTAssertEqual(PreferenceCatalog.defaultPlaybackSpeed, 1.0)
        XCTAssertTrue(PlaybackConstants.speeds.contains(Float(PreferenceCatalog.defaultPlaybackSpeed)))
        XCTAssertEqual(PreferenceCatalog.defaultArticleOpenMode, .inApp)
        XCTAssertTrue(PreferenceCatalog.defaultSoundEnabled)
        XCTAssertTrue(PreferenceCatalog.defaultHapticsEnabled)
    }
}
