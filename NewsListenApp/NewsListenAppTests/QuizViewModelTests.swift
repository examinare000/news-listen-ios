// verifies: T-QuizViewModel
import XCTest
@testable import NewsListenApp

@MainActor
final class QuizViewModelTests: XCTestCase {

    private static let failureMessage = "採点結果を取得できませんでした。もう一度お試しください。"

    private var double: RecordingLearningGateway!
    private var viewModel: QuizViewModel!

    override func setUp() {
        super.setUp()
        double = RecordingLearningGateway()
        viewModel = QuizViewModel(grading: QuizGrading(gateway: double.gateway), episodeId: "e1", questionCount: 2)
    }

    private func answerAll() {
        viewModel.select(1, for: 0)
        viewModel.select(2, for: 1)
    }

    func testSubmitWithUnansweredQuestionDoesNothing() async {
        viewModel.select(1, for: 0)

        await viewModel.submit()

        XCTAssertEqual(double.writeCount, 0)
        XCTAssertNil(viewModel.grade)
        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isUnavailable)
        XCTAssertEqual(viewModel.attempt.selection(for: 0), 1, "選択は保持される")
    }

    func testSubmitShowsSubmittingThenGradeWithEpisodeIdAndAnswers() async {
        answerAll()
        let hold = Hold<QuizGrade>()
        double.submitQuizImpl = { _, _ in try await hold.wait() }

        let task = Task { await viewModel.submit() }
        await hold.waitUntilArrived()

        XCTAssertTrue(viewModel.isSubmitting)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(double.quizSubmissions.first?.episodeId, "e1")
        XCTAssertEqual(double.quizSubmissions.first?.answers, [1, 2])

        let grade = LearningFixture.grade()
        hold.complete(.success(grade))
        await task.value

        XCTAssertEqual(viewModel.grade, grade)
        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertFalse(viewModel.isUnavailable)
    }

    func testNotFoundOfQuizSetsUnavailableWithoutGradeOrError() async {
        answerAll()
        double.submitQuizImpl = { _, _ in throw ApiFailure.notFound(subject: .quiz) }

        await viewModel.submit()

        XCTAssertTrue(viewModel.isUnavailable)
        XCTAssertNil(viewModel.grade)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isSubmitting)
    }

    func testFailureSetsMessageKeepsSelectionAndResubmitClearsMessageThenGrades() async {
        answerAll()
        double.submitQuizImpl = { _, _ in throw ApiFailure.server(status: 500) }

        await viewModel.submit()

        XCTAssertEqual(viewModel.errorMessage, Self.failureMessage)
        XCTAssertNil(viewModel.grade)
        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertFalse(viewModel.isUnavailable)
        XCTAssertEqual(viewModel.attempt.answers, [1, 2], "選択は保持される")

        let hold = Hold<QuizGrade>()
        double.submitQuizImpl = { _, _ in try await hold.wait() }
        let task = Task { await viewModel.submit() }
        await hold.waitUntilArrived()
        XCTAssertNil(viewModel.errorMessage, "再送信の開始でエラー文言が消える")
        XCTAssertTrue(viewModel.isSubmitting)

        let grade = LearningFixture.grade()
        hold.complete(.success(grade))
        await task.value

        XCTAssertEqual(viewModel.grade, grade)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isSubmitting)
        XCTAssertEqual(double.writeCount, 2)
    }
}
