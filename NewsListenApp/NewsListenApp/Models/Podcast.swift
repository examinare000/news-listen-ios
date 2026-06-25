//
//  Podcast.swift
//  NewsListenApp
//
//  バックエンド PodcastResponse / PodcastListResponse に対応する Codable モデル。
//

import Foundation

/// 生成済みの Podcast 1件。バックエンドの `PodcastResponse` に対応する。
struct Podcast: Codable, Identifiable {
    /// Podcast の一意な識別子。
    let id: String
    /// Podcast の種別（例: daily など）。
    let type: String
    /// この Podcast の元になった記事 ID の一覧。
    let articleIds: [String]
    /// 難易度区分（例: `toeic_900`）。表示時は `PodcastRowView` でラベルへ変換する。
    let difficulty: String
    /// 音声ファイルの URL（AVPlayer で再生する）。
    let audioUrl: String
    /// 再生前に提示する日本語イントロ要約。
    let japaneseIntroText: String
    /// 音声の長さ（秒）。
    let durationSeconds: Int
    /// 生成日時（ISO 8601 文字列）。
    let createdAt: String
    /// 生成ステータス（`"processing"` | `"completed"` | `"failed"` | `"partial_failed"`）。
    /// バックエンドが常時返却するため非 Optional。表示層での enum 変換は ADR-021 に従い iOS#15 で対応。
    let status: String
    /// 失敗時のエラー詳細。`status` が `"failed"` または `"partial_failed"` のときのみ非 nil。
    let errorMessage: String?

    /// バックエンドの snake_case フィールドに対応する。
    enum CodingKeys: String, CodingKey {
        case id, type, difficulty, status
        case articleIds = "article_ids"
        case audioUrl = "audio_url"
        case japaneseIntroText = "japanese_intro_text"
        case durationSeconds = "duration_seconds"
        case createdAt = "created_at"
        case errorMessage = "error_message"
    }

    /// `durationSeconds` を `分:秒`（例: `3:05`）の表示用文字列に整形する。
    var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// `/podcasts` エンドポイントのレスポンス。Podcast 一覧を保持する。
struct PodcastListResponse: Codable {
    /// 取得した Podcast 一覧。
    let podcasts: [Podcast]
}
