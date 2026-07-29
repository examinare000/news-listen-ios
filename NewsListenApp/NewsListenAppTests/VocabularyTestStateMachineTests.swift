import XCTest
@testable import NewsListenApp

final class VocabularyTestStateMachineTests: XCTestCase {
    func testUnknownWordsAloneEnterRetestAndChoicesStayFixed() throws {
        var machine = VocabularyTestStateMachine()
        machine.start(items: sampleItems)

        XCTAssertEqual(machine.phase, .selfAssessment)
        XCTAssertEqual(machine.progressText, "1/2")
        XCTAssertEqual(machine.recordSelfAssessment(known: true), .advance)
        XCTAssertEqual(machine.recordSelfAssessment(known: false), .beginRetest)
        XCTAssertEqual(machine.phase, .retest)
        XCTAssertEqual(machine.retestItems.map(\.vocabularyId), ["word-2"])

        let firstChoices = try XCTUnwrap(machine.currentChoices)
        let secondChoices = try XCTUnwrap(machine.currentChoices)
        XCTAssertEqual(firstChoices, secondChoices)
        XCTAssertEqual(Set(firstChoices), Set(["意味2", "誤答C", "誤答D", "誤答E"]))
    }

    func testAllKnownSkipsRetestAndBuildsNullableResultPayload() {
        var machine = VocabularyTestStateMachine()
        machine.start(items: sampleItems)

        _ = machine.recordSelfAssessment(known: true)
        XCTAssertEqual(machine.recordSelfAssessment(known: true), .submit)
        XCTAssertEqual(machine.phase, .readyToSubmit)
        XCTAssertEqual(
            machine.resultPayload,
            [
                VocabularyTestResultItem(vocabularyId: "word-1", selfKnown: true, retestCorrect: nil),
                VocabularyTestResultItem(vocabularyId: "word-2", selfKnown: true, retestCorrect: nil),
            ]
        )
    }

    func testRetestRejectsDoubleAnswerUntilFeedbackFinishes() {
        var machine = VocabularyTestStateMachine()
        machine.start(items: [sampleItems[0]])
        _ = machine.recordSelfAssessment(known: false)

        XCTAssertTrue(machine.recordRetestChoice("誤答A"))
        XCTAssertFalse(machine.recordRetestChoice("意味1"))
        XCTAssertTrue(machine.isAdvancing)
        XCTAssertEqual(machine.revealedCorrectAnswer, "意味1")
        XCTAssertEqual(machine.retestResults["word-1"], false)

        XCTAssertEqual(machine.finishRetestFeedback(), .submit)
        XCTAssertEqual(machine.phase, .readyToSubmit)
    }

    func testSummaryMatchesWebResultDenominators() {
        var machine = VocabularyTestStateMachine()
        machine.start(items: sampleItems)
        _ = machine.recordSelfAssessment(known: true)
        _ = machine.recordSelfAssessment(known: false)
        XCTAssertTrue(machine.recordRetestChoice("意味2"))
        _ = machine.finishRetestFeedback()

        XCTAssertEqual(
            machine.summary,
            VocabularyTestSummary(knownCount: 1, retestCount: 1, retestCorrectCount: 1)
        )
    }

    private var sampleItems: [VocabularyTestItem] {
        [
            VocabularyTestItem(
                vocabularyId: "word-1",
                term: "term1",
                meaning: "意味1",
                example: "Example one.",
                distractors: ["誤答A", "誤答B", "誤答C"]
            ),
            VocabularyTestItem(
                vocabularyId: "word-2",
                term: "term2",
                meaning: "意味2",
                example: "Example two.",
                distractors: ["誤答C", "誤答D", "誤答E"]
            ),
        ]
    }
}
