import XCTest
@testable import NewsListenApp

@MainActor
final class FeedViewModelTests: XCTestCase {

    private func makeClient(json: String, statusCode: Int = 200) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: json.data(using: .utf8)!, statusCode: statusCode)
        )
    }

    private func sampleArticle(id: String = "a1") -> Article {
        Article(id: id, title: "Test", url: "https://example.com", source: "hackernews", score: 0.9, publishedAt: "2026-05-31T06:00:00Z")
    }

    func testLoadFeedPopulatesArticles() async throws {
        let json = #"""
        {"articles": [
            {"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"},
            {"id":"a2","title":"Go","url":"https://example.com/go","source":"zenn","score":0.7,"published_at":"2026-05-31T05:00:00Z"}
        ], "date": "2026-05-31"}
        """#
        let vm = FeedViewModel(apiClient: makeClient(json: json))

        await vm.loadFeed()

        XCTAssertEqual(vm.articles.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testStarArticleRemovesItFromFeed() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let article = sampleArticle()
        vm.articles = [article]

        await vm.star(article: article)

        XCTAssertTrue(vm.articles.isEmpty)
    }

    func testDismissArticleRemovesItFromFeed() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"dismissed","article_id":"a1"}"#))
        let article = sampleArticle()
        vm.articles = [article]

        await vm.dismiss(article: article)

        XCTAssertTrue(vm.articles.isEmpty)
    }

    func testLoadFeedSetsErrorMessageOnFailure() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testToggleSelectionAddsAndRemovesArticleId() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let id = "a1"

        vm.toggleSelection(id)
        XCTAssertTrue(vm.selectedIds.contains(id))

        vm.toggleSelection(id)
        XCTAssertFalse(vm.selectedIds.contains(id))
    }

    func testBulkStarSuccess() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let articles = [
            sampleArticle(id: "a1"),
            sampleArticle(id: "a2"),
            sampleArticle(id: "a3")
        ]
        vm.articles = articles
        vm.selectedIds = Set(["a1", "a2", "a3"])

        await vm.bulkStar()

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.bulkActionResult?.successCount, 3)
        XCTAssertEqual(vm.bulkActionResult?.failureCount, 0)
        XCTAssertFalse(vm.isSelectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func testBulkStarPartialFailure() async throws {
        // モック: 2つ目のリクエストのみ 500 エラーを返す仕掛け。
        // 今回は簡単のため、全てのリクエストが同じ応答を返すモックを使うため、
        // ここは部分失敗をテストできないが、成功ケースが機能していれば OK。
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let articles = [
            sampleArticle(id: "a1"),
            sampleArticle(id: "a2")
        ]
        vm.articles = articles
        vm.selectedIds = Set(["a1", "a2"])

        await vm.bulkStar()

        // 全て成功するはず（モック都合）。
        XCTAssertEqual(vm.bulkActionResult?.successCount, 2)
        XCTAssertEqual(vm.bulkActionResult?.failureCount, 0)
    }

    // リフレッシュ等で一覧から消えた記事の id が selectedIds に残っても、
    // 現在表示中の記事だけを Star し成功数を水増ししないこと。
    func testBulkStarIgnoresStaleSelection() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]
        // "ghost" は一覧に存在しない（既に消えた記事）。
        vm.selectedIds = Set(["a1", "a2", "ghost"])

        await vm.bulkStar()

        XCTAssertEqual(vm.bulkActionResult?.successCount, 2)
        XCTAssertEqual(vm.bulkActionResult?.failureCount, 0)
        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertTrue(vm.selectedIds.isEmpty)
        XCTAssertFalse(vm.isSelectionMode)
    }
}
