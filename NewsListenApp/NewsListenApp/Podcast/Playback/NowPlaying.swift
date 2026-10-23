//
//  NowPlaying.swift
//  NewsListenApp
//
//  再生中エピソードと待機列の行のリードモデル。`struct`・`let` だけで持つ。
//

import Foundation

struct QueueEntry: Identifiable, Equatable {
    let episodeId: String
    var id: String { episodeId }
    let introText: String
    let difficulty: String
    let durationSeconds: Int
}

struct NowPlaying: Identifiable, Equatable {
    let episodeId: String
    var id: String { episodeId }
    let displayTitle: String
    let japaneseIntroText: String
    let segments: [TranscriptSegment]?
    let vocabulary: [VocabularyEntry]?
    let quiz: [QuizQuestion]?
    let difficulty: String
    let sourceArticles: [PodcastSourceArticle]?
    let sourceKind: String?
    let hasTranscript: Bool
    let hasVocabulary: Bool
    let hasQuiz: Bool
    let hasSourceArticles: Bool
    let showsCcBySaLicense: Bool
    let queueEntry: QueueEntry
}
