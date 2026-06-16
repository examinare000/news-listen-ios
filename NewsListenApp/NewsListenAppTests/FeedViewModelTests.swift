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
}
