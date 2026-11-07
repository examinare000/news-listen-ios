import Foundation

extension ListeningStreak {
    func toStatus() -> ListeningStreakStatus {
        ListeningStreakStatus(days: currentStreakDays, listenedToday: todayListened, lastListenedDay: lastListenedDay)
    }
}

extension WeeklyGoal {
    func toProgress() -> WeeklyProgress { WeeklyProgress(completed: completedThisWeek, goal: goalEpisodes) }
}

extension WeeklyGoalRecord {
    func toProgress() -> WeeklyProgress { WeeklyProgress(completed: completed, goal: goal) }
}

extension LearningDashboard {
    /// 通信のデータモデルを presentation に見せないための写し。
    func toSummary() -> LearningDashboardSummary {
        LearningDashboardSummary(
            streak: streak.toStatus(),
            weekly: weeklyGoal?.toProgress(),
            weeklyHistory: (weeklyGoal?.history ?? []).map { WeeklyHistoryEntry(week: $0.week, progress: $0.toProgress()) },
            achievements: achievements ?? [],
            monthlyListeningDays: monthlyActivity.map { MonthlyListening(month: $0.month, days: $0.activeDays) },
            completedCount: totalEpisodes,
            masteredVocabularyCount: vocabularyAcquired,
            currentLevel: currentDifficulty,
            quizzedEpisodeCount: quiz.quizzedEpisodes,
            averageCorrectRate: quiz.averageCorrectRate,
            quizTrend: quiz.trend.map { QuizTrendEntry(date: $0.gradedAt, rate: $0.correctRate) }
        )
    }
}

extension Achievement: Codable {
    enum CodingKeys: String, CodingKey {
        case id
        case unlockedAt = "unlocked_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            unlockedAt: try container.decode(String.self, forKey: .unlockedAt)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(unlockedAt, forKey: .unlockedAt)
    }
}
