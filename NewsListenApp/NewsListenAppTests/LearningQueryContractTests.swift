// verifies: ios-query-learning-04, ios-query-learning-05
import XCTest
@testable import NewsListenApp

/// 語彙の query（`savingTerms`・`registered`・`lastSaveFailed`・`book()`・`registeredTerms(episodeId:)`・`due()`）が
/// 書込み port に書かないことの契約テスト（ios-check-09）と、`LearningGateway.live` の写し（adapter）のテスト。
///
/// 応答を返す `ScriptedURLSession` を `RecordingURLSession` で包み、その `APIClient` から `LearningGateway.live` を組む
/// （`CatalogQueryContractTests` と同じ形）。`due()` の `GET /vocabulary/test-session` のサーバー側の間引きは数えない。
@MainActor
final class LearningQueryContractTests: XCTestCase {

    private var scripted: ScriptedURLSession!
    private var recording: RecordingURLSession!
    private var gateway: LearningGateway!

    override func setUp() {
        super.setUp()
        scripted = ScriptedURLSession()
        recording = RecordingURLSession(delegate: scripted)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: recording)
        gateway = LearningGateway.live(apiClient: client)
    }

    // MARK: fixtures

    private func vocabularyItemJSON(podcastId: String, term: String) -> [String: Any] {
        [
            "vocabulary_id": "v-\(term)", "podcast_id": podcastId, "term": term,
            "meaning": "意味-\(term)", "example": "example", "registered_at": "2026-11-0\(podcastId == "e1" ? 7 : 8)T00:00:00Z",
        ]
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func serveVocabulary(count: Int = 2) {
        scripted.configure(
            method: "GET", path: "/vocabulary", status: 200,
            body: json([
                "vocabulary": [vocabularyItemJSON(podcastId: "e1", term: "Apple"), vocabularyItemJSON(podcastId: "e2", term: "pear")],
                "count": count,
            ]))
    }

    private func serveTestSession() {
        scripted.configure(
            method: "GET", path: "/vocabulary/test-session", status: 200,
            body: json([
                "items": [[
                    "vocabulary_id": "w1", "term": "apple", "meaning": "りんご",
                    "example": "An apple a day.", "distractors": ["なし", "みかん", "ぶどう"],
                ]],
            ]))
    }

    private func quizResponse(correct: Int, total: Int, results: [[String: Any]]) -> Data {
        json(["correct_count": correct, "total": total, "correct_rate": Double(correct) / Double(total), "results": results])
    }

    private func sentBody(method: String, path: String) throws -> Any {
        let request = try XCTUnwrap(
            scripted.sentRequests.last { $0.httpMethod == method && $0.url?.path == path },
            "\(method) \(path) が送られていない")
        return try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
    }

    // MARK: query は書かない

    func testQueriesWriteNothingEvenAfterYield() async throws {
        serveVocabulary()
        serveTestSession()
        let book = VocabularyBook(gateway: gateway)
        let testing = VocabularyTesting(gateway: gateway)

        _ = book.savingTerms
        _ = book.registered
        _ = book.lastSaveFailed
        let view = try await book.book()
        let registered = try await book.registeredTerms(episodeId: "e1")
        let due = try await testing.due()

        XCTAssertEqual(view.count, 2, "正方向の対照: 読みは実際に値を返している")
        XCTAssertEqual(registered.terms, ["apple"])
        XCTAssertEqual(due.words.map(\.id), ["w1"])
        XCTAssertEqual(recording.writeCount, 0)
        await Task.yield()
        XCTAssertEqual(recording.writeCount, 0)
        XCTAssertFalse(scripted.sentRequests.isEmpty, "対照: 読みの GET は送られている")
    }

    // MARK: adapter の写し

    func testFetchVocabularyMapsPodcastIdAndTermAndKeepsResponseCount() async throws {
        serveVocabulary(count: 7)

        let result = try await gateway.fetchVocabulary()

        XCTAssertEqual(result.terms, [
            SavedTerm(episodeId: "e1", term: "Apple", meaning: "意味-Apple", registeredAt: "2026-11-07T00:00:00Z"),
            SavedTerm(episodeId: "e2", term: "pear", meaning: "意味-pear", registeredAt: "2026-11-08T00:00:00Z"),
        ], "意味と登録日を写す")
        XCTAssertEqual(result.count, 7, "count は応答の値（terms.count で数え直さない）")
    }

    func testSaveVocabularyPostsPodcastIdAndTerm() async throws {
        scripted.configure(
            method: "POST", path: "/vocabulary", status: 200,
            body: json(vocabularyItemJSON(podcastId: "e1", term: "Term")))

        try await gateway.saveVocabulary("e1", "Term")

        let body = try XCTUnwrap(try sentBody(method: "POST", path: "/vocabulary") as? [String: String])
        XCTAssertEqual(body, ["podcast_id": "e1", "term": "Term"])
    }

    func testFetchTestSessionMapsAllFiveFields() async throws {
        serveTestSession()

        let words = try await gateway.fetchTestSession()

        XCTAssertEqual(
            words,
            [VocabularyTestWord(
                id: "w1", term: "apple", meaning: "りんご", example: "An apple a day.",
                distractors: ["なし", "みかん", "ぶどう"])])
    }

    func testSubmitTestResultPostsResultPayload() async throws {
        scripted.configure(method: "POST", path: "/vocabulary/test-result", status: 200, body: Data(#"{"updated":2}"#.utf8))
        var test = VocabularyTest()
        test.start(items: [LearningFixture.word("w1"), LearningFixture.word("w2")])
        test.recordSelfAssessment(known: true)
        test.recordSelfAssessment(known: true)

        try await gateway.submitTestResult(test)

        let rows = try XCTUnwrap(try sentBody(method: "POST", path: "/vocabulary/test-result") as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["vocabulary_id"] as? String }, ["w1", "w2"])
        XCTAssertEqual(rows.map { $0["self_known"] as? Bool }, [true, true])
        XCTAssertTrue(rows.allSatisfy { $0["retest_correct"] is NSNull }, "既知の語の retest_correct は null")
    }

    func testSubmitQuizMapsFourItemsByNameAndComputesPositive() async throws {
        scripted.configure(
            method: "POST", path: "/podcasts/e1/quiz-answers", status: 200,
            body: quizResponse(correct: 1, total: 2, results: [
                ["question_index": 0, "selected_index": 2, "correct_index": 1, "is_correct": false],
                ["question_index": 1, "selected_index": 0, "correct_index": 0, "is_correct": true],
            ]))

        let grade = try await gateway.submitQuiz("e1", [2, 0])

        XCTAssertEqual(grade.correctCount, 1)
        XCTAssertEqual(grade.total, 2)
        XCTAssertEqual(
            grade.perQuestion,
            [
                QuizGradeItem(questionIndex: 0, selectedIndex: 2, correctIndex: 1, isCorrect: false),
                QuizGradeItem(questionIndex: 1, selectedIndex: 0, correctIndex: 0, isCorrect: true),
            ])
        XCTAssertTrue(grade.isPositive, "1/2 は閾値 0.5 以上")
        let body = try XCTUnwrap(try sentBody(method: "POST", path: "/podcasts/e1/quiz-answers") as? [String: [Int]])
        XCTAssertEqual(body, ["answers": [2, 0]])
    }

    func testSubmitQuizBelowThresholdIsNotPositive() async throws {
        scripted.configure(
            method: "POST", path: "/podcasts/e1/quiz-answers", status: 200,
            body: quizResponse(correct: 1, total: 3, results: [
                ["question_index": 0, "selected_index": 1, "correct_index": 1, "is_correct": true],
                ["question_index": 1, "selected_index": 0, "correct_index": 2, "is_correct": false],
                ["question_index": 2, "selected_index": 3, "correct_index": 0, "is_correct": false],
            ]))

        let grade = try await gateway.submitQuiz("e1", [1, 0, 3])

        XCTAssertFalse(grade.isPositive, "1/3 は閾値 0.5 未満")
    }

    func testNotFoundOnQuizAnswersBecomesUnavailableThroughQuizGrading() async throws {
        scripted.configure(method: "POST", path: "/podcasts/e1/quiz-answers", status: 404, body: Data("{}".utf8))

        let result = try await QuizGrading(gateway: gateway).submit(episodeId: "e1", answers: [0])

        XCTAssertEqual(result, .unavailable)
    }
}
