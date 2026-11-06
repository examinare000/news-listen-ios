//
//  SourceSubscriptions.swift
//  NewsListenApp
//
//  RSS ソースの一覧・追加・更新・削除と、おすすめの取得・購読・編集の可否（application）。
//  一覧の正本はサーバー。直前の command の応答だけを次の `list()` のために持ち越す。
//

import Foundation

/// 登録済みの RSS ソース 1 件。
struct SourceEntry: Identifiable, Equatable {
    let name: String
    let url: String
    var id: String { url }
}

/// おすすめサイト 1 件。カテゴリは正規化済み。
struct FeaturedSiteCard: Identifiable, Equatable {
    let id: String
    let name: String
    let url: String
    let thumbnailURL: String?
    let description: String?
    let category: FeaturedCategory
}

/// 通信の入口（port）。adapter が組む。
struct SourcesGateway {
    let list: () async throws -> [SourceEntry]
    let add: (String, String) async throws -> [SourceEntry]
    let update: (String, String, String) async throws -> [SourceEntry]
    let remove: (String) async throws -> Void
    let featured: () async throws -> [FeaturedSiteCard]
}

@MainActor
final class SourceSubscriptions {
    private let gateway: SourcesGateway
    /// 直前の追加・更新・購読の応答の一覧。次の `list()` が通信せずに返して手放す。
    private var carriedList: [SourceEntry]?

    init(gateway: SourcesGateway) {
        self.gateway = gateway
    }

    func list() async throws -> [SourceEntry] {
        if let carried = carriedList {
            carriedList = nil
            return carried
        }
        return try await gateway.list()
    }

    func featured() async throws -> [(category: FeaturedCategory, sites: [FeaturedSiteCard])] {
        let sites = try await gateway.featured()
        return FeaturedCategory.grouped(sites, category: { $0.category }).map { (category: $0.category, sites: $0.items) }
    }

    func add(name: String, url: String) async throws {
        carriedList = try await gateway.add(name, url)
    }

    func update(oldURL: String, name: String, url: String) async throws {
        carriedList = try await gateway.update(oldURL, name, url)
    }

    func remove(url: String) async throws {
        try await gateway.remove(url)
        carriedList = nil
    }

    func subscribe(_ site: FeaturedSiteCard) async throws {
        do {
            carriedList = try await gateway.add(site.name, site.url)
        } catch ApiFailure.conflict {
            // 既に登録済み。望みどおりの状態なので成功として扱い、持っている一覧には触らない。
        }
    }

    func canEdit(role: Role) -> Bool {
        role.isAdmin
    }
}
