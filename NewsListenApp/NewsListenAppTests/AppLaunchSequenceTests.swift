import XCTest
@testable import NewsListenApp

/// 起動時の連鎖（`LaunchSequence`）と、`AppState.resolve()` が連鎖を起こさない（Account だけを持つ）ことの契約テスト。
///
/// `resolve()` は主体の解決だけをして、設定の同期と端末トークンの登録は呼ばない。
/// 連鎖は合成 root が `resolve()` の戻り値（true）を受けて `LaunchSequence.run()` を起こす。
@MainActor
final class AppLaunchSequenceTests: XCTestCase {

    private let aliceJSON = #"{"username":"alice","role":"user","display_name":"Alice"}"#

    // MARK: - LaunchSequence

    /// 呼ばれた順の記録と、主体が現在のものかどうかを切り替える box。
    @MainActor
    private final class LaunchLog {
        var events: [String] = []
        var isCurrent = true
    }

    private func makeSequence(
        _ log: LaunchLog,
        refresh: @escaping () async -> Void
    ) -> LaunchSequence {
        // `SubjectStamp` は `AppState.swift` の外から作れないので、本物の `AppState` から借りる。
        let stamp = makeSubjectAwareAppState().subjectStamp
        return LaunchSequence(
            refreshPreferences: refresh,
            registerPush: { log.events.append("register") },
            subjectStamp: { stamp },
            isCurrentSubject: { _ in log.isCurrent }
        )
    }

    func testRunSyncsPreferencesBeforeRegisteringPush() async {
        let log = LaunchLog()
        let sequence = makeSequence(log) {
            log.events.append("refresh-start")
            await Task.yield()
            await Task.yield()
            log.events.append("refresh-end")
        }

        await sequence.run()

        XCTAssertEqual(log.events, ["refresh-start", "refresh-end", "register"], "登録は同期の完了後にしか呼ばない")
    }

    func testRunDoesNotRegisterWhenSubjectChangedDuringSync() async {
        let log = LaunchLog()
        let sequence = makeSequence(log) {
            log.events.append("refresh")
            log.isCurrent = false
        }

        await sequence.run()

        XCTAssertEqual(log.events, ["refresh"], "同期の途中で主体が交代したら登録しない")
    }

    func testRunDoesNothingWhenNotCurrentSubjectAtStart() async {
        let log = LaunchLog()
        log.isCurrent = false
        let sequence = makeSequence(log) { log.events.append("refresh") }

        await sequence.run()

        XCTAssertEqual(log.events, [], "開始時に現在の主体でなければ、同期も登録も始めない")
    }

    // MARK: - AppState.resolve()

    func testResolveReturnsTrueOnlyWhenItTransitionsToAuthenticated() async {
        let harness = makeAppStateHarness(
            session: MockURLSession(data: Data(aliceJSON.utf8), statusCode: 200),
            sessionStore: InMemorySessionStore(token: "tA")
        )

        let first = await harness.state.resolve()
        let second = await harness.state.resolve()

        XCTAssertTrue(first, "自分の呼出で authenticated へ遷移させたときだけ true")
        XCTAssertFalse(second, "resolving を出た後の呼出は何もせず false（冪等）")
        XCTAssertEqual(harness.state.currentSubject?.username, "alice")
    }

    func testResolveReturnsFalseForAnonymousUnavailableAndRace() async {
        // (i) token なし
        let noToken = makeAppStateHarness(session: MockURLSession(data: Data(), statusCode: 200))
        let noTokenResult = await noToken.state.resolve()
        XCTAssertFalse(noTokenResult)
        XCTAssertEqual(noToken.state.session, .anonymous)

        // (ii) 401
        let unauthorizedStore = InMemorySessionStore(token: "tA")
        let unauthorized = makeAppStateHarness(
            session: MockURLSession(data: Data(), statusCode: 401), sessionStore: unauthorizedStore)
        let unauthorizedResult = await unauthorized.state.resolve()
        XCTAssertFalse(unauthorizedResult)
        XCTAssertEqual(unauthorized.state.session, .anonymous)
        XCTAssertNil(unauthorizedStore.token)

        // (iii) 500
        let server = makeAppStateHarness(
            session: MockURLSession(data: Data(), statusCode: 500), sessionStore: InMemorySessionStore(token: "tA"))
        let serverResult = await server.state.resolve()
        XCTAssertFalse(serverResult)
        XCTAssertEqual(server.state.session, .unavailable(.server(status: 500)))

        // (iv) 応答待ちの間に別の主体がログインした（遅延応答は後発の主体を書き換えない）
        let scripted = ScriptedURLSession()
        scripted.configurePending(method: "GET", path: "/auth/me")
        let race = makeAppStateHarness(session: scripted, sessionStore: InMemorySessionStore(token: "tA"))
        let task = Task { await race.state.resolve() }
        await scripted.waitUntilRequested(method: "GET", path: "/auth/me")
        race.state.completeLogin(LoginReceipt(
            token: "tB", subject: Subject(username: "bob", displayName: "Bob", role: Role(rawValue: "user"), key: nil)))
        scripted.release(method: "GET", path: "/auth/me", status: 200, body: Data(aliceJSON.utf8))
        let raceResult = await task.value
        XCTAssertFalse(raceResult, "競合に負けた呼出は true を返さない")
        XCTAssertEqual(race.state.currentSubject?.username, "bob")
    }

    func testResolveFallsBackToAnonymousWhenGatewayCannotBeMade() async {
        let state = AppState(
            sessionStore: InMemorySessionStore(token: "tA"),
            accountGatewayFactory: { _, _ in nil },
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: { _ in }
        )

        let result = await state.resolve()

        XCTAssertFalse(result)
        XCTAssertEqual(state.session, .anonymous, "gateway を作れないときは `.unavailable` ではなく `.anonymous`")
    }

    func testResolveDoesNotWriteThroughPreferencesOrPushPorts() async {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/auth/me", status: 200, body: Data(aliceJSON.utf8))
        scripted.configure(method: "GET", path: "/settings/preferences", status: 200, body: Data("{}".utf8))
        scripted.configure(method: "POST", path: "/notifications/device-tokens", status: 200)
        let harness = makeAppStateHarness(session: scripted, sessionStore: InMemorySessionStore(token: "tA"))
        // token を保持しておく（予約は cancel）。`resolve()` が登録を呼べば、認証済みの後に送られてしまう。
        harness.push.didReceiveDeviceToken("apns-1")
        harness.push.cancelPendingRegistration()

        let result = await harness.state.resolve()
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(result)
        XCTAssertEqual(
            scripted.sentRequests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            ["GET /auth/me"],
            "resolve は設定の同期も端末トークンの登録も呼ばない"
        )
    }

    // MARK: - 合成 root の配線

    func testLoginCompletionWiringSendsNoPreferencesRequest() async {
        let scripted = ScriptedURLSession()
        scripted.configure(method: "GET", path: "/settings/preferences", status: 200, body: Data("{}".utf8))
        scripted.configure(method: "POST", path: "/notifications/device-tokens", status: 200)
        let harness = makeAppStateHarness(session: scripted)
        harness.push.didReceiveDeviceToken("apns-1")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(scripted.sentRequests.isEmpty, "前提: 未認証では送らない")

        harness.login(LoginReceipt(
            token: "tA", subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)))
        await waitForRequests(scripted, method: "POST", path: "/notifications/device-tokens")
        for _ in 0..<30 { await Task.yield() }

        let paths = scripted.sentRequests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }
        XCTAssertEqual(paths.filter { $0 == "GET /settings/preferences" }.count, 0, "ログイン直後に設定の同期を送らない")
        XCTAssertEqual(paths.filter { $0 == "POST /notifications/device-tokens" }.count, 1, "保留していた token の登録だけを 1 回送る")
    }
}
