// verifies: ios-query-learning-05, ios-cmd-learning-03, ios-test-032, ios-test-014
import XCTest
@testable import NewsListenApp

@MainActor
final class VocabularyTestingTests: XCTestCase {

    private var double: RecordingLearningGateway!
    private var testing: VocabularyTesting!

    override func setUp() {
        super.setUp()
        double = RecordingLearningGateway()
        testing = VocabularyTesting(gateway: double.gateway)
    }

    private func words(_ count: Int) -> [VocabularyTestWord] {
        (0..<count).map { LearningFixture.word("w\($0)") }
    }

    private func answeredTest(_ words: [VocabularyTestWord]) -> VocabularyTest {
        var test = VocabularyTest()
        test.start(items: words)
        for _ in words { test.recordSelfAssessment(known: true) }
        return test
    }

    func testDueReturnsAtMostTenWordsFromTheFrontWithMatchingCount() async throws {
        let source = words(12)
        double.fetchTestSessionImpl = { source }

        let due = try await testing.due()

        XCTAssertEqual(due.words.map(\.id), source.prefix(10).map(\.id), "先頭から 10 語")
        XCTAssertEqual(due.dueCount, 10)
        XCTAssertEqual(double.writeCount, 0)
    }

    func testDueWithFewWordsReturnsAllOfThem() async throws {
        let source = words(3)
        double.fetchTestSessionImpl = { source }

        let due = try await testing.due()

        XCTAssertEqual(due.words, source)
        XCTAssertEqual(due.dueCount, 3)
    }

    func testDueWithNoWordsReturnsEmptyAndZero() async throws {
        double.fetchTestSessionImpl = { [] }

        let due = try await testing.due()

        XCTAssertTrue(due.words.isEmpty)
        XCTAssertEqual(due.dueCount, 0)
        XCTAssertEqual(double.writeCount, 0)
    }

    func testDueFailureIsRethrown() async {
        double.fetchTestSessionImpl = { throw ApiFailure.server(status: 500) }

        do {
            _ = try await testing.due()
            XCTFail("失敗はそのまま投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    func testSubmitPassesTheGivenTestToGatewayOnce() async throws {
        let test = answeredTest(words(2))

        try await testing.submit(test)

        XCTAssertEqual(double.submittedTests.count, 1)
        XCTAssertEqual(double.submittedTests.first?.outcomes, test.outcomes)
        XCTAssertEqual(double.submittedTests.first?.outcomes.count, 2, "対照: 回答済みの 2 語が渡る")
    }

    func testSubmitFailureIsRethrownAndCallersAnswersAreKept() async {
        let test = answeredTest(words(2))
        let before = test.outcomes
        double.submitTestResultImpl = { _ in throw ApiFailure.server(status: 500) }

        do {
            try await testing.submit(test)
            XCTFail("送信の失敗はそのまま投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }

        XCTAssertEqual(test.outcomes, before, "呼出側の回答は残り、再試行できる")
        XCTAssertEqual(test.phase, .readyToSubmit)
    }
}
