// verifies: ios-cmd-learning-02, ios-rule-learning-06, ios-test-013, ios-test-031, ios-test-114
import XCTest
import Combine
import os
@testable import NewsListenApp

// MARK: - test double

/// 保留した呼出を、テストが好きな時点で成功・失敗にして解放する。到着を上限つきで待てる。
final class Hold<Value>: @unchecked Sendable {
    private struct State {
        var arrived = false
        var continuation: CheckedContinuation<Value, Error>?
        var result: Result<Value, Error>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    struct ReenteredError: Error {}

    /// double の closure から呼ぶ。`complete` が呼ばれるまで返らない。
    /// 2 回目の呼出は待たずに `ReenteredError` を投げる（想定外の再送でテストが止まらないため）。
    func wait() async throws -> Value {
        if lock.withLock({ state -> Bool in
            defer { state.arrived = true }
            return state.arrived
        }) {
            throw ReenteredError()
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let ready: Result<Value, Error>? = lock.withLock { state in
                if let result = state.result { return result }
                state.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func complete(_ result: Result<Value, Error>) {
        let waiting: CheckedContinuation<Value, Error>? = lock.withLock { state in
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        waiting?.resume(with: result)
    }

    /// 呼出が到着するまで待つ。上限（約 5 秒）を超えたら `XCTFail` して false を返す。
    @discardableResult
    func waitUntilArrived(file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        for _ in 0..<1000 {
            if lock.withLock({ $0.arrived }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("保留した呼出が届かなかった", file: file, line: line)
        return false
    }
}

/// `LearningGateway` の記録 double（`RecordingPlaybackGateway` と同じ形）。
/// 書込（`saveVocabulary`・`submitTestResult`・`submitQuiz`）を `WriteCounter` で数え、引数を記録する。
/// 各 closure は `var` で差し替えられる。
final class RecordingLearningGateway: @unchecked Sendable {
    private let counter = WriteCounter()
    private let lock = OSAllocatedUnfairLock(initialState: Recorded())

    private struct Recorded {
        var savedTerms: [(episodeId: String, term: String)] = []
        var submittedTests: [VocabularyTest] = []
        var quizSubmissions: [(episodeId: String, answers: [Int])] = []
    }

    var fetchVocabularyImpl: () async throws -> (terms: [SavedTerm], count: Int) = { (terms: [], count: 0) }
    var saveVocabularyImpl: (String, String) async throws -> Void = { _, _ in }
    var fetchTestSessionImpl: () async throws -> [VocabularyTestWord] = { [] }
    var submitTestResultImpl: (VocabularyTest) async throws -> Void = { _ in }
    var submitQuizImpl: (String, [Int]) async throws -> QuizGrade = { _, _ in
        QuizGrade(correctCount: 0, total: 0, perQuestion: [], isPositive: false)
    }

    var writeCount: Int { counter.count }
    var savedTerms: [(episodeId: String, term: String)] { lock.withLock { $0.savedTerms } }
    var submittedTests: [VocabularyTest] { lock.withLock { $0.submittedTests } }
    var quizSubmissions: [(episodeId: String, answers: [Int])] { lock.withLock { $0.quizSubmissions } }

    var gateway: LearningGateway {
        LearningGateway(
            fetchVocabulary: { [self] in try await fetchVocabularyImpl() },
            saveVocabulary: { [self] episodeId, term in
                counter.increment()
                lock.withLock { $0.savedTerms.append((episodeId, term)) }
                try await saveVocabularyImpl(episodeId, term)
            },
            fetchTestSession: { [self] in try await fetchTestSessionImpl() },
            submitTestResult: { [self] test in
                counter.increment()
                lock.withLock { $0.submittedTests.append(test) }
                try await submitTestResultImpl(test)
            },
            submitQuiz: { [self] episodeId, answers in
                counter.increment()
                lock.withLock { $0.quizSubmissions.append((episodeId, answers)) }
                return try await submitQuizImpl(episodeId, answers)
            }
        )
    }

    /// `fetchVocabulary` を呼出順の保留に差し替える。n 番目の呼出は n 番目の `Hold` が解放するまで返らない。
    func holdFetchVocabulary(_ count: Int) -> [Hold<(terms: [SavedTerm], count: Int)>] {
        let holds = (0..<count).map { _ in Hold<(terms: [SavedTerm], count: Int)>() }
        let next = OSAllocatedUnfairLock(initialState: 0)
        fetchVocabularyImpl = {
            let index = next.withLock { value -> Int in defer { value += 1 }; return value }
            guard holds.indices.contains(index) else { return (terms: [], count: 0) }
            return try await holds[index].wait()
        }
        return holds
    }
}

// MARK: - fixtures

enum LearningFixture {
    static func word(_ id: String) -> VocabularyTestWord {
        VocabularyTestWord(
            id: id, term: "term-\(id)", meaning: "意味-\(id)", example: "example \(id)",
            distractors: ["誤答A-\(id)", "誤答B-\(id)", "誤答C-\(id)"])
    }

    static func grade(correct: Int = 1, total: Int = 2) -> QuizGrade {
        QuizGrade(
            correctCount: correct, total: total,
            perQuestion: [
                QuizGradeItem(questionIndex: 0, selectedIndex: 2, correctIndex: 1, isCorrect: false),
                QuizGradeItem(questionIndex: 1, selectedIndex: 0, correctIndex: 0, isCorrect: true),
            ],
            isPositive: true)
    }
}

// MARK: - tests

@MainActor
final class VocabularyBookTests: XCTestCase {

    private var double: RecordingLearningGateway!
    private var book: VocabularyBook!

    override func setUp() {
        super.setUp()
        double = RecordingLearningGateway()
        book = VocabularyBook(gateway: double.gateway)
    }

    private nonisolated func saved(_ episodeId: String, _ term: String) -> SavedTerm {
        SavedTerm(episodeId: episodeId, term: term)
    }

    /// `registered` を `{episodeId, normalized(terms)}` にする。
    private func load(_ episodeId: String, terms: [String]) async throws {
        double.fetchVocabularyImpl = { [self] in
            (terms: terms.map { saved(episodeId, $0) }, count: terms.count)
        }
        _ = try await book.registeredTerms(episodeId: episodeId)
    }

    func testSaveOfRegisteredTermIsAlreadySavedWithoutSending() async throws {
        try await load("e1", terms: ["apple"])

        let receipt = try await book.save(episodeId: "e1", term: " Apple ")

        XCTAssertEqual(receipt, .alreadySaved)
        XCTAssertEqual(double.writeCount, 0, "登録済みの語は送らない")
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e1", terms: ["apple"]))
        XCTAssertTrue(book.savingTerms.isEmpty)
        XCTAssertFalse(book.lastSaveFailed)
    }

    func testSaveOfTermBeingSavedIsAlreadySavingWithoutSecondSend() async throws {
        let hold = Hold<Void>()
        double.saveVocabularyImpl = { _, _ in try await hold.wait() }
        let first = Task { try await book.save(episodeId: "e1", term: "apple") }
        await hold.waitUntilArrived()

        let second = try await book.save(episodeId: "e1", term: "APPLE ")

        XCTAssertEqual(second, .alreadySaving)
        XCTAssertEqual(double.writeCount, 1, "保存中の語は 2 回目を送らない")
        XCTAssertEqual(book.savingTerms, ["apple"])

        hold.complete(.success(()))
        let firstReceipt = try await first.value
        XCTAssertEqual(firstReceipt, .saved)
    }

    func testSaveSucceedsAddsNormalizedTermToRegisteredOfSameEpisode() async throws {
        try await load("e1", terms: [])
        let hold = Hold<Void>()
        double.saveVocabularyImpl = { _, _ in try await hold.wait() }

        let task = Task { try await book.save(episodeId: "e1", term: " Apple ") }
        await hold.waitUntilArrived()

        XCTAssertEqual(book.savingTerms, ["apple"], "保存中は正規化した語が入る")
        XCTAssertEqual(double.savedTerms.map(\.term), [" Apple "], "gateway へは渡された語のまま")
        XCTAssertEqual(double.savedTerms.map(\.episodeId), ["e1"])

        hold.complete(.success(()))
        let receipt = try await task.value

        XCTAssertEqual(receipt, .saved)
        XCTAssertTrue(book.savingTerms.isEmpty)
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e1", terms: ["apple"]))
    }

    func testSaveSuccessDoesNotLeakIntoRegisteredOfAnotherEpisode() async throws {
        try await load("e1", terms: [])
        let hold = Hold<Void>()
        double.saveVocabularyImpl = { _, _ in try await hold.wait() }
        let task = Task { try await book.save(episodeId: "e1", term: "apple") }
        await hold.waitUntilArrived()

        double.fetchVocabularyImpl = { [self] in
            (terms: [saved("e2", "pear"), saved("e1", "kiwi")], count: 2)
        }
        let loaded = try await book.registeredTerms(episodeId: "e2")
        XCTAssertEqual(loaded, RegisteredTerms(episodeId: "e2", terms: ["pear"]), "対照: e2 の語だけが入る")

        hold.complete(.success(()))
        let receipt = try await task.value

        XCTAssertEqual(receipt, .saved)
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e2", terms: ["pear"]), "e1 の apple は混ざらない")
        XCTAssertTrue(book.savingTerms.isEmpty)
    }

    func testSaveSuccessWithoutRegisteredLeavesRegisteredNil() async throws {
        let receipt = try await book.save(episodeId: "e1", term: "apple")

        XCTAssertEqual(receipt, .saved)
        XCTAssertNil(book.registered)
    }

    func testSaveFailureRethrowsMarksFailureAndReleasesSavingTerm() async throws {
        try await load("e1", terms: ["pear"])
        double.saveVocabularyImpl = { _, _ in throw ApiFailure.server(status: 500) }

        do {
            _ = try await book.save(episodeId: "e1", term: "apple")
            XCTFail("失敗は投げ直される")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }

        XCTAssertTrue(book.lastSaveFailed)
        XCTAssertTrue(book.savingTerms.isEmpty)
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e1", terms: ["pear"]))
    }

    func testSaveRetryAfterFailureSendsAgainAndDismissClearsFailure() async throws {
        try await load("e1", terms: ["pear"])
        double.saveVocabularyImpl = { _, _ in throw ApiFailure.server(status: 500) }
        _ = try? await book.save(episodeId: "e1", term: "apple")
        double.saveVocabularyImpl = { _, _ in }

        let receipt = try await book.save(episodeId: "e1", term: "apple")

        XCTAssertEqual(receipt, .saved)
        XCTAssertEqual(double.writeCount, 2, "失敗した語は詰まらず、もう一度 gateway へ送る")
        XCTAssertTrue(book.lastSaveFailed, "保存の成功では lastSaveFailed を変えない")

        book.dismissSaveFailure()

        XCTAssertFalse(book.lastSaveFailed)
    }

    func testRegisteredTermsResetsBeforeAwaitThenKeepsOnlyRequestedEpisodeNormalized() async throws {
        let hold = Hold<(terms: [SavedTerm], count: Int)>()
        double.fetchVocabularyImpl = { try await hold.wait() }

        let task = Task { try await book.registeredTerms(episodeId: "e1") }
        await hold.waitUntilArrived()

        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e1", terms: []), "応答の前に空へ置き換える")

        hold.complete(.success((terms: [saved("e1", " Apple "), saved("e2", "pear")], count: 2)))
        let result = try await task.value

        XCTAssertEqual(result, RegisteredTerms(episodeId: "e1", terms: ["apple"]))
        XCTAssertEqual(book.registered, result)
    }

    func testStaleResponseOfEarlierEpisodeIsDiscardedWithCancellation() async throws {
        let holds = double.holdFetchVocabulary(2)
        let first = Task { try await book.registeredTerms(episodeId: "e1") }
        await holds[0].waitUntilArrived()
        let second = Task { try await book.registeredTerms(episodeId: "e2") }
        await holds[1].waitUntilArrived()

        holds[1].complete(.success((terms: [saved("e2", "pear")], count: 1)))
        _ = try await second.value
        holds[0].complete(.success((terms: [saved("e1", "apple")], count: 1)))

        do {
            _ = try await first.value
            XCTFail("古い応答は CancellationError で捨てる")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e2", terms: ["pear"]))
    }

    func testCancelledTaskDiscardsResponseAndKeepsEmptyRegistered() async throws {
        let hold = Hold<(terms: [SavedTerm], count: Int)>()
        double.fetchVocabularyImpl = { try await hold.wait() }
        let task = Task { try await book.registeredTerms(episodeId: "e1") }
        await hold.waitUntilArrived()

        task.cancel()
        hold.complete(.success((terms: [saved("e1", "apple")], count: 1)))

        do {
            _ = try await task.value
            XCTFail("cancel された task の応答は捨てる")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e1", terms: []))
    }

    func testRegisteredTermsFailureThrowsLeavesEmptyAndNextCallRecovers() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        double.fetchVocabularyImpl = { [self] in
            let call = calls.withLock { value -> Int in value += 1; return value }
            if call == 2 { throw ApiFailure.server(status: 503) }
            return (terms: [saved("e1", "Apple")], count: 1)
        }

        let first = try await book.registeredTerms(episodeId: "e1")
        XCTAssertEqual(first.terms, ["apple"], "対照: 1 回目は読み込めている")

        do {
            _ = try await book.registeredTerms(episodeId: "e1")
            XCTFail("取得の失敗はそのまま投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 503))
        }
        XCTAssertEqual(book.registered, RegisteredTerms(episodeId: "e1", terms: []), "再読み込みの失敗では空になる")

        let third = try await book.registeredTerms(episodeId: "e1")
        XCTAssertEqual(third.terms, ["apple"])
        XCTAssertEqual(book.registered, third)
    }

    func testBookReturnsGatewayCountAndFirstFiveTermsAsIs() async throws {
        let terms = [" Apple ", "Pear", "kiwi", "Plum", "fig", "grape", "lime"]
        double.fetchVocabularyImpl = { [self] in (terms: terms.map { saved("e1", $0) }, count: 9) }

        let view = try await book.book()

        XCTAssertEqual(view.count, 9, "count は gateway の値（terms.count で数え直さない）")
        XCTAssertEqual(view.firstTerms, [" Apple ", "Pear", "kiwi", "Plum", "fig"])
        XCTAssertNil(book.registered)
        XCTAssertTrue(book.savingTerms.isEmpty)
        XCTAssertFalse(book.lastSaveFailed)
        XCTAssertEqual(double.writeCount, 0)
    }

    func testBookWithFewerThanFiveTermsReturnsAllAndRethrowsFailure() async throws {
        double.fetchVocabularyImpl = { [self] in (terms: ["a", "b", "c", "d"].map { saved("e1", $0) }, count: 4) }
        let view = try await book.book()
        XCTAssertEqual(view.firstTerms, ["a", "b", "c", "d"])

        double.fetchVocabularyImpl = { throw ApiFailure.server(status: 500) }
        do {
            _ = try await book.book()
            XCTFail("失敗はそのまま投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    func testMutatingReturnedCopyDoesNotChangeNextBookResult() async throws {
        double.fetchVocabularyImpl = { [self] in (terms: ["a", "b"].map { saved("e1", $0) }, count: 2) }
        let view = try await book.book()

        var copy = view.firstTerms
        copy.append("x")
        copy[0] = "changed"
        let again = try await book.book()

        XCTAssertEqual(again, view)
        XCTAssertEqual(again.firstTerms, ["a", "b"])
    }

    func testFacadeForwardsVocabularyBookChangesToItsObjectWillChange() async throws {
        let rig = PlaybackEntryRig()
        var fired = 0
        let subscription = rig.viewModel.objectWillChange.sink { fired += 1 }
        defer { subscription.cancel() }

        _ = try? await rig.viewModel.vocabularyBook.registeredTerms(episodeId: "e1")

        XCTAssertGreaterThan(fired, 0, "vocabularyBook の変化で facade の購読が発火する")
    }
}
