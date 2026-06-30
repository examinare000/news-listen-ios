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

    func testFetchPodcastCallsCorrectEndpoint() async throws {
        let mockJSON = #"""
        {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"}
        """#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let podcast = try await client.fetchPodcast(id: "p1")

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/podcasts/p1")
        XCTAssertEqual(mockSession.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(podcast.id, "p1")
    }

    func testDownloadAudioFetchesDataFromURL() async throws {
        let audioData = "mock audio content".data(using: .utf8)!
        let mockSession = MockURLSession(data: audioData, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let data = try await client.downloadAudio(from: URL(string: "https://storage.example.com/audio.mp3")!)

        XCTAssertEqual(data, audioData)
    }

    func testDownloadAudioDoesNotIncludeAPIKeyHeader() async throws {
        let audioData = "mock audio".data(using: .utf8)!
        let mockSession = MockURLSession(data: audioData, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "secret-key",
            session: mockSession
        )

        _ = try await client.downloadAudio(from: URL(string: "https://storage.example.com/audio.mp3")!)

        // downloadAudio は X-API-Key を付けない
        XCTAssertNil(mockSession.lastRequest?.value(forHTTPHeaderField: "X-API-Key"))
        // Authorization も付けない
        XCTAssertNil(mockSession.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testDownloadAudioThrowsOnHTTPError() async throws {
        let mockSession = MockURLSession(data: Data(), statusCode: 500)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        do {
            _ = try await client.downloadAudio(from: URL(string: "https://storage.example.com/audio.mp3")!)
            XCTFail("HTTP 500 でエラーが送出されるべき")
        } catch let APIError.httpError(statusCode) {
            XCTAssertEqual(statusCode, 500)
        }
    }

    // issue #82: 429 は rateLimited(retryAfter:) として Retry-After を添えて送出する。
    func testStar429ThrowsRateLimitedWithRetryAfter() async {
        let mockSession = MockURLSession(data: Data(), statusCode: 429, headerFields: ["Retry-After": "43200"])
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )
        do {
            try await client.starArticle(id: "a1")
            XCTFail("429 で rateLimited が送出されるべき")
        } catch APIError.rateLimited(let retryAfter) {
            XCTAssertEqual(retryAfter, 43200)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStar429WithoutHeaderHasNilRetryAfter() async {
        let mockSession = MockURLSession(data: Data(), statusCode: 429)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mockSession)
        do {
            try await client.starArticle(id: "a1")
            XCTFail("429 で rateLimited が送出されるべき")
        } catch APIError.rateLimited(let retryAfter) {
            XCTAssertNil(retryAfter)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Preferences (Settings sync)

    func testFetchPreferencesDecodesResponse() async throws {
        let mockJSON = #"""
        {"default_difficulty":"toeic_900","default_playback_speed":1.5}
        """#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let preferences = try await client.fetchPreferences()

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/settings/preferences")
        XCTAssertEqual(mockSession.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(preferences.defaultDifficulty, "toeic_900")
        XCTAssertEqual(preferences.defaultPlaybackSpeed, 1.5)
    }

    func testUpdatePreferencesCallsCorrectEndpoint() async throws {
        let mockJSON = #"""
        {"default_difficulty":"toeic_600","default_playback_speed":1.0}
        """#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let preferences = try await client.updatePreferences(defaultDifficulty: "toeic_600", defaultPlaybackSpeed: nil)

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/settings/preferences")
        XCTAssertEqual(mockSession.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(preferences.defaultDifficulty, "toeic_600")
    }

    func testUpdatePreferencesIncludesAuthorizationHeader() async throws {
        let mockJSON = #"""
        {"default_difficulty":"ielts_55","default_playback_speed":1.25}
        """#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "secret-key",
            sessionToken: "test-token",
            session: mockSession
        )

        _ = try await client.updatePreferences(defaultDifficulty: nil, defaultPlaybackSpeed: 1.25)

        XCTAssertEqual(mockSession.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(mockSession.lastRequest?.value(forHTTPHeaderField: "X-API-Key"), "secret-key")
    }

    // MARK: - Podcast position sync

    func testUpdatePlaybackPositionCallsCorrectEndpoint() async throws {
        let mockJSON = #"""
        {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed","playback_position_seconds":45.5}
        """#.data(using: .utf8)!
        let mockSession = MockURLSession(data: mockJSON, statusCode: 200)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: mockSession
        )

        let podcast = try await client.updatePlaybackPosition(podcastId: "p1", positionSeconds: 45.5)

        XCTAssertEqual(mockSession.lastRequest?.url?.path, "/podcasts/p1/position")
        XCTAssertEqual(mockSession.lastRequest?.httpMethod, "PATCH")
        XCTAssertEqual(podcast.id, "p1")
        XCTAssertEqual(podcast.playbackPositionSeconds, 45.5)
    }

    func testPodcastDecodesPlaybackPositionSeconds() async throws {
        let mockJSON = #"""
        {"id":"p2","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p2.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed","playback_position_seconds":120.0}
        """#.data(using: .utf8)!
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )

        let podcast = try await client.fetchPodcast(id: "p2")

        XCTAssertEqual(podcast.playbackPositionSeconds, 120.0)
    }

    func testPodcastDecodesPlaybackPositionSecondsDefaultsToZero() async throws {
        let mockJSON = #"""
        {"id":"p3","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p3.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"}
        """#.data(using: .utf8)!
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: mockJSON, statusCode: 200)
        )

        let podcast = try await client.fetchPodcast(id: "p3")

        XCTAssertEqual(podcast.playbackPositionSeconds, 0.0)
    }
}

// MARK: - MockURLSession

// 複数のテストファイル（Feed / Podcast / Settings の ViewModel テスト）から共用する。
final class MockURLSession: URLSessionProtocol {
    let data: Data
    let statusCode: Int
    /// レスポンスヘッダ（issue #82: Retry-After 検証用。既定 nil）。
    let headerFields: [String: String]?
    var lastRequest: URLRequest?

    init(data: Data, statusCode: Int, headerFields: [String: String]? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.headerFields = headerFields
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: headerFields
        )!
        return (data, response)
    }
}
