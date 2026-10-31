//
//  PreviewSupport.swift
//  NewsListenApp
//
//  Xcode Previews 専用のサンプルデータとネットワークモック。
//  ログイン・実バックエンド無しで各画面を populated 状態で確認するために使う。
//  本番バイナリには含めない（全体を #if DEBUG で囲む）。
//

#if DEBUG
import Foundation
import SwiftUI

/// プレビュー用のサンプルモデルと、それらを返すモック群。
enum PreviewSamples {
    /// Feed プレビュー用のサンプル記事。ソース・スコア・長さに変化を付ける。
    static let articles: [Article] = [
        Article(
            id: "a1",
            title: "Fed signals rate pause as inflation cools toward target",
            url: "https://example.com/1",
            source: "Reuters",
            score: 0.92,
            publishedAt: "2026-06-29T06:30:00Z"
        ),
        Article(
            id: "a2",
            title: "UK economy returns to growth in surprise first-quarter rebound",
            url: "https://example.com/2",
            source: "BBC",
            score: 0.74,
            publishedAt: "2026-06-29T03:10:00Z"
        ),
        Article(
            id: "a3",
            title: "Chipmakers rally as demand for AI accelerators outpaces supply",
            url: "https://example.com/3",
            source: "Bloomberg",
            score: 0.58,
            publishedAt: "2026-06-28T21:45:00Z"
        ),
        Article(
            id: "a4",
            title: "Climate summit ends with new pledges on methane reduction",
            url: "https://example.com/4",
            source: "The Guardian",
            score: 0.33,
            publishedAt: "2026-06-28T18:00:00Z"
        ),
    ]

    /// Podcast プレビュー用のサンプル。完了/生成中/失敗の3状態を含める。
    /// p1 はトランスクリプト・語彙・クイズを含む完全版（AudioPlayerView プレビュー用）。
    static let podcasts: [Podcast] = {
        // p1: vocabulary と quiz を含む完全なエピソード
        let p1 = Podcast(
            id: "p1",
            type: "daily",
            articleIds: ["a1", "a2"],
            difficulty: "toeic_900",
            audioUrl: "https://example.com/p1.mp3",
            title: "米連邦準備制度が利上げを見送り、英国経済が予想外の回復を見せた。",
            japaneseIntroText: "今日は米連邦準備制度の利上げ見送りと、英国経済の予想外の回復について取り上げます。",
            durationSeconds: 247,
            createdAt: "2026-06-29T07:00:00Z",
            status: "completed",
            errorMessage: nil,
            playbackPositionSeconds: 72,
            segments: [
                TranscriptSegment(speaker: "A", text: "米連邦準備制度が今回の会合で利上げを見送りました。"),
                TranscriptSegment(speaker: "B", text: "一方、英国経済は予想外の回復を見せています。"),
            ],
            vocabulary: [
                VocabularyEntry(term: "pause", meaningJa: "一時中断する、中断期間", example: "The central bank will pause its rate hikes."),
                VocabularyEntry(term: "rebound", meaningJa: "反発、回復", example: "The UK economy showed a strong rebound in the first quarter."),
                VocabularyEntry(term: "inflation", meaningJa: "インフレーション、物価上昇", example: "Inflation has cooled toward the target."),
            ],
            quiz: [
                QuizQuestion(
                    question: "According to the podcast, why did the central bank pause its rate hikes?",
                    options: ["Inflation cooled toward the target", "The economy was growing too fast", "Interest rates were too high", "Banks requested a halt"]),
                QuizQuestion(
                    question: "How did the UK economy perform in the first quarter?",
                    options: ["It contracted sharply", "It showed an unexpected rebound", "It remained flat", "Growth slowed significantly"]),
                QuizQuestion(
                    question: "What is the main topic of today's podcast?",
                    options: ["Global stock market trends", "Central bank decisions and economic recovery", "Brexit negotiations", "Technology sector performance"]),
            ],
            sourceArticles: [
                PodcastSourceArticle(articleId: "a1", title: "Fed signals rate pause as inflation cools toward target", url: "https://example.com/1", source: "Reuters"),
                PodcastSourceArticle(articleId: "a2", title: "UK economy returns to growth in surprise first-quarter rebound", url: "not a url", source: "BBC"),
            ],
            sourceKind: "featured"
        )

        return [
            p1,
        Podcast(
            id: "p2",
            type: "daily",
            articleIds: ["a3"],
            difficulty: "toeic_600",
            audioUrl: "https://example.com/p2.mp3",
            title: "",
            japaneseIntroText: "AI半導体の需要が供給を上回り、関連銘柄が上昇しています。",
            durationSeconds: 188,
            createdAt: "2026-06-28T22:30:00Z",
            status: "processing",
            errorMessage: nil,
            playbackPositionSeconds: 0,
            segments: nil
        ),
            Podcast(
                id: "p3",
                type: "daily",
                articleIds: ["a4"],
                difficulty: "eiken_2",
                audioUrl: "https://example.com/p3.mp3",
                title: "",
                japaneseIntroText: "気候サミットがメタン削減の新たな誓約とともに閉幕しました。",
                durationSeconds: 0,
                createdAt: "2026-06-28T19:00:00Z",
                status: "failed",
                errorMessage: "音声生成に失敗しました",
                playbackPositionSeconds: 0,
                segments: nil
            ),
        ]
    }()

    /// プレビュー用の `AppState`（API 未注入のまま既定値で動く）。
    @MainActor static func appState() -> AppState { AppState() }

    /// サンプル JSON を返すモックセッションを背負った `APIClient`。
    @MainActor static func apiClient() -> APIClient {
        APIClient(
            baseURL: URL(string: "https://preview.example.com")!,
            apiKey: "preview",
            sessionToken: "preview",
            session: PreviewURLSession()
        )
    }

    /// 再生中状態を仕込んだ `PodcastViewModel`（プレイヤー UI 確認用）。
    @MainActor static func playerViewModel() -> PodcastViewModel {
        let episode = previewPlayable()
        return previewFacade(
            session: .playing(episode: episode, position: 72, duration: 247, speed: 1.0),
            queue: PlaybackQueue<Episode>(items: [.playable(episode)], currentIndex: 0))
    }

    /// 聴き終わり後のコンパクト表示を仕込んだ `PodcastViewModel`（finishedContent プレビュー用）。
    @MainActor static func finishedPlayerViewModel() -> PodcastViewModel {
        let episode = previewPlayable()
        return previewFacade(
            session: .ended(episode: episode, duration: 247),
            queue: PlaybackQueue<Episode>(items: [.playable(episode)], currentIndex: 0))
    }

    private static func previewPlayable() -> PlayableEpisode {
        guard case .playable(let episode) = podcasts[0].toEpisode() else {
            preconditionFailure("プレビューの標本 p1 は再生可能な種別であること")
        }
        return episode
    }

    /// Coordinator・Reporter・保存庫は `previewParts` の「何もしない」実装。ダウンロードとネットワークもここで作る。
    @MainActor private static func previewFacade(session: PlaybackState, queue: PlaybackQueue<Episode>) -> PodcastViewModel {
        let parts = PlaybackCoordinator.previewParts(session: session, queue: queue)
        let downloads = OfflineDownloads(
            library: parts.library,
            fetchEpisode: { _ in throw CancellationError() },
            downloadAudio: { _ in throw CancellationError() })
        return PodcastViewModel(
            apiClient: apiClient(),
            coordinator: parts.coordinator,
            reporter: parts.reporter,
            library: parts.library,
            downloads: downloads,
            networkMonitor: StubNetworkMonitor(),
            defaultSpeed: { 1.0 })
    }
}

/// `feed` / `podcasts` / `starred` のパスに応じてサンプル JSON を 200 で返すプレビュー用モックセッション。
private struct PreviewURLSession: URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://preview.example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        if path.contains("podcast") {
            return (Data(#"{"podcasts":\#(previewPodcastsJSON)}"#.utf8), response)
        }
        // feed 分岐より前に置く（"starred" は "feed" を含まないが誤マッチ余地を残さない）。
        if path.contains("starred") {
            return (Data(#"{"articles":\#(previewArticlesJSON)}"#.utf8), response)
        }
        if path.contains("feed") {
            return (Data(#"{"articles":\#(previewArticlesJSON),"date":"2026-06-29"}"#.utf8), response)
        }
        return (Data("{}".utf8), response)
    }
}

/// `PreviewSamples.articles` と同じ値の API 応答（snake_case）。
private let previewArticlesJSON = #"""
[
    {"id": "a1", "title": "Fed signals rate pause as inflation cools toward target", "url": "https://example.com/1", "source": "Reuters", "score": 0.92, "published_at": "2026-06-29T06:30:00Z"},
    {"id": "a2", "title": "UK economy returns to growth in surprise first-quarter rebound", "url": "https://example.com/2", "source": "BBC", "score": 0.74, "published_at": "2026-06-29T03:10:00Z"},
    {"id": "a3", "title": "Chipmakers rally as demand for AI accelerators outpaces supply", "url": "https://example.com/3", "source": "Bloomberg", "score": 0.58, "published_at": "2026-06-28T21:45:00Z"},
    {"id": "a4", "title": "Climate summit ends with new pledges on methane reduction", "url": "https://example.com/4", "source": "The Guardian", "score": 0.33, "published_at": "2026-06-28T18:00:00Z"}
]
"""#

/// `PreviewSamples.podcasts` と同じ値の API 応答（snake_case）。
private let previewPodcastsJSON = #"""
[
    {
        "id": "p1",
        "type": "daily",
        "article_ids": ["a1", "a2"],
        "difficulty": "toeic_900",
        "audio_url": "https://example.com/p1.mp3",
        "title": "米連邦準備制度が利上げを見送り、英国経済が予想外の回復を見せた。",
        "japanese_intro_text": "今日は米連邦準備制度の利上げ見送りと、英国経済の予想外の回復について取り上げます。",
        "duration_seconds": 247,
        "created_at": "2026-06-29T07:00:00Z",
        "status": "completed",
        "playback_position_seconds": 72,
        "segments": [
            {"speaker": "A", "text": "米連邦準備制度が今回の会合で利上げを見送りました。"},
            {"speaker": "B", "text": "一方、英国経済は予想外の回復を見せています。"}
        ],
        "vocabulary": [
            {"term": "pause", "meaning_ja": "一時中断する、中断期間", "example": "The central bank will pause its rate hikes."},
            {"term": "rebound", "meaning_ja": "反発、回復", "example": "The UK economy showed a strong rebound in the first quarter."},
            {"term": "inflation", "meaning_ja": "インフレーション、物価上昇", "example": "Inflation has cooled toward the target."}
        ],
        "quiz": [
            {
                "question": "According to the podcast, why did the central bank pause its rate hikes?",
                "options": ["Inflation cooled toward the target", "The economy was growing too fast", "Interest rates were too high", "Banks requested a halt"]
            },
            {
                "question": "How did the UK economy perform in the first quarter?",
                "options": ["It contracted sharply", "It showed an unexpected rebound", "It remained flat", "Growth slowed significantly"]
            },
            {
                "question": "What is the main topic of today's podcast?",
                "options": ["Global stock market trends", "Central bank decisions and economic recovery", "Brexit negotiations", "Technology sector performance"]
            }
        ],
        "source_articles": [
            {"article_id": "a1", "title": "Fed signals rate pause as inflation cools toward target", "url": "https://example.com/1", "source": "Reuters"},
            {"article_id": "a2", "title": "UK economy returns to growth in surprise first-quarter rebound", "url": "not a url", "source": "BBC"}
        ],
        "source_kind": "featured"
    },
    {
        "id": "p2",
        "type": "daily",
        "article_ids": ["a3"],
        "difficulty": "toeic_600",
        "audio_url": "https://example.com/p2.mp3",
        "title": "",
        "japanese_intro_text": "AI半導体の需要が供給を上回り、関連銘柄が上昇しています。",
        "duration_seconds": 188,
        "created_at": "2026-06-28T22:30:00Z",
        "status": "processing",
        "error_message": null,
        "playback_position_seconds": 0
    },
    {
        "id": "p3",
        "type": "daily",
        "article_ids": ["a4"],
        "difficulty": "eiken_2",
        "audio_url": "https://example.com/p3.mp3",
        "title": "",
        "japanese_intro_text": "気候サミットがメタン削減の新たな誓約とともに閉幕しました。",
        "duration_seconds": 0,
        "created_at": "2026-06-28T19:00:00Z",
        "status": "failed",
        "error_message": "音声生成に失敗しました",
        "playback_position_seconds": 0
    }
]
"""#
#endif
