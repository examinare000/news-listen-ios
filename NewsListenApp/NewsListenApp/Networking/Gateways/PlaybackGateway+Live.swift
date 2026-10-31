//
//  PlaybackGateway+Live.swift
//  NewsListenApp
//
//  再生の gateway（closure）を `APIClient` から組む adapter。応答は `Episode` に変換して返す。
//

import Foundation

/// 再生の gateway を組む adapter の名前空間（case を持たない）。
enum PlaybackGateway {
    typealias Closures = (
        fetchEpisode: (String) async throws -> Episode,
        updatePosition: (_ id: String, _ seconds: Double) async throws -> Episode,
        markCompleted: (String) async throws -> Void,
        downloadAudio: (URL) async throws -> Data
    )

    /// - Parameter onPodcastUpdated: 位置の保存の応答（`Podcast`）を、`Episode` に変換する前に受け取る。
    ///   一覧の同じ行を置き換えるために使う。
    static func live(
        apiClient: APIClient,
        onPodcastUpdated: (@MainActor (Podcast) -> Void)? = nil
    ) -> Closures {
        (
            fetchEpisode: { id in try await apiClient.fetchPodcast(id: id).toEpisode() },
            updatePosition: { id, seconds in
                let podcast = try await apiClient.updatePlaybackPosition(podcastId: id, positionSeconds: seconds)
                await onPodcastUpdated?(podcast)
                return podcast.toEpisode()
            },
            markCompleted: { id in try await apiClient.markCompleted(id: id) },
            downloadAudio: { url in try await apiClient.downloadAudio(from: url) }
        )
    }
}
