import XCTest
@testable import NewsListenApp

final class LearningDomainTests: XCTestCase {
    // MARK: - ストリーク

    // verifies: ios-rule-learning-01, ios-test-043
    func testIosTest043_isShownRequiresLastDayAndPositiveDays() {
        XCTAssertTrue(status(3, "2026-07-29").isShown)
        XCTAssertTrue(status(1, "2026-07-29").isShown)
        XCTAssertFalse(status(0, "2026-07-29").isShown)
        XCTAssertFalse(status(3, nil).isShown)
        XCTAssertFalse(status(0, nil).isShown)
    }

    // verifies: ios-rule-learning-02, ios-test-106
    func testIosTest106_didIncreaseIsTrueOnlyWhenPreviousExistsAndDaysGrew() {
        XCTAssertFalse(ListeningStreakStatus.didIncrease(from: nil, to: status(3, "d")))
        XCTAssertFalse(ListeningStreakStatus.didIncrease(from: status(3, "d"), to: status(3, "d")))
        XCTAssertTrue(ListeningStreakStatus.didIncrease(from: status(3, "d"), to: status(4, "d")))
        XCTAssertTrue(ListeningStreakStatus.didIncrease(from: status(3, "d"), to: status(5, "d")))
        XCTAssertFalse(ListeningStreakStatus.didIncrease(from: status(3, "d"), to: status(2, "d")))
        XCTAssertTrue(ListeningStreakStatus.didIncrease(from: status(0, "d"), to: status(1, "d")))
    }

    // MARK: - 週の進み

    // verifies: ios-rule-learning-03, ios-test-044
    func testIosTest044_fractionIsClampedToUnitRangeAndZeroForNonPositiveGoal() {
        XCTAssertEqual(fraction(3, 5), 0.6, accuracy: 0.000001)
        XCTAssertEqual(fraction(5, 5), 1, accuracy: 0.000001)
        XCTAssertEqual(fraction(7, 5), 1, accuracy: 0.000001)
        XCTAssertEqual(fraction(0, 5), 0, accuracy: 0.000001)
        XCTAssertEqual(fraction(-2, 5), 0, accuracy: 0.000001)
        XCTAssertEqual(fraction(3, 0), 0, accuracy: 0.000001)
        XCTAssertEqual(fraction(3, -1), 0, accuracy: 0.000001)
    }

    // MARK: - 実績

    // verifies: ios-rule-learning-04, ios-test-045
    func testIosTest045_catalogKeepsSevenIdsInOrder() {
        XCTAssertEqual(
            AchievementCatalog.all.map(\.id),
            [
                "first_episode_completed",
                "first_quiz_correct",
                "streak_7",
                "streak_30",
                "streak_100",
                "completed_10",
                "completed_50",
            ]
        )
    }

    // verifies: ios-rule-learning-04, ios-test-045
    func testIosTest045_unseenDropsSeenIdsAndKeepsOrder() {
        XCTAssertEqual(AchievementCatalog.unseen(threeAchievements, seenIds: ["b"]).map(\.id), ["a", "c"])
        XCTAssertEqual(AchievementCatalog.unseen(threeAchievements, seenIds: []), threeAchievements)
        XCTAssertTrue(AchievementCatalog.unseen(threeAchievements, seenIds: ["a", "b", "c"]).isEmpty)
    }

    // MARK: - 単語テスト

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_startKeepsFirstTenWordsAndResetsPreviousState() {
        var twelve = VocabularyTest()
        twelve.start(items: (0..<12).map { word("w\($0)") })
        XCTAssertEqual(twelve.items.map(\.id), (0..<10).map { "w\($0)" })
        XCTAssertEqual(twelve.phase, .selfAssessment)

        var ten = VocabularyTest()
        ten.start(items: (0..<10).map { word("w\($0)") })
        XCTAssertEqual(ten.items.count, 10)

        var empty = VocabularyTest()
        empty.start(items: [])
        XCTAssertEqual(empty.phase, .empty)
        XCTAssertTrue(empty.items.isEmpty)

        var restarted = VocabularyTest()
        let two = [word("a"), word("b")]
        restarted.start(items: two)
        _ = restarted.recordSelfAssessment(known: false)
        _ = restarted.recordSelfAssessment(known: false)
        XCTAssertEqual(restarted.phase, .retest)
        restarted.start(items: two)
        XCTAssertEqual(restarted.phase, .selfAssessment)
        XCTAssertTrue(restarted.assessments.isEmpty)
        XCTAssertEqual(restarted.assessmentIndex, 0)
        XCTAssertTrue(restarted.retestItems.isEmpty)
        XCTAssertTrue(restarted.choicesByID.isEmpty)
        XCTAssertEqual(restarted.items.map(\.id), ["a", "b"])
    }

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_selfAssessmentRetestsOnlyUnknownWords() {
        var test = VocabularyTest()
        test.start(items: [word("a"), word("b"), word("c")])
        XCTAssertEqual(test.currentAssessment?.id, "a")
        XCTAssertEqual(test.recordSelfAssessment(known: true), .advance)
        XCTAssertEqual(test.currentAssessment?.id, "b")
        XCTAssertEqual(test.recordSelfAssessment(known: false), .advance)
        XCTAssertEqual(test.currentAssessment?.id, "c")
        XCTAssertEqual(test.recordSelfAssessment(known: true), .beginRetest)
        XCTAssertEqual(test.phase, .retest)
        XCTAssertEqual(test.retestItems.map(\.id), ["b"])
        XCTAssertNil(test.currentAssessment)

        let before = test.assessments
        XCTAssertEqual(test.recordSelfAssessment(known: true), .ignored)
        XCTAssertEqual(test.assessments, before)

        var allKnownDuplicate = VocabularyTest()
        allKnownDuplicate.start(items: [word("a"), word("a")])
        XCTAssertEqual(allKnownDuplicate.recordSelfAssessment(known: true), .advance)
        XCTAssertEqual(allKnownDuplicate.recordSelfAssessment(known: true), .submit)
        XCTAssertEqual(allKnownDuplicate.phase, .readyToSubmit)

        var lastKnownDuplicate = VocabularyTest()
        lastKnownDuplicate.start(items: [word("a"), word("a")])
        _ = lastKnownDuplicate.recordSelfAssessment(known: false)
        XCTAssertEqual(lastKnownDuplicate.recordSelfAssessment(known: true), .submit)
        XCTAssertTrue(lastKnownDuplicate.retestItems.isEmpty)
    }

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_choicesAreMeaningPlusFirstThreeDistractorsWithoutDuplicates() {
        var test = VocabularyTest()
        test.start(items: [word("a", distractors: ["A", "M", "B", "C"], meaning: "M")])
        XCTAssertNil(test.currentChoices)
        _ = test.recordSelfAssessment(known: false)
        guard let choices = test.currentChoices else {
            XCTFail("再確認に入った直後は選択肢がある")
            return
        }
        XCTAssertEqual(Set(choices), ["A", "B", "M"])
        XCTAssertEqual(choices.count, 3)
        XCTAssertFalse(choices.contains("C"))
        XCTAssertEqual(test.currentChoices, choices)

        _ = test.recordRetestChoice("A")
        XCTAssertEqual(test.currentChoices, choices)

        _ = test.finishRetestFeedback()
        XCTAssertEqual(test.phase, .readyToSubmit)
        XCTAssertEqual(test.retestItems.count, 1)
        XCTAssertNil(test.currentChoices)

        var firstChoices = Set<String>()
        for _ in 0..<30 {
            var test = VocabularyTest()
            test.start(items: [word("a", distractors: ["A", "B", "C"], meaning: "M")])
            _ = test.recordSelfAssessment(known: false)
            firstChoices.insert(test.currentChoices?.first ?? "")
        }
        XCTAssertGreaterThan(firstChoices.count, 1, "正解を先頭に固定しない")
    }

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_retestFeedbackRecordsAnswersAndRejectsInvalidOperations() {
        var test = VocabularyTest()
        test.start(items: [word("a"), word("b")])
        _ = test.recordSelfAssessment(known: false)
        _ = test.recordSelfAssessment(known: false)

        XCTAssertEqual(test.finishRetestFeedback(), .ignored)
        XCTAssertEqual(test.retestIndex, 0)
        XCTAssertEqual(test.phase, .retest)
        XCTAssertNil(test.feedback)
        XCTAssertFalse(test.isAdvancing)

        XCTAssertEqual(test.currentRetest?.id, "a")
        XCTAssertEqual(test.currentChoices?.contains("Ma"), true)
        XCTAssertTrue(test.recordRetestChoice("x"))
        XCTAssertEqual(test.revealedCorrectAnswer, "Ma")
        XCTAssertTrue(test.isAdvancing)
        XCTAssertFalse(test.recordRetestChoice("Ma"))
        XCTAssertEqual(test.retestResults["a"], false)

        XCTAssertEqual(test.finishRetestFeedback(), .advance)
        XCTAssertNil(test.feedback)
        XCTAssertFalse(test.isAdvancing)
        XCTAssertEqual(test.retestIndex, 1)
        XCTAssertEqual(test.currentRetest?.id, "b")
        XCTAssertEqual(test.currentChoices?.contains("Mb"), true)

        XCTAssertTrue(test.recordRetestChoice("Mb"))
        XCTAssertEqual(test.feedback, .correct)
        XCTAssertNil(test.revealedCorrectAnswer)
        XCTAssertEqual(test.retestResults["b"], true)

        XCTAssertEqual(test.finishRetestFeedback(), .submit)
        XCTAssertEqual(test.phase, .readyToSubmit)
        XCTAssertNil(test.currentRetest)
        XCTAssertFalse(test.recordRetestChoice("x"))

        var failed = VocabularyTest()
        failed.start(items: [word("a")])
        _ = failed.recordSelfAssessment(known: false)
        _ = failed.recordRetestChoice("x")
        failed.markLoadingFailed()
        XCTAssertEqual(failed.phase, .loadingError)
        XCTAssertTrue(failed.isAdvancing)
        XCTAssertNotNil(failed.feedback)
        XCTAssertEqual(failed.revealedCorrectAnswer, "Ma")
        XCTAssertEqual(failed.finishRetestFeedback(), .ignored)
        XCTAssertEqual(failed.phase, .loadingError)
    }

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_outcomesAndSummaryCountKnownRetestAndCorrect() {
        var test = VocabularyTest()
        test.start(items: [word("w1"), word("w2"), word("w3")])
        XCTAssertEqual(
            test.outcomes,
            [outcome("w1", false, false), outcome("w2", false, false), outcome("w3", false, false)]
        )

        _ = test.recordSelfAssessment(known: true)
        _ = test.recordSelfAssessment(known: false)
        _ = test.recordSelfAssessment(known: false)
        XCTAssertEqual(test.retestItems.map(\.id), ["w2", "w3"])
        XCTAssertEqual(
            test.outcomes,
            [outcome("w1", true, nil), outcome("w2", false, false), outcome("w3", false, false)]
        )

        _ = test.recordRetestChoice("Mw2")
        _ = test.finishRetestFeedback()
        _ = test.recordRetestChoice("x")
        _ = test.finishRetestFeedback()
        XCTAssertEqual(
            test.outcomes,
            [outcome("w1", true, nil), outcome("w2", false, true), outcome("w3", false, false)]
        )
        XCTAssertEqual(test.summary, VocabularyTestSummary(knownCount: 1, retestCount: 2, retestCorrectCount: 1))

        var allKnown = VocabularyTest()
        allKnown.start(items: [word("a"), word("b")])
        _ = allKnown.recordSelfAssessment(known: true)
        XCTAssertEqual(allKnown.recordSelfAssessment(known: true), .submit)
        XCTAssertEqual(allKnown.phase, .readyToSubmit)
        XCTAssertTrue(allKnown.outcomes.allSatisfy { $0.retestCorrect == nil })
    }

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_submissionAndLoadingTransitionsFollowTheirGuards() {
        var test = VocabularyTest()
        test.start(items: [word("a")])
        _ = test.recordSelfAssessment(known: true)
        let outcomes = test.outcomes
        test.markSubmitting()
        XCTAssertEqual(test.phase, .submitting)
        test.markSubmissionFailed()
        XCTAssertEqual(test.phase, .submissionError)
        test.markSubmitting()
        XCTAssertEqual(test.phase, .submitting)
        test.markSubmitted()
        XCTAssertEqual(test.phase, .result)
        XCTAssertEqual(test.outcomes, outcomes)

        var outsideGuard = VocabularyTest()
        outsideGuard.start(items: [word("a")])
        outsideGuard.markSubmitting()
        XCTAssertEqual(outsideGuard.phase, .selfAssessment)
        outsideGuard.markSubmitted()
        XCTAssertEqual(outsideGuard.phase, .selfAssessment)
        outsideGuard.markSubmissionFailed()
        XCTAssertEqual(outsideGuard.phase, .selfAssessment)

        var restarted = test
        restarted.restartLoading()
        XCTAssertEqual(restarted.phase, .loading)
        XCTAssertTrue(restarted.items.isEmpty)

        test.markLoadingFailed()
        XCTAssertEqual(test.phase, .loadingError)
        XCTAssertEqual(test.items.count, 1)
        test.restartLoading()
        XCTAssertEqual(test.phase, .loading)
        XCTAssertTrue(test.items.isEmpty)
    }

    // verifies: ios-rule-learning-05, ios-test-046
    func testIosTest046_progressTextShowsPositionOnlyWhileAnswering() {
        var test = VocabularyTest()
        test.start(items: [word("a"), word("b"), word("c")])
        XCTAssertEqual(test.progressText, "1/3")
        _ = test.recordSelfAssessment(known: true)
        _ = test.recordSelfAssessment(known: false)
        _ = test.recordSelfAssessment(known: false)
        XCTAssertEqual(test.progressText, "1/2")
        _ = test.recordRetestChoice("x")
        _ = test.finishRetestFeedback()
        XCTAssertEqual(test.progressText, "2/2")
        _ = test.recordRetestChoice("x")
        _ = test.finishRetestFeedback()
        XCTAssertEqual(test.phase, .readyToSubmit)
        XCTAssertEqual(test.progressText, "")
    }

    // MARK: - 語の正規化

    // verifies: ios-rule-learning-06, T-TA-R-LV-2-normalize
    func testTTARLV2_normalizeTrimsAndLowercasesButKeepsInnerSpaces() {
        XCTAssertEqual(VocabularyTerm.normalize("  Apple\n"), "apple")
        XCTAssertEqual(VocabularyTerm.normalize("\tNEW  York "), "new  york")
        XCTAssertEqual(VocabularyTerm.normalize("new  york"), "new  york")
    }

    // MARK: - クイズ

    // verifies: ios-rule-learning-07, ios-test-042
    func testIosTest042_attemptTracksSelectionsAndSubmitReadiness() {
        var attempt = QuizAttempt(questionCount: 3)
        XCTAssertFalse(attempt.canSubmit)
        XCTAssertTrue(attempt.answers.isEmpty)
        XCTAssertNil(attempt.selection(for: 0))

        attempt.select(2, for: 1)
        XCTAssertFalse(attempt.canSubmit)
        XCTAssertEqual(attempt.answers, [2])
        XCTAssertEqual(attempt.selection(for: 1), 2)
        XCTAssertNil(attempt.selection(for: 0))

        attempt.select(2, for: 1)
        XCTAssertEqual(attempt.selection(for: 1), 2)
        XCTAssertEqual(attempt.answers, [2])

        attempt.select(0, for: 1)
        XCTAssertEqual(attempt.selection(for: 1), 0)
        XCTAssertEqual(attempt.answers, [0])

        attempt.select(3, for: 0)
        attempt.select(1, for: 2)
        XCTAssertTrue(attempt.canSubmit)
        XCTAssertEqual(attempt.answers, [3, 0, 1])

        attempt.select(5, for: -1)
        attempt.select(5, for: 3)
        XCTAssertEqual(attempt.answers, [3, 0, 1])
        XCTAssertNil(attempt.selection(for: -1))
        XCTAssertNil(attempt.selection(for: 3))

        attempt.select(9, for: 0)
        XCTAssertEqual(attempt.selection(for: 0), 9)
        XCTAssertEqual(attempt.answers, [9, 0, 1])

        let empty = QuizAttempt(questionCount: 0)
        XCTAssertTrue(empty.canSubmit)
        XCTAssertTrue(empty.answers.isEmpty)
    }

    // verifies: ios-rule-learning-07, ios-test-042
    func testIosTest042_isPositiveUsesHalfAsInclusiveThreshold() {
        XCTAssertTrue(QuizAttempt.isPositive(correct: 1, total: 2))
        XCTAssertTrue(QuizAttempt.isPositive(correct: 2, total: 3))
        XCTAssertFalse(QuizAttempt.isPositive(correct: 49, total: 100))
        XCTAssertFalse(QuizAttempt.isPositive(correct: 0, total: 3))
        XCTAssertFalse(QuizAttempt.isPositive(correct: 0, total: 0))
        XCTAssertTrue(QuizAttempt.isPositive(correct: 1, total: 0))
    }

    // MARK: - 値の独立（ios-check-07）

    // verifies: ios-check-07, ios-test-113
    func testIosTest113_startIsIndependentOfCallerArray() {
        var given = [word("a"), word("b")]
        var test = VocabularyTest()
        test.start(items: given)
        XCTAssertEqual(test.items.count, 2)
        given.removeAll()
        XCTAssertEqual(test.items.map(\.id), ["a", "b"])
        XCTAssertEqual(test.currentAssessment?.id, "a")
        XCTAssertEqual(test.recordSelfAssessment(known: true), .advance)
        XCTAssertEqual(test.progressText, "2/2")
    }

    // verifies: ios-check-07, ios-test-113
    func testIosTest113_unseenResultIsIndependentOfLaterReads() {
        var result = AchievementCatalog.unseen(Array(threeAchievements.prefix(2)), seenIds: [])
        XCTAssertEqual(result.count, 2)
        result.removeAll()
        XCTAssertEqual(AchievementCatalog.unseen(Array(threeAchievements.prefix(2)), seenIds: []).count, 2)
    }

    // verifies: ios-check-07, ios-test-113
    func testIosTest113_answersResultIsIndependentOfAttempt() {
        var attempt = QuizAttempt(questionCount: 1)
        attempt.select(1, for: 0)
        var answers = attempt.answers
        XCTAssertEqual(answers, [1])
        answers.removeAll()
        XCTAssertEqual(attempt.answers, [1])
        XCTAssertTrue(attempt.canSubmit)
    }

    // MARK: - fixtures

    private let threeAchievements = [
        Achievement(id: "a", unlockedAt: "1"),
        Achievement(id: "b", unlockedAt: "2"),
        Achievement(id: "c", unlockedAt: "3"),
    ]

    private func status(_ days: Int, _ lastListenedDay: String?) -> ListeningStreakStatus {
        ListeningStreakStatus(days: days, listenedToday: false, lastListenedDay: lastListenedDay)
    }

    private func fraction(_ completed: Int, _ goal: Int) -> Double {
        WeeklyProgress(completed: completed, goal: goal).fraction
    }

    private func word(_ id: String, distractors: [String] = ["x", "y", "z"], meaning: String? = nil) -> VocabularyTestWord {
        VocabularyTestWord(id: id, term: "t" + id, meaning: meaning ?? "M" + id, example: "e", distractors: distractors)
    }

    private func outcome(_ wordId: String, _ selfKnown: Bool, _ retestCorrect: Bool?) -> VocabularyTestOutcome {
        VocabularyTestOutcome(wordId: wordId, selfKnown: selfKnown, retestCorrect: retestCorrect)
    }
}
