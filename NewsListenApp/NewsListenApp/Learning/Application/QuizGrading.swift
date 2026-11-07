//
//  QuizGrading.swift
//  NewsListenApp
//
//  クイズの送信と、クイズが無い（404）ときの扱い。通信は port（`LearningGateway`）の向こうにある。
//

import Foundation

struct QuizGradeItem: Equatable {
    let questionIndex: Int
    let selectedIndex: Int
    let correctIndex: Int
    let isCorrect: Bool
}

struct QuizGrade: Equatable {
    let correctCount: Int
    let total: Int
    let perQuestion: [QuizGradeItem]
    let isPositive: Bool
}

enum QuizGradingResult: Equatable { case graded(QuizGrade), unavailable }

@MainActor
final class QuizGrading {
    private let gateway: LearningGateway

    init(gateway: LearningGateway) {
        self.gateway = gateway
    }

    func submit(episodeId: String, answers: [Int]) async throws -> QuizGradingResult {
        do {
            return .graded(try await gateway.submitQuiz(episodeId, answers))
        } catch ApiFailure.notFound(subject: .quiz) {
            // 旧 backend・提供なしは警告にせず、クイズ自体を隠す。
            return .unavailable
        }
    }
}
