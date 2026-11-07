import Foundation

/// 学習ダッシュボードのクイズ正答率推移。
struct QuizTrendPoint: Codable, Equatable, Identifiable {
    let gradedAt: String
    let correctRate: Double

    var id: String { gradedAt }

    enum CodingKeys: String, CodingKey {
        case gradedAt = "graded_at"
        case correctRate = "correct_rate"
    }
}

/// 学習ダッシュボードのクイズ集計。
struct QuizStats: Codable, Equatable {
    let quizzedEpisodes: Int
    let averageCorrectRate: Double?
    let trend: [QuizTrendPoint]

    enum CodingKeys: String, CodingKey {
        case quizzedEpisodes = "quizzed_episodes"
        case averageCorrectRate = "average_correct_rate"
        case trend
    }
}

/// 月別の聴取活動日数。
struct MonthlyActivity: Codable, Equatable, Identifiable {
    let month: String
    let activeDays: Int

    var id: String { month }

    enum CodingKeys: String, CodingKey {
        case month
        case activeDays = "active_days"
    }
}

/// 閉じた週の目標と実績。達否の評価語を持たず事実だけを表す。
struct WeeklyGoalRecord: Codable, Equatable, Identifiable {
    let week: String
    let goal: Int
    let completed: Int

    var id: String { week }
}

/// 現在の週次目標進捗と履歴。
struct WeeklyGoal: Codable, Equatable {
    let goalEpisodes: Int
    let week: String
    let completedThisWeek: Int
    let history: [WeeklyGoalRecord]

    enum CodingKeys: String, CodingKey {
        case goalEpisodes = "goal_episodes"
        case week
        case completedThisWeek = "completed_this_week"
        case history
    }

    /// 警告や達否を付けず、backend の事実をそのまま示す。
    var progressText: String {
        "今週 \(completedThisWeek)/目標 \(goalEpisodes) 本"
    }
}

/// `GET /users/me/learning-dashboard` のレスポンス。
///
/// Phase 2 追加フィールドは Optional とし、旧 server のレスポンスも継続して表示できる。
struct LearningDashboard: Codable, Equatable {
    let streak: ListeningStreak
    let totalEpisodes: Int
    let vocabularyAcquired: Int
    let quiz: QuizStats
    let monthlyActivity: [MonthlyActivity]
    let currentDifficulty: String
    let weeklyGoal: WeeklyGoal?
    let achievements: [Achievement]?

    enum CodingKeys: String, CodingKey {
        case streak
        case totalEpisodes = "total_episodes"
        case vocabularyAcquired = "vocabulary_acquired"
        case quiz
        case monthlyActivity = "monthly_activity"
        case currentDifficulty = "current_difficulty"
        case weeklyGoal = "weekly_goal"
        case achievements
    }
}

/// 端末で既に祝福した実績を保持し、初回ロードを含む未表示差分だけを返す。
struct AchievementCelebrationTracker {
    /// key 文字列の宣言は `PreferenceRegistry`（ios-slice-auth-01）が正本で、これはその別名（D-5）。
    static let seenAchievementIDsKey = PreferenceRegistry.seenAchievementIdsKey

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func consumeNewlyUnlocked(_ unlocked: [Achievement]) -> [Achievement] {
        let seen = Set(userDefaults.stringArray(forKey: Self.seenAchievementIDsKey) ?? [])
        let newlyUnlocked = AchievementCatalog.unseen(unlocked, seenIds: seen)
        guard !newlyUnlocked.isEmpty else { return [] }

        let updated = seen.union(unlocked.map(\.id))
        userDefaults.set(updated.sorted(), forKey: Self.seenAchievementIDsKey)
        return newlyUnlocked
    }
}
