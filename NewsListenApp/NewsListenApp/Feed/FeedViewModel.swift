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
    /// 確定前なら `undoLast()` で元に戻せる。un-star API 自体はスタータブ側に追加されたが
    /// （`StarredViewModel.unstar(_:)`）、un-dismiss API は依然として存在しないため、Feed の
    /// この取り消しは「まだ送っていない」遅延コミット方式のまま維持する（クォータを消費しない
    /// 取り消し導線として、un-star 追加後も引き続き有効）。
    @Published private(set) var pendingAction: PendingArticleAction?
    /// 現在ネットワークがオンラインかどうか（オフラインバナー表示用に View から購読する・issue #54）。
    @Published private(set) var isOnline: Bool

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

    /// API 通信に使うクライアント。
    private let apiClient: APIClient
    /// ネットワーク接続状態を監視する（issue #54: オフライン時の事前無効化）。
    private let networkMonitor: NetworkMonitoring
    /// 保留中の Star/Dismiss を取り消せる猶予期間（既定 4 秒）。
    ///
    /// 猶予経過で `commitPending()` を自動的に呼ぶタイマーは ViewModel 自身が所有する。
    /// 旧実装ではトーストビューの `.task` が所有しており、トースト自身が `pendingAction`
    /// 変化で破棄されると `.task` がキャンセルされ、実行中の確定送信（POST）まで
    /// 巻き込んでキャンセルされてしまう自己破壊構造になっていた（star cancelled alert バグ）。
    let undoGracePeriod: Duration
    /// 自動確定タイマーの投げっぱなし Task。新規 stage/undo のたびに前回分を cancel してから
    /// 差し替える（cancel-then-replace の投げっぱなし Task 追跡は `AppState.deviceTokenRegistrationTask`
    /// と同じ形だが、ライフサイクルは異なる点に注意: `AppState` はプロセス生存期間のシングルトンで
    /// deinit を意識しなくてよいのに対し、`FeedViewModel` は `FeedView` の `@StateObject` として
    /// 画面遷移・ログアウト等で破棄されうるため、`deinit` でも明示的に cancel する）。
    private var autoCommitTask: Task<Void, Never>?

    /// オフライン時にフィード更新をブロックした際の案内文言。
    static let offlineMessage = "オフラインです。接続を確認してから、もう一度お試しください"

    /// ViewModel を生成する。
    /// - Parameters:
    ///   - apiClient: API 通信に使うクライアント。
    ///   - networkMonitor: ネットワーク監視（既定: 実機監視の `NetworkMonitor()`。`PodcastViewModel` と同一パターン）。
    ///   - undoGracePeriod: 保留中の Star/Dismiss を取り消せる猶予期間（既定 4 秒。テストでは短縮値を注入する）。
    init(apiClient: APIClient, networkMonitor: NetworkMonitoring = NetworkMonitor(), undoGracePeriod: Duration = .seconds(4)) {
        self.apiClient = apiClient
        self.networkMonitor = networkMonitor
        self.undoGracePeriod = undoGracePeriod
        self.isOnline = networkMonitor.isOnline
        networkMonitor.isOnlinePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)
    }

    /// 画面破棄時に自動確定タイマーを止める最終防衛線。
    ///
    /// `deinit` は `nonisolated` のためプロパティ変更はできず `cancel()` の呼び出しのみ行う。
    /// 通常経路（`scheduleAutoCommit()` のタイマー自身が `commitPending()` 直前に
    /// `autoCommitTask = nil` する・`stage()`/`undoLast()` が次操作で cancel する）では
    /// `deinit` 到達時点で既に `nil` になっている想定だが、想定外の解放順序に備える。
    deinit {
        autoCommitTask?.cancel()
    }

    /// フィードを取得して `articles` を更新する。失敗時は `errorMessage` に反映する。
    ///
    /// オフライン時はネットワークを一切呼ばず（保留中操作の確定も含め）、案内メッセージのみ設定する。
    func loadFeed() async {
        guard networkMonitor.isOnline else {
            errorMessage = Self.offlineMessage
            return
        }
        // 保留中の Star/Dismiss は一覧を置き換える前に確定させる（issue #111）。
        // これをしないとサーバ未反映の記事がリフレッシュで再出現し、楽観削除と id 重複する。
        await commitPending()
        isLoading = true
        errorMessage = nil
        do {
            let response = try await apiClient.fetchFeed()
            articles = response.articles
        } catch is CancellationError {
            // 画面遷移等で loadFeed 呼び出し元 Task がキャンセルされただけ。ユーザーに見せる
            // エラーではない（commit() 側と同じ理由・star cancelled alert バグ）。
        } catch let error as URLError where error.code == .cancelled {
            // 同上。
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 記事を Star する（楽観的に一覧から除去し、確定は `commitPending()` まで遅延）。issue #111。
    /// 確定前は `undoLast()` で取り消せる。
    /// - Parameters:
    ///   - article: 対象記事。
    ///   - difficulty: 記事単位で指定する難易度（issue #163）。`nil` なら従来どおり prefs の
    ///     デフォルト難易度で生成する。
    func star(article: Article, difficulty: String? = nil) async {
        await stage(article: article, kind: .star, difficulty: difficulty)
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
    private func stage(article: Article, kind: PendingArticleAction.Kind, difficulty: String? = nil) async {
        let previous = pendingAction
        // 旧タイマーはこれから積む新しい保留（または「保留なし」）とは無関係になるため、
        // 先に cancel する。旧実装（id 指定なしトーストの `.task`）は View の構造的同一性が
        // 保たれる限り同じ `.task` インスタンスが使い回されるため、A→B と連続 stage しても
        // 最初にカウントを始めた 4 秒タイマーがそのまま生き続け、B の猶予が実質的に短縮されて
        // いた。cancel を先に行わないと、この VM 所有のタイマーでも同じ問題が再発する。
        autoCommitTask?.cancel()
        autoCommitTask = nil
        if let index = articles.firstIndex(where: { $0.id == article.id }) {
            articles.remove(at: index)
            expandedId = nil
            pendingAction = PendingArticleAction(article: article, index: index, kind: kind, difficulty: difficulty)
            scheduleAutoCommit()
        } else {
            // 対象がリフレッシュ等で一覧から消えている。新規 staging はせず、直前の保留のみ確定する。
            pendingAction = nil
        }
        if let previous {
            await commit(previous)
        }
    }

    /// 猶予期間経過後に保留中の操作を自動確定するタイマーを起動する。
    ///
    /// このタイマー Task 自身が `commitPending()` を呼ぶため、`commitPending()` 側は
    /// `autoCommitTask` を cancel しない（自己 cancel は不要かつ危険 - 実行中の自分自身を
    /// 止めてしまうと確定送信そのものが打ち切られる）。
    private func scheduleAutoCommit() {
        autoCommitTask = Task {
            try? await Task.sleep(for: undoGracePeriod)
            guard !Task.isCancelled else { return }
            autoCommitTask = nil
            await commitPending()
        }
    }

    /// 直近の Star/Dismiss を取り消し、記事を元の位置へ戻す（サーバ未送信のため副作用なし）。issue #111。
    func undoLast() {
        guard let pending = pendingAction else { return }
        autoCommitTask?.cancel()
        autoCommitTask = nil
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
                try await apiClient.starArticle(id: pending.article.id, difficulty: pending.difficulty)
            case .dismiss:
                try await apiClient.dismissArticle(id: pending.article.id)
            }
        } catch APIError.rateLimited(let retryAfter) {
            // 生成上限到達（issue #82）。記事を戻し、次回可能時刻を添えて案内する。
            let index = min(pending.index, articles.count)
            articles.insert(pending.article, at: index)
            errorMessage = Self.generationLimitMessage(retryAfter: retryAfter)
        } catch is CancellationError {
            // 呼び出し元 Task がキャンセルされただけで、ユーザーに見せるエラーではない。
            // 記事も再挿入しない: backend が star 済み/dismiss 済みを `/feed` から除外するため、
            // 表示は次回 loadFeed() でサーバの真実（除外済みの一覧）に収束する。キャンセル黙殺・
            // 非再挿入の判断自体は本除外仕様の前後で変わらない（backend api/routers/feed.py・
            // ADR-044 追記を参照）。
            return
        } catch let error as URLError where error.code == .cancelled {
            // 同上。実 URLSession はキャンセルを CancellationError ではなく URLError(.cancelled)
            // として投げるため、両方のケースを黙殺する。
            return
        } catch {
            let index = min(pending.index, articles.count)
            articles.insert(pending.article, at: index)
            errorMessage = error.localizedDescription
        }
    }

    /// 生成上限メッセージ（次回可能時刻があれば併記・issue #82）。
    static func generationLimitMessage(retryAfter seconds: Int?) -> String {
        guard let seconds, seconds > 0 else {
            return "本日の生成上限に達しました"
        }
        let when: String
        let minutes = (seconds + 59) / 60   // 切り上げ
        if seconds < 60 {
            when = "まもなく"
        } else if minutes < 60 {
            // web（lib/format.ts）と揃えるため derived minutes で分岐し「約60分後」を避ける。
            when = "約\(minutes)分後"
        } else {
            when = "約\((seconds + 3599) / 3600)時間後"
        }
        return "本日の生成上限に達しました（\(when)に可能）"
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
        // 生成上限（429）に当たったら次回可能時刻を控え、まとめて案内する（issue #82・web とパリティ）。
        var limitRetryAfter: Int??

        // 各記事を並行で Star する。失敗は error を持ち帰り、429 を判別できるようにする。
        await withTaskGroup(of: (String, Error?).self) { group in
            for id in ids {
                group.addTask {
                    do {
                        try await self.apiClient.starArticle(id: id)
                        return (id, nil)
                    } catch {
                        return (id, error)
                    }
                }
            }

            // 結果を収集し、成功分は一覧から削除する。
            for await (id, error) in group {
                if error == nil {
                    successCount += 1
                    articles.removeAll { $0.id == id }
                } else {
                    failureCount += 1
                    if case APIError.rateLimited(let retryAfter)? = error {
                        limitRetryAfter = retryAfter   // 直近の上限到達を保持
                    }
                }
            }
        }

        // 生成上限に当たっていれば上限メッセージを優先表示する。
        if let retryAfter = limitRetryAfter {
            errorMessage = Self.generationLimitMessage(retryAfter: retryAfter)
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
    /// 記事単位で指定された難易度（`.star` のみ有効・issue #163）。`nil` なら prefs のデフォルト難易度。
    let difficulty: String?

    /// 既存呼び出し（difficulty 未指定）との互換のため、明示的にデフォルト引数付き init を用意する
    /// （構造体の自動生成 memberwise init はデフォルト引数を省略できないため）。
    init(article: Article, index: Int, kind: Kind, difficulty: String? = nil) {
        self.article = article
        self.index = index
        self.kind = kind
        self.difficulty = difficulty
    }

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
