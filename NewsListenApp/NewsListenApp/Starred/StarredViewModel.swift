//
//  StarredViewModel.swift
//  NewsListenApp
//
//  スタータブの状態とロジック。Star 済み記事一覧の取得と un-star を担う。
//

import Foundation
import Combine

/// スタータブの状態とロジックを担う ViewModel。Star 済み記事一覧の取得と un-star を行う
/// （star/dismiss は Feed タブの役割のためここには持たない）。
@MainActor
final class StarredViewModel: ObservableObject {
    /// 表示中の Star 済み記事一覧。
    @Published var articles: [Article] = []
    /// 読み込み中かどうか。
    @Published var isLoading = false
    /// 直近のエラーメッセージ（なければ `nil`）。アラート表示に使う。
    @Published var errorMessage: String?
    /// 現在ネットワークがオンラインかどうか（オフラインバナー表示用に View から購読する）。
    @Published private(set) var isOnline: Bool

    /// 一覧画面の表示状態（ロード中/エラー/空/一覧）。`FeedViewModel`/`PodcastViewModel` と同じ
    /// 判定を共有し、ロード失敗と「本当に空」を同一の空状態に畳まない（issue #53 と同じ理由）。
    var displayState: ListDisplayState {
        ListDisplayState.resolve(isLoading: isLoading, isEmpty: articles.isEmpty, errorMessage: errorMessage)
    }

    /// エラーアラート（`.alert`）を表示すべきかどうか。
    /// 一覧が空でインラインエラー表示（`displayState == .error`）が出ている場合は、
    /// 同じエラーの二重表示を避けるためアラートを出さない（issue #58 と同じ理由）。
    var shouldPresentErrorAlert: Bool {
        ListDisplayState.shouldPresentAlert(errorMessage: errorMessage, displayState: displayState)
    }

    /// API 通信に使うクライアント。
    private let apiClient: APIClient
    /// ネットワーク接続状態を監視する。
    private let networkMonitor: NetworkMonitoring

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - apiClient: API 通信に使うクライアント。
    ///   - networkMonitor: ネットワーク監視（既定: 実機監視の `NetworkMonitor()`。`FeedViewModel` と同一パターン）。
    init(apiClient: APIClient, networkMonitor: NetworkMonitoring = NetworkMonitor()) {
        self.apiClient = apiClient
        self.networkMonitor = networkMonitor
        self.isOnline = networkMonitor.isOnline
        networkMonitor.isOnlinePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)
    }

    /// Star 済み記事一覧を取得して `articles` を更新する。失敗時は `errorMessage` に反映する。
    ///
    /// 閲覧専用のため `FeedViewModel.loadFeed()` と異なり保留中操作の確定処理は持たない。
    /// オフライン時はネットワークを一切呼ばず、案内メッセージのみ設定する（`FeedViewModel` と同じ文言）。
    ///
    /// - Note: タブ初回表示の直後は、直前に Feed タブでスターした記事が反映されていないことがある
    ///   （Feed 側の `onDisappear` の確定 POST とこのロードが競合しうるため）。両 ViewModel 間の
    ///   協調機構は作らず、pull-to-refresh での解消を許容する既知の挙動とする。同様に、`unstar(_:)`
    ///   直後にこのロードが古い（un-star 前の）レスポンスと競合すると行が一時的に復活しうるが、
    ///   これも次回リフレッシュでサーバの真実に収束する許容範囲の挙動とする。
    func loadStarred() async {
        guard networkMonitor.isOnline else {
            errorMessage = FeedViewModel.offlineMessage
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchStarredArticles()
            articles = response.articles
        } catch is CancellationError {
            // 画面遷移等で呼び出し元 Task がキャンセルされただけ。ユーザーに見せるエラーではない
            // （FeedViewModel.loadFeed() と同じ理由・star cancelled alert バグ対応を参照）。
        } catch let error as URLError where error.code == .cancelled {
            // 同上。
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 指定記事の Star を解除する（スタータブのスワイプ導線）。
    ///
    /// `FeedViewModel.commit(_:)` と同じ楽観的更新の流儀: 先に一覧から除去し、失敗時のみ
    /// 元の位置（他の削除で index がずれていれば末尾）へ戻す。404 は「記事 doc が既に存在しない」
    /// という backend の冪等仕様上の成功扱いのため、行を残さない（残すとゴースト化するため）。
    /// キャンセルは黙殺し、非復元のまま次回 `loadStarred()` でサーバの真実に収束させる。
    ///
    /// - Note: 複数記事の un-star をネットワーク往復中に連続実行し、いずれも失敗した場合、
    ///   復元 index の計算がそれぞれ独立して行われるため表示順が崩れうる（例:
    ///   `[A,B,C]` → A・C を同時に失敗復元 → `[A,C,B]`）。重複や消失はしないため、構造的な
    ///   直列化・排他制御は導入せず許容とし、次回 `loadStarred()` でサーバの真実（順序含む）に
    ///   収束させる（`loadStarred()` 側の既知レース Note と同型の割り切り）。
    /// - Parameter article: 解除対象の記事。
    func unstar(_ article: Article) async {
        guard networkMonitor.isOnline else {
            errorMessage = FeedViewModel.offlineMessage
            return
        }
        guard let index = articles.firstIndex(where: { $0.id == article.id }) else { return }
        articles.remove(at: index)
        do {
            try await apiClient.unstarArticle(id: article.id)
        } catch APIError.httpError(404) {
            // 記事 doc が既に存在しない＝サーバ側としては既に望みどおりの状態。復元しない。
        } catch is CancellationError {
            // 呼び出し元 Task がキャンセルされただけで、ユーザーに見せるエラーではない。
        } catch let error as URLError where error.code == .cancelled {
            // 同上。
        } catch {
            let restoreIndex = min(index, articles.count)
            articles.insert(article, at: restoreIndex)
            errorMessage = error.localizedDescription
        }
    }
}
