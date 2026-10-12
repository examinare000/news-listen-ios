import XCTest
@testable import NewsListenApp

/// 通信のデータモデル `Podcast` から Catalog の `Episode` への変換 `toEpisode()` を検証する。
///
/// 判別の規則は status 5 × audioUrl 2 × errorMessage 2 = 20 通りの表で固定する。
/// I/O は使わない。
final class EpisodeTests: XCTestCase {

    private enum ExpectedKind: Equatable {
        case playable, generating, failed
    }

    private struct Row {
        let status: String
        let audioUrl: String
        let errorMessage: String?
        let kind: ExpectedKind

        var label: String { "status=\(status) audioUrl=\(audioUrl.isEmpty ? "(empty)" : audioUrl) errorMessage=\(errorMessage ?? "nil")" }
    }

    private let audio = "https://example.com/a.mp3"

    /// 11 field がすべて異なる値の Podcast を作る（写し間違いを区別できるようにするため）。
    private func podcast(status: String, audioUrl: String, errorMessage: String?) -> Podcast {
        Podcast(
            id: "ep-1", type: "single", articleIds: ["art-1"], difficulty: "toeic_900",
            audioUrl: audioUrl, title: "題名", japaneseIntroText: "導入文",
            durationSeconds: 321, createdAt: "2026-05-31T06:00:00Z", status: status,
            errorMessage: errorMessage, playbackPositionSeconds: 12.5,
            segments: [TranscriptSegment(speaker: "A", text: "hello", role: "fact")],
            vocabulary: [VocabularyEntry(term: "term", meaningJa: "意味", example: "example")],
            quiz: [QuizQuestion(question: "q", options: ["x", "y"])],
            sourceArticles: [PodcastSourceArticle(articleId: "art-1", title: "t", url: "https://example.com/s", source: "src")],
            sourceKind: "featured"
        )
    }

    private func expectedContent() -> EpisodeContent {
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

    /// order の表（20 行）。`completed` だけが audioUrl と errorMessage で分かれる。
    private func table() -> [Row] {
        var rows: [Row] = []
        for status in ["completed", "processing", "failed", "partial_failed", "queued"] {
            for audioUrl in ["", audio] {
                for errorMessage in [nil, "boom"] as [String?] {
                    let kind: ExpectedKind
                    switch status {
                    case "completed":
                        kind = (!audioUrl.isEmpty && errorMessage == nil) ? .playable : .failed
                    case "processing":
                        kind = .generating
                    default:
                        kind = .failed
                    }
                    rows.append(Row(status: status, audioUrl: audioUrl, errorMessage: errorMessage, kind: kind))
                }
            }
        }
        return rows
    }

    // MARK: - 判別の表

    // verifies: CI-T11
    func testTableHasTwentyDistinctRowsWithExpectedBreakdown() {
        let rows = table()
        XCTAssertEqual(rows.count, 20)
        XCTAssertEqual(Set(rows.map { $0.label }).count, 20)
        XCTAssertEqual(rows.filter { $0.kind == .playable }.count, 1)
        XCTAssertEqual(rows.filter { $0.kind == .generating }.count, 4)
        XCTAssertEqual(rows.filter { $0.kind == .failed }.count, 15)
    }

    // verifies: CI-T11
    func testToEpisodeClassifiesAllTwentyCombinations() {
        for row in table() {
            let source = podcast(status: row.status, audioUrl: row.audioUrl, errorMessage: row.errorMessage)
            let episode = source.toEpisode()

            switch (episode, row.kind) {
            case (.playable(let playable), .playable):
                XCTAssertEqual(playable.audioUrl, source.audioUrl, row.label)
                XCTAssertEqual(playable.serverPosition, 12.5, row.label)
                XCTAssertEqual(playable.content, expectedContent(), row.label)
                XCTAssertTrue(episode.isPlayable, row.label)
            case (.generating(let generating), .generating):
                XCTAssertEqual(generating.content, expectedContent(), row.label)
                XCTAssertFalse(episode.isPlayable, row.label)
            case (.failed(let failed), .failed):
                XCTAssertEqual(failed.reportedMessage, row.errorMessage, row.label)
                XCTAssertEqual(failed.content, expectedContent(), row.label)
                XCTAssertFalse(episode.isPlayable, row.label)
            default:
                XCTFail("種別が表と違う: \(row.label) → \(episode)")
            }
            XCTAssertEqual(episode.content, expectedContent(), row.label)
            XCTAssertEqual(episode.id, "ep-1", row.label)
        }
    }

    // verifies: CI-T11
    func testFailedReportedMessageKeepsDTOValueWithoutDefaultText() {
        let withMessage = podcast(status: "failed", audioUrl: "", errorMessage: "boom").toEpisode()
        let withoutMessage = podcast(status: "failed", audioUrl: "", errorMessage: nil).toEpisode()
        let contradictory = podcast(status: "completed", audioUrl: "", errorMessage: nil).toEpisode()

        guard case .failed(let a) = withMessage, case .failed(let b) = withoutMessage, case .failed(let c) = contradictory else {
            return XCTFail("3 つとも failed であるべき")
        }
        XCTAssertEqual(a.reportedMessage, "boom")
        XCTAssertNil(b.reportedMessage)
        XCTAssertNil(c.reportedMessage)
    }

    // verifies: CI-T11
    func testStatusComparisonIsExactAndAudioUrlIsNotTrimmed() {
        // 大文字違いの status は未知として failed。空白だけの audioUrl は「非空」なので playable のまま。
        if case .failed = podcast(status: "Completed", audioUrl: audio, errorMessage: nil).toEpisode() {} else {
            XCTFail("Completed（大文字）は failed であるべき")
        }
        if case .failed = podcast(status: "completed ", audioUrl: audio, errorMessage: nil).toEpisode() {} else {
            XCTFail("末尾空白付きの status は failed であるべき")
        }
        if case .playable = podcast(status: "completed", audioUrl: " ", errorMessage: nil).toEpisode() {} else {
            XCTFail("空白だけの audioUrl は trim せず非空として playable であるべき")
        }
    }

    // verifies: CI-T11
    func testToEpisodeIsPureAndRepeatable() {
        let source = podcast(status: "completed", audioUrl: audio, errorMessage: nil)
        XCTAssertEqual(source.toEpisode(), source.toEpisode())
    }

    // verifies: CI-T11
    func testToEpisodeDoesNotCompleteOrTrimTitle() {
        let source = Podcast(
            id: "p", type: "single", articleIds: [], difficulty: "d", audioUrl: audio,
            title: "  ", japaneseIntroText: "intro", durationSeconds: 1, createdAt: "c",
            status: "completed", errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        XCTAssertEqual(source.toEpisode().content.title, "  ")
        XCTAssertEqual(source.toEpisode().content.displayTitle, "intro")
    }

    // MARK: - 値の独立

    // verifies: TA-V6
    func testEpisodeContentIsIndependentOfSourceArraysAndReturnedArrays() {
        var segments = [TranscriptSegment(speaker: "A", text: "one")]
        var vocabulary = [VocabularyEntry(term: "t1", meaningJa: "m1", example: "e1")]
        var quiz = [QuizQuestion(question: "q1", options: ["x"])]
        var articles = [PodcastSourceArticle(articleId: "a1", title: "t", url: "https://example.com", source: "s")]
        let source = Podcast(
            id: "p", type: "single", articleIds: [], difficulty: "d", audioUrl: audio,
            title: "t", japaneseIntroText: "i", durationSeconds: 1, createdAt: "c",
            status: "completed", errorMessage: nil, playbackPositionSeconds: 0,
            segments: segments, vocabulary: vocabulary, quiz: quiz, sourceArticles: articles, sourceKind: nil
        )
        let snapshot = (segments, vocabulary, quiz, articles)

        let episode = source.toEpisode()

        // 変換の後で元の配列を書き換える。
        segments.append(TranscriptSegment(speaker: "B", text: "two"))
        segments[0] = TranscriptSegment(speaker: "Z", text: "changed")
        vocabulary.removeAll()
        quiz.append(QuizQuestion(question: "q2", options: []))
        articles[0] = PodcastSourceArticle(articleId: "a9", title: "changed", url: "x", source: "x")

        XCTAssertEqual(episode.content.segments, snapshot.0)
        XCTAssertEqual(episode.content.vocabulary, snapshot.1)
        XCTAssertEqual(episode.content.quiz, snapshot.2)
        XCTAssertEqual(episode.content.sourceArticles, snapshot.3)

        // content から取り出した配列を書き換えても、次の読みは変わらない。
        var taken = episode.content.segments ?? []
        taken.removeAll()
        var takenQuiz = episode.content.quiz ?? []
        takenQuiz.append(QuizQuestion(question: "q3", options: []))
        XCTAssertEqual(episode.content.segments, snapshot.0)
        XCTAssertEqual(episode.content.quiz, snapshot.2)
        XCTAssertEqual(episode, source.toEpisode())
    }
}
