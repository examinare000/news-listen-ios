//
//  LearningGateway+Live.swift
//  NewsListenApp
//
//  学習の取得・送信 port を `APIClient` から組む adapter。応答はリードモデルに変換して返す。
//

import Foundation

extension LearningGateway {
    static func live(apiClient: APIClient) -> LearningGateway {
        live(client: { apiClient })
    }

    /// - Parameter client: 呼出のたびに現在の `APIClient` を返す。nil のとき全 closure が
    ///   `ApiFailure.network(URLError(.badURL))` を投げる（UI からは届かない経路）。
    static func live(client: @escaping @MainActor () -> APIClient?) -> LearningGateway {
        let current: @MainActor () throws -> APIClient = {
            guard let resolved = client() else { throw ApiFailure.network(URLError(.badURL)) }
            return resolved
        }
        return LearningGateway(
            fetchVocabulary: { @MainActor in
                let response = try await current().fetchVocabulary()
                return (
                    terms: response.vocabulary.map {
                        SavedTerm(episodeId: $0.podcastId, term: $0.term, meaning: $0.meaning, registeredAt: $0.registeredAt)
                    },
                    count: response.count
                )
            },
            saveVocabulary: { @MainActor episodeId, term in
                _ = try await current().saveVocabulary(podcastId: episodeId, term: term)
            },
            fetchTestSession: { @MainActor in
                try await current().fetchVocabularyTestSession().items.map { $0.toWord() }
            },
            submitTestResult: { @MainActor test in
                _ = try await current().submitVocabularyTestResult(test.resultPayload)
            },
            submitQuiz: { @MainActor episodeId, answers in
                let response = try await current().submitQuizAnswers(podcastId: episodeId, answers: answers)
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
            },
            fetchDashboard: { @MainActor in
                try await current().fetchLearningDashboard().toSummary()
            },
            fetchStreak: { @MainActor in
                try await current().fetchListeningStreak().toStatus()
            }
        )
    }
}
