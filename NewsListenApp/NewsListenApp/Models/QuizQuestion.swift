//
//  QuizQuestion.swift
//  NewsListenApp
//
//  理解度クイズ（ADR-070）の公開設問・採点レスポンスモデル。
//

import Foundation

/// API が公開する理解度クイズ設問。
///
/// 正解はサーバー採点まで秘匿するため `answer_index` を持たない。
struct QuizQuestion: Codable, Equatable {
    let question: String
    let options: [String]
}

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
