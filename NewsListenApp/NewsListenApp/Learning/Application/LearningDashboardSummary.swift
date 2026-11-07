//
//  LearningDashboardSummary.swift
//  NewsListenApp
//
//  学習ダッシュボードのリードモデル。通信のデータモデルを presentation に見せないための形。
//

import Foundation

struct LearningDashboardSummary: Equatable {
    let streak: ListeningStreakStatus
    /// `weekly_goal` が無い（旧 server）とき nil。
    let weekly: WeeklyProgress?
    let weeklyHistory: [WeeklyHistoryEntry]
    /// カタログに無い id も落とさない（既読の判定が全 id を見る）。
    let achievements: [Achievement]
    let monthlyListeningDays: [MonthlyListening]
    let completedCount: Int
    let masteredVocabularyCount: Int
    let currentLevel: String
    let quizzedEpisodeCount: Int
    let averageCorrectRate: Double?
    let quizTrend: [QuizTrendEntry]
}

struct WeeklyHistoryEntry: Equatable {
    let week: String
    let progress: WeeklyProgress
}

struct MonthlyListening: Equatable {
    let month: String
    let days: Int
}

struct QuizTrendEntry: Equatable {
    /// 通信の `graded_at` のまま（表示で先頭 10 文字にするのは View）。
    let date: String
    let rate: Double
}
