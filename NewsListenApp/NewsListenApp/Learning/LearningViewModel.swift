import Foundation
import Combine

/// 学習タブの状態を集約し、端末で未表示だった実績を知らせる。音は鳴らさない（鳴らすのは View）。
@MainActor
final class LearningViewModel: ObservableObject {
    @Published private(set) var dashboard: LearningDashboardSummary?
    @Published private(set) var vocabulary: VocabularyBookView?
    @Published private(set) var dueVocabularyCount = 0
    @Published private(set) var newlyUnlocked: [Achievement] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadFailed = false

    private let engagement: EngagementStore
    private let vocabularyBook: VocabularyBook
    private let vocabularyTesting: VocabularyTesting

    init(engagement: EngagementStore, vocabularyBook: VocabularyBook, vocabularyTesting: VocabularyTesting) {
        self.engagement = engagement
        self.vocabularyBook = vocabularyBook
        self.vocabularyTesting = vocabularyTesting
    }

    func load() async {
        isLoading = dashboard == nil
        defer { isLoading = false }

        do {
            let loadedDashboard = try await engagement.dashboard()
            dashboard = loadedDashboard
            loadFailed = false
            let unseen = engagement.unseenAchievements(in: loadedDashboard)
            if !unseen.isEmpty {
                // 既読には未表示だけでなく解錠済みの全 id を渡す（現行の union と同じ結果）。
                engagement.markAchievementsSeen(loadedDashboard.achievements.map(\.id))
                newlyUnlocked = unseen
            }
        } catch {
            // 再取得失敗で表示済みデータを消さない。初回失敗だけ空状態として見せる。
            loadFailed = true
        }

        // 語彙帳と期日到来数は旧 server で未提供でもダッシュボードを壊さない best-effort。
        if let loadedVocabulary = try? await vocabularyBook.book() {
            vocabulary = loadedVocabulary
        }
        if let due = try? await vocabularyTesting.due() {
            dueVocabularyCount = due.dueCount
        }
    }

    func dismissAchievementCelebration() {
        newlyUnlocked = []
    }
}
