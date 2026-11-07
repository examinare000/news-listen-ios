// verifies: T-VocabularyTestViewModel
import XCTest
@testable import NewsListenApp

/// `VocabularyTestViewModel` の挙動（読み込み・自己申告・再確認・送信の失敗と再試行）を固定する特性テスト。
///
/// テスト本体は下の「Given の組み立て」のヘルパだけを使い、通信も double も直接触らない。
@MainActor
final class VocabularyTestViewModelTests: XCTestCase {

    // MARK: Given の組み立て

    private var double: RecordingLearningGateway!

    override func setUp() {
        super.setUp()
        double = RecordingLearningGateway()
    }

    private func makeViewModel() -> VocabularyTestViewModel {
        VocabularyTestViewModel(vocabularyTesting: VocabularyTesting(gateway: double.gateway))
    }

    private func serveWords(_ words: [VocabularyTestWord]) {
        double.fetchTestSessionImpl = { words }
    }

    private func failLoad() {
        double.fetchTestSessionImpl = { throw ApiFailure.server(status: 500) }
    }

    private func acceptSubmit() {
        double.submitTestResultImpl = { _ in }
    }

    private func failSubmit() {
        double.submitTestResultImpl = { _ in throw ApiFailure.server(status: 500) }
    }

    /// 送信された単語テストの結果を、送信ごとに 1 配列で返す。
    private func sentOutcomes() -> [[VocabularyTestOutcome]] {
        double.submittedTests.map(\.outcomes)
    }

    // MARK: 共通の部品（通信にも double にも触れない）

    private func word(_ id: String) -> VocabularyTestWord {
        VocabularyTestWord(
            id: id, term: "term-\(id)", meaning: "意味-\(id)", example: "example \(id)",
            distractors: ["誤答A-\(id)", "誤答B-\(id)", "誤答C-\(id)"])
    }

    /// 上限つきで `feedback` が入るのを待つ。入らなければ `XCTFail` して false。
    private func waitForFeedback(_ viewModel: VocabularyTestViewModel) async -> Bool {
        for _ in 0..<2000 {
            if viewModel.machine.feedback != nil { return true }
            await Task.yield()
        }
        XCTFail("feedback が入らなかった")
        return false
    }

    /// 未知の 1 語を再確認の段階にし、再確認の選択肢（正解・誤答）を返す。
    private func enterRetest(_ viewModel: VocabularyTestViewModel) async -> (word: VocabularyTestWord, wrong: String)? {
        serveWords([word("w1")])
        acceptSubmit()
        await viewModel.load()
        await viewModel.assess(known: false)
        guard viewModel.machine.phase == .retest, let current = viewModel.machine.currentRetest else {
            XCTFail("再確認の段階に入らなかった")
            return nil
        }
        guard let wrong = viewModel.machine.currentChoices?.first(where: { $0 != current.meaning }) else {
            XCTFail("誤答の選択肢が無い")
            return nil
        }
        return (current, wrong)
    }

    // MARK: load

    func testLoadWithWordsEntersSelfAssessment() async {
        let viewModel = makeViewModel()
        serveWords([word("w1"), word("w2")])

        await viewModel.load()

        XCTAssertEqual(viewModel.machine.phase, .selfAssessment)
        XCTAssertEqual(viewModel.machine.items.map(\.id), ["w1", "w2"])
    }

    func testLoadWithNoWordsIsEmpty() async {
        let viewModel = makeViewModel()
        serveWords([])

        await viewModel.load()

        XCTAssertEqual(viewModel.machine.phase, .empty)
    }

    func testLoadFailureIsLoadingError() async {
        let viewModel = makeViewModel()
        failLoad()

        await viewModel.load()

        XCTAssertEqual(viewModel.machine.phase, .loadingError)
    }

    func testRestartAfterLoadingErrorLoadsAgain() async {
        let viewModel = makeViewModel()
        failLoad()
        await viewModel.load()
        XCTAssertEqual(viewModel.machine.phase, .loadingError, "対照: 先に失敗している")
        serveWords([word("w1")])

        await viewModel.restart()

        XCTAssertEqual(viewModel.machine.phase, .selfAssessment)
    }

    // MARK: assess

    func testAllKnownSubmitsOnceAndShowsResult() async {
        let viewModel = makeViewModel()
        serveWords([word("w1"), word("w2")])
        acceptSubmit()
        await viewModel.load()

        await viewModel.assess(known: true)
        XCTAssertTrue(sentOutcomes().isEmpty, "最後の語の前は送信しない")
        await viewModel.assess(known: true)

        XCTAssertEqual(viewModel.machine.phase, .result)
        let sent = sentOutcomes()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(
            sent.first,
            [
                VocabularyTestOutcome(wordId: "w1", selfKnown: true, retestCorrect: nil),
                VocabularyTestOutcome(wordId: "w2", selfKnown: true, retestCorrect: nil),
            ])
    }

    func testAnyUnknownEntersRetestWithoutSubmitting() async {
        let viewModel = makeViewModel()
        serveWords([word("w1"), word("w2")])
        acceptSubmit()
        await viewModel.load()

        await viewModel.assess(known: true)
        await viewModel.assess(known: false)

        XCTAssertEqual(viewModel.machine.phase, .retest)
        XCTAssertTrue(sentOutcomes().isEmpty)
    }

    // MARK: answerRetest

    func testCorrectRetestShowsFeedbackDuringWaitThenSubmitsAndShowsResult() async {
        let viewModel = makeViewModel()
        guard let (current, _) = await enterRetest(viewModel) else { return }

        let task = Task { await viewModel.answerRetest(current.meaning) }
        guard await waitForFeedback(viewModel) else { return }

        XCTAssertEqual(viewModel.machine.feedback, .correct)
        XCTAssertTrue(viewModel.machine.isAdvancing)
        XCTAssertTrue(sentOutcomes().isEmpty, "待機の間は送信しない")

        await task.value

        XCTAssertNil(viewModel.machine.feedback)
        XCTAssertEqual(viewModel.machine.phase, .result)
        XCTAssertEqual(sentOutcomes().first?.first?.retestCorrect, true)
    }

    func testWrongRetestShowsIncorrectWithCorrectAnswerAndRecordsFalse() async {
        let viewModel = makeViewModel()
        guard let (current, wrong) = await enterRetest(viewModel) else { return }

        let task = Task { await viewModel.answerRetest(wrong) }
        guard await waitForFeedback(viewModel) else { return }

        XCTAssertEqual(viewModel.machine.feedback, .incorrect(correctAnswer: current.meaning))

        await task.value

        XCTAssertEqual(viewModel.machine.phase, .result)
        XCTAssertEqual(sentOutcomes().first?.first?.retestCorrect, false)
    }

    // MARK: 待機中の cancel と二重選択

    func testCancelDuringFeedbackWaitDoesNotAdvanceOrSubmit() async {
        let viewModel = makeViewModel()
        guard let (current, _) = await enterRetest(viewModel) else { return }
        let task = Task { await viewModel.answerRetest(current.meaning) }
        guard await waitForFeedback(viewModel) else { return }

        task.cancel()
        await task.value

        XCTAssertEqual(viewModel.machine.phase, .retest)
        XCTAssertTrue(sentOutcomes().isEmpty)
    }

    func testSecondChoiceDuringFeedbackWaitIsIgnored() async {
        let viewModel = makeViewModel()
        guard let (current, wrong) = await enterRetest(viewModel) else { return }
        let task = Task { await viewModel.answerRetest(current.meaning) }
        guard await waitForFeedback(viewModel) else { return }

        await viewModel.answerRetest(wrong)
        XCTAssertEqual(viewModel.machine.feedback, .correct, "2 回目の選択は結果を変えない")

        await task.value

        XCTAssertEqual(sentOutcomes().first?.first?.retestCorrect, true)
    }

    // MARK: 送信の失敗と再試行

    func testSubmissionFailureKeepsOutcomesAndRetrySendsSameOutcomes() async {
        let viewModel = makeViewModel()
        serveWords([word("w1")])
        failSubmit()
        await viewModel.load()

        await viewModel.assess(known: true)

        XCTAssertEqual(viewModel.machine.phase, .submissionError)
        XCTAssertEqual(viewModel.machine.outcomes, [VocabularyTestOutcome(wordId: "w1", selfKnown: true, retestCorrect: nil)])

        acceptSubmit()
        await viewModel.retrySubmission()

        XCTAssertEqual(viewModel.machine.phase, .result)
        let sent = sentOutcomes()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first, sent.last, "再試行は同じ回答を送る")
    }

    // MARK: 入力の配列の後からの変更

    func testMachineItemsDoNotChangeWhenSourceArrayIsMutatedAfterStart() {
        var source = [word("w1"), word("w2")]
        let original = source
        var machine = VocabularyTest()

        machine.start(items: source)
        source.append(word("w3"))
        source[0] = word("changed")

        XCTAssertEqual(machine.items, original)
    }
}
