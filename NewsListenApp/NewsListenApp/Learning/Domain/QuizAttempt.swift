import Foundation

struct QuizAttempt: Equatable {
    private var selections: [Int?]

    init(questionCount: Int) {
        selections = Array(repeating: nil, count: questionCount)
    }

    var canSubmit: Bool {
        !selections.contains { $0 == nil }
    }

    var answers: [Int] {
        selections.compactMap { $0 }
    }

    func selection(for question: Int) -> Int? {
        guard selections.indices.contains(question) else { return nil }
        return selections[question]
    }

    mutating func select(_ option: Int, for question: Int) {
        guard selections.indices.contains(question) else { return }
        selections[question] = option
    }

    static func isPositive(correct: Int, total: Int) -> Bool {
        Double(correct) / Double(total) >= 0.5
    }
}
