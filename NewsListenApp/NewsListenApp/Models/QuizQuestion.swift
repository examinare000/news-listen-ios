//
//  QuizQuestion.swift
//  NewsListenApp
//
//  理解度クイズ（ADR-070）の公開設問・採点レスポンスモデル。
//

import Foundation

/// 採点済み設問 1 件の結果。
struct QuizGradeResult: Codable, Equatable {
    let questionIndex: Int
    let selectedIndex: Int
    let correctIndex: Int
    let isCorrect: Bool

    enum CodingKeys: String, CodingKey {
        case questionIndex = "question_index"
        case selectedIndex = "selected_index"
        case correctIndex = "correct_index"
        case isCorrect = "is_correct"
    }
}

/// `POST /podcasts/{id}/quiz-answers` の採点レスポンス。
struct QuizAnswerResponse: Codable, Equatable {
    let correctCount: Int
    let total: Int
    let correctRate: Double
    let results: [QuizGradeResult]

    enum CodingKeys: String, CodingKey {
        case correctCount = "correct_count"
        case total
        case correctRate = "correct_rate"
        case results
    }
}
