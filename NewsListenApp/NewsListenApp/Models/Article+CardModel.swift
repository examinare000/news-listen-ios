//
//  Article+CardModel.swift
//  NewsListenApp
//
//  通信の `Article` をカードのリードモデルへ写す adapter。
//

import Foundation

extension Article {
    func toCardModel() -> ArticleCardModel {
        ArticleCardModel(id: id, title: title, url: url, source: source, score: score, publishedAt: publishedAt)
    }
}
