import XCTest
@testable import NewsListenApp

/// verifies: CI-T13（R-keep2）。`PasskeyCredentialsViewModel.deleteCredential(id:)` の既存分岐
/// （404 = 冪等成功／500 = 汎用エラー文言）を、`ApiFailure` への置換前後で固定する特性テスト。
@MainActor
final class PasskeyCredentialsViewModelTests: XCTestCase {

    private func makeClient(statusCode: Int) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(), statusCode: statusCode)
        )
    }

    func testDeleteCredential404IsTreatedAsIdempotentSuccess() async throws {
        let vm = PasskeyCredentialsViewModel(apiClient: makeClient(statusCode: 404))

        await vm.deleteCredential(id: "c1")

        XCTAssertNil(vm.errorMessage)
    }

    func testDeleteCredential500SetsGenericErrorMessage() async throws {
        let vm = PasskeyCredentialsViewModel(apiClient: makeClient(statusCode: 500))

        await vm.deleteCredential(id: "c1")

        XCTAssertEqual(vm.errorMessage, "Passkey の削除に失敗しました")
    }
}
