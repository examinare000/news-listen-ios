//
//  APIEndpoint.swift
//  NewsListenApp
//
//  バックエンド API のエンドポイント定義（パスと HTTP メソッド）。
//

import Foundation

/// バックエンド API のエンドポイント定義。各ケースが URL パスと HTTP メソッドを表す。
enum APIEndpoint {
    /// フィード記事一覧の取得。
    case feed
    /// 記事を Star する。
    case starArticle(id: String)
    /// 記事を Dismiss する。
    case dismissArticle(id: String)
    /// Podcast 一覧の取得。
    case podcasts
    /// 登録済み RSS 配信元一覧の取得。
    case sources
    /// RSS 配信元の追加。
    case addSource
    /// 指定 URL の RSS 配信元の削除。
    case removeSource(url: String)

    /// エンドポイントへの相対パス（baseURL に連結して使う）。
    var path: String {
        switch self {
        case .feed: return "/feed"
        case .starArticle(let id): return "/articles/\(id)/star"
        case .dismissArticle(let id): return "/articles/\(id)/dismiss"
        case .podcasts: return "/podcasts"
        case .sources, .addSource: return "/settings/sources"
        case .removeSource: return "/settings/sources"
        }
    }

    /// このエンドポイントで使用する HTTP メソッド（GET / POST / DELETE）。
    var method: String {
        switch self {
        case .feed, .podcasts, .sources: return "GET"
        case .starArticle, .dismissArticle, .addSource: return "POST"
        case .removeSource: return "DELETE"
        }
    }
}
