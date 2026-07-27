import XCTest
@testable import NewsListenApp

@MainActor
final class StarredViewModelTests: XCTestCase {

    private func makeClient(json: String, statusCode: Int = 200) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: json.data(using: .utf8)!, statusCode: statusCode)
        )
    }

    func testLoadStarredPopulatesArticles() async throws {
        let json = #"""
        {"articles": [
            {"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"},
            {"id":"a2","title":"Go","url":"https://example.com/go","source":"zenn","score":0.7,"published_at":"2026-05-31T05:00:00Z"}
        ]}
        """#
        let vm = StarredViewModel(apiClient: makeClient(json: json))

        await vm.loadStarred()

        XCTAssertEqual(vm.articles.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadStarredSetsErrorMessageOnFailure() async throws {
        let vm = StarredViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadStarred()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadStarredOfflineSetsOfflineMessageWithoutNetworkCall() async throws {
        let mock = MockURLSession(data: Data(), statusCode: 200)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        let vm = StarredViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: false))

        await vm.loadStarred()

        XCTAssertNil(mock.lastRequest)   // ネットワークを一切呼ばない
        XCTAssertEqual(vm.errorMessage, FeedViewModel.offlineMessage)
        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadStarredSwallowsURLErrorCancelled() async throws {
        let vm = StarredViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: AlwaysThrowingURLSession(error: URLError(.cancelled))
        ))

        await vm.loadStarred()

        XCTAssertNil(vm.errorMessage)
    }

    func testLoadStarredSwallowsRawCancellationError() async throws {
        let vm = StarredViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: AlwaysThrowingURLSession(error: CancellationError())
        ))

        await vm.loadStarred()

        XCTAssertNil(vm.errorMessage)
    }

    func testDisplayStateIsEmptyAfterSuccessfulEmptyLoad() async throws {
        let vm = StarredViewModel(apiClient: makeClient(json: #"{"articles": []}"#))

        await vm.loadStarred()

        XCTAssertEqual(vm.displayState, .empty)
    }

    func testShouldPresentErrorAlertFalseWhenErrorShownInline() async throws {
        // 一覧が空でロード失敗＝インラインエラー表示中は、同じエラーのアラートを重ねて出さない
        // （FeedViewModel と同じ判定を ListDisplayState 経由で共有する）。
        let vm = StarredViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadStarred()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }
}

/// `data(for:)` を呼ぶたびに常に指定エラーを投げる軽量スタブ。
/// キャンセル系エラー（`URLError(.cancelled)` / `CancellationError`）の黙殺経路のみを
/// 検証する用途のため、共有 `MockURLSession` とは別に本ファイル内で定義する。
private struct AlwaysThrowingURLSession: URLSessionProtocol {
    let error: Error

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}
