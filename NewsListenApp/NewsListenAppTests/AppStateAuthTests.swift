import XCTest
@testable import NewsListenApp

/// AppState の認証状態遷移とセッション保管のテスト。
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

    func testCompleteLoginStoresTokenAndUser() {
        let store = InMemorySessionStore()
        let appState = AppState(sessionStore: store)
        let response = LoginResponse(
            token: "tok-1",
            user: AuthUser(username: "alice", role: "admin", displayName: "Alice")
        )

        appState.completeLogin(response)

        XCTAssertEqual(store.token, "tok-1")
        XCTAssertEqual(appState.currentUser?.username, "alice")
        if case .authenticated = appState.authStatus {} else {
            XCTFail("authStatus は authenticated になるべき")
        }
    }

    func testLogoutClearsTokenAndUser() async {
        let store = InMemorySessionStore(token: "tok-1")
        let appState = AppState(sessionStore: store)
        appState.currentUser = AuthUser(username: "alice", role: "user", displayName: "Alice")
        // apiBaseURL/apiKey 未設定のため apiClient は nil。logout はローカル状態のみ落とす。

        await appState.logout()

        XCTAssertNil(store.token)
        XCTAssertNil(appState.currentUser)
        if case .unauthenticated = appState.authStatus {} else {
            XCTFail("authStatus は unauthenticated になるべき")
        }
    }

    func testRefreshAuthWithoutTokenIsUnauthenticated() async {
        let appState = AppState(sessionStore: InMemorySessionStore())

        await appState.refreshAuth()

        if case .unauthenticated = appState.authStatus {} else {
            XCTFail("トークン無しでは unauthenticated になるべき")
        }
    }

    // MARK: - APNs プッシュ（issue #80）

    func testHandleNotificationPodcastIdSetsSelectedPodcastId() {
        let appState = AppState(sessionStore: InMemorySessionStore())

        appState.handleNotificationPodcastId("pod123")

        XCTAssertEqual(appState.selectedPodcastId, "pod123")
    }

    func testDidRegisterDeviceTokenStoresTokenWithoutCrashWhenUnauthenticated() {
        // 未認証・apiClient nil でもクラッシュせず、トークンを保持して登録を保留する。
        let appState = AppState(sessionStore: InMemorySessionStore())

        appState.didRegisterDeviceToken("devicetokenhex")

        XCTAssertEqual(appState.apnsDeviceToken, "devicetokenhex")
    }

    private func makeAppState(session: URLSessionProtocol) -> AppState {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        return AppState(sessionStore: InMemorySessionStore(), apiClientOverride: client)
    }

    func testRegisterDeviceTokenIfPossibleDoesNotCallAPIAfterLogout() async {
        // logout() 後（authStatus = .unauthenticated）に registerDeviceTokenIfPossible() を
        // 直接 await しても、HTTP リクエストが発生しないことを検証する（issue #80 レビュー指摘）。
        let session = MockURLSession(data: Data(), statusCode: 200)
        let appState = makeAppState(session: session)
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
