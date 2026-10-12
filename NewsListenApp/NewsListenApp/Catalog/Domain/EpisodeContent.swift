//
//  EpisodeContent.swift
//  NewsListenApp
//
//  エピソードの内容（11 field）と、表示の規則・葉の値型 4 つ。
//  JSON との変換（キー名・必須か省略可か）は adapter 側（Models/Podcast+Episode.swift）が持つ。
//

import Foundation

/// トランスクリプトの1発話。
struct TranscriptSegment: Equatable {
    /// 話者ラベル（例: `"A"` / `"B"`）。
    let speaker: String
    /// その発話のテキスト。
    let text: String
    /// 役割ラベル（`"fact"` / `"commentary"`）。ADR-094 第一段階（issue #237）。
    /// `var` + 既定値にして `TranscriptSegment(speaker:text:)` の memberwise init を維持する。
    var role: String? = nil
}

/// エピソードの出典記事1件（ADR-095 / issue #240）。
struct PodcastSourceArticle: Equatable {
    /// 出典記事の ID。
    let articleId: String
    /// 出典記事のタイトル。
    let title: String
    /// 出典記事の URL（文字列のまま保持し、表示直前に `linkURL` で検証する）。
    let url: String
    /// 出典元の名称（例: `"hackernews"`）。
    let source: String

    /// `url` を検証済みの `URL` として返す。`http` / `https` スキームのときだけ非 nil。
    /// - WHY: `Link` は任意スキームを `openURL` に渡すため、外部由来文字列を
    ///        無検証で開かない（入力検証）。
    var linkURL: URL? {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased() else { return nil }
        return (scheme == "http" || scheme == "https") ? url : nil
    }
}

/// エピソード本編から抽出された学習語彙。
struct VocabularyEntry: Equatable {
    /// 英語用語（原形）。
    let term: String
    /// 日本語の意味説明。
    let meaningJa: String
    /// 用語を含む本編由来の英文。
    let example: String
}

/// 理解度クイズ（ADR-070）の公開設問。
///
/// 正解はサーバー採点まで秘匿するため `answer_index` を持たない。
struct QuizQuestion: Equatable {
    let question: String
    let options: [String]
}

/// エピソードの内容。再生可否の種別（`Episode`）によらず共通の 11 field と表示の規則を持つ。
struct EpisodeContent: Equatable {
    let id: String
    let title: String
    let japaneseIntroText: String
    let difficulty: String
    let createdAt: String
    let durationSeconds: Int
    let segments: [TranscriptSegment]?
    let vocabulary: [VocabularyEntry]?
    let quiz: [QuizQuestion]?
    let sourceArticles: [PodcastSourceArticle]?
    let sourceKind: String?

    /// 表示用タイトル文字列。3段フォールバック（title → japaneseIntroText → デフォルト文字列）。
    /// - `title`（trim後）が非空ならそれを返す。
    /// - `japaneseIntroText`（trim後）が非空ならそれを返す。
    /// - 両方空の場合は `"ニュースポッドキャスト"` を返す（空欄は決して表示しない）。
    var displayTitle: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty { return trimmedTitle }
        let trimmedIntro = japaneseIntroText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedIntro.isEmpty ? "ニュースポッドキャスト" : trimmedIntro
    }

    /// トランスクリプト折りたたみ UI を表示すべきかどうか。
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
