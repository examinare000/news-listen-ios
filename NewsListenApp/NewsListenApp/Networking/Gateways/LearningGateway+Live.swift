//
//  LearningGateway+Live.swift
//  NewsListenApp
//
//  学習の取得・送信 port を `APIClient` から組む adapter。応答はリードモデルに変換して返す。
//

import Foundation

extension LearningGateway {
    static func live(apiClient: APIClient) -> LearningGateway {
        LearningGateway(
            fetchVocabulary: {
                let response = try await apiClient.fetchVocabulary()
                return (
                    terms: response.vocabulary.map { SavedTerm(episodeId: $0.podcastId, term: $0.term) },
                    count: response.count
                )
            },
            saveVocabulary: { episodeId, term in
                _ = try await apiClient.saveVocabulary(podcastId: episodeId, term: term)
            },
            fetchTestSession: {
                try await apiClient.fetchVocabularyTestSession().items.map { $0.toWord() }
            },
            submitTestResult: { test in
                _ = try await apiClient.submitVocabularyTestResult(test.resultPayload)
            },
            submitQuiz: { episodeId, answers in
                let response = try await apiClient.submitQuizAnswers(podcastId: episodeId, answers: answers)
                return QuizGrade(
                    correctCount: response.correctCount,
                    total: response.total,
                    perQuestion: response.results.map {
                        QuizGradeItem(
                            questionIndex: $0.questionIndex,
                            selectedIndex: $0.selectedIndex,
                            correctIndex: $0.correctIndex,
                            isCorrect: $0.isCorrect
                        )
                    },
                    isPositive: QuizAttempt.isPositive(correct: response.correctCount, total: response.total)
                )
            }
        )
    }
}
