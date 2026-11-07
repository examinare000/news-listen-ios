// verifies: ios-cmd-learning-04, ios-rule-learning-08, ios-test-011
import XCTest
@testable import NewsListenApp

@MainActor
final class QuizGradingTests: XCTestCase {

    private var double: RecordingLearningGateway!
    private var grading: QuizGrading!

    override func setUp() {
        super.setUp()
        double = RecordingLearningGateway()
        grading = QuizGrading(gateway: double.gateway)
    }

    func testSubmitPassesArgumentsOnceAndReturnsGradeUnchanged() async throws {
        let grade = LearningFixture.grade()
        double.submitQuizImpl = { _, _ in grade }

        let result = try await grading.submit(episodeId: "e1", answers: [0, 2])

        XCTAssertEqual(result, .graded(grade))
        XCTAssertEqual(double.quizSubmissions.count, 1)
        XCTAssertEqual(double.quizSubmissions.first?.episodeId, "e1")
        XCTAssertEqual(double.quizSubmissions.first?.answers, [0, 2])
    }

    func testNotFoundOfQuizSubjectIsUnavailable() async throws {
        double.submitQuizImpl = { _, _ in throw ApiFailure.notFound(subject: .quiz) }

        let result = try await grading.submit(episodeId: "e1", answers: [0])

        XCTAssertEqual(result, .unavailable)
    }

    func testNotFoundOfOtherSubjectIsRethrown() async {
        double.submitQuizImpl = { _, _ in throw ApiFailure.notFound(subject: .streak) }

        do {
            _ = try await grading.submit(episodeId: "e1", answers: [0])
            XCTFail("quiz 以外の主語の 404 は機能なしにしない")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .notFound(subject: .streak))
        }
    }

    func testOtherFailureIsRethrown() async {
        double.submitQuizImpl = { _, _ in throw ApiFailure.server(status: 500) }

        do {
            _ = try await grading.submit(episodeId: "e1", answers: [0])
            XCTFail("ほかの失敗はそのまま投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }
}
