//
//  FeedViewModel.swift
//  NewsListenApp
//
//  Feed タブの画面状態（読み込み中・文言・選択モード・展開中の行）。一覧と確定待ちは `FeedCuration` が持つ。
//

import Foundation
import Combine

/// Feed タブの画面状態を担う ViewModel。記事一覧・保留・確定の失敗は `FeedCuration` から読む。
@MainActor
final class FeedViewModel: ObservableObject {
    /// 読み込み中かどうか。
    @Published private(set) var isLoading = false
    /// 直近のエラーメッセージ（なければ `nil`）。アラート表示に使う。
    @Published private(set) var errorMessage: String?
    /// 選択モード中かどうか。
    @Published private(set) var isSelectionMode = false
    /// 選択中の記事 ID の集合。
    @Published private(set) var selectedIds: Set<String> = []
    /// 一括処理の成功/失敗の件数（トースト表示用）。
    @Published private(set) var bulkActionResult: BulkStarReceipt?
    /// タップで全文展開中の記事 ID（なければ `nil`）。issue #111。
    @Published private(set) var expandedId: String?
    /// 現在ネットワークがオンラインかどうか（オフラインバナー表示用に View から購読する・issue #54）。
    @Published private(set) var isOnline: Bool

    /// 表示中の記事一覧。
    var articles: [ArticleCardModel] { curation.cards }
    /// 直近の Star/Dismiss（取り消し可能な保留中操作）。issue #111。
    var pendingAction: PendingCuration? { curation.pending }

    /// 一覧画面の表示状態（ロード中/エラー/空/一覧）。
    /// ロード失敗と「本当に空」を同一の空状態に畳んで表示しないよう、View はこの値のみで分岐する（issue #53）。
    var displayState: ListDisplayState {
        ListDisplayState.resolve(isLoading: isLoading, isEmpty: articles.isEmpty, errorMessage: errorMessage)
    }

    /// エラーアラート（`.alert`）を表示すべきかどうか。
    /// 一覧が空でインラインエラー表示（`displayState == .error`）が出ている場合は、
    /// 同じエラーの二重表示を避けるためアラートを出さない（issue #58）。
    var shouldPresentErrorAlert: Bool {
        ListDisplayState.shouldPresentAlert(errorMessage: errorMessage, displayState: displayState)
    }

    private let curation: FeedCuration
    /// ネットワーク接続状態を監視する（issue #54: オフライン時の事前無効化）。
    private let networkMonitor: NetworkMonitoring
    private var cancellables = Set<AnyCancellable>()

    /// オフライン時にフィード更新をブロックした際の案内文言。
    static let offlineMessage = "オフラインです。接続を確認してから、もう一度お試しください"

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - curation: 一覧・保留・確定を持つ application。
    ///   - networkMonitor: ネットワーク監視（既定: 実機監視の `NetworkMonitor()`。`PodcastViewModel` と同一パターン）。
    init(curation: FeedCuration, networkMonitor: NetworkMonitoring = NetworkMonitor()) {
        self.curation = curation
        self.networkMonitor = networkMonitor
        self.isOnline = networkMonitor.isOnline
        networkMonitor.isOnlinePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)
        // closure が VM を強く持つと curation → closure → VM → curation の循環になり、logout 後も解放されない。
        curation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // `receive(on:)` を挟まない。挟むと `await commitPending()` の直後に文言が読めない。
        curation.$lastFailure
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] failure in self?.errorMessage = Self.message(for: failure) }
            .store(in: &cancellables)
    }

    /// フィードを取得して一覧を更新する。失敗時は `errorMessage` に反映する。
    ///
    /// オフライン時はネットワークを一切呼ばず（保留中操作の確定も含め）、案内メッセージのみ設定する。
    func loadFeed() async {
        guard networkMonitor.isOnline else {
            errorMessage = Self.offlineMessage
            return
        }
        // 保留中の Star/Dismiss は一覧を置き換える前に確定させる（issue #111）。
        // これをしないとサーバ未反映の記事がリフレッシュで再出現し、楽観削除と id 重複する。
        await curation.commitPending()
        isLoading = true
        errorMessage = nil
        do {
            try await curation.reload()
        } catch is CancellationError {
            // 画面遷移等で loadFeed 呼び出し元 Task がキャンセルされただけ。ユーザーに見せるエラーではない。
        } catch let error as URLError where error.code == .cancelled {
            // 同上。
        } catch let f as ApiFailure {
            errorMessage = FailureMessages.message(for: f, context: .feed)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 記事を Star する（楽観的に一覧から除去し、確定は猶予の後）。issue #111。
    /// - Parameters:
    ///   - articleId: 対象記事の ID。
    ///   - difficulty: 記事単位で指定する難易度（issue #163）。`nil` なら prefs のデフォルト難易度で生成する。
    func star(articleId: String, difficulty: DifficultyLevel?) async {
        collapseIfPresent(articleId)
        await curation.star(articleId: articleId, difficulty: difficulty)
    }

    /// 記事を Dismiss する（楽観的に一覧から除去し、確定は猶予の後）。issue #111。
    func dismiss(articleId: String) async {
        collapseIfPresent(articleId)
        await curation.dismiss(articleId: articleId)
    }

    /// 直近の Star/Dismiss を取り消し、記事を元の位置へ戻す。issue #111。
    func undoLast() {
        curation.undoLast()
    }

    /// 保留中の操作を確定送信する。取り消し猶予の経過・別操作・画面離脱・バックグラウンド遷移で呼ぶ。issue #111。
    func commitPending() async {
        await curation.commitPending()
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

    /// 選択モードを切り替える。オフになったら選択を空にする。
    func toggleSelectionMode() {
        isSelectionMode.toggle()
        if !isSelectionMode {
            selectedIds.removeAll()
        }
    }

    /// エラー文言と、そのもとになった確定の失敗を消す。
    func clearError() {
        errorMessage = nil
        curation.clearFailure()
    }

    /// 選択中の全記事を Star する（部分失敗に強い）。結果を `bulkActionResult` に保存し、選択モードを抜ける。
    func bulkStar() async {
        let receipt = await curation.bulkStar(articleIds: selectedIds)
        if receipt.succeeded + receipt.failed != 0 {
            bulkActionResult = receipt
        }
        isSelectionMode = false
        selectedIds.removeAll()
    }

    /// 対象が一覧にあるときだけ展開を解除する（操作で展開状態は解除される）。
    private func collapseIfPresent(_ articleId: String) {
        if articles.contains(where: { $0.id == articleId }) {
            expandedId = nil
        }
    }

    private static func message(for failure: CurationFailure) -> String {
        switch failure {
        case .rateLimited(let wait):
            return generationLimitMessage(wait)
        case .api(let f):
            return FailureMessages.message(for: f, context: .feed)
        case .other(let description):
            return description
        }
    }

    /// 生成上限メッセージ（次回可能時刻があれば併記・issue #82）。
    static func generationLimitMessage(_ wait: GenerationLimitWait?) -> String {
        let when: String
        switch wait {
        case nil:
            return "本日の生成上限に達しました"
        case .soon?:
            when = "まもなく"
        case .minutes(let minutes)?:
            when = "約\(minutes)分後"
        case .hours(let hours)?:
            when = "約\(hours)時間後"
        }
        return "本日の生成上限に達しました（\(when)に可能）"
    }

    /// 一括 Star の結果の説明（トースト表示用）。
    static func bulkMessage(_ receipt: BulkStarReceipt) -> String {
        if receipt.failed == 0 {
            return "\(receipt.succeeded)件を一括スターしました"
        } else {
            return "\(receipt.succeeded)件をスターしました（失敗: \(receipt.failed)件）"
        }
    }
}
