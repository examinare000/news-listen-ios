import XCTest
@testable import NewsListenApp

/// AppState の認証状態遷移（`AuthSession` 4 状態）とセッション保管のテスト（I-S2）。
///
/// spec.md §5.1 CI-T14 / §5.5 T-T14-* に対応する。既存テスト（§6.1 の機械的書換え対象）は
/// `authStatus` → `session` のパターンマッチへ、`currentUser` 直接代入（stored 廃止で
/// コンパイル不可）→ `completeLogin(...)` へ置き換えた。
@MainActor
final class AppStateAuthTests: XCTestCase {

    func testInMemorySessionStoreRoundTrip() {
        let store = InMemorySessionStore()
        XCTAssertNil(store.token)
        store.token = "abc"
        XCTAssertEqual(store.token, "abc")
        store.token = nil
        XCTAssertNil(store.token)
    }

    // MARK: - T-T14-01（CI-T14.1）

    // verifies: CI-T14.1
    func testTT14_01_authSessionHasFourCasesAndStartsResolving() {
        let appState = makeSubjectAwareAppState()

        // default 無しで 4 case を網羅してコンパイルされることも検証する（CI-T14.1）。
        let described: String
        switch appState.session {
        case .resolving: described = "resolving"
        case .authenticated: described = "authenticated"
        case .anonymous: described = "anonymous"
        case .unavailable: described = "unavailable"
        }

        XCTAssertEqual(described, "resolving")
        XCTAssertNil(appState.currentUser)
    }

    // MARK: - T-T14-02（CI-T14.2）

    // verifies: CI-T14.2
    func testTT14_02_refreshAuthWithoutTokenBecomesAnonymous() async {
        let session = MockURLSession(data: Data(), statusCode: 200)
        let appState = makeSubjectAwareAppState(session: session)

        await appState.refreshAuth()

        guard case .anonymous = appState.session else { return XCTFail("トークン無しでは anonymous になるべき") }
        XCTAssertNil(session.lastRequest)
    }

    // verifies: CI-T14.2
    func testTT14_12_refreshAuthWhenAlreadyAuthenticatedIsNoOp() async {
        let session = MockURLSession(data: Data(), statusCode: 200)
        let appState = makeSubjectAwareAppState(session: session, sessionStore: InMemorySessionStore(token: "tA"))
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.refreshAuth()

        guard case .authenticated(let user) = appState.session, user.username == "alice" else {
            return XCTFail("authenticated のまま変わらないべき")
        }
        XCTAssertNil(session.lastRequest, "resolving 以外での refreshAuth は HTTP を送らないべき")
    }

    // MARK: - T-T14-03（CI-T14.3）

    // verifies: CI-T14.3
    func testTT14_03_refreshAuthSuccessBecomesAuthenticated() async {
        let json = #"{"username":"alice","role":"user","display_name":"Alice"}"#
        let session = MockURLSession(data: Data(json.utf8), statusCode: 200)
        let appState = makeSubjectAwareAppState(session: session, sessionStore: InMemorySessionStore(token: "tA"))

        await appState.refreshAuth()

        guard case .authenticated(let user) = appState.session else { return XCTFail("authenticated になるべき") }
        XCTAssertEqual(user.username, "alice")
        XCTAssertEqual(appState.currentUser?.username, "alice")
    }

    // MARK: - T-T14-04（CI-T14.4, CI-T15.4）

    // verifies: CI-T14.4, CI-T15.4
    func testTT14_04_refreshAuthUnauthorizedBecomesAnonymousWithoutCleanup() async {
        let session = MockURLSession(data: Data(), statusCode: 401)
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(session: session, sessionStore: store, nowPlayingCenter: nowPlaying)
        appState.registerPlaybackLifecycle(playback)

        await appState.refreshAuth()

        guard case .anonymous = appState.session else { return XCTFail(".anonymous になるべき") }
        XCTAssertNil(store.token)
        XCTAssertEqual(nowPlaying.clearCallCount, 0, "起動時の失効（③）は SubjectCleanup を走らせない")
        XCTAssertEqual(playback.stopForLogoutCallCount, 0)
    }

    // MARK: - T-T14-05a〜d（CI-T14.5）

    // verifies: CI-T14.5
    func testTT14_05a_refreshAuthTransportErrorBecomesUnavailableNetwork() async {
        let session = MockURLSession(mode: .transportError(URLError(.notConnectedToInternet)))
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(session: session, sessionStore: store)

        await appState.refreshAuth()

        guard case .unavailable(.network) = appState.session else { return XCTFail(".unavailable(.network) になるべき") }
        XCTAssertEqual(store.token, "tA", "トークンは保持されるべき")
    }

    // verifies: CI-T14.5
    func testTT14_05b_refreshAuthServerErrorBecomesUnavailableServer() async {
        let session = MockURLSession(data: Data(), statusCode: 500)
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(session: session, sessionStore: store)

        await appState.refreshAuth()

        guard case .unavailable(.server(status: 500)) = appState.session else {
            return XCTFail(".unavailable(.server(status: 500)) になるべき")
        }
        XCTAssertEqual(store.token, "tA")
    }

    // verifies: CI-T14.5
    func testTT14_05c_refreshAuthInvalidJSONBecomesUnavailableDecoding() async {
        let session = MockURLSession(data: Data("not json".utf8), statusCode: 200)
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(session: session, sessionStore: store)

        await appState.refreshAuth()

        guard case .unavailable(.decoding) = appState.session else { return XCTFail(".unavailable(.decoding) になるべき") }
        XCTAssertEqual(store.token, "tA")
    }

    // verifies: CI-T14.5
    func testTT14_05d_cancellationKeepsResolving() async {
        let session = MockURLSession(mode: .transportError(CancellationError()))
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let appState = makeSubjectAwareAppState(session: session, sessionStore: store, nowPlayingCenter: nowPlaying)
        appState.registerPlaybackLifecycle(playback)

        await appState.refreshAuth()

        guard case .resolving = appState.session else { return XCTFail("キャンセルでは resolving のまま") }
        XCTAssertEqual(store.token, "tA")
        XCTAssertEqual(nowPlaying.clearCallCount, 0)
        XCTAssertEqual(playback.stopForLogoutCallCount, 0)
    }

    // MARK: - T-T14-06（CI-T14.6）

    // verifies: CI-T14.6
    func testTT14_06_retryResolveOnlyFromUnavailable() async {
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(session: MockURLSession(data: Data(), statusCode: 500), sessionStore: store)
        await appState.refreshAuth()
        guard case .unavailable = appState.session else { return XCTFail("前提: unavailable") }

        appState.retryResolve()

        guard case .resolving = appState.session else { return XCTFail("1 回目で resolving になるべき") }
        XCTAssertEqual(store.token, "tA", "token は保持されるべき")

        // anonymous から呼んでも不変（unavailable 以外は no-op）。
        let anonymousAppState = makeSubjectAwareAppState(session: MockURLSession(data: Data(), statusCode: 200))
        await anonymousAppState.refreshAuth()
        guard case .anonymous = anonymousAppState.session else { return XCTFail("前提: anonymous") }

        anonymousAppState.retryResolve()

        guard case .anonymous = anonymousAppState.session else { return XCTFail("anonymous からの retryResolve は no-op であるべき") }
    }

    // MARK: - T-T14-07, T-T14-08（CI-T14.7）

    // verifies: CI-T14.7
    func testTT14_07_handleIgnoredWhenNotAuthenticated() async {
        // resolving
        let nowPlaying1 = NowPlayingCenterSpy()
        let s1 = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"), nowPlayingCenter: nowPlaying1)
        s1.handle(failure: .unauthorized, sentToken: "tA")
        guard case .resolving = s1.session else { return XCTFail("resolving のまま") }
        XCTAssertEqual(nowPlaying1.clearCallCount, 0)

        // anonymous
        let store2 = InMemorySessionStore()
        let nowPlaying2 = NowPlayingCenterSpy()
        let s2 = makeSubjectAwareAppState(sessionStore: store2, nowPlayingCenter: nowPlaying2)
        await s2.refreshAuth()
        s2.handle(failure: .unauthorized, sentToken: store2.token)
        guard case .anonymous = s2.session else { return XCTFail("anonymous のまま") }
        XCTAssertEqual(nowPlaying2.clearCallCount, 0)

        // unavailable
        let store3 = InMemorySessionStore(token: "tA")
        let nowPlaying3 = NowPlayingCenterSpy()
        let s3 = makeSubjectAwareAppState(session: MockURLSession(data: Data(), statusCode: 500), sessionStore: store3, nowPlayingCenter: nowPlaying3)
        await s3.refreshAuth()
        s3.handle(failure: .unauthorized, sentToken: "tA")
        guard case .unavailable = s3.session else { return XCTFail("unavailable のまま") }
        XCTAssertEqual(store3.token, "tA")
        XCTAssertEqual(nowPlaying3.clearCallCount, 0)
    }

    // verifies: CI-T14.7
    func testTT14_08_handleIgnoresNonUnauthorizedFailures() {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let appState = makeSubjectAwareAppState(sessionStore: store, nowPlayingCenter: nowPlaying)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        let nonUnauthorized: [ApiFailure] = [.network(URLError(.notConnectedToInternet)), .server(status: 500), .forbidden, .decoding]
        for failure in nonUnauthorized {
            appState.handle(failure: failure, sentToken: "tA")
        }

        guard case .authenticated(let user) = appState.session, user.username == "alice" else {
            return XCTFail("authenticated のまま変わらないべき")
        }
        XCTAssertEqual(store.token, "tA")
        XCTAssertEqual(nowPlaying.clearCallCount, 0)
    }

    // MARK: - T-T14-09, T-T14-10（CI-T14.8: APIClient observer）

    // verifies: CI-T14.8
    func testTT14_09_observerFiresOnceOnUnauthorizedWithAuthorization() async {
        var observerCallCount = 0
        let session = MockURLSession(data: Data(), statusCode: 401)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: "tA",
            session: session,
            onUnauthorized: { observerCallCount += 1 }
        )

        do {
            _ = try await client.fetchListeningStreak()
            XCTFail("401 は throw されるべき")
        } catch ApiFailure.unauthorized {
            // 期待どおり。
        } catch {
            XCTFail("想定外のエラー: \(error)")
        }

        XCTAssertEqual(observerCallCount, 1)
    }

    // verifies: CI-T14.8
    func testTT14_10a_observerDoesNotFireWithoutAuthorizationHeader() async {
        var observerCallCount = 0
        let session = MockURLSession(data: Data(), statusCode: 401)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: nil,
            session: session,
            onUnauthorized: { observerCallCount += 1 }
        )

        do {
            _ = try await client.login(username: "alice", password: "wrong")
            XCTFail("401 は throw されるべき")
        } catch ApiFailure.unauthorized {
            // 期待どおり。
        } catch { XCTFail("想定外のエラー: \(error)") }

        XCTAssertEqual(observerCallCount, 0, "Authorization 無しのリクエストでは observer は発火しない")
    }

    // verifies: CI-T14.8
    func testTT14_10b_observerDoesNotFireForDownloadAudio401() async {
        var observerCallCount = 0
        let session = MockURLSession(data: Data(), statusCode: 401)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: "tA",
            session: session,
            onUnauthorized: { observerCallCount += 1 }
        )

        do {
            _ = try await client.downloadAudio(from: URL(string: "https://storage.example.com/signed.mp3")!)
            XCTFail("401 は throw されるべき")
        } catch ApiFailure.unauthorized {
            // 期待どおり。
        } catch { XCTFail("想定外のエラー: \(error)") }

        XCTAssertEqual(observerCallCount, 0, "downloadAudio は Authorization を付けないため observer は発火しない")
    }

    // verifies: CI-T14.8
    func testTT14_10c_observerDoesNotFireForNon401Failures() async {
        var observerCallCount = 0
        for statusCode in [403, 500] {
            let session = MockURLSession(data: Data(), statusCode: statusCode)
            let client = APIClient(
                baseURL: URL(string: "https://api.example.com")!,
                apiKey: "key",
                sessionToken: "tA",
                session: session,
                onUnauthorized: { observerCallCount += 1 }
            )
            _ = try? await client.fetchListeningStreak()
        }

        XCTAssertEqual(observerCallCount, 0)
    }

    // verifies: CI-T14.8
    func testTT14_10d_observerDoesNotFireOnCancellationAndThrowValueUnchanged() async {
        var observerCallCount = 0
        let session = MockURLSession(mode: .transportError(CancellationError()))
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: "tA",
            session: session,
            onUnauthorized: { observerCallCount += 1 }
        )

        do {
            _ = try await client.fetchListeningStreak()
            XCTFail("CancellationError は伝播すべき")
        } catch is CancellationError {
            // 期待どおり。
        } catch { XCTFail("想定外のエラー: \(error)") }

        XCTAssertEqual(observerCallCount, 0)
    }

    // MARK: - T-T14-11（CI-T14.10）

    // verifies: CI-T14.10
    func testTT14_11_completeLoginStoresTokenAndSession() {
        let store = InMemorySessionStore()
        let appState = makeSubjectAwareAppState(sessionStore: store)
        let response = LoginResponse(
            token: "tok-1",
            user: AuthUser(username: "alice", role: "admin", displayName: "Alice")
        )

        appState.completeLogin(response)

        XCTAssertEqual(store.token, "tok-1")
        XCTAssertEqual(appState.currentUser?.username, "alice")
        guard case .authenticated(let user) = appState.session, user.username == "alice" else {
            return XCTFail("session は authenticated になるべき")
        }
    }

    // MARK: - T-T14-13a〜c（CI-T14.11）

    // verifies: CI-T14.11
    func testTT14_13a_updateCurrentUserAppliesWithOwnStamp() {
        let appState = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let stamp = appState.subjectStamp
        let updated = AuthUser(username: "alice", role: "user", displayName: "Alice2")

        appState.updateCurrentUser(updated, capturedAt: stamp)

        XCTAssertEqual(appState.currentUser?.displayName, "Alice2")
    }

    // verifies: CI-T14.11
    func testTT14_13b_updateCurrentUserIgnoredWhenCapturedAnonymous() async {
        // 前提: トークン無しで refreshAuth() し anonymous にする（HTTP は送らない: CI-T14.2）
        let appState = makeSubjectAwareAppState()
        await appState.refreshAuth()
        let stamp = appState.subjectStamp
        guard case .anonymous = appState.session else { return XCTFail("前提: 新規は resolving。まず anonymous にする") }

        appState.updateCurrentUser(AuthUser(username: "alice", role: "user", displayName: "Alice"), capturedAt: stamp)

        guard case .anonymous = appState.session else { return XCTFail("anonymous のまま変わらないべき") }
    }

    // verifies: CI-T14.11
    func testTT14_13c_updateCurrentUserIgnoredWhenSubjectChanged() async {
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(sessionStore: store)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let stampA = appState.subjectStamp

        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))

        appState.updateCurrentUser(AuthUser(username: "alice", role: "user", displayName: "Alice-updated"), capturedAt: stampA)

        guard case .authenticated(let user) = appState.session, user.username == "bob" else {
            return XCTFail("bob の session が A の stamp で書き換わってはならない（F6 の再現手順）")
        }
        XCTAssertEqual(store.token, "tB")
    }

    // MARK: - T-T14-14（CI-T14.12）

    // verifies: CI-T14.12
    func testTT14_14_logoutClearsTokenAndSession() async {
        let store = InMemorySessionStore(token: "tok-1")
        let appState = makeSubjectAwareAppState(sessionStore: store)
        appState.completeLogin(LoginResponse(token: "tok-1", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))

        await appState.logout()

        XCTAssertNil(store.token)
        XCTAssertNil(appState.currentUser)
        guard case .anonymous = appState.session else { return XCTFail("session は anonymous になるべき") }
    }

    // MARK: - T-T14-16（CI-T14.15, CI-T14.7）

    // verifies: CI-T14.15, CI-T14.7
    func testTT14_16_handleIgnoresStaleAndMissingSentToken() {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let appState = makeSubjectAwareAppState(sessionStore: store, nowPlayingCenter: nowPlaying)
        appState.registerPlaybackLifecycle(playback)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        // B が確立済み（前主体 A の失効トークンで送ったリクエストが後から届く想定）。
        store.token = "tB"
        appState.updateCurrentUser(AuthUser(username: "bob", role: "user", displayName: "Bob"), capturedAt: appState.subjectStamp)

        appState.handle(failure: .unauthorized, sentToken: "tA")
        appState.handle(failure: .unauthorized, sentToken: nil)

        guard case .authenticated(let user) = appState.session, user.username == "bob" else {
            return XCTFail("B の session が保たれるべき")
        }
        XCTAssertEqual(store.token, "tB")
        XCTAssertEqual(nowPlaying.clearCallCount, 0)
        XCTAssertEqual(playback.stopForLogoutCallCount, 0)
        XCTAssertNil(appState.lastCleanupIncomplete)
    }

    // MARK: - T-T14-17a/b（CI-T14.16, G1）

    // verifies: CI-T14.16
    func testTT14_17a_refreshAuthDoesNotOverwriteLaterSubjectOnSuccess() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/auth/me")
        scripted.configure(method: "GET", path: "/settings/preferences", status: 200, body: Data("{}".utf8))
        scripted.configure(method: "POST", path: "/notifications/device-tokens", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)

        let task = Task { await appState.refreshAuth() }
        await scripted.waitUntilRequested(method: "GET", path: "/auth/me")
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        let aliceJSON = #"{"username":"alice","role":"user","display_name":"Alice"}"#
        scripted.release(method: "GET", path: "/auth/me", status: 200, body: Data(aliceJSON.utf8))
        await task.value

        guard case .authenticated(let user) = appState.session, user.username == "bob" else {
            return XCTFail("B の session が A の遅延応答で書き換わってはならない")
        }
        XCTAssertEqual(store.token, "tB")
        XCTAssertTrue(
            scripted.sentRequests.filter { $0.httpMethod == "GET" && $0.url?.path == "/settings/preferences" }.isEmpty,
            "A の同期を予約してはならない"
        )
    }

    // verifies: CI-T14.16
    func testTT14_17b_refreshAuthDoesNotOverwriteLaterSubjectOn401() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/auth/me")
        scripted.configure(method: "GET", path: "/settings/preferences", status: 200, body: Data("{}".utf8))
        scripted.configure(method: "POST", path: "/notifications/device-tokens", status: 200)
        let nowPlaying = NowPlayingCenterSpy()
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store, nowPlayingCenter: nowPlaying)

        let task = Task { await appState.refreshAuth() }
        await scripted.waitUntilRequested(method: "GET", path: "/auth/me")
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        scripted.release(method: "GET", path: "/auth/me", status: 401)
        await task.value

        guard case .authenticated(let user) = appState.session, user.username == "bob" else {
            return XCTFail("B の session が A 宛ての 401 で書き換わってはならない")
        }
        XCTAssertEqual(store.token, "tB")
        XCTAssertEqual(nowPlaying.clearCallCount, 0, "A の 401 由来の handle も no-op であるべき")
        XCTAssertTrue(scripted.sentRequests.filter { $0.httpMethod == "GET" && $0.url?.path == "/settings/preferences" }.isEmpty)
    }

    // MARK: - T-T14-18（CI-T14.3, CI-T15.10, D-10）

    // verifies: CI-T14.3, CI-T15.10
    func testTT14_18_outerCancellationDoesNotCancelPreferencesSync() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        let aliceJSON = #"{"username":"alice","role":"user","display_name":"Alice"}"#
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: Data(aliceJSON.utf8))
        scripted.configurePending(method: "GET", path: "/settings/preferences")
        scripted.configure(method: "POST", path: "/notifications/device-tokens", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)

        let outer = Task { await appState.refreshAuth() }
        await scripted.waitUntilRequested(method: "GET", path: "/settings/preferences")
        outer.cancel()
        let prefsJSON = #"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":5}"#
        scripted.release(method: "GET", path: "/settings/preferences", status: 200, body: Data(prefsJSON.utf8))
        await outer.value

        guard case .authenticated(let user) = appState.session, user.username == "alice" else {
            return XCTFail("authenticated(alice) になるべき")
        }
        XCTAssertEqual(appState.defaultDifficulty, "toeic_900")
        XCTAssertEqual(appState.defaultPlaybackSpeed, 1.25)
        XCTAssertEqual(appState.weeklyGoalEpisodes, 5)
        XCTAssertFalse(appState.preferencesSyncFailed)
    }

    // MARK: - T-T14-19a〜c（CI-T14.16, G5〜G7）

    // verifies: CI-T14.16
    func testTT14_19a_refreshListeningStreakGuardedBySubject() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/users/me/listening-streak")
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        XCTAssertNil(appState.listeningStreak)
        XCTAssertFalse(appState.listeningStreakLoadFailed)

        let task = Task { await appState.refreshListeningStreak() }
        await scripted.waitUntilRequested(method: "GET", path: "/users/me/listening-streak")
        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        scripted.release(
            method: "GET", path: "/users/me/listening-streak", status: 200,
            body: Data(#"{"current_streak_days":5,"today_listened":true,"last_listened_day":"2026-07-29"}"#.utf8)
        )
        await task.value

        XCTAssertNil(appState.listeningStreak, "前の主体の応答は B の状態を書き換えないべき")
        XCTAssertFalse(appState.listeningStreakLoadFailed)
        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("B のまま") }
        XCTAssertEqual(store.token, "tB")
    }

    // verifies: CI-T14.16
    func testTT14_19b_refreshOnboardingStatusGuardedBySubject() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/settings/onboarding")
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        XCTAssertNil(appState.onboardingCompleted)

        let task = Task { await appState.refreshOnboardingStatus() }
        await scripted.waitUntilRequested(method: "GET", path: "/settings/onboarding")
        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        scripted.release(method: "GET", path: "/settings/onboarding", status: 200, body: Data(#"{"onboarding_completed":false}"#.utf8))
        await task.value

        XCTAssertNil(appState.onboardingCompleted, "前の主体の応答は B の状態を書き換えないべき")
        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("B のまま") }
        XCTAssertEqual(store.token, "tB")
    }

    // verifies: CI-T14.16
    func testTT14_19c_completeOnboardingGuardedBySubject() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "POST", path: "/settings/onboarding/complete")
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        XCTAssertNil(appState.onboardingCompleted)

        let task = Task { await appState.completeOnboarding() }
        await scripted.waitUntilRequested(method: "POST", path: "/settings/onboarding/complete")
        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        scripted.release(method: "POST", path: "/settings/onboarding/complete", status: 200, body: Data(#"{"onboarding_completed":true}"#.utf8))
        await task.value

        XCTAssertNil(appState.onboardingCompleted, "前の主体の応答は B の状態を書き換えないべき")
        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("B のまま") }
        XCTAssertEqual(store.token, "tB")
    }

    // MARK: - T-T14-20（CI-T14.12, A10）

    // verifies: CI-T14.12
    func testTT14_20_logoutFromResolvingOnlyClearsTokenWithoutCleanup() async {
        let store = InMemorySessionStore(token: "tA")
        let nowPlaying = NowPlayingCenterSpy()
        let playback = PlaybackLifecycleSpy()
        let appState = makeSubjectAwareAppState(sessionStore: store, nowPlayingCenter: nowPlaying)
        appState.registerPlaybackLifecycle(playback)
        guard case .resolving = appState.session else { return XCTFail("前提: resolving（refreshAuth 未実行）") }

        await appState.logout()

        XCTAssertNil(store.token)
        guard case .anonymous = appState.session else { return XCTFail(".anonymous になるべき") }
        XCTAssertEqual(nowPlaying.clearCallCount, 0, "離脱元が authenticated でないため SubjectCleanup は走らない")
        XCTAssertEqual(playback.stopForLogoutCallCount, 0)
    }

    // MARK: - T-T14-21（CI-T14.16, G2, SR-12）

    // verifies: CI-T14.16
    func testTT14_21_refreshAuthDoesNotCancelLaterSubjectsDeviceTokenRegistration() async {
        let store = InMemorySessionStore(token: "tA")
        let scripted = ScriptedURLSession()
        let aliceJSON = #"{"username":"alice","role":"user","display_name":"Alice"}"#
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: Data(aliceJSON.utf8))
        scripted.configurePending(method: "GET", path: "/settings/preferences")
        scripted.configure(method: "DELETE", path: "/notifications/device-tokens", status: 200)
        scripted.configure(method: "POST", path: "/auth/logout", status: 200)
        scripted.configurePending(method: "POST", path: "/notifications/device-tokens")
        let appState = makeSubjectAwareAppState(session: scripted, sessionStore: store)

        let t = Task { await appState.refreshAuth() }
        await scripted.waitUntilRequested(method: "GET", path: "/settings/preferences")
        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        appState.didRegisterDeviceToken("apns-bob")
        await scripted.waitUntilRequested(method: "POST", path: "/notifications/device-tokens")
        scripted.release(method: "GET", path: "/settings/preferences", status: 200, body: Data("{}".utf8))
        await t.value

        XCTAssertTrue(scripted.cancelledRequests.isEmpty, "A の refreshAuth が B の登録 Task を cancel してはならない")
        let registerRequests = scripted.sentRequests.filter { $0.httpMethod == "POST" && $0.url?.path == "/notifications/device-tokens" }
        XCTAssertEqual(registerRequests.count, 1)
        guard case .authenticated(let user) = appState.session, user.username == "bob" else { return XCTFail("B のまま") }
        XCTAssertEqual(store.token, "tB")

        // 後片付け: 保留中の POST を解放する。
        scripted.release(method: "POST", path: "/notifications/device-tokens", status: 200)
    }

    // MARK: - T-T14-22（CI-T14.17）

    // verifies: CI-T14.17
    func testTT14_22_isCurrentSubjectReflectsSessionAtCaptureTime() async {
        let store = InMemorySessionStore()
        let appState = makeSubjectAwareAppState(sessionStore: store)
        await appState.refreshAuth() // -> anonymous（トークン無し）
        guard case .anonymous = appState.session else { return XCTFail("前提: anonymous") }
        let s0 = appState.subjectStamp

        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let sA = appState.subjectStamp
        XCTAssertTrue(appState.isCurrentSubject(sA))
        XCTAssertFalse(appState.isCurrentSubject(s0))

        await appState.logout()
        XCTAssertFalse(appState.isCurrentSubject(sA))

        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        XCTAssertFalse(appState.isCurrentSubject(sA))
        XCTAssertFalse(appState.isCurrentSubject(s0))

        let resolvingStore = InMemorySessionStore(token: "tA")
        let resolvingState = makeSubjectAwareAppState(sessionStore: resolvingStore)
        let sR = resolvingState.subjectStamp
        XCTAssertFalse(resolvingState.isCurrentSubject(sR), "resolving（非 authenticated）では常に false")
    }

    // MARK: - T-T14-23（CI-T14.18）

    // verifies: CI-T14.18
    func testTT14_23_confirmWeeklyGoalSyncGuardedBySubject() async {
        let store = InMemorySessionStore(token: "tA")
        let appState = makeSubjectAwareAppState(sessionStore: store)
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        let sA = appState.subjectStamp

        appState.confirmWeeklyGoalSync(5, capturedAt: sA)
        XCTAssertEqual(appState.lastConfirmedWeeklyGoalEpisodes, 5)

        await appState.logout()
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        let before = appState.lastConfirmedWeeklyGoalEpisodes

        appState.confirmWeeklyGoalSync(7, capturedAt: sA)
        XCTAssertEqual(appState.lastConfirmedWeeklyGoalEpisodes, before, "A の stamp では B の値を書き換えないべき")

        appState.confirmWeeklyGoalSync(10, capturedAt: appState.subjectStamp)
        XCTAssertEqual(appState.lastConfirmedWeeklyGoalEpisodes, 10)
    }

    // MARK: - APNs（既存。authStatus → session への機械的書換えのみ）

    func testHandleNotificationPodcastIdSetsSelectedPodcastId() {
        let appState = makeSubjectAwareAppState()

        appState.handleNotificationPodcastId("pod123")

        XCTAssertEqual(appState.selectedPodcastId, "pod123")
    }

    func testDidRegisterDeviceTokenStoresTokenWithoutCrashWhenUnauthenticated() {
        let appState = makeSubjectAwareAppState()

        appState.didRegisterDeviceToken("devicetokenhex")

        XCTAssertEqual(appState.apnsDeviceToken, "devicetokenhex")
    }

    private func makeAppState(session: URLSessionProtocol) -> AppState {
        makeSubjectAwareAppState(session: session)
    }

    func testRegisterDeviceTokenIfPossibleDoesNotCallAPIAfterLogout() async {
        // logout() 後（session = .anonymous）に registerDeviceTokenIfPossible() を
        // 直接 await しても、HTTP リクエストが発生しないことを検証する（issue #80 レビュー指摘）。
        let session = MockURLSession(data: Data(), statusCode: 200)
        let appState = makeAppState(session: session)
        appState.completeLogin(LoginResponse(token: "tok-1", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        appState.didRegisterDeviceToken("devicetokenhex")
        await appState.logout()

        await appState.registerDeviceTokenIfPossible()

        // logout() 自体が /auth/logout・デバイストークン解除の HTTP 呼び出しを行うため
        // lastRequest は nil にならない。検証すべきは「登録（POST /notifications/device-tokens）
        // が発生していないこと」。
        let isRegisterRequest = session.lastRequest?.httpMethod == "POST"
            && session.lastRequest?.url?.path == "/notifications/device-tokens"
        XCTAssertFalse(isRegisterRequest, "unauthenticated では登録リクエストが発生してはならない")
    }

    func testRegisterDeviceTokenIfPossibleCallsAPIWhenAuthenticated() async {
        // authenticated 状態で didRegisterDeviceToken を呼ぶと、登録リクエストが発生する（正常系）。
        let session = MockURLSession(data: Data(), statusCode: 200)
        let appState = makeAppState(session: session)
        appState.completeLogin(
            LoginResponse(
                token: "tok-1",
                user: AuthUser(username: "alice", role: "user", displayName: "Alice")
            )
        )

        appState.didRegisterDeviceToken("devicetokenhex")
        // didRegisterDeviceToken() 内で投げっぱなし Task が起動するが、テストからは追跡できない
        // ため、決定論的に検証するには同一状態で registerDeviceTokenIfPossible() を直接 await する。
        await appState.registerDeviceTokenIfPossible()

        XCTAssertEqual(
            session.lastRequest?.url?.path,
            "/notifications/device-tokens"
        )
    }
}
