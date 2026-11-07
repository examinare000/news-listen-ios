//
//  EngagementStore.swift
//  NewsListenApp
//
//  継続（ストリーク・ダッシュボード・実績の既読）の application。音は鳴らさない（鳴らすのは presentation）。
//  アプリの寿命で生き、主体をまたぐので、書き込みは取得の前に捕捉した主体の照合を通す（ios-contract-20.16）。
//

import Foundation
import Combine

/// `refreshStreak()` の結果（ios-cmd-learning-05 の receipt）。
struct StreakRefreshReceipt: Equatable {
    /// 取得の前の値より日数が増えたか。初回・失敗や 404 の後・主体が違うときは false。
    let increased: Bool
}

@MainActor
final class EngagementStore: ObservableObject {
    /// 未取得・未提供・失敗のとき nil。主体の離脱では消さない（次の主体の取得で置き換わる）。
    @Published private(set) var streak: ListeningStreakStatus?
    /// 直近の取得が 404 以外で失敗したか。
    @Published private(set) var streakLoadFailed = false

    private let gateway: LearningGateway
    private let seenStore: (read: () -> Set<String>, write: (Set<String>) -> Void)
    private let subjectStamp: () -> SubjectStamp
    private let isCurrentSubject: (SubjectStamp) -> Bool

    init(
        gateway: LearningGateway,
        seenStore: (read: () -> Set<String>, write: (Set<String>) -> Void),
        subjectStamp: @escaping () -> SubjectStamp,
        isCurrentSubject: @escaping (SubjectStamp) -> Bool
    ) {
        self.gateway = gateway
        self.seenStore = seenStore
        self.subjectStamp = subjectStamp
        self.isCurrentSubject = isCurrentSubject
    }

    /// 呼出ごとに取得する。読み取りだけで、保持も書込もしない。
    func dashboard() async throws -> LearningDashboardSummary {
        try await gateway.fetchDashboard()
    }

    /// 保存を読むだけで書かない。
    func unseenAchievements(in dashboard: LearningDashboardSummary) -> [Achievement] {
        AchievementCatalog.unseen(dashboard.achievements, seenIds: seenStore.read())
    }

    /// 空なら書かない。集合は持ち越さず、呼出のたびに保存を読んで union を書く。
    func markAchievementsSeen(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        seenStore.write(seenStore.read().union(ids))
    }

    /// 同時の呼出は束ねない。各呼出が自分の取得前の値で判定し、応答の順に上書きする。
    @discardableResult
    func refreshStreak() async -> StreakRefreshReceipt {
        let stamp = subjectStamp()
        let previous = streak
        do {
            let status = try await gateway.fetchStreak()
            guard isCurrentSubject(stamp) else { return StreakRefreshReceipt(increased: false) }
            streak = status
            streakLoadFailed = false
            return StreakRefreshReceipt(increased: ListeningStreakStatus.didIncrease(from: previous, to: status))
        } catch ApiFailure.notFound(subject: .streak) {
            guard isCurrentSubject(stamp) else { return StreakRefreshReceipt(increased: false) }
            streak = nil
            streakLoadFailed = false
            return StreakRefreshReceipt(increased: false)
        } catch {
            guard isCurrentSubject(stamp) else { return StreakRefreshReceipt(increased: false) }
            streak = nil
            streakLoadFailed = true
            return StreakRefreshReceipt(increased: false)
        }
    }
}
