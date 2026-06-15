//
//  RssSource.swift
//  NewsListenApp
//
//  バックエンド RssSourcesResponse（sources: [{name, url}]）に対応する Codable モデル。
//

import Foundation

struct RssSource: Codable, Identifiable {
    let name: String
    let url: String
    // url を一意キーとして Identifiable に利用する（バックエンドは id を持たない）。
    var id: String { url }
}

struct RssSourcesResponse: Codable {
    let sources: [RssSource]
}
