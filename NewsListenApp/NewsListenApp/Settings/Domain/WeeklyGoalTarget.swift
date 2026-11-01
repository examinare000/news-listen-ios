//
//  WeeklyGoalTarget.swift
//  NewsListenApp
//
//  週の目標（完聴本数）の値域と既定値の正本（ios-rule-prefs-02）。
//

import Foundation

/// 週の目標。3 / 5 / 7 / 10 以外は作れない。
struct WeeklyGoalTarget: Equatable, Hashable {
    let episodes: Int

    /// 値域のどれかでなければ nil。
    init?(episodes: Int) {
        guard Self.values.contains(episodes) else { return nil }
        self.episodes = episodes
    }

    private init(checked episodes: Int) {
        self.episodes = episodes
    }

    private static let values = [3, 5, 7, 10]

    static let allCases: [WeeklyGoalTarget] = values.map { WeeklyGoalTarget(checked: $0) }

    static let `default`: WeeklyGoalTarget = WeeklyGoalTarget(checked: 3)
}
