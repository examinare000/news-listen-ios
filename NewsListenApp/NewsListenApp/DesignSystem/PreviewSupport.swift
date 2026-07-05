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
    static let podcasts: [Podcast] = [
        Podcast(
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
            playbackPositionSeconds: 72
        ),
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
            playbackPositionSeconds: 0
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
            playbackPositionSeconds: 0
        ),
    ]

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
        let vm = PodcastViewModel(apiClient: apiClient())
        vm.currentPodcast = podcasts[0]
        vm.duration = 247
        vm.currentTime = 72
        vm.isPlaying = true
        vm.playbackSpeed = 1.0
        return vm
    }
}

/// `feed` / `podcasts` のパスに応じてサンプル JSON を 200 で返すプレビュー用モックセッション。
private struct PreviewURLSession: URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://preview.example.com")!,
            statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        let encoder = JSONEncoder()
        if path.contains("podcast") {
            let body = (try? encoder.encode(PodcastListResponse(podcasts: PreviewSamples.podcasts))) ?? Data("{\"podcasts\":[]}".utf8)
            return (body, response)
        }
        if path.contains("feed") {
            let body = (try? encoder.encode(FeedResponse(articles: PreviewSamples.articles, date: "2026-06-29"))) ?? Data("{\"articles\":[],\"date\":\"2026-06-29\"}".utf8)
            return (body, response)
        }
        return (Data("{}".utf8), response)
    }
}
#endif
