//
//  Preferences+Domain.swift
//  NewsListenApp
//
//  通信のデータモデル `Preferences` から application の `PreferenceValues` への変換（adapter）。
//  値域の外の値は捨てて nil にする。
//

import Foundation

extension Preferences {
    func toPreferenceValues() -> PreferenceValues {
        PreferenceValues(
            difficulty: defaultDifficulty.flatMap { DifficultyLevel(code: $0) },
            playbackSpeed: defaultPlaybackSpeed.flatMap { PlaybackConstants.speeds.contains(Float($0)) ? $0 : nil },
            weeklyGoal: weeklyGoalEpisodes.flatMap { WeeklyGoalTarget(episodes: $0) }
        )
    }
}
