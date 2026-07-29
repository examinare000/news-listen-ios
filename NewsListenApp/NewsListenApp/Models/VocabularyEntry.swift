//
//  VocabularyEntry.swift
//  NewsListenApp
//
//  エピソード語彙グロッサリ（ADR-069）の公開 API モデル。
//

import Foundation

/// Podcast 本編から抽出された学習語彙。
struct VocabularyEntry: Codable, Equatable {
    /// 英語用語（原形）。
    let term: String
    /// 日本語の意味説明。
    let meaningJa: String
    /// 用語を含む本編由来の英文。
    let example: String

    enum CodingKeys: String, CodingKey {
        case term
        case meaningJa = "meaning_ja"
        case example
    }
}
