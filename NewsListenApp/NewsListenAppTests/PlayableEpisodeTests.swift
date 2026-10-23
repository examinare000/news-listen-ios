import XCTest
@testable import NewsListenApp

/// `PlayableEpisode` の通常生成（DTO を使わない直接生成）の契約を検証する。
///
/// 音声 URL が空の値は作れない。それ以外の入力には新しい制約を加えない。
/// I/O は使わない。
final class PlayableEpisodeTests: XCTestCase {

    private func content() -> EpisodeContent {
        EpisodeContent(
            id: "ep-1", title: "題名", japaneseIntroText: "導入文", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 321,
            segments: [TranscriptSegment(speaker: "A", text: "hello", role: "fact")],
            vocabulary: [VocabularyEntry(term: "term", meaningJa: "意味", example: "example")],
            quiz: [QuizQuestion(question: "q", options: ["x", "y"])],
            sourceArticles: [PodcastSourceArticle(articleId: "art-1", title: "t", url: "https://example.com/s", source: "src")],
            sourceKind: "featured"
        )
    }

    // verifies: ios-rule-catalog-01
    func testEmptyAudioUrlYieldsNil() {
        XCTAssertNil(PlayableEpisode(content: content(), audioUrl: "", serverPosition: 12.5))
    }

    // verifies: ios-rule-catalog-01
    func testNonEmptyAudioUrlKeepsContentAudioUrlAndPosition() throws {
        let source = content()

        let episode = try XCTUnwrap(PlayableEpisode(content: source, audioUrl: "https://example.com/a.mp3", serverPosition: 12.5))

        XCTAssertEqual(episode.content, source)
        XCTAssertEqual(episode.audioUrl, "https://example.com/a.mp3")
        XCTAssertEqual(episode.serverPosition, 12.5)
    }

    // verifies: ios-rule-catalog-01
    func testWhitespaceOnlyAndNonUrlAudioUrlAndNegativePositionAreAccepted() throws {
        let whitespace = try XCTUnwrap(PlayableEpisode(content: content(), audioUrl: " ", serverPosition: 0))
        XCTAssertEqual(whitespace.audioUrl, " ", "trim しない")

        let nonUrl = try XCTUnwrap(PlayableEpisode(content: content(), audioUrl: "not a url", serverPosition: 0))
        XCTAssertEqual(nonUrl.audioUrl, "not a url")

        let negative = try XCTUnwrap(PlayableEpisode(content: content(), audioUrl: "https://example.com/a.mp3", serverPosition: -1))
        XCTAssertEqual(negative.serverPosition, -1)
    }
}
