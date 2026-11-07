//
//  QuizViewModel.swift
//  NewsListenApp
//
//  クイズの画面の状態。音・触覚・読み上げは View が行う。
//

import Foundation
import Combine

@MainActor
final class QuizViewModel: ObservableObject {
    @Published private(set) var attempt: QuizAttempt
    @Published private(set) var grade: QuizGrade?
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUnavailable = false

    private let grading: QuizGrading
    private let episodeId: String

    init(grading: QuizGrading, episodeId: String, questionCount: Int) {
        self.grading = grading
        self.episodeId = episodeId
        self.attempt = QuizAttempt(questionCount: questionCount)
    }

    func select(_ option: Int, for question: Int) {
        attempt.select(option, for: question)
    }

    func submit() async {
        guard attempt.canSubmit else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            switch try await grading.submit(episodeId: episodeId, answers: attempt.answers) {
            case .graded(let result):
                grade = result
            case .unavailable:
                isUnavailable = true
            }
        } catch {
            errorMessage = "採点結果を取得できませんでした。もう一度お試しください。"
        }
    }
}
