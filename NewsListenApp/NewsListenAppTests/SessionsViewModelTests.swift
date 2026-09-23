import XCTest
@testable import NewsListenApp

/// verifies: CI-T13（R-keep2）。`SessionsViewModel.revokeSession(id:)` の既存分岐
/// （404 = 冪等成功／500 = 汎用エラー文言）を、`ApiFailure` への置換前後で固定する特性テスト。
@MainActor
final class SessionsViewModelTests: XCTestCase {

    private func makeClient(statusCode: Int) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: statusCode)
        )
    }

    func testRevokeSession404IsTreatedAsIdempotentSuccess() async throws {
        let vm = SessionsViewModel(apiClient: makeClient(statusCode: 404))

        await vm.revokeSession(id: "s1")

        XCTAssertNil(vm.errorMessage)
    }

    func testRevokeSession500SetsGenericErrorMessage() async throws {
        let vm = SessionsViewModel(apiClient: makeClient(statusCode: 500))

        await vm.revokeSession(id: "s1")

        XCTAssertEqual(vm.errorMessage, "ログアウトに失敗しました")
    }
}
