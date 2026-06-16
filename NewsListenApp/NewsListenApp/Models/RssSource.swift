//
//  RssSource.swift
//  NewsListenApp
//
//  バックエンド RssSourcesResponse（sources: [{name, url}]）に対応する Codable モデル。
//

import Foundation

/// 登録済みの RSS 配信元1件。バックエンドの `RssSourcesResponse` 内の要素に対応する。
struct RssSource: Codable, Identifiable {
    /// 配信元の表示名。
    let name: String
    /// RSS フィードの URL。一意キーも兼ねる。
    let url: String
    /// `url` を一意キーとして Identifiable に利用する（バックエンドは id を持たない）。
    var id: String { url }
}

/// `/settings/sources` エンドポイントのレスポンス。登録済み RSS 配信元の一覧を保持する。
struct RssSourcesResponse: Codable {
    /// 登録済みの RSS 配信元一覧。
    let sources: [RssSource]
}
