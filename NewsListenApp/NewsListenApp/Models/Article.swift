//
//  Article.swift
//  NewsListenApp
//
//  バックエンド ArticleResponse / FeedResponse に対応する Codable モデル。
//

import Foundation

/// フィードに表示する記事1件。バックエンドの `ArticleResponse` に対応する。
struct Article: Codable, Identifiable {
    /// 記事の一意な識別子。
    let id: String
    /// 記事タイトル。
    let title: String
    /// 記事本文の URL（タップ時に Safari で開く）。
    let url: String
    /// 配信元（RSS ソース名）。
    let source: String
    /// ユーザーへの関連度スコア（0.0〜1.0）。
    let score: Double
    /// 公開日時（ISO 8601 文字列）。
    let publishedAt: String

    /// バックエンドは snake_case（published_at）で返すため CodingKeys で対応する。
    enum CodingKeys: String, CodingKey {
        case id, title, url, source, score
        case publishedAt = "published_at"
    }
}

/// `/feed` エンドポイントのレスポンス。指定日の記事一覧を保持する。
struct FeedResponse: Codable {
    /// 取得した記事一覧。
    let articles: [Article]
    /// 対象日（YYYY-MM-DD 形式の文字列）。
    let date: String
}
