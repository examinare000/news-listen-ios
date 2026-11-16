//
//  Episode.swift
//  NewsListenApp
//
//  エピソードの種別（再生できる／生成中／失敗）。種別の判別は adapter が行う。
//

import Foundation

/// 再生できるエピソード。
struct PlayableEpisode: Equatable {
    let content: EpisodeContent
    let audioUrl: String
    /// サーバーが保持する最後の再生位置（秒）。
    let serverPosition: Double
    /// `serverPosition` をサーバーが記録した時刻（ミリ秒）。応答に無ければ nil（最も古い扱い）。
    let serverRecordedAt: Date?

    /// 空の音声 URL は再生できないため nil を返す。
    init?(content: EpisodeContent, audioUrl: String, serverPosition: Double, serverRecordedAt: Date? = nil) {
        guard !audioUrl.isEmpty else { return nil }
        self.content = content
        self.audioUrl = audioUrl
        self.serverPosition = serverPosition
        self.serverRecordedAt = serverRecordedAt
    }
}

/// 生成中のエピソード。
struct GeneratingEpisode: Equatable {
    let content: EpisodeContent
}

/// 生成に失敗した（または状態が矛盾している）エピソード。
struct FailedEpisode: Equatable {
    let content: EpisodeContent
    /// サーバーが返した失敗の詳細。無ければ nil（既定文言は持たない）。
    let reportedMessage: String?
}

enum Episode: Equatable, Identifiable {
    case playable(PlayableEpisode)
    case generating(GeneratingEpisode)
    case failed(FailedEpisode)

    var content: EpisodeContent {
        switch self {
        case .playable(let episode): return episode.content
        case .generating(let episode): return episode.content
        case .failed(let episode): return episode.content
        }
    }

    var id: String { content.id }

    var isPlayable: Bool {
        if case .playable = self { return true }
        return false
    }
}
