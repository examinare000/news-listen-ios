//
//  Podcast.swift
//  NewsListenApp
//
//  バックエンド PodcastResponse / PodcastListResponse に対応する Codable モデル。
//

import Foundation

/// トランスクリプトの1発話。バックエンドの `segments[]` 要素に対応する（issue #162）。
struct TranscriptSegment: Codable, Equatable {
    /// 話者ラベル（例: `"A"` / `"B"`）。
    let speaker: String
    /// その発話のテキスト。
    let text: String
    /// 役割ラベル（`"fact"` / `"commentary"`）。ADR-094 第一段階（issue #237）。
    /// バックエンドは常にキーを返す（未設定時 null）が、`var` + 既定値にして
    /// 既存の `TranscriptSegment(speaker:text:)` 呼び出し（memberwise init）を維持する。
    var role: String? = nil
}

/// Podcast の出典記事1件。バックエンドの `source_articles[]` 要素に対応する（ADR-095 / issue #240）。
/// 4キーすべて必須（要素内のキー欠落は `Podcast` 全体のデコード失敗として扱い、部分救済しない）。
struct PodcastSourceArticle: Codable, Equatable {
    /// 出典記事の ID。
    let articleId: String
    /// 出典記事のタイトル。
    let title: String
    /// 出典記事の URL（文字列のまま保持し、表示直前に `linkURL` で検証する）。
    let url: String
    /// 出典元の名称（例: `"hackernews"`）。
    let source: String

    enum CodingKeys: String, CodingKey {
        case articleId = "article_id"
        case title, url, source
    }

    /// `url` を検証済みの `URL` として返す。`http` / `https` スキームのときだけ非 nil。
    /// - WHY: `Link` は任意スキームを `openURL` に渡すため、バックエンド経由の外部由来文字列を
    ///        無検証で開かない（入力検証）。
    var linkURL: URL? {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased() else { return nil }
        return (scheme == "http" || scheme == "https") ? url : nil
    }
}

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
        case segments, vocabulary, quiz
        case sourceArticles = "source_articles"
        case sourceKind = "source_kind"
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
        self.segments = try container.decodeIfPresent([TranscriptSegment].self, forKey: .segments)
        self.vocabulary = try container.decodeIfPresent([VocabularyEntry].self, forKey: .vocabulary)
        self.quiz = try container.decodeIfPresent([QuizQuestion].self, forKey: .quiz)
        self.sourceArticles = try container.decodeIfPresent([PodcastSourceArticle].self, forKey: .sourceArticles)
        self.sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind)
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

    /// トランスクリプト折りたたみ UI（`AudioPlayerView`）を表示すべきかどうか。
    /// `segments` が nil または空配列の場合は表示しない（旧エピソードのグレースフルデグレード・issue #162）。
    var hasTranscript: Bool {
        guard let segments else { return false }
        return !segments.isEmpty
    }

    /// 語彙グロッサリを表示できる内容があるか。
    var hasVocabulary: Bool {
        guard let vocabulary else { return false }
        return !vocabulary.isEmpty
    }

    /// 理解度クイズを提示できる設問があるか。
    var hasQuiz: Bool {
        guard let quiz else { return false }
        return !quiz.isEmpty
    }

    /// 出典セクションを表示すべきか（`sourceArticles` が非nil非空、issue #240）。
    var hasSourceArticles: Bool {
        guard let sourceArticles else { return false }
        return !sourceArticles.isEmpty
    }

    /// CC BY-SA 4.0 表示を出すべきか。`sourceKind == "featured"` の完全一致のときだけ true
    /// （ADR-095、fail-closed）。`"user"` / `"unknown"` / `nil` / 未知値は false。
    /// 正規化（trim / lowercased）は行わない。契約上の値は小文字固定であり、正規化を入れると
    /// backend と iOS の二重管理になる。
    var showsCcBySaLicense: Bool {
        sourceKind == "featured"
    }
}

extension Podcast {
    /// web `page.tsx` と同一文言の Markdown ソース。リンク範囲は "CC BY-SA 4.0" のみ（issue #240）。
    static let ccBySaLicenseNoticeMarkdown =
        "この音声コンテンツは [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.ja) で提供されます。"
    /// Markdown 除去後の表示文字列（テストと Markdown 解析失敗時のフォールバックで共有）。
    static let ccBySaLicenseNoticePlainText = "この音声コンテンツは CC BY-SA 4.0 で提供されます。"
    /// `Text(_: AttributedString)` に渡す値。`.link` 属性を持つ run が "CC BY-SA 4.0" だけになる。
    static let ccBySaLicenseNotice: AttributedString = {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        // WHY: 定数リテラルの解析失敗は起こらない前提だが、万一失敗してもプレイヤーを落とさず
        //      プレーン文で帰属表示を維持する。
        return (try? AttributedString(markdown: ccBySaLicenseNoticeMarkdown, options: options))
            ?? AttributedString(ccBySaLicenseNoticePlainText)
    }()
}

/// `/podcasts` エンドポイントのレスポンス。Podcast 一覧を保持する。
struct PodcastListResponse: Codable {
    /// 取得した Podcast 一覧。
    let podcasts: [Podcast]
}
