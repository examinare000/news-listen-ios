//
//  StarredArticles.swift
//  NewsListenApp
//
//  Star 済み記事の一覧と Star 解除（application）。状態は持たない。
//

import Foundation

@MainActor
final class StarredArticles {
    private let gateway: CurationGateway

    init(gateway: CurationGateway) {
        self.gateway = gateway
    }

    func list() async throws -> [ArticleCardModel] {
        try await gateway.fetchStarred()
    }

    func unstar(articleId: String) async throws {
        do {
            try await gateway.unstar(articleId)
        } catch ApiFailure.notFound(subject: .star) {
            // 既に Star が無い。望みどおりの状態なので成功として扱う。
        }
    }
}
