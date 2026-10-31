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

    static func live(apiClient: APIClient) -> Closures {
        (
            fetchEpisode: { id in try await apiClient.fetchPodcast(id: id).toEpisode() },
            updatePosition: { id, seconds in
                try await apiClient.updatePlaybackPosition(podcastId: id, positionSeconds: seconds).toEpisode()
            },
            markCompleted: { id in try await apiClient.markCompleted(id: id) },
            downloadAudio: { url in try await apiClient.downloadAudio(from: url) }
        )
    }
}
