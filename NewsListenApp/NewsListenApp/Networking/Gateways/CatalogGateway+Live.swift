//
//  CatalogGateway+Live.swift
//  NewsListenApp
//
//  一覧の取得 port を `APIClient` から組む adapter。応答は `Episode` に変換して返す。
//

import Foundation

extension CatalogGateway {
    static func live(apiClient: APIClient) -> CatalogGateway {
        CatalogGateway(fetchEpisodes: {
            try await apiClient.fetchPodcasts().podcasts.map { $0.toEpisode() }
        })
    }
}
