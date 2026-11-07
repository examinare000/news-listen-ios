import Foundation

struct Achievement: Equatable, Identifiable {
    let id: String
    let unlockedAt: String
}

struct AchievementCatalogItem: Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
}

enum AchievementCatalog {
    static let all: [AchievementCatalogItem] = [
        AchievementCatalogItem(
            id: "first_episode_completed",
            name: "初回エピソード完聴",
            description: "はじめてエピソードを最後まで聴く"
        ),
        AchievementCatalogItem(
            id: "first_quiz_correct",
            name: "初回クイズ正解",
            description: "はじめて理解度クイズに正解する"
        ),
        AchievementCatalogItem(id: "streak_7", name: "7 日連続聴取", description: "7 日間連続で聴く"),
        AchievementCatalogItem(id: "streak_30", name: "30 日連続聴取", description: "30 日間連続で聴く"),
        AchievementCatalogItem(id: "streak_100", name: "100 日連続聴取", description: "100 日間連続で聴く"),
        AchievementCatalogItem(
            id: "completed_10",
            name: "累計 10 本完聴",
            description: "エピソードを累計 10 本聴き終える"
        ),
        AchievementCatalogItem(
            id: "completed_50",
            name: "累計 50 本完聴",
            description: "エピソードを累計 50 本聴き終える"
        ),
    ]

    static func unseen(_ unlocked: [Achievement], seenIds: Set<String>) -> [Achievement] {
        unlocked.filter { !seenIds.contains($0.id) }
    }
}
