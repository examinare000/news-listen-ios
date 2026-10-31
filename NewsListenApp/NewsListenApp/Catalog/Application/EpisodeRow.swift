//
//  EpisodeRow.swift
//  NewsListenApp
//
//  一覧の行のリードモデル。`struct`・`let` だけで持つ。
//

import Foundation

enum EpisodeBadge: Equatable {
    case none
    case generating
    case failed(detail: String)
}

struct EpisodeRow: Identifiable, Equatable {
    let episodeId: String
    var id: String { episodeId }
    let title: String
    let difficulty: String
    let durationSeconds: Int
    let createdAt: String
    let badge: EpisodeBadge
}
