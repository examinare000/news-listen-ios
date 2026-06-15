//
//  Podcast.swift
//  NewsListenApp
//
//  バックエンド PodcastResponse / PodcastListResponse に対応する Codable モデル。
//

import Foundation

struct Podcast: Codable, Identifiable {
    let id: String
    let type: String
    let articleIds: [String]
    let difficulty: String
    let audioUrl: String
    let japaneseIntroText: String
    let durationSeconds: Int
    let createdAt: String

    // バックエンドの snake_case フィールドに対応する。
    enum CodingKeys: String, CodingKey {
        case id, type, difficulty
        case articleIds = "article_ids"
        case audioUrl = "audio_url"
        case japaneseIntroText = "japanese_intro_text"
        case durationSeconds = "duration_seconds"
        case createdAt = "created_at"
    }

    var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct PodcastListResponse: Codable {
    let podcasts: [Podcast]
}
