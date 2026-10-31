//
//  Podcast+Episode.swift
//  NewsListenApp
//
//  通信のデータモデル `Podcast` と domain（`Episode`・`TranscriptSource`）の境界。
//  status の文字列による判別、葉の値型 4 つの JSON 形式（別ファイルの extension では
//  Codable が合成されないため手で書く）、推定タイミングの移行用の入口を持つ。
//

import Foundation

// MARK: - Podcast → Episode

extension Podcast {
    /// `status` の文字列で 3 種別へ判別する（全域関数。矛盾した組は `.failed`）。
    /// - `completed` かつ `audioUrl` 非空（判定は `PlayableEpisode.init?`）かつ `errorMessage` なし → `.playable`
    /// - `processing` → `.generating`
    /// - それ以外（`failed` / `partial_failed` / 未知 / `completed` の矛盾）→ `.failed`
    func toEpisode() -> Episode {
        let content = EpisodeContent(
            id: id,
            title: title,
            japaneseIntroText: japaneseIntroText,
            difficulty: difficulty,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            segments: segments,
            vocabulary: vocabulary,
            quiz: quiz,
            sourceArticles: sourceArticles,
            sourceKind: sourceKind
        )
        switch status {
        case "completed" where errorMessage == nil:
            guard let playable = PlayableEpisode(
                content: content,
                audioUrl: audioUrl,
                serverPosition: playbackPositionSeconds
            ) else {
                return .failed(FailedEpisode(content: content, reportedMessage: errorMessage))
            }
            return .playable(playable)
        case "processing":
            return .generating(GeneratingEpisode(content: content))
        default:
            return .failed(FailedEpisode(content: content, reportedMessage: errorMessage))
        }
    }
}

// MARK: - 葉の値型の Codable

extension TranscriptSegment: Codable {
    enum CodingKeys: String, CodingKey {
        case speaker, text, role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.speaker = try container.decode(String.self, forKey: .speaker)
        self.text = try container.decode(String.self, forKey: .text)
        self.role = try container.decodeIfPresent(String.self, forKey: .role)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(role, forKey: .role)
    }
}

/// 4 キーすべて必須。要素内のキー欠落は `Podcast` 全体のデコード失敗として扱い、部分救済しない。
extension PodcastSourceArticle: Codable {
    enum CodingKeys: String, CodingKey {
        case articleId = "article_id"
        case title, url, source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.articleId = try container.decode(String.self, forKey: .articleId)
        self.title = try container.decode(String.self, forKey: .title)
        self.url = try container.decode(String.self, forKey: .url)
        self.source = try container.decode(String.self, forKey: .source)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(articleId, forKey: .articleId)
        try container.encode(title, forKey: .title)
        try container.encode(url, forKey: .url)
        try container.encode(source, forKey: .source)
    }
}

extension VocabularyEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case term
        case meaningJa = "meaning_ja"
        case example
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.term = try container.decode(String.self, forKey: .term)
        self.meaningJa = try container.decode(String.self, forKey: .meaningJa)
        self.example = try container.decode(String.self, forKey: .example)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(term, forKey: .term)
        try container.encode(meaningJa, forKey: .meaningJa)
        try container.encode(example, forKey: .example)
    }
}

extension QuizQuestion: Codable {
    enum CodingKeys: String, CodingKey {
        case question, options
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.question = try container.decode(String.self, forKey: .question)
        self.options = try container.decode([String].self, forKey: .options)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(question, forKey: .question)
        try container.encode(options, forKey: .options)
    }
}
