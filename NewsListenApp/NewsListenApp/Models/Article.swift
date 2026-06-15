//
//  Article.swift
//  NewsListenApp
//
//  バックエンド ArticleResponse / FeedResponse に対応する Codable モデル。
//

import Foundation

struct Article: Codable, Identifiable {
    let id: String
    let title: String
    let url: String
    let source: String
    let score: Double
    let publishedAt: String

    // バックエンドは snake_case（published_at）で返すため CodingKeys で対応する。
    enum CodingKeys: String, CodingKey {
        case id, title, url, source, score
        case publishedAt = "published_at"
    }
}

struct FeedResponse: Codable {
    let articles: [Article]
    let date: String
}
