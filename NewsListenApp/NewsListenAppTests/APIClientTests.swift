import XCTest
@testable import NewsListenApp

// APIClient は @MainActor 分離のため、テストクラスも @MainActor にして
// init / メソッド呼び出しの分離コンテキストを揃える。
@MainActor
final class APIClientTests: XCTestCase {

    func testFetchFeedDecodesResponse() async throws {
        let mockJSON = #"""
        {"articles": [{"id":"a1","title":"Test","url":"https://example.com","source":"hackernews","score":0.8,"published_at":"2026-05-31T06:00:00Z"}], "date": "2026-05-31"}
        """#.data(using: .utf8)!

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "test-key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )

        let feed = try await client.fetchFeed()
        XCTAssertEqual(feed.articles.count, 1)
        XCTAssertEqual(feed.articles[0].id, "a1")
    }

    func testStarArticleCallsCorrectEndpoint() async throws {
        let mockJSON = #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "test-key",
            session: mockSession
        )

        try await client.starArticle(id: "a1")

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/articles/a1/star")
        XCTAssertEqual(mockSession.lastRequest?.httpMethod, "POST")
    }

    func testAPIKeyIsIncludedInHeader() async throws {
        let mockJSON = #"{"articles":[],"date":"2026-05-31"}"#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)

        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "secret-key",
            session: mockSession
        )

        _ = try await client.fetchFeed()
        XCTAssertEqual(mockSession.lastRequest?.value(forHTTPHeaderField: "X-API-Key"), "secret-key")
    }

    func testHTTPErrorThrowsAPIError() async throws {
        let mockSession = MockURLSession(data: Data(), statusCode: 500)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        do {
            _ = try await client.fetchFeed()
            XCTFail("HTTP 500 でエラーが送出されるべき")
        } catch let APIError.httpError(statusCode) {
            XCTAssertEqual(statusCode, 500)
        }
    }

    func testFetchFeaturedSitesDecodesResponse() async throws {
        let mockJSON = #"""
        {"sites": [
            {"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":"https://www.theverge.com/favicon.ico","description":"テクノロジー全般"},
            {"id":"techcrunch","name":"TechCrunch","url":"https://techcrunch.com/feed/","thumbnail_url":null,"description":null}
        ]}
        """#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let response = try await client.fetchFeaturedSites()

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/settings/featured-sources")
        XCTAssertEqual(response.sites.count, 2)
        XCTAssertEqual(response.sites[0].id, "the-verge")
        XCTAssertEqual(response.sites[0].thumbnailURL, "https://www.theverge.com/favicon.ico")
        XCTAssertNil(response.sites[1].thumbnailURL)
    }

    func testFetchOnboardingStatusDecodesSnakeCase() async throws {
        let mockJSON = #"{"onboarding_completed": false}"#.data(using: .utf8)!
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )

        let status = try await client.fetchOnboardingStatus()
        XCTAssertFalse(status.onboardingCompleted)
    }

    func testCompleteOnboardingCallsCorrectEndpoint() async throws {
        let mockJSON = #"{"onboarding_completed": true}"#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let status = try await client.completeOnboarding()

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/settings/onboarding/complete")
        XCTAssertEqual(mockSession.lastRequest?.httpMethod, "POST")
        XCTAssertTrue(status.onboardingCompleted)
    }
}

// MARK: - MockURLSession

// 複数のテストファイル（Feed / Podcast / Settings の ViewModel テスト）から共用する。
final class MockURLSession: URLSessionProtocol {
    let data: Data
    let statusCode: Int
    var lastRequest: URLRequest?

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
