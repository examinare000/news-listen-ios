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
    /// 文字起こしの発話一覧。旧エピソードや未デプロイ環境ではキー自体が欠落、または `null` になるため
    /// Optional にして後方互換を保つ（issue #162）。
    let segments: [TranscriptSegment]?
    /// エピソード語彙。旧エピソードではキー欠落または `null` のため Optional。
    private(set) var vocabulary: [VocabularyEntry]? = nil
    /// 公開用クイズ設問。正解キーは API 契約上含まれない。
    private(set) var quiz: [QuizQuestion]? = nil
    /// この Podcast の元になった出典記事一覧。旧エピソードや未デプロイ環境ではキー欠落・`null` の
    /// ため Optional にして後方互換を保つ（ADR-095 / issue #240）。
    private(set) var sourceArticles: [PodcastSourceArticle]? = nil
    /// 出典区分（`"featured"` | `"user"` | `"unknown"`）。`"featured"` のときだけ CC BY-SA 4.0 表示を
    /// 出す（ADR-095、fail-closed）。旧エピソードや未デプロイ環境ではキー欠落・`null` のため Optional。
    private(set) var sourceKind: String? = nil
    /// `playback_position_seconds` をサーバーが記録した時刻（ISO 8601 文字列）。旧応答ではキー欠落・`null`。
    private(set) var playbackPositionRecordedAt: String? = nil

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
        case playbackPositionRecordedAt = "playback_position_recorded_at"
        case segments, vocabulary, quiz
        case sourceArticles = "source_articles"
        case sourceKind = "source_kind"
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
        self.segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments)
        self.vocabulary = try container.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary)
        self.quiz = try container.decodeIfPresent([QuizQuestion].self, forKey: .quiz)
        self.sourceArticles = try container.decodeIfPresent([PodcastSourceArticle].self, forKey: .sourceArticles)
        self.sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind)
        // 読めない値は nil にして、位置の時刻のために一覧全体の decode を失敗させない。
        self.playbackPositionRecordedAt = (try? container.decodeIfPresent(String.self, forKey: .playbackPositionRecordedAt)) ?? nil
    }
}

/// `/podcasts` エンドポイントのレスポンス。Podcast 一覧を保持する。
struct PodcastListResponse: Codable {
    /// 取得した Podcast 一覧。
    let podcasts: [Podcast]
}
