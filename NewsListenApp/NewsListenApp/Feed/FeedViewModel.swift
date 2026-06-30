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
    /// タップで全文展開中の記事 ID（なければ `nil`）。issue #111。
    @Published var expandedId: String?
    /// 直近の Star/Dismiss（取り消し可能な保留中操作）。issue #111。
    ///
    /// Star/Dismiss は楽観的に一覧から消し、サーバ送信は `commitPending()` まで遅延する。
    /// 確定前なら `undoLast()` で元に戻せる（サーバ側に un-star/un-dismiss API が無いため、
    /// 取り消しは「まだ送っていない」遅延コミット方式で実現する）。
    @Published private(set) var pendingAction: PendingArticleAction?

    /// API 通信に使うクライアント。
    private let apiClient: APIClient

    /// ViewModel を生成する。
    /// - Parameter apiClient: API 通信に使うクライアント。
    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    /// フィードを取得して `articles` を更新する。失敗時は `errorMessage` に反映する。
    func loadFeed() async {
        // 保留中の Star/Dismiss は一覧を置き換える前に確定させる（issue #111）。
        // これをしないとサーバ未反映の記事がリフレッシュで再出現し、楽観削除と id 重複する。
        await commitPending()
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

    /// 記事を Star する（楽観的に一覧から除去し、確定は `commitPending()` まで遅延）。issue #111。
    /// 確定前は `undoLast()` で取り消せる。
    /// - Parameter article: 対象記事。
    func star(article: Article) async {
        await stage(article: article, kind: .star)
    }

    /// 記事を Dismiss する（楽観的に一覧から除去し、確定は `commitPending()` まで遅延）。issue #111。
    /// - Parameter article: 対象記事。
    func dismiss(article: Article) async {
        await stage(article: article, kind: .dismiss)
    }

    /// 操作を保留に積む（取り消しは直近1件）。
    ///
    /// 楽観削除を**先に**行って UI を即時更新し、直前の保留はその後に確定送信する。
    /// こうすることで、連続スワイプ時に新しい操作の反映が前操作の通信完了を待たない（ラグ防止）。
    private func stage(article: Article, kind: PendingArticleAction.Kind) async {
        let previous = pendingAction
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            articles.remove(at: index)
            expandedId = nil
            pendingAction = PendingArticleAction(article: article, index: index, kind: kind)
        } else {
            // 対象がリフレッシュ等で一覧から消えている。新規 staging はせず、直前の保留のみ確定する。
            pendingAction = nil
        }
        if let previous {
            await commit(previous)
        }
    }

    /// 直近の Star/Dismiss を取り消し、記事を元の位置へ戻す（サーバ未送信のため副作用なし）。issue #111。
    func undoLast() {
        guard let pending = pendingAction else { return }
        let index = min(pending.index, articles.count)
        articles.insert(pending.article, at: index)
        pendingAction = nil
    }

    /// 保留中の操作をサーバへ確定送信する。失敗時は記事を戻し `errorMessage` に反映する。issue #111。
    /// 取り消し猶予の経過・別操作・画面離脱・バックグラウンド遷移のタイミングで呼ぶ。
    func commitPending() async {
        guard let pending = pendingAction else { return }
        // 再入防止のため先に保留を解除してから送信する（タイマー・onDisappear・別操作の同時到来でも 1 回のみ）。
        pendingAction = nil
        await commit(pending)
    }

    /// 指定の保留操作をサーバへ送信する。失敗時は記事を元の位置へ戻し `errorMessage` に反映する。
    private func commit(_ pending: PendingArticleAction) async {
        do {
            switch pending.kind {
            case .star:
                try await apiClient.starArticle(id: pending.article.id)
            case .dismiss:
                try await apiClient.dismissArticle(id: pending.article.id)
            }
        } catch {
            let index = min(pending.index, articles.count)
            articles.insert(pending.article, at: index)
            errorMessage = error.localizedDescription
        }
    }

    /// タップで全文表示の展開/折り畳みをトグルする。issue #111。
    func toggleExpand(_ id: String) {
        expandedId = (expandedId == id) ? nil : id
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

/// 取り消し可能な保留中の Star/Dismiss 操作（issue #111）。
struct PendingArticleAction {
    /// 操作種別。
    enum Kind { case star, dismiss }
    /// 対象記事。
    let article: Article
    /// 楽観的削除前の一覧内インデックス（取り消し時に元の位置へ戻すため）。
    let index: Int
    /// 操作種別。
    let kind: Kind

    /// 取り消しトーストに出す文言。
    var message: String {
        switch kind {
        case .star: return "スターしました"
        case .dismiss: return "削除しました"
        }
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
