//
//  EpisodeCatalog.swift
//  NewsListenApp
//
//  エピソード一覧の保持と更新。一覧の取得は port（`CatalogGateway`）の向こうにある。
//

import Foundation
import Combine

/// 一覧の取得 port。実体は adapter が組む。
struct CatalogGateway {
    let fetchEpisodes: () async throws -> [Episode]
}

@MainActor
final class EpisodeCatalog: ObservableObject {
    @Published private(set) var rows: [EpisodeRow] = []

    private var episodes: [Episode] = []
    private let gateway: CatalogGateway

    init(gateway: CatalogGateway) {
        self.gateway = gateway
    }

    /// 取得に成功したときだけ保持を置き換える。失敗は error をそのまま投げ、保持を変えない。
    func reload() async throws {
        let fetched = try await gateway.fetchEpisodes()
        episodes = fetched
        rows = fetched.map(Self.row(from:))
    }

    func episode(id: String) -> Episode? {
        episodes.first { $0.id == id }
    }

    /// 位置の保存の応答で、同じ id の要素を置き換える（後勝ち）。保持に無ければ何もしない。
    func applyPositionSaved(_ episode: Episode) {
        guard let index = episodes.firstIndex(where: { $0.id == episode.id }) else { return }
        episodes[index] = episode
        rows = episodes.map(Self.row(from:))
    }

    private static func row(from episode: Episode) -> EpisodeRow {
        let content = episode.content
        return EpisodeRow(
            episodeId: content.id,
            title: content.displayTitle,
            difficulty: content.difficulty,
            durationSeconds: content.durationSeconds,
            createdAt: content.createdAt,
            badge: badge(for: episode)
        )
    }

    private static func badge(for episode: Episode) -> EpisodeBadge {
        switch episode {
        case .playable: return .none
        case .generating: return .generating
        case .failed(let failed): return .failed(detail: failed.reportedMessage ?? "")
        }
    }
}
