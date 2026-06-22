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

    func testSuccessCallsOnSuccessWithResponse() async {
        let json = #"{"token":"tok","user":{"username":"alice","role":"user","display_name":"Alice"}}"#.data(using: .utf8)!
        var captured: LoginResponse?
        let vm = LoginViewModel(apiClient: makeClient(data: json, status: 200)) { captured = $0 }
        vm.username = "alice"
        vm.password = "pw"

        await vm.submit()

        XCTAssertEqual(captured?.token, "tok")
        XCTAssertEqual(captured?.user.username, "alice")
        XCTAssertNil(vm.errorMessage)
    }

    func testWrongCredentialsShowsGenericError() async {
        var called = false
        let vm = LoginViewModel(apiClient: makeClient(data: Data(), status: 401)) { _ in called = true }
        vm.username = "alice"
        vm.password = "wrong"

        await vm.submit()

        XCTAssertFalse(called)
        XCTAssertEqual(vm.errorMessage, "ユーザーIDまたはパスワードが正しくありません")
    }

    func testEmptyInputDoesNotSubmit() async {
        var called = false
        let vm = LoginViewModel(apiClient: makeClient(data: Data(), status: 200)) { _ in called = true }

        await vm.submit()

        XCTAssertFalse(called)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testCanSubmitReflectsInput() {
        let vm = LoginViewModel(apiClient: makeClient(data: Data(), status: 200)) { _ in }
        XCTAssertFalse(vm.canSubmit)
        vm.username = "alice"
        vm.password = "pw"
        XCTAssertTrue(vm.canSubmit)
    }
}
