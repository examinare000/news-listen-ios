//
//  FeaturedCategory.swift
//  NewsListenApp
//
//  Featured sites のカテゴリ定義と処理ユーティリティ。
//  Backend API の category フィールド（tech, business, sports, entertainment, culture）に対応。
//

import Foundation

/// Featured sites のカテゴリ（5値の列挙型）。表示順を定義（allCases の順序）。
enum FeaturedCategory: String, CaseIterable {
    /// テクノロジー。デフォルトカテゴリ（未知値/nil は自動的にこれに正規化）。
    case tech
    /// ビジネス。
    case business
    /// スポーツ。
    case sports
    /// 芸能。
    case entertainment
    /// カルチャー。
    case culture

    /// カテゴリの日本語ラベル。表示順に対応。
    var label: String {
        switch self {
        case .tech:
            return "テクノロジー"
        case .business:
            return "ビジネス"
        case .sports:
            return "スポーツ"
        case .entertainment:
            return "芸能"
        case .culture:
            return "カルチャー"
        }
    }

    /// 与えられた category 値を検証し、無効な場合は `.tech` へ正規化する。
    /// category が nil / 未知値の場合、`.tech` へ統一してフォールバック。
    /// - Parameter value: バックエンドから受け取った category 文字列（任意）。
    /// - Returns: 正規化されたカテゴリ。
    static func normalize(_ value: String?) -> FeaturedCategory {
        guard let value, let category = FeaturedCategory(rawValue: value) else {
            return .tech
        }
        return category
    }

    /// FeaturedSite 配列をカテゴリでグループ化。
    /// 各カテゴリの配列は表示順（allCases）に従い、0件のカテゴリも含まれる（空配列）。
    /// サーバから返された sites の順序は各カテゴリ内で維持される。
    /// - Parameter items: グループ化対象の FeaturedSite 配列。
    /// - Returns: カテゴリをキーとした辞書（全カテゴリ5値を含む。値は空可）。
    static func groupByCategoryInOrder(_ items: [FeaturedSite]) -> [FeaturedCategory: [FeaturedSite]] {
        var result: [FeaturedCategory: [FeaturedSite]] = [:]
        for category in allCases {
            result[category] = []
        }

        for item in items {
            let normalized = normalize(item.category)
            result[normalized]?.append(item)
        }

        return result
    }
}
