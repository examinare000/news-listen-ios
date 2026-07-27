import XCTest
@testable import NewsListenApp

@MainActor
final class StarredViewModelTests: XCTestCase {

    /// 送信されたリクエストを検証できるよう `MockURLSession` も返す（戻り値がタプルである点は
    /// `SessionsAPIClientTests.makeClient` と同じ形。ただし引数・オーバーロードの有無は異なる）。
    /// 戻り値型のみで多重定義すると将来の呼び出しで型推論があいまいになりうるため、単一シグネチャに統一する。
    private func makeClient(json: String, statusCode: Int = 200) -> (APIClient, MockURLSession) {
        let session = MockURLSession(data: json.data(using: .utf8)!, statusCode: statusCode)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
        return (client, session)
    }

    private func makeArticle(id: String) -> Article {
        Article(
            id: id,
            title: id,
            url: "https://example.com/\(id)",
            source: "hackernews",
            score: 0.5,
            publishedAt: "2026-05-31T06:00:00Z"
        )
    }

    func testLoadStarredPopulatesArticles() async throws {
        let json = #"""
        {"articles": [
            {"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"},
            {"id":"a2","title":"Go","url":"https://example.com/go","source":"zenn","score":0.7,"published_at":"2026-05-31T05:00:00Z"}
        ]}
        """#
        let vm = StarredViewModel(apiClient: makeClient(json: json).0)

        await vm.loadStarred()

        XCTAssertEqual(vm.articles.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testLoadStarredSetsErrorMessageOnFailure() async throws {
        let vm = StarredViewModel(apiClient: makeClient(json: "", statusCode: 500).0)

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
        let vm = StarredViewModel(apiClient: makeClient(json: #"{"articles": []}"#).0)

        await vm.loadStarred()

        XCTAssertEqual(vm.displayState, .empty)
    }

    func testShouldPresentErrorAlertFalseWhenErrorShownInline() async throws {
        // 一覧が空でロード失敗＝インラインエラー表示中は、同じエラーのアラートを重ねて出さない
        // （FeedViewModel と同じ判定を ListDisplayState 経由で共有する）。
        let vm = StarredViewModel(apiClient: makeClient(json: "", statusCode: 500).0)

        await vm.loadStarred()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    // MARK: - unstar（スタータブのスワイプ導線）

    func testUnstarRemovesArticleAndSendsDelete() async throws {
        let (client, session) = makeClient(json: "")
        let vm = StarredViewModel(apiClient: client)
        let article = makeArticle(id: "a1")
        vm.articles = [article]

        await vm.unstar(article)

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(session.lastRequest?.url?.path, "/articles/a1/star")
        XCTAssertEqual(session.lastRequest?.httpMethod, "DELETE")
        XCTAssertNil(vm.errorMessage)
    }

    func testUnstarFailureRestoresArticleAtOriginalIndexAndSetsError() async throws {
        let (client, _) = makeClient(json: "", statusCode: 500)
        let vm = StarredViewModel(apiClient: client)
        let a = makeArticle(id: "a1")
        let b = makeArticle(id: "b1")
        let c = makeArticle(id: "c1")
        vm.articles = [a, b, c]

        await vm.unstar(b)

        XCTAssertEqual(vm.articles.map(\.id), ["a1", "b1", "c1"])
        XCTAssertNotNil(vm.errorMessage)
    }

    func testUnstar404IsTreatedAsSuccess() async throws {
        let (client, _) = makeClient(json: "", statusCode: 404)
        let vm = StarredViewModel(apiClient: client)
        let article = makeArticle(id: "a1")
        vm.articles = [article]

        await vm.unstar(article)

        // 記事 doc が既に存在しない＝サーバ側の状態としては既に望みどおりのため、行を残すとゴースト化する。
        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    func testUnstarOfflineSetsOfflineMessageWithoutNetworkCall() async throws {
        let (client, session) = makeClient(json: "")
        let vm = StarredViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: false))
        let article = makeArticle(id: "a1")
        vm.articles = [article]

        await vm.unstar(article)

        XCTAssertNil(session.lastRequest)
        XCTAssertEqual(vm.errorMessage, FeedViewModel.offlineMessage)
        // オフラインガードは楽観削除より先に効くため、記事は除去されないまま残る。
        XCTAssertEqual(vm.articles.map(\.id), ["a1"])
    }

    func testUnstarSwallowsURLErrorCancelled() async throws {
        let vm = StarredViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: AlwaysThrowingURLSession(error: URLError(.cancelled))
        ))
        let article = makeArticle(id: "a1")
        vm.articles = [article]

        await vm.unstar(article)

        XCTAssertNil(vm.errorMessage)
        // キャンセルは非復元（次回 loadStarred でサーバの真実に収束させる）。
        XCTAssertTrue(vm.articles.isEmpty)
    }

    func testUnstarSwallowsRawCancellationError() async throws {
        let vm = StarredViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: AlwaysThrowingURLSession(error: CancellationError())
        ))
        let article = makeArticle(id: "a1")
        vm.articles = [article]

        await vm.unstar(article)

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.articles.isEmpty)
    }

    /// 許容仕様の回帰ガード（doc コメント参照）: 別記事の un-star を並行実行して両方失敗させても、
    /// 表示順の崩れは許容するが記事の重複・消失はしないことを固定する。順序はここでは検証しない。
    func testConcurrentUnstarFailuresLeaveAllArticlesPresentWithoutOrderGuarantee() async throws {
        let (client, _) = makeClient(json: "", statusCode: 500)
        let vm = StarredViewModel(apiClient: client)
        let a = makeArticle(id: "a1")
        let b = makeArticle(id: "b1")
        let c = makeArticle(id: "c1")
        vm.articles = [a, b, c]

        async let first: Void = vm.unstar(a)
        async let second: Void = vm.unstar(c)
        _ = await (first, second)

        XCTAssertEqual(Set(vm.articles.map(\.id)), Set(["a1", "b1", "c1"]))
        XCTAssertEqual(vm.articles.count, 3)
        XCTAssertNotNil(vm.errorMessage)
    }

    func testUnstarLastArticleYieldsEmptyDisplayState() async throws {
        let (client, _) = makeClient(json: "")
        let vm = StarredViewModel(apiClient: client)
        let article = makeArticle(id: "a1")
        vm.articles = [article]

        await vm.unstar(article)

        XCTAssertEqual(vm.displayState, .empty)
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
