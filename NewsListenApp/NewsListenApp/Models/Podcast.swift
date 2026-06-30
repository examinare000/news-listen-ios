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
    /// ニュース内容を1センテンスに要約した日本語タイトル。
    /// バックエンドが未デプロイまたは既存データの場合は空文字になる（後方互換）。
    let title: String
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
    /// 最後の再生位置（秒）。サーバで同期・復元される。ない場合は 0。
    let playbackPositionSeconds: Double

    /// バックエンドの snake_case フィールドに対応する。
    enum CodingKeys: String, CodingKey {
        case id, type, difficulty, status
        case articleIds = "article_ids"
        case audioUrl = "audio_url"
        case title
        case japaneseIntroText = "japanese_intro_text"
        case durationSeconds = "duration_seconds"
        case createdAt = "created_at"
        case errorMessage = "error_message"
        case playbackPositionSeconds = "playback_position_seconds"
    }

    /// `durationSeconds` を `分:秒`（例: `3:05`）の表示用文字列に整形する。
    var formattedDuration: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Decodable
// WHY: カスタム init(from:) を本体ではなく extension に置くことで、合成される
//      メンバーワイズ初期化子（テストやプレビューが Podcast(id:...) を直接生成する）を維持する。
//      本体に init を書くとメンバーワイズ初期化子が抑止されコンパイルできなくなる。
extension Podcast {
    /// Codable デコード時のカスタマイズ。
    /// `playback_position_seconds` が欠如する場合は 0 を既定値として使う。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decode(String.self, forKey: .type)
        self.articleIds = try container.decode([String].self, forKey: .articleIds)
        self.difficulty = try container.decode(String.self, forKey: .difficulty)
        self.audioUrl = try container.decode(String.self, forKey: .audioUrl)
        // title は新規フィールド。既存レスポンスや未デプロイ環境でキーが欠落しても空文字で後方互換を保つ。
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.japaneseIntroText = try container.decode(String.self, forKey: .japaneseIntroText)
        self.durationSeconds = try container.decode(Int.self, forKey: .durationSeconds)
        self.createdAt = try container.decode(String.self, forKey: .createdAt)
        self.status = try container.decode(String.self, forKey: .status)
        self.errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        self.playbackPositionSeconds = try container.decodeIfPresent(Double.self, forKey: .playbackPositionSeconds) ?? 0.0
    }
}

// MARK: - Display

extension Podcast {
    /// 表示用タイトル文字列。3段フォールバック（title → japaneseIntroText → デフォルト文字列）。
    /// - `title`（trim後）が非空ならそれを返す。
    /// - `japaneseIntroText`（trim後）が非空ならそれを返す。
    /// - 両方空の場合は `"ニュースポッドキャスト"` を返す（空欄は決して表示しない）。
    /// - Note: ロック画面 (`NowPlayingInfo`) とリスト行 (`PodcastRowView`) の両方がこのプロパティを経由することで
    ///         最終デフォルトを含むフォールバック階層を一か所に集約する。
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let trimmedIntro = japaneseIntroText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedIntro.isEmpty ? "ニュースポッドキャスト" : trimmedIntro
    }
}

/// `/podcasts` エンドポイントのレスポンス。Podcast 一覧を保持する。
struct PodcastListResponse: Codable {
    /// 取得した Podcast 一覧。
    let podcasts: [Podcast]
}
