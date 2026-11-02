//
//  ArticleCardModel.swift
//  NewsListenApp
//
//  フィード・Star 一覧のカードに出す記事（リードモデル）。通信のデータモデルは持たない。
//

import Foundation

struct ArticleCardModel: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String
    let source: String
    let score: Double
    let publishedAt: String
}
