import Foundation

struct VocabularyItem: Codable, Equatable, Identifiable {
    let vocabularyId: String
    let podcastId: String
    let term: String
    let meaning: String
    let example: String
    let registeredAt: String

    var id: String { vocabularyId }

    enum CodingKeys: String, CodingKey {
        case vocabularyId = "vocabulary_id"
        case podcastId = "podcast_id"
        case term, meaning, example
        case registeredAt = "registered_at"
    }
}

struct VocabularyListResponse: Codable, Equatable {
    let vocabulary: [VocabularyItem]
    let count: Int
}

struct DeleteVocabularyResponse: Codable, Equatable {
    let status: String
    let vocabularyId: String

    enum CodingKeys: String, CodingKey {
        case status
        case vocabularyId = "vocabulary_id"
    }
}

struct VocabularyTestItem: Codable, Equatable, Identifiable {
    let vocabularyId: String
    let term: String
    let meaning: String
    let example: String
    let distractors: [String]

    var id: String { vocabularyId }

    enum CodingKeys: String, CodingKey {
        case vocabularyId = "vocabulary_id"
        case term, meaning, example, distractors
    }
}

struct VocabularyTestSessionResponse: Codable, Equatable {
    let items: [VocabularyTestItem]
}

struct VocabularyTestResultItem: Codable, Equatable {
    let vocabularyId: String
    let selfKnown: Bool
    let retestCorrect: Bool?

    enum CodingKeys: String, CodingKey {
        case vocabularyId = "vocabulary_id"
        case selfKnown = "self_known"
        case retestCorrect = "retest_correct"
    }
}

struct VocabularyTestResultResponse: Codable, Equatable {
    let updated: Int
}

struct VocabularyTestSummary: Equatable {
    let knownCount: Int
    let retestCount: Int
    let retestCorrectCount: Int
}

/// 単語テストの操作可能な状態だけを表現する純粋な状態機械。
///
/// 通信・800ms 待機・フィードバックは ViewModel に置き、遷移自体を決定的にテストできるようにする。
struct VocabularyTestStateMachine {
    enum Phase: Equatable {
        case loading
        case selfAssessment
        case retest
        case readyToSubmit
        case submitting
        case result
        case empty
        case loadingError
        case submissionError
    }

    enum Transition: Equatable {
        case ignored
        case advance
        case beginRetest
        case submit
    }

    enum RetestFeedback: Equatable {
        case correct
        case incorrect(correctAnswer: String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [VocabularyTestItem] = []
    private(set) var assessmentIndex = 0
    private(set) var assessments: [String: Bool] = [:]
    private(set) var retestItems: [VocabularyTestItem] = []
    private(set) var retestIndex = 0
    private(set) var retestResults: [String: Bool] = [:]
    private(set) var choicesByID: [String: [String]] = [:]
    private(set) var feedback: RetestFeedback?
    private(set) var isAdvancing = false

    var currentAssessment: VocabularyTestItem? {
        guard phase == .selfAssessment, items.indices.contains(assessmentIndex) else { return nil }
        return items[assessmentIndex]
    }

    var currentRetest: VocabularyTestItem? {
        guard phase == .retest, retestItems.indices.contains(retestIndex) else { return nil }
        return retestItems[retestIndex]
    }

    var currentChoices: [String]? {
        currentRetest.flatMap { choicesByID[$0.vocabularyId] }
    }

    var revealedCorrectAnswer: String? {
        guard case .incorrect(let answer) = feedback else { return nil }
        return answer
    }

    var progressText: String {
        switch phase {
        case .selfAssessment:
            return "\(assessmentIndex + 1)/\(items.count)"
        case .retest:
            return "\(retestIndex + 1)/\(retestItems.count)"
        default:
            return ""
        }
    }

    var resultPayload: [VocabularyTestResultItem] {
        items.map { item in
            let known = assessments[item.vocabularyId] ?? false
            return VocabularyTestResultItem(
                vocabularyId: item.vocabularyId,
                selfKnown: known,
                retestCorrect: known ? nil : (retestResults[item.vocabularyId] ?? false)
            )
        }
    }

    var summary: VocabularyTestSummary {
        let retestCount = resultPayload.filter { $0.retestCorrect != nil }.count
        return VocabularyTestSummary(
            knownCount: resultPayload.count - retestCount,
            retestCount: retestCount,
            retestCorrectCount: resultPayload.filter { $0.retestCorrect == true }.count
        )
    }

    mutating func start(items: [VocabularyTestItem]) {
        self = VocabularyTestStateMachine()
        self.items = Array(items.prefix(10))
        phase = self.items.isEmpty ? .empty : .selfAssessment
    }

    @discardableResult
    mutating func recordSelfAssessment(known: Bool) -> Transition {
        guard phase == .selfAssessment, let item = currentAssessment else { return .ignored }
        assessments[item.vocabularyId] = known

        if assessmentIndex < items.count - 1 {
            assessmentIndex += 1
            return .advance
        }

        retestItems = items.filter { assessments[$0.vocabularyId] == false }
        guard !retestItems.isEmpty else {
            phase = .readyToSubmit
            return .submit
        }

        choicesByID = Dictionary(uniqueKeysWithValues: retestItems.map { item in
            var uniqueChoices: [String] = []
            for choice in [item.meaning] + Array(item.distractors.prefix(3))
            where !uniqueChoices.contains(choice) {
                uniqueChoices.append(choice)
            }
            return (item.vocabularyId, uniqueChoices.shuffled())
        })
        phase = .retest
        return .beginRetest
    }

    @discardableResult
    mutating func recordRetestChoice(_ choice: String) -> Bool {
        guard phase == .retest, !isAdvancing, let item = currentRetest else { return false }
        let correct = choice == item.meaning
        retestResults[item.vocabularyId] = correct
        feedback = correct ? .correct : .incorrect(correctAnswer: item.meaning)
        isAdvancing = true
        return true
    }

    @discardableResult
    mutating func finishRetestFeedback() -> Transition {
        guard phase == .retest, isAdvancing else { return .ignored }
        feedback = nil
        isAdvancing = false
        if retestIndex < retestItems.count - 1 {
            retestIndex += 1
            return .advance
        }
        phase = .readyToSubmit
        return .submit
    }

    mutating func markSubmitting() {
        guard phase == .readyToSubmit || phase == .submissionError else { return }
        phase = .submitting
    }

    mutating func markSubmitted() {
        guard phase == .submitting else { return }
        phase = .result
    }

    mutating func markSubmissionFailed() {
        guard phase == .submitting else { return }
        phase = .submissionError
    }

    mutating func markLoadingFailed() {
        phase = .loadingError
    }

    mutating func restartLoading() {
        self = VocabularyTestStateMachine()
    }
}
