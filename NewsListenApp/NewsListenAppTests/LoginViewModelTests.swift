import XCTest
@testable import NewsListenApp

/// LoginViewModel の送信ロジックのテスト。
@MainActor
final class LoginViewModelTests: XCTestCase {

    private func makeClient(data: Data, status: Int) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: data, statusCode: status)
        )
    }

    private func makeAuthentication(client: APIClient) -> Authentication {
        Authentication(gateway: .live(client: { client }))
    }

    func testSuccessCallsOnSuccessWithResponse() async {
        let json = #"{"token":"tok","user":{"username":"alice","role":"user","display_name":"Alice"}}"#.data(using: .utf8)!
        var captured: LoginReceipt?
        let vm = LoginViewModel(authentication: makeAuthentication(client: makeClient(data: json, status: 200))) { captured = $0 }
        vm.username = "alice"
        vm.password = "pw"

        await vm.submit()

        XCTAssertEqual(captured?.token, "tok")
        XCTAssertEqual(captured?.subject.username, "alice")
        XCTAssertNil(vm.errorMessage)
    }

    // T-T13-04（verifies: ios-contract-19, R-keep2）。
    func testWrongCredentialsShowsGenericError() async {
        var called = false
        let vm = LoginViewModel(authentication: makeAuthentication(client: makeClient(data: Data(), status: 401))) { _ in called = true }
        vm.username = "alice"
        vm.password = "wrong"

        await vm.submit()

        XCTAssertFalse(called)
        XCTAssertEqual(vm.errorMessage, "ユーザーIDまたはパスワードが正しくありません")
    }

    func testEmptyInputDoesNotSubmit() async {
        var called = false
        let vm = LoginViewModel(authentication: makeAuthentication(client: makeClient(data: Data(), status: 200))) { _ in called = true }

        await vm.submit()

        XCTAssertFalse(called)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testCanSubmitReflectsInput() {
        let vm = LoginViewModel(authentication: makeAuthentication(client: makeClient(data: Data(), status: 200))) { _ in }
        XCTAssertFalse(vm.canSubmit)
        vm.username = "alice"
        vm.password = "pw"
        XCTAssertTrue(vm.canSubmit)
    }

    // verifies: ios-cmd-account-01
    func testSubmitSendsTrimmedUsernameAndUntrimmedPassword() async throws {
        let json = #"{"token":"tok","user":{"username":"alice","role":"user","display_name":"Alice"}}"#.data(using: .utf8)!
        let session = MockURLSession(data: json, statusCode: 200)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
        let vm = LoginViewModel(authentication: makeAuthentication(client: client)) { _ in }
        vm.username = "  alice  "
        vm.password = " pw "

        await vm.submit()

        let data = try XCTUnwrap(session.lastRequest?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["username"] as? String, "alice")
        XCTAssertEqual(body["password"] as? String, " pw ")
    }

    // verifies: ios-cmd-account-01
    func testGenericFailureShowsMessageThenSuccessClearsItAndKeepsSubmitting() async {
        let json = #"{"token":"tok","user":{"username":"alice","role":"user","display_name":"Alice"}}"#.data(using: .utf8)!
        let session = SequentialMockSession([
            .init(data: Data(), statusCode: 500),
            .init(data: json, statusCode: 200),
        ])
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
        var successCount = 0
        let vm = LoginViewModel(authentication: makeAuthentication(client: client)) { _ in successCount += 1 }
        vm.username = "alice"
        vm.password = "pw"

        await vm.submit()

        XCTAssertEqual(vm.errorMessage, "ログインに失敗しました。接続設定を確認してください")
        XCTAssertFalse(vm.isSubmitting)
        XCTAssertEqual(successCount, 0)

        await vm.submit()

        XCTAssertNil(vm.errorMessage, "再実行の開始で前回の文言が消える")
        XCTAssertTrue(vm.isSubmitting, "成功時は画面遷移までボタン無効を維持する")
        XCTAssertEqual(successCount, 1)
    }
}
