//
//  FeaturedCategory.swift
//  NewsListenApp
//
//  おすすめサイトのカテゴリの値域・正規化・並べ方の正本（ios-rule-sources-01）。
//  Backend API の category フィールド（tech, business, sports, entertainment, culture）に対応。
//

import Foundation

/// おすすめサイトのカテゴリ。5 値のどれかでなければ作れない。表示順は `allCases` の順。
struct FeaturedCategory: Hashable {
    let rawValue: String

    /// 5 値のどれかでなければ nil。
    init?(rawValue: String) {
        guard Self.values.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(checked rawValue: String) {
        self.rawValue = rawValue
    }

    private static let values = ["tech", "business", "sports", "entertainment", "culture"]

    /// テクノロジー。既定のカテゴリ（欠落・未知値は `normalize` がこれに寄せる）。
    static let tech = FeaturedCategory(checked: "tech")
    static let business = FeaturedCategory(checked: "business")
    static let sports = FeaturedCategory(checked: "sports")
    static let entertainment = FeaturedCategory(checked: "entertainment")
    static let culture = FeaturedCategory(checked: "culture")

    /// 表示順。
    static let allCases: [FeaturedCategory] = values.map { FeaturedCategory(checked: $0) }

    /// カテゴリの日本語ラベル。
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
        default:
            return "カルチャー"
        }
    }

    /// 5 値の完全一致はその値、nil・未知値・`"TECH"` などは `.tech`。
    /// - Parameter value: バックエンドから受け取った category 文字列（任意）。
    static func normalize(_ value: String?) -> FeaturedCategory {
        guard let value, let category = FeaturedCategory(rawValue: value) else {
            return .tech
        }
        return category
    }

    /// 要素を表示順にカテゴリ別へ束ねる。要素を持たないカテゴリは返さず、カテゴリ内は入力順を保つ。
    /// - Parameters:
    ///   - items: 束ねる要素。
    ///   - category: 要素のカテゴリ。
    static func grouped<Item>(_ items: [Item], category: (Item) -> FeaturedCategory) -> [(category: FeaturedCategory, items: [Item])] {
        allCases.compactMap { current in
            let members = items.filter { category($0) == current }
            return members.isEmpty ? nil : (category: current, items: members)
        }
    }
}
