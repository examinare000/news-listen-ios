//
//  IdentifiableURL.swift
//  NewsListenApp
//
//  URL を `sheet(item:)` で提示するための `Identifiable` ラッパー。
//  FeedView / StarredView など、記事タップでアプリ内 Safari を開く複数の画面から共有する。
//

import Foundation

/// URL を `sheet(item:)` で提示するための `Identifiable` ラッパー。
struct IdentifiableURL: Identifiable {
    /// 提示対象の URL。
    let url: URL
    /// URL 文字列を一意な識別子とする。
    var id: String { url.absoluteString }
}
