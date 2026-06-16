//
//  FeedViewModel.swift
//  NewsListenApp
//
//  Feed タブの状態とロジック。記事一覧の取得と Star/Dismiss を担う。
//

import Foundation
import Combine

@MainActor
final class FeedViewModel: ObservableObject {
    @Published var articles: [Article] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

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

    func star(article: Article) async {
        do {
            try await apiClient.starArticle(id: article.id)
            articles.removeAll { $0.id == article.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismiss(article: Article) async {
        do {
            try await apiClient.dismissArticle(id: article.id)
            articles.removeAll { $0.id == article.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
