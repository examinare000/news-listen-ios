//
//  PreviewGateways.swift
//  NewsListenApp
//
//  Xcode Previews 専用。サンプル JSON を返すモックセッションを背負った `APIClient` を組む。
//  `APIClient` の static な生成関数にすると adapter の生成の入口（factory）として数えられるので、別の型に置く。
//  本番バイナリには含めない（全体を #if DEBUG で囲む）。
//

#if DEBUG
import Foundation

enum PreviewGateways {
    /// サンプル JSON を返すモックセッションを背負った `APIClient`。
    @MainActor static func apiClient() -> APIClient {
        APIClient(
            baseURL: URL(string: "https://preview.example.com")!,
            apiKey: "preview",
            sessionToken: "preview",
            session: PreviewURLSession()
        )
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

/// `PreviewSamples.episodes` と同じ値の API 応答（snake_case）。
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
