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
    /// 選択モード中かどうか。
    @Published var isSelectionMode = false
    /// 選択中の記事 ID の集合。
    @Published var selectedIds: Set<String> = []
    /// 一括処理の成功/失敗の統計情報（トースト表示用）。
    @Published var bulkActionResult: BulkActionResult?

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

    /// 記事 ID の選択状態を切り替える。
    /// - Parameter id: 対象記事の ID。
    func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    /// 選択中の全記事を Star する（部分失敗に強い）。
    /// 成功分は一覧から削除し、結果を `bulkActionResult` に保存する。選択モード・selectedIds はリセットする。
    func bulkStar() async {
        // WHY 現在の一覧と突き合わせ: 選択中にリフレッシュ等で一覧から消えた記事の id が
        // selectedIds に残ると、存在しない記事を Star して成功数が水増しされる。
        // 現在表示中の記事に限定して一括 Star する。
        let currentIds = Set(articles.map { $0.id })
        let ids = Array(selectedIds.intersection(currentIds))
        guard !ids.isEmpty else {
            isSelectionMode = false
            selectedIds.removeAll()
            return
        }

        var successCount = 0
        var failureCount = 0

        // 各記事を並行で Star する。
        await withTaskGroup(of: (String, Bool).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await self.apiClient.starArticle(id: id)
                        return (id, true)
                    } catch {
                        return (id, false)
                    }
                }
            }

            // 結果を収集し、成功分は一覧から削除する。
            for await (id, success) in group {
                if success {
                    successCount += 1
                    articles.removeAll { $0.id == id }
                } else {
                    failureCount += 1
                }
            }
        }

        // 結果をセッションに保存。
        bulkActionResult = BulkActionResult(successCount: successCount, failureCount: failureCount)

        // 選択モードをリセット。
        isSelectionMode = false
        selectedIds.removeAll()
    }
}

/// 一括 Star 操作の結果情報。
struct BulkActionResult {
    /// 成功した記事数。
    let successCount: Int
    /// 失敗した記事数。
    let failureCount: Int

    /// 操作結果の日本語説明（トースト表示用）。
    var message: String {
        if failureCount == 0 {
            return "\(successCount)件を一括スターしました"
        } else {
            return "\(successCount)件をスターしました（失敗: \(failureCount)件）"
        }
    }
}
