//
//  APIEndpoint.swift
//  NewsListenApp
//
//  バックエンド API のエンドポイント定義（パスと HTTP メソッド）。
//

import Foundation

enum APIEndpoint {
    case feed
    case starArticle(id: String)
    case dismissArticle(id: String)
    case podcasts
    case sources
    case addSource
    case removeSource(url: String)

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

    var method: String {
        switch self {
        case .feed, .podcasts, .sources: return "GET"
        case .starArticle, .dismissArticle, .addSource: return "POST"
        case .removeSource: return "DELETE"
        }
    }
}
