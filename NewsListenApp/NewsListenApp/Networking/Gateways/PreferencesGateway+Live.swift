//
//  PreferencesGateway+Live.swift
//  NewsListenApp
//
//  設定の取得・更新の port を `APIClient` から組む adapter。応答は `PreferenceValues` に変換して返す。
//

import Foundation

extension PreferencesGateway {
    /// - Parameter client: 呼出のたびに現在の `APIClient` を返す。`AppState.apiClient` は保存トークンから
    ///   作る computed なので、構築時に固定できない。nil のとき `update` は何もせず成功、`fetch` は値なし。
    static func live(client: @escaping () -> APIClient?) -> PreferencesGateway {
        PreferencesGateway(
            fetch: { @MainActor in
                guard let client = client() else {
                    return PreferenceValues(difficulty: nil, playbackSpeed: nil, weeklyGoal: nil)
                }
                return try await client.fetchPreferences().toPreferenceValues()
            },
            update: { @MainActor change in
                guard let client = client() else { return }
                switch change {
                case .difficulty(let level):
                    _ = try await client.updatePreferences(defaultDifficulty: level.code, defaultPlaybackSpeed: nil)
                case .playbackSpeed(let speed):
                    _ = try await client.updatePreferences(defaultDifficulty: nil, defaultPlaybackSpeed: speed)
                case .weeklyGoal(let goal):
                    _ = try await client.updatePreferences(defaultDifficulty: nil, defaultPlaybackSpeed: nil, weeklyGoalEpisodes: goal.episodes)
                }
            }
        )
    }
}
