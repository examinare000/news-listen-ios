import XCTest
@testable import NewsListenApp

/// verifies: ios-contract-19（R-keep2）。`SessionsViewModel.revokeSession(id:)` の既存分岐
/// （404 = 冪等成功／500 = 汎用エラー文言）を、`ApiFailure` への置換前後で固定する特性テスト。
@MainActor
final class SessionsViewModelTests: XCTestCase {

    private let listPath = "/auth/sessions"

    private func makeViewModel(session: URLSessionProtocol) -> SessionsViewModel {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        return SessionsViewModel(deviceSessions: DeviceSessions(gateway: .live(client: { client })))
    }

    private func makeViewModel(statusCode: Int) -> SessionsViewModel {
        makeViewModel(session: MockURLSession(data: Data(), statusCode: statusCode))
    }

    private func sessionsJSON(_ ids: [String]) -> Data {
        let items = ids.map {
            #"{"id":"\#($0)","device_label":"Device \#($0)","created_at":"2026-01-01T00:00:00Z","last_used_at":null,"current":false}"#
        }
        return Data(#"{"sessions":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    func testRevokeSession404IsTreatedAsIdempotentSuccess() async throws {
        let vm = makeViewModel(statusCode: 404)

        await vm.revokeSession(id: "s1")

        XCTAssertNil(vm.errorMessage)
    }

    func testRevokeSession500SetsGenericErrorMessage() async throws {
        let vm = makeViewModel(statusCode: 500)

        await vm.revokeSession(id: "s1")

        XCTAssertEqual(vm.errorMessage, "ログアウトに失敗しました")
    }

    // verifies: ios-rule-account-06
    func testRevokeSession404RemovesRowAndKeepsMessageNil() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: listPath, status: 200, body: sessionsJSON(["s1", "s2"]))
        session.configure(method: "DELETE", path: "/auth/sessions/s1", status: 404)
        let vm = makeViewModel(session: session)
        await vm.loadSessions()
        XCTAssertEqual(vm.sessions.map(\.id), ["s1", "s2"])

        await vm.revokeSession(id: "s1")

        XCTAssertEqual(vm.sessions.map(\.id), ["s2"])
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // verifies: ios-rule-account-06
    func testRevokeSession500KeepsRowAndShowsMessage() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: listPath, status: 200, body: sessionsJSON(["s1", "s2"]))
        session.configure(method: "DELETE", path: "/auth/sessions/s1", status: 500)
        let vm = makeViewModel(session: session)
        await vm.loadSessions()

        await vm.revokeSession(id: "s1")

        XCTAssertEqual(vm.sessions.map(\.id), ["s1", "s2"])
        XCTAssertEqual(vm.errorMessage, "ログアウトに失敗しました")
        XCTAssertFalse(vm.isLoading)
    }

    // verifies: ios-rule-account-06
    func testLoadFailureKeepsRowsAndNextLoadReplacesThemAndClearsMessage() async {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: listPath, status: 200, body: sessionsJSON(["s1", "s2"]))
        let vm = makeViewModel(session: session)

        await vm.loadSessions()
        XCTAssertEqual(vm.sessions.map(\.id), ["s1", "s2"])
        XCTAssertFalse(vm.isLoading)

        session.configure(method: "GET", path: listPath, status: 500)
        await vm.loadSessions()

        XCTAssertEqual(vm.sessions.map(\.id), ["s1", "s2"], "取り直しの失敗で一覧を空にしない")
        XCTAssertEqual(vm.errorMessage, "デバイス一覧の取得に失敗しました")
        XCTAssertFalse(vm.isLoading)

        session.configure(method: "GET", path: listPath, status: 200, body: sessionsJSON(["s3"]))
        await vm.loadSessions()

        XCTAssertEqual(vm.sessions.map(\.id), ["s3"])
        XCTAssertNil(vm.errorMessage, "再実行の開始で前回の文言が消える")
        XCTAssertFalse(vm.isLoading)
    }

    // verifies: ios-cmd-account-07
    func testRevokeOthersPostsThenReloadsTheList() async {
        let session = ScriptedURLSession()
        session.configure(method: "POST", path: "/auth/sessions/revoke-others", status: 200, body: Data(#"{"revoked_count":2}"#.utf8))
        session.configure(method: "GET", path: listPath, status: 200, body: sessionsJSON(["s1"]))
        let vm = makeViewModel(session: session)

        await vm.revokeOthers()

        let sent = session.sentRequests.map { "\($0.httpMethod ?? "?") \($0.url?.path ?? "?")" }
        XCTAssertEqual(sent, ["POST /auth/sessions/revoke-others", "GET /auth/sessions"])
        XCTAssertEqual(vm.sessions.map(\.id), ["s1"])
    }
}
