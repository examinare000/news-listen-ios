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
