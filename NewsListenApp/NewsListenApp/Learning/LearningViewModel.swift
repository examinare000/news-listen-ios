import Foundation
import Combine

/// 学習タブの API 集約と、端末で未表示だった実績の祝福を担う。
@MainActor
final class LearningViewModel: ObservableObject {
    @Published private(set) var dashboard: LearningDashboard?
    @Published private(set) var vocabulary: VocabularyListResponse?
    @Published private(set) var dueVocabularyCount = 0
    @Published private(set) var newlyUnlocked: [Achievement] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    let apiClient: APIClient
    private var achievementTracker: AchievementCelebrationTracker

    init(
        apiClient: APIClient,
        achievementTracker: AchievementCelebrationTracker = AchievementCelebrationTracker()
    ) {
        self.apiClient = apiClient
        self.achievementTracker = achievementTracker
    }

    func load() async {
        isLoading = dashboard == nil
        defer { isLoading = false }

        do {
            let loadedDashboard = try await apiClient.fetchLearningDashboard()
            dashboard = loadedDashboard
            loadFailed = false
            let unseen = achievementTracker.consumeNewlyUnlocked(loadedDashboard.achievements ?? [])
            if !unseen.isEmpty {
                newlyUnlocked = unseen
                DSFeedback.shared.play(.achievement)
            }
        } catch {
            // 再取得失敗で表示済みデータを消さない。初回失敗だけ空状態として見せる。
            loadFailed = true
        }

        // 語彙帳と期日到来数は旧 server で未提供でもダッシュボードを壊さない best-effort。
        if let loadedVocabulary = try? await apiClient.fetchVocabulary() {
            vocabulary = loadedVocabulary
        }
        if let session = try? await apiClient.fetchVocabularyTestSession() {
            dueVocabularyCount = session.items.count
        }
    }

    func dismissAchievementCelebration() {
        newlyUnlocked = []
    }
}
