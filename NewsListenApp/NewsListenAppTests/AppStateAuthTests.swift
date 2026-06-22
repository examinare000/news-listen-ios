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
}
