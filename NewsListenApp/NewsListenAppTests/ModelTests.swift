import XCTest
@testable import NewsListenApp

final class ModelTests: XCTestCase {

    func testArticleDecodesFromJSON() throws {
        let json = """
        {
            "id": "abc123",
            "title": "Rust is amazing",
            "url": "https://example.com/rust",
            "source": "hackernews",
            "score": 0.9,
            "published_at": "2026-05-31T06:00:00Z"
        }
        """.data(using: .utf8)!

        let article = try JSONDecoder().decode(Article.self, from: json)
        XCTAssertEqual(article.id, "abc123")
        XCTAssertEqual(article.title, "Rust is amazing")
        XCTAssertEqual(article.score, 0.9)
    }

    func testPodcastDecodesFromJSON() throws {
        let json = """
        {
            "id": "pod1",
            "type": "single",
            "article_ids": ["abc123"],
            "difficulty": "toeic_900",
            "audio_url": "https://storage.example.com/pod1.mp3",
            "japanese_intro_text": "今日のニュースは...",
            "duration_seconds": 300,
            "created_at": "2026-05-31T06:00:00Z"
        }
        """.data(using: .utf8)!

        let podcast = try JSONDecoder().decode(Podcast.self, from: json)
        XCTAssertEqual(podcast.id, "pod1")
        XCTAssertEqual(podcast.durationSeconds, 300)
        XCTAssertEqual(podcast.difficulty, "toeic_900")
    }

    func testPodcastFormattedDuration() throws {
        let podcast = Podcast(
            id: "pod1",
            type: "single",
            articleIds: ["abc123"],
            difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/pod1.mp3",
            japaneseIntroText: "今日のニュースは...",
            durationSeconds: 305,
            createdAt: "2026-05-31T06:00:00Z"
        )
        XCTAssertEqual(podcast.formattedDuration, "5:05")
    }

    func testFeedResponseDecodes() throws {
        let json = """
        {
            "articles": [],
            "date": "2026-05-31"
        }
        """.data(using: .utf8)!

        let feed = try JSONDecoder().decode(FeedResponse.self, from: json)
        XCTAssertEqual(feed.date, "2026-05-31")
        XCTAssertTrue(feed.articles.isEmpty)
    }

    func testRssSourcesResponseDecodes() throws {
        let json = """
        {
            "sources": [
                {"name": "HackerNews", "url": "https://hnrss.org/frontpage"}
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RssSourcesResponse.self, from: json)
        XCTAssertEqual(response.sources.count, 1)
        XCTAssertEqual(response.sources[0].name, "HackerNews")
        // id は url から導出される
        XCTAssertEqual(response.sources[0].id, "https://hnrss.org/frontpage")
    }
}
