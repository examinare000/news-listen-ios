import XCTest
@testable import NewsListenApp

/// `PreferenceRegistry`（I-S2 / CI-T17）のテスト。spec.md §3.3・§5.3 CI-T17・§5.5 T-T17-* に対応する。
///
/// T-T17-07〜10 は `AppState`（`@MainActor`）を直接構築・操作するため、クラス全体を
/// `@MainActor` にする（`AppStateAuthTests`・`SubjectCleanupTests` と同じ方針）。
@MainActor
final class PreferenceRegistryTests: XCTestCase {

    private func makeSuite() -> UserDefaults {
        let suite = UserDefaults(suiteName: "PreferenceRegistryTests.\(UUID().uuidString)")!
        return suite
    }

    // MARK: - T-T17-01（CI-T17.1）

    // verifies: CI-T17.1
    func testTT17_01_allKeysMatchesSpecTable() {
        let registry = PreferenceRegistry(defaults: makeSuite())

        XCTAssertEqual(registry.allKeys, [
            "default_difficulty", "default_playback_speed", "weekly_goal_episodes", "seen_achievement_ids",
            "article_open_mode", "time_format", "sfx_enabled", "haptics_enabled",
        ])
    }

    // MARK: - T-T17-02（CI-T17.2）

    // verifies: CI-T17.2
    func testTT17_02_subjectScopedKeysMatchesSpecTable() {
        let registry = PreferenceRegistry(defaults: makeSuite())

        XCTAssertEqual(registry.subjectScopedKeys, [
            "default_difficulty", "default_playback_speed", "weekly_goal_episodes", "seen_achievement_ids",
        ])
        XCTAssertEqual(registry.defaultDifficulty.scope, .server)
        XCTAssertEqual(registry.defaultPlaybackSpeed.scope, .server)
        XCTAssertEqual(registry.weeklyGoalEpisodes.scope, .server)
        XCTAssertEqual(registry.seenAchievementIds.scope, .local)
        XCTAssertEqual(registry.articleOpenMode.scope, .local)
        XCTAssertEqual(registry.timeFormat.scope, .local)
        XCTAssertEqual(registry.sfxEnabled.scope, .local)
        XCTAssertEqual(registry.hapticsEnabled.scope, .local)
        XCTAssertFalse(registry.articleOpenMode.subjectScoped)
        XCTAssertFalse(registry.timeFormat.subjectScoped)
        XCTAssertFalse(registry.sfxEnabled.subjectScoped)
        XCTAssertFalse(registry.hapticsEnabled.subjectScoped)
    }

    // MARK: - T-T17-03（CI-T17.3, 表駆動: 8 設定 × {未保存, 列挙外/型不一致, 正常}）

    // verifies: CI-T17.3
    func testTT17_03_getReturnsDefaultWhenUnsetOrInvalid() {
        let suite = makeSuite()
        let registry = PreferenceRegistry(defaults: suite)

        // 未保存はすべて既定値。
        XCTAssertEqual(registry.get(registry.defaultDifficulty), "toeic_600")
        XCTAssertEqual(registry.get(registry.defaultPlaybackSpeed), 1.0)
        XCTAssertEqual(registry.get(registry.weeklyGoalEpisodes), 3)
        XCTAssertEqual(registry.get(registry.seenAchievementIds), [])
        XCTAssertEqual(registry.get(registry.articleOpenMode), "in_app")
        XCTAssertEqual(registry.get(registry.timeFormat), "absolute")
        XCTAssertEqual(registry.get(registry.sfxEnabled), true)
        XCTAssertEqual(registry.get(registry.hapticsEnabled), true)

        // 列挙外・型不一致は既定値（throw しない）。
        suite.set("bogus", forKey: "default_difficulty")
        suite.set(1.1, forKey: "default_playback_speed")
        suite.set(4, forKey: "weekly_goal_episodes")
        suite.set("x", forKey: "article_open_mode")
        suite.set("x", forKey: "time_format")
        suite.set("abc", forKey: "sfx_enabled")

        XCTAssertEqual(registry.get(registry.defaultDifficulty), "toeic_600")
        XCTAssertEqual(registry.get(registry.defaultPlaybackSpeed), 1.0)
        XCTAssertEqual(registry.get(registry.weeklyGoalEpisodes), 3)
        XCTAssertEqual(registry.get(registry.articleOpenMode), "in_app")
        XCTAssertEqual(registry.get(registry.timeFormat), "absolute")
        XCTAssertEqual(registry.get(registry.sfxEnabled), true)

        // 正常値はその値。
        suite.set("toeic_900", forKey: "default_difficulty")
        suite.set(1.25, forKey: "default_playback_speed")
        suite.set(5, forKey: "weekly_goal_episodes")
        suite.set(["a1"], forKey: "seen_achievement_ids")
        suite.set("external", forKey: "article_open_mode")
        suite.set("relative", forKey: "time_format")
        suite.set(false, forKey: "sfx_enabled")
        suite.set(false, forKey: "haptics_enabled")

        XCTAssertEqual(registry.get(registry.defaultDifficulty), "toeic_900")
        XCTAssertEqual(registry.get(registry.defaultPlaybackSpeed), 1.25)
        XCTAssertEqual(registry.get(registry.weeklyGoalEpisodes), 5)
        XCTAssertEqual(registry.get(registry.seenAchievementIds), ["a1"])
        XCTAssertEqual(registry.get(registry.articleOpenMode), "external")
        XCTAssertEqual(registry.get(registry.timeFormat), "relative")
        XCTAssertEqual(registry.get(registry.sfxEnabled), false)
        XCTAssertEqual(registry.get(registry.hapticsEnabled), false)
    }

    // MARK: - T-T17-04（CI-T17.4）

    // verifies: CI-T17.4
    func testTT17_04_setRejectsOutOfEnumValues() {
        let suite = makeSuite()
        let registry = PreferenceRegistry(defaults: suite)
        XCTAssertTrue(registry.set(registry.defaultDifficulty, "toeic_900"))
        XCTAssertEqual(registry.get(registry.defaultDifficulty), "toeic_900")

        let accepted = registry.set(registry.defaultDifficulty, "bogus")

        XCTAssertFalse(accepted)
        XCTAssertEqual(registry.get(registry.defaultDifficulty), "toeic_900", "列挙外は既存値を変えないべき")

        let acceptedAgain = registry.set(registry.defaultDifficulty, "ielts_7")
        XCTAssertTrue(acceptedAgain)
        XCTAssertEqual(registry.get(registry.defaultDifficulty), "ielts_7")
    }

    // MARK: - T-T17-05（CI-T17.5）

    // verifies: CI-T17.5
    func testTT17_05_clearSubjectScopedRemovesOnlySubjectScopedKeys() {
        let suite = makeSuite()
        let registry = PreferenceRegistry(defaults: suite)
        registry.set(registry.defaultDifficulty, "toeic_900")
        registry.set(registry.defaultPlaybackSpeed, 1.25)
        registry.set(registry.weeklyGoalEpisodes, 5)
        registry.set(registry.seenAchievementIds, ["a1"])
        registry.set(registry.articleOpenMode, "external")
        registry.set(registry.timeFormat, "relative")
        registry.set(registry.sfxEnabled, false)
        registry.set(registry.hapticsEnabled, false)
        suite.set("kept", forKey: "other_key")

        registry.clearSubjectScoped()
        registry.clearSubjectScoped() // 冪等

        for key in registry.subjectScopedKeys {
            XCTAssertNil(suite.object(forKey: key))
        }
        XCTAssertEqual(registry.get(registry.articleOpenMode), "external")
        XCTAssertEqual(registry.get(registry.timeFormat), "relative")
        XCTAssertEqual(registry.get(registry.sfxEnabled), false)
        XCTAssertEqual(registry.get(registry.hapticsEnabled), false)
        XCTAssertEqual(suite.string(forKey: "other_key"), "kept")
    }

    // MARK: - T-T17-07（CI-T17.7, AppState の読込）

    // verifies: CI-T17.7
    func testTT17_07_appStateReadsRegistryDefaultsWhenUnset() {
        let appState = AppState(
            sessionStore: InMemorySessionStore(),
            preferences: PreferenceRegistry(defaults: makeSuite()),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )

        XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
        XCTAssertEqual(appState.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(appState.weeklyGoalEpisodes, 3)
        XCTAssertEqual(appState.articleOpenMode, .inApp)
        XCTAssertEqual(appState.timeFormat, "absolute")
    }

    // MARK: - T-T17-08（CI-T17.8, AppState の保存）

    // verifies: CI-T17.8
    func testTT17_08_appStateWritesThroughInjectedRegistry() async {
        let suite = makeSuite()
        let appState = AppState(
            sessionStore: InMemorySessionStore(token: "tA"),
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        appState.defaultDifficulty = "toeic_900"
        appState.defaultPlaybackSpeed = 1.25
        appState.weeklyGoalEpisodes = 5

        XCTAssertEqual(suite.string(forKey: "default_difficulty"), "toeic_900")
        XCTAssertEqual(suite.double(forKey: "default_playback_speed"), 1.25)
        XCTAssertEqual(suite.integer(forKey: "weekly_goal_episodes"), 5)
    }

    // MARK: - T-T17-09, T-T17-10（CI-T17.9, CI-T15.10）

    // verifies: CI-T17.9, CI-T15.10
    func testTT17_09_refreshPreferencesDoesNotAdoptOutOfEnumServerValues() async {
        let suite = makeSuite()
        let session = MockURLSession(
            data: Data(#"{"default_difficulty":"unknown_code","default_playback_speed":1.1}"#.utf8),
            statusCode: 200
        )
        let appState = AppState(
            sessionStore: InMemorySessionStore(token: "tA"),
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.refreshPreferences()

        XCTAssertEqual(appState.defaultDifficulty, "toeic_600", "列挙外のサーバ値は採用せずローカル値を保持する")
        XCTAssertFalse(appState.preferencesSyncFailed)
    }

    // verifies: CI-T17.9, CI-T15.10
    func testTT17_10_refreshPreferencesAdoptsInEnumServerValues() async {
        let suite = makeSuite()
        let json = #"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":5}"#
        let session = MockURLSession(data: Data(json.utf8), statusCode: 200)
        let appState = AppState(
            sessionStore: InMemorySessionStore(token: "tA"),
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.refreshPreferences()

        XCTAssertEqual(appState.defaultDifficulty, "toeic_900")
        XCTAssertEqual(appState.defaultPlaybackSpeed, 1.25)
        XCTAssertEqual(appState.weeklyGoalEpisodes, 5)
        XCTAssertEqual(suite.string(forKey: "default_difficulty"), "toeic_900")
        XCTAssertEqual(suite.double(forKey: "default_playback_speed"), 1.25)
        XCTAssertEqual(suite.integer(forKey: "weekly_goal_episodes"), 5)
        XCTAssertEqual(appState.lastConfirmedWeeklyGoalEpisodes, 5)
        XCTAssertFalse(appState.preferencesSyncFailed)
    }
}
