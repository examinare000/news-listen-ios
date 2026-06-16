//
//  FeedViewModel.swift
//  NewsListenApp
//
//  Feed タブの状態とロジック。記事一覧の取得と Star/Dismiss を担う。
//

import Foundation
import Combine

/// Feed タブの状態とロジックを担う ViewModel。記事一覧の取得と Star/Dismiss を行う。
@MainActor
final class FeedViewModel: ObservableObject {
    /// 表示中の記事一覧。
    @Published var articles: [Article] = []
    /// 読み込み中かどうか。
    @Published var isLoading = false
    /// 直近のエラーメッセージ（なければ `nil`）。アラート表示に使う。
    @Published var errorMessage: String?

    /// API 通信に使うクライアント。
    private let apiClient: APIClient

    /// ViewModel を生成する。
    /// - Parameter apiClient: API 通信に使うクライアント。
    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    /// フィードを取得して `articles` を更新する。失敗時は `errorMessage` に反映する。
    func loadFeed() async {
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchFeed()
            articles = response.articles
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 記事を Star し、一覧から取り除く。失敗時は `errorMessage` に反映する。
    /// - Parameter article: 対象記事。
    func star(article: Article) async {
        do {
            try await apiClient.starArticle(id: article.id)
            articles.removeAll { $0.id == article.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 記事を Dismiss し、一覧から取り除く。失敗時は `errorMessage` に反映する。
    /// - Parameter article: 対象記事。
    func dismiss(article: Article) async {
        do {
            try await apiClient.dismissArticle(id: article.id)
            articles.removeAll { $0.id == article.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
