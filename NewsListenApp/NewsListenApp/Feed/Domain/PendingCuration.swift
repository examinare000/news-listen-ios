//
//  PendingCuration.swift
//  NewsListenApp
//
//  取り消し猶予の中にある Star / Dismiss の形と、取り消したときの戻し位置の規則（ios-rule-curation-01）。
//

import Foundation

/// 猶予中の Star / Dismiss 1 件。
struct PendingCuration: Equatable {
    enum Kind: Equatable {
        case star(DifficultyLevel?)
        case dismiss
    }

    let kind: Kind
    let articleId: String
    let originalIndex: Int
}

extension PendingCuration {
    /// 除去した要素を元の位置へ戻した配列。一覧が短くなっていれば末尾に入れる。
    func restore<Element>(_ element: Element, into list: [Element]) -> [Element] {
        var restored = list
        restored.insert(element, at: min(originalIndex, list.count))
        return restored
    }
}
