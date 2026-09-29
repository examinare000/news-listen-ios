import XCTest
@testable import NewsListenApp

/// `SubjectCleanup` 単体テストと、`AppState` を介した主体離脱の統合テスト（I-S2 / CI-T15）。
///
/// spec.md §5.2 CI-T15 / §5.5 T-T15-* に対応する。SL-01〜SL-05 は共有仕様 §4.4 の行 ID で、
/// テスト名に含める（spec §5.5 テスト名規約）。
@MainActor
final class SubjectCleanupTests: XCTestCase {

    // MARK: - status を後から切り替えられる URLSessionProtocol double

    /// `MockURLSession.mode` は `let` で固定のため、同一セッションで応答を時系列に変えたい
    /// テスト（T-T15-15: 同じ client を後から別ステータスで使う）用に別途用意する。
    private final class MutableStatusSession: URLSessionProtocol {
        var statusCode: Int
        init(statusCode: Int) { self.statusCode = statusCode }
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (Data("{}".utf8), response)
        }
    }

    // MARK: - 主体依存設定の直接キー（PreferenceRegistry と同じ文字列。spec §3.3）

    private let subjectScopedKeys = [
        "default_difficulty", "default_playback_speed", "weekly_goal_episodes", "seen_achievement_ids",
    ]
    private let deviceLocalKeys = ["article_open_mode", "time_format", "sfx_enabled", "haptics_enabled"]

    /// 8 key すべてに非既定の値を書き込む。
    private func seedAllKeys(_ suite: UserDefaults) {
        suite.set("toeic_900", forKey: "default_difficulty")
        suite.set(1.25, forKey: "default_playback_speed")
        suite.set(5, forKey: "weekly_goal_episodes")
        suite.set(["a1"], forKey: "seen_achievement_ids")
        suite.set("external", forKey: "article_open_mode")
        suite.set("relative", forKey: "time_format")
        suite.set(false, forKey: "sfx_enabled")
        suite.set(false, forKey: "haptics_enabled")
    }

    /// `MockFileManager` へ 2 ファイル分のキャッシュを事前投入する。
    private func makeFileManagerWithTwoCachedFiles() -> AudioCacheManagerTests.MockFileManager {
        let fm = AudioCacheManagerTests.MockFileManager()
        fm.directories.insert("/mock-caches")
        fm.directories.insert("/mock-caches/NewsListenApp")
        fm.directories.insert("/mock-caches/NewsListenApp/audio-cache")
        fm.files["/mock-caches/NewsListenApp/audio-cache/p1.mp3"] = Data("audio1".utf8)
        fm.files["/mock-caches/NewsListenApp/audio-cache/p2.mp3"] = Data("audio2".utf8)
        return fm
    }

    // MARK: - T-T15-01（CI-T15.1, CI-T15.2, SL-01）

    // verifies: CI-T15.1, CI-T15.2
    func testTT15_01_SL01_logoutClearsSubjectAssets() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let fileManager = makeFileManagerWithTwoCachedFiles()
        let suiteName = "SubjectCleanupTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        seedAllKeys(suite)
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(data: Data("{}".utf8), statusCode: 200), onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: { try AudioCacheManager(fileManager: fileManager).clearCache() }
        )
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        var observedTokenAtStop: String?
        var observedAnonymousAtStop = false
        playback.onStopForLogout = {
            observedTokenAtStop = store.token
            if case .anonymous = appState.session { observedAnonymousAtStop = true }
        }

        await appState.logout()

        XCTAssertNil(observedTokenAtStop, "後始末が観測する時点で token は既に nil であるべき")
        XCTAssertTrue(observedAnonymousAtStop, "後始末が観測する時点で session は既に anonymous であるべき")
        XCTAssertEqual(AudioCacheManager(fileManager: fileManager).cacheSize(), 0)
        XCTAssertEqual(playback.stopForLogoutCallCount, 1)
        XCTAssertEqual(nowPlaying.clearCallCount, 1)
        for key in subjectScopedKeys {
            XCTAssertNil(suite.object(forKey: key), "subjectScoped key '\(key)' は消えるべき")
        }
        for key in deviceLocalKeys {
            XCTAssertNotNil(suite.object(forKey: key), "端末設定 key '\(key)' は残るべき")
        }
        XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
        XCTAssertEqual(appState.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(appState.weeklyGoalEpisodes, 3)
        XCTAssertNil(appState.lastCleanupIncomplete)
    }

    // MARK: - T-T15-02（CI-T14.9, CI-T15.2, SL-02）

    // verifies: CI-T14.9, CI-T15.2
    func testTT15_02_SL02_unauthorizedFromAnyAPIClearsSubjectAssets() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let fileManager = makeFileManagerWithTwoCachedFiles()
        let suiteName = "SubjectCleanupTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        seedAllKeys(suite)
        let session = MockURLSession(data: Data(), statusCode: 401)
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: { try AudioCacheManager(fileManager: fileManager).clearCache() }
        )
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.refreshListeningStreak() // 保存トークン付きの任意 API が 401（SL-02 の契機）

        guard case .anonymous = appState.session else { return XCTFail(".anonymous になるべき") }
        XCTAssertNil(store.token)
        XCTAssertEqual(AudioCacheManager(fileManager: fileManager).cacheSize(), 0)
        XCTAssertEqual(playback.stopForLogoutCallCount, 1)
        XCTAssertEqual(nowPlaying.clearCallCount, 1)
        for key in subjectScopedKeys {
            XCTAssertNil(suite.object(forKey: key))
        }
        for key in deviceLocalKeys {
            XCTAssertNotNil(suite.object(forKey: key))
        }
        XCTAssertNil(appState.lastCleanupIncomplete)
    }

    // MARK: - T-T15-03, T-T15-04（CI-T15.3, SL-04）

    // verifies: CI-T15.3
    func testTT15_03_SL04_logoutReportsCleanupIncompleteWhenCacheClearFails() async {
        let store = InMemorySessionStore(token: "tA")
        let playback = PlaybackLifecycleSpy()
        let nowPlaying = NowPlayingCenterSpy()
        let failingFileManager = FailingRemoveFileManager()
        failingFileManager.directories.insert("/mock-caches")
        failingFileManager.directories.insert("/mock-caches/NewsListenApp")
        failingFileManager.directories.insert("/mock-caches/NewsListenApp/audio-cache")
        failingFileManager.files["/mock-caches/NewsListenApp/audio-cache/p1.mp3"] = Data("audio1".utf8)
        let suite = UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(data: Data("{}".utf8), statusCode: 200), onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: { try AudioCacheManager(fileManager: failingFileManager).clearCache() }
        )
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.logout()

        guard case .anonymous = appState.session else { return XCTFail(".anonymous になるべき") }
        XCTAssertNil(store.token)
        XCTAssertEqual(playback.stopForLogoutCallCount, 1, "音声キャッシュ削除の失敗が他の手順を止めてはならない")
        XCTAssertEqual(nowPlaying.clearCallCount, 1)
        XCTAssertEqual(appState.lastCleanupIncomplete?.failedParts, [.offlineLibrary])
    }

    // verifies: CI-T15.3
    func testTT15_04_SL04_subjectCleanupRunConvergesAfterDoubleRecovers() {
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let failingFileManager = FailingRemoveFileManager()
        failingFileManager.files["/mock-caches/NewsListenApp/audio-cache/p1.mp3"] = Data("audio1".utf8)
        let cacheManager = AudioCacheManager(fileManager: failingFileManager)
        let cleanup = SubjectCleanup(
            playbackLifecycle: playback,
            nowPlayingCenter: nowPlaying,
            clearSubjectPreferences: {},
            clearOfflineLibrary: { try cacheManager.clearCache() }
        )

        let firstResult = cleanup.run()
        XCTAssertEqual(firstResult?.failedParts, [.offlineLibrary])

        // double を回復させる（removeItem が成功するようになる）。
        let recoveredFileManager = AudioCacheManagerTests.MockFileManager()
        recoveredFileManager.files = failingFileManager.files
        let recoveredCacheManager = AudioCacheManager(fileManager: recoveredFileManager)
        let recoveredCleanup = SubjectCleanup(
            playbackLifecycle: playback,
            nowPlayingCenter: nowPlaying,
            clearSubjectPreferences: {},
            clearOfflineLibrary: { try recoveredCacheManager.clearCache() }
        )

        let secondResult = recoveredCleanup.run()
        XCTAssertNil(secondResult)
        XCTAssertEqual(recoveredCacheManager.cacheSize(), 0)

        let thirdResult = recoveredCleanup.run()
        XCTAssertNil(thirdResult, "冪等: 再実行しても nil のまま")
        XCTAssertEqual(recoveredCacheManager.cacheSize(), 0)
    }

    // MARK: - T-T15-05（CI-T15.5, CI-T14.7, CI-T14.12）

    // verifies: CI-T15.5, CI-T14.7, CI-T14.12
    func testTT15_05_logoutDuplicateTriggerRunsCleanupOnce() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let session = MockURLSession(data: Data(), statusCode: 401) // /auth/logout・device-token 解除の両方が 401
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.logout()

        guard case .anonymous = appState.session else { return XCTFail(".anonymous になるべき") }
        XCTAssertNil(store.token)
        XCTAssertEqual(nowPlaying.clearCallCount, 1, "サーバ呼出中の 401 由来の離脱と logout() 自身の離脱で後始末が重複してはならない")
        XCTAssertEqual(playback.stopForLogoutCallCount, 1)
    }

    // MARK: - T-T15-06（CI-T15.4, SL-03）

    // verifies: CI-T15.4
    func testTT15_06_SL03_unavailableDoesNotRunCleanup() async {
        for mode: MockURLSession.Mode in [.transportError(URLError(.notConnectedToInternet)), .http(statusCode: 500, headerFields: nil)] {
            let store = InMemorySessionStore(token: "tA")
            let nowPlaying = NowPlayingCenterSpy()
            let playback = PlaybackLifecycleSpy()
            let suite = UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!
            seedAllKeys(suite)
            let appState = AppState(
                sessionStore: store,
                apiClientFactory: { token, onUnauthorized in
                    APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(mode: mode), onUnauthorized: onUnauthorized)
                },
                preferences: PreferenceRegistry(defaults: suite),
                nowPlayingCenter: nowPlaying,
                clearOfflineLibrary: {}
            )
            appState.registerPlaybackLifecycle(playback)

            await appState.refreshAuth()

            guard case .unavailable = appState.session else { return XCTFail(".unavailable になるべき") }
            XCTAssertEqual(store.token, "tA")
            XCTAssertEqual(nowPlaying.clearCallCount, 0)
            XCTAssertEqual(playback.stopForLogoutCallCount, 0)
            for key in subjectScopedKeys {
                XCTAssertNotNil(suite.object(forKey: key), "unavailable では subjectScoped key は残るべき")
            }
        }
    }

    // verifies: CI-T15.4
    func testTT15_06_SL03_decodingFailureDoesNotRunCleanup() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(data: Data("not json".utf8), statusCode: 200), onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )

        await appState.refreshAuth()

        guard case .unavailable(.decoding) = appState.session else { return XCTFail(".unavailable(.decoding) になるべき") }
        XCTAssertEqual(store.token, "tA")
        XCTAssertEqual(nowPlaying.clearCallCount, 0)
    }

    // MARK: - T-T15-07（CI-T15.4, SL-05）

    // verifies: CI-T15.4
    func testTT15_07_SL05_loginFailureDoesNotRunCleanup() async {
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let session = MockURLSession(data: Data(), statusCode: 401)
        let appState = AppState(
            sessionStore: InMemorySessionStore(),
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )
        appState.registerPlaybackLifecycle(playback)
        guard case .resolving = appState.session else { return XCTFail("前提: resolving") }

        do {
            _ = try await appState.apiClient!.login(username: "alice", password: "wrong")
            XCTFail("401 は throw されるべき")
        } catch ApiFailure.unauthorized {
            // 期待どおり。
        } catch { XCTFail("想定外のエラー: \(error)") }

        guard case .resolving = appState.session else { return XCTFail("resolving のまま（.anonymous 相当）変わらないべき") }
        XCTAssertEqual(nowPlaying.clearCallCount, 0)
        XCTAssertEqual(playback.stopForLogoutCallCount, 0)
    }

    // MARK: - T-T15-08（CI-T15.6）

    // verifies: CI-T15.6
    func testTT15_08_logoutWithoutRegisteredLifecycleStillClearsNowPlaying() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(data: Data("{}".utf8), statusCode: 200), onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )
        // registerPlaybackLifecycle を呼ばない（未登録）。
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.logout()

        XCTAssertEqual(nowPlaying.clearCallCount, 1, "lifecycle 未登録でも clear は呼ばれる（SG4）")
        XCTAssertNil(appState.lastCleanupIncomplete, "lifecycle 未登録は CleanupIncomplete に含めない")
    }

    // verifies: CI-T15.6
    func testTT15_08_logoutWithReleasedLifecycleStillClearsNowPlaying() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(data: Data("{}".utf8), statusCode: 200), onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )
        autoreleasepool {
            let playback = PlaybackLifecycleSpy()
            appState.registerPlaybackLifecycle(playback)
            // playback はここでスコープを抜けて解放される（weak 保持のため参照が消える）。
        }
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.logout()

        XCTAssertEqual(nowPlaying.clearCallCount, 1)
        XCTAssertNil(appState.lastCleanupIncomplete)
    }

    // MARK: - T-T15-11a（CI-T15.8）

    // verifies: CI-T15.8
    func testTT15_11a_writesToSubjectScopedPropertiesWhileNotAuthenticatedDoNotPersist() {
        let suite = UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!
        let appState = AppState(
            sessionStore: InMemorySessionStore(),
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )
        guard case .resolving = appState.session else { return XCTFail("前提: 非 authenticated（resolving）") }

        appState.defaultDifficulty = "toeic_900"
        appState.defaultPlaybackSpeed = 1.25
        appState.weeklyGoalEpisodes = 5

        for key in subjectScopedKeys where key != "seen_achievement_ids" {
            XCTAssertNil(suite.object(forKey: key), "非 authenticated の代入は永続化されないべき")
        }
        XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
        XCTAssertEqual(appState.defaultPlaybackSpeed, 1.0)
        XCTAssertEqual(appState.weeklyGoalEpisodes, 3)
    }

    // MARK: - T-T15-11b, T-T15-14（CI-T15.10, G3）

    // verifies: CI-T15.10
    func testTT15_11b_logoutDuringPreferencesSyncDiscardsResult() async {
        let store = InMemorySessionStore(token: "t0")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/settings/preferences")
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let suite = UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: scripted, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )
        appState.completeLogin(LoginResponse(token: "t0", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let failedBefore = appState.preferencesSyncFailed

        let task = Task { await appState.refreshPreferences() }
        await scripted.waitUntilRequested(method: "GET", path: "/settings/preferences")
        await appState.logout()
        let prefsJSON = #"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":5}"#
        scripted.release(method: "GET", path: "/settings/preferences", status: 200, body: Data(prefsJSON.utf8))
        await task.value

        for key in subjectScopedKeys {
            XCTAssertNil(suite.object(forKey: key))
        }
        XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
        XCTAssertEqual(appState.preferencesSyncFailed, failedBefore)
    }

    // verifies: CI-T15.10
    func testTT15_14_preferencesSyncDoesNotLeakIntoNextSubject() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/settings/preferences")
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let suite = UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: scripted, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: suite),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: {}
        )
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let failedBefore = appState.preferencesSyncFailed

        let task = Task { await appState.refreshPreferences() }
        await scripted.waitUntilRequested(method: "GET", path: "/settings/preferences")
        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        let prefsJSON = #"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":5}"#
        scripted.release(method: "GET", path: "/settings/preferences", status: 200, body: Data(prefsJSON.utf8))
        await task.value

        XCTAssertEqual(appState.defaultDifficulty, "toeic_600", "bob の値が A の応答で書き換わってはならない")
        for key in subjectScopedKeys {
            XCTAssertNil(suite.object(forKey: key))
        }
        XCTAssertEqual(appState.preferencesSyncFailed, failedBefore)
    }

    // MARK: - T-T15-13（CI-T15.10）

    // verifies: CI-T15.10
    func testTT15_13_refreshPreferencesNoOpWhenNotAuthenticated() async {
        let session = MockURLSession(data: Data(), statusCode: 500)
        for store in [InMemorySessionStore(), InMemorySessionStore(token: "tA")] {
            let appState = AppState(
                sessionStore: store,
                apiClientFactory: { token, onUnauthorized in
                    APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
                },
                preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
                nowPlayingCenter: NowPlayingCenterSpy(),
                clearOfflineLibrary: {}
            )
            guard case .resolving = appState.session else { return XCTFail("前提: 非 authenticated") }

            await appState.refreshPreferences()

            XCTAssertNil(session.lastRequest)
            XCTAssertFalse(appState.preferencesSyncFailed)
            XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
        }
    }

    // MARK: - T-T15-15（CI-T14.15）

    // verifies: CI-T14.15
    func testTT15_15_staleClientAfterLogoutCannotAffectNextSubject() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let session = MutableStatusSession(statusCode: 200) // logout 自体は成功させる
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: session, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let staleClient = appState.apiClient! // A の client（トークンは生成時点で固定）

        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))

        session.statusCode = 401
        do {
            _ = try await staleClient.fetchListeningStreak()
            XCTFail("401 は throw されるべき")
        } catch ApiFailure.unauthorized {
            // 期待どおり。
        } catch { XCTFail("想定外のエラー: \(error)") }

        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("bob のまま") }
        XCTAssertEqual(store.token, "tB")
        XCTAssertEqual(nowPlaying.clearCallCount, 1, "logout 分の累計 1 のまま増えないべき")
        XCTAssertEqual(playback.stopForLogoutCallCount, 1)
    }

    // MARK: - T-T15-16（CI-T14.12, CI-T15.5）

    // verifies: CI-T14.12, CI-T15.5
    func testTT15_16_logoutInProgressDoesNotAffectNextSubject() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let scripted = ScriptedURLSession()
        scripted.configure(method: "DELETE", path: "/notifications/device-tokens", status: 401)
        scripted.configurePending(method: "POST", path: "/auth/logout")
        scripted.configure(method: "POST", path: "/notifications/device-tokens", status: 200)
        let appState = AppState(
            sessionStore: store,
            apiClientFactory: { token, onUnauthorized in
                APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: scripted, onUnauthorized: onUnauthorized)
            },
            preferences: PreferenceRegistry(defaults: UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!),
            nowPlayingCenter: nowPlaying,
            clearOfflineLibrary: {}
        )
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        appState.didRegisterDeviceToken("apns-1")

        let logoutTask = Task { await appState.logout() }
        await scripted.waitUntilRequested(method: "POST", path: "/auth/logout")
        // DELETE の 401 が observer 経由で離脱を既に済ませているはず。
        guard case .anonymous = appState.session else { return XCTFail("observer 経由の離脱が先に済んでいるべき") }
        XCTAssertEqual(nowPlaying.clearCallCount, 1)

        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        scripted.release(method: "POST", path: "/auth/logout", status: 401)
        await logoutTask.value

        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("bob のまま") }
        XCTAssertEqual(store.token, "tB")
        XCTAssertEqual(nowPlaying.clearCallCount, 1, "累計 1 のまま（SR-09 / F5 の再現手順）")
        XCTAssertEqual(playback.stopForLogoutCallCount, 1)
        XCTAssertNil(appState.lastCleanupIncomplete)
    }

    // MARK: - T-T15-17（CI-T15.10）

    // verifies: CI-T15.10
    func testTT15_17_cancellationDuringPreferencesSyncIsNotTreatedAsFailure() async {
        for mode: MockURLSession.Mode in [.transportError(CancellationError()), .transportError(URLError(.cancelled))] {
            let store = InMemorySessionStore(token: "tA")
            let suite = UserDefaults(suiteName: "SubjectCleanupTests.\(UUID().uuidString)")!
            let appState = AppState(
                sessionStore: store,
                apiClientFactory: { token, onUnauthorized in
                    APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", sessionToken: token, session: MockURLSession(mode: mode), onUnauthorized: onUnauthorized)
                },
                preferences: PreferenceRegistry(defaults: suite),
                nowPlayingCenter: NowPlayingCenterSpy(),
                clearOfflineLibrary: {}
            )
            appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
            appState.defaultDifficulty = "ielts_7"
            XCTAssertFalse(appState.preferencesSyncFailed)

            await appState.refreshPreferences()

            XCTAssertFalse(appState.preferencesSyncFailed, "キャンセルは失敗として扱わないべき")
            XCTAssertEqual(appState.defaultDifficulty, "ielts_7")
        }
    }
}
