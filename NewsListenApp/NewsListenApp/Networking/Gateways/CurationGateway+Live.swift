//
//  CurationGateway+Live.swift
//  NewsListenApp
//
//  フィード・Star・残り回数の port を `APIClient` から組む adapter。応答は domain / リードモデルに変換して返す。
//

import Foundation

extension CurationGateway {
    /// - Parameter client: 呼出のたびに現在の `APIClient` を返す。nil のとき書込みは何もせず成功、
    ///   一覧は空、残り回数は値なし。
    static func live(client: @escaping @MainActor () -> APIClient?) -> CurationGateway {
        CurationGateway(
            fetchFeed: { @MainActor in
                guard let client = client() else { return [] }
                return try await client.fetchFeed().articles.map { $0.toCardModel() }
            },
            star: { @MainActor id, difficulty in
                guard let client = client() else { return }
                try await client.starArticle(id: id, difficulty: difficulty?.code)
            },
            dismiss: { @MainActor id in
                guard let client = client() else { return }
                try await client.dismissArticle(id: id)
            },
            fetchStarred: { @MainActor in
                guard let client = client() else { return [] }
                return try await client.fetchStarredArticles().articles.map { $0.toCardModel() }
            },
            unstar: { @MainActor id in
                guard let client = client() else { return }
                try await client.unstarArticle(id: id)
            },
            fetchAllowance: { @MainActor in
                guard let client = client() else { return nil }
                return try await client.fetchGenerationQuota().toAllowance()
            }
        )
    }
}
