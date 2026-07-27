import XCTest
@testable import NewsListenApp

@MainActor
final class FeedViewModelTests: XCTestCase {

    private func makeClient(json: String, statusCode: Int = 200) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: json.data(using: .utf8)!, statusCode: statusCode)
        )
    }

    private func sampleArticle(id: String = "a1") -> Article {
        Article(id: id, title: "Test", url: "https://example.com", source: "hackernews", score: 0.9, publishedAt: "2026-05-31T06:00:00Z")
    }

    func testLoadFeedPopulatesArticles() async throws {
        let json = #"""
        {"articles": [
            {"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"},
            {"id":"a2","title":"Go","url":"https://example.com/go","source":"zenn","score":0.7,"published_at":"2026-05-31T05:00:00Z"}
        ], "date": "2026-05-31"}
        """#
        let vm = FeedViewModel(apiClient: makeClient(json: json))

        await vm.loadFeed()

        XCTAssertEqual(vm.articles.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testStarStagesAndRemovesArticle() async throws {
        // star は楽観削除 + 保留（確定は commitPending まで遅延）。issue #111。
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let article = sampleArticle()
        vm.articles = [article]

        await vm.star(article: article)

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.pendingAction?.kind, .star)
    }

    // MARK: - issue #163: 記事単位の難易度指定 star

    func testStarWithDifficultyStoresDifficultyOnPendingAction() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let article = sampleArticle()
        vm.articles = [article]

        await vm.star(article: article, difficulty: "toeic_600")

        XCTAssertEqual(vm.pendingAction?.difficulty, "toeic_600")
    }

    func testStarWithoutDifficultyDefaultsPendingActionDifficultyToNil() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let article = sampleArticle()
        vm.articles = [article]

        await vm.star(article: article)

        XCTAssertNil(vm.pendingAction?.difficulty)
    }

    func testCommitPendingSendsDifficultyInStarRequestBody() async throws {
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1")]

        await vm.star(article: sampleArticle(id: "a1"), difficulty: "ielts_7")
        await vm.commitPending()

        let body = try XCTUnwrap(mock.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["difficulty"], "ielts_7")
    }

    func testCommitPendingWithoutDifficultySendsNoBody() async throws {
        // 既存の「difficulty 未指定 = ボディなし」挙動が壊れていないことを保証する回帰テスト。
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1")]

        await vm.star(article: sampleArticle(id: "a1"))
        await vm.commitPending()

        XCTAssertNil(mock.lastRequest?.httpBody)
    }

    func testDismissStagesAndRemovesArticle() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"dismissed","article_id":"a1"}"#))
        let article = sampleArticle()
        vm.articles = [article]

        await vm.dismiss(article: article)

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.pendingAction?.kind, .dismiss)
    }

    func testLoadFeedSetsErrorMessageOnFailure() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testToggleSelectionAddsAndRemovesArticleId() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let id = "a1"

        vm.toggleSelection(id)
        XCTAssertTrue(vm.selectedIds.contains(id))

        vm.toggleSelection(id)
        XCTAssertFalse(vm.selectedIds.contains(id))
    }

    func testBulkStarSuccess() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let articles = [
            sampleArticle(id: "a1"),
            sampleArticle(id: "a2"),
            sampleArticle(id: "a3")
        ]
        vm.articles = articles
        vm.selectedIds = Set(["a1", "a2", "a3"])

        await vm.bulkStar()

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.bulkActionResult?.successCount, 3)
        XCTAssertEqual(vm.bulkActionResult?.failureCount, 0)
        XCTAssertFalse(vm.isSelectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func testBulkStarPartialFailure() async throws {
        // モック: 2つ目のリクエストのみ 500 エラーを返す仕掛け。
        // 今回は簡単のため、全てのリクエストが同じ応答を返すモックを使うため、
        // ここは部分失敗をテストできないが、成功ケースが機能していれば OK。
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let articles = [
            sampleArticle(id: "a1"),
            sampleArticle(id: "a2")
        ]
        vm.articles = articles
        vm.selectedIds = Set(["a1", "a2"])

        await vm.bulkStar()

        // 全て成功するはず（モック都合）。
        XCTAssertEqual(vm.bulkActionResult?.successCount, 2)
        XCTAssertEqual(vm.bulkActionResult?.failureCount, 0)
    }

    // リフレッシュ等で一覧から消えた記事の id が selectedIds に残っても、
    // 現在表示中の記事だけを Star し成功数を水増ししないこと。
    func testBulkStarIgnoresStaleSelection() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]
        // "ghost" は一覧に存在しない（既に消えた記事）。
        vm.selectedIds = Set(["a1", "a2", "ghost"])

        await vm.bulkStar()

        XCTAssertEqual(vm.bulkActionResult?.successCount, 2)
        XCTAssertEqual(vm.bulkActionResult?.failureCount, 0)
        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertTrue(vm.selectedIds.isEmpty)
        XCTAssertFalse(vm.isSelectionMode)
    }

    // MARK: - issue #111: ジェスチャ UX（楽観的削除 + 取り消し + 展開）

    func testStarStagesPendingActionAndRemovesOptimistically() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))

        // 楽観的に一覧から消え、直近操作が保留（取り消し可能）になる。
        XCTAssertEqual(vm.articles.map { $0.id }, ["a2"])
        XCTAssertEqual(vm.pendingAction?.article.id, "a1")
        XCTAssertEqual(vm.pendingAction?.kind, .star)
    }

    func testUndoLastReinsertsArticleAtOriginalIndex() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a2"}"#))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2"), sampleArticle(id: "a3")]

        await vm.dismiss(article: sampleArticle(id: "a2"))   // index 1 を削除
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a3"])

        vm.undoLast()

        // 元の位置（index 1）に戻る。保留は解除。
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2", "a3"])
        XCTAssertNil(vm.pendingAction)
    }

    func testCommitPendingSuccessClearsPendingAndKeepsRemoval() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))
        await vm.commitPending()

        XCTAssertNil(vm.pendingAction)
        XCTAssertEqual(vm.articles.map { $0.id }, ["a2"])   // 確定済み（戻らない）
        XCTAssertNil(vm.errorMessage)
    }

    func testCommitPendingFailureReinsertsAndSetsError() async throws {
        // 失敗するクライアント。初回 star は保留のみ（API 未呼出）、commit で 500 → 復元。
        let vm = FeedViewModel(apiClient: makeClient(json: "", statusCode: 500))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))
        await vm.commitPending()

        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2"])   // 復元
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.pendingAction)
    }

    func testStagingNewActionCommitsPrevious() async throws {
        // モックを直接持ち、直前操作が実際にサーバへ送信されたことを検証する（API 経路の確証）。
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))   // 保留 a1（API 未送信）
        XCTAssertNil(mock.lastRequest)                     // まだ送信されていない
        await vm.dismiss(article: sampleArticle(id: "a2"))  // 直前 a1 を確定送信し a2 を保留

        XCTAssertEqual(vm.pendingAction?.article.id, "a2")
        XCTAssertEqual(vm.pendingAction?.kind, .dismiss)
        XCTAssertTrue(vm.articles.isEmpty)
        // 直前の star(a1) がサーバへ確定送信された。
        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a1/star")
    }

    func testLoadFeedCommitsPendingBeforeReplacingArticles() async throws {
        // リフレッシュ前に保留を確定し、id 重複（楽観削除した記事の再出現）を防ぐ。issue #111 H1。
        let json = #"{"articles":[{"id":"a1","title":"X","url":"https://e.com","source":"s","score":0.5,"published_at":"2026-05-31T06:00:00Z"}],"date":"2026-05-31"}"#
        let mock = MockURLSession(data: json.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))   // 保留 a1
        await vm.loadFeed()                                // 取得前に a1 を確定

        XCTAssertNil(vm.pendingAction)                     // 保留は解消済み
        // a1 が二重にならない（重複 id 無し）。
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1"])
    }

    func testStageClearsExpandedId() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        vm.articles = [sampleArticle(id: "a1")]
        vm.expandedId = "a1"

        await vm.star(article: sampleArticle(id: "a1"))

        XCTAssertNil(vm.expandedId)   // 操作で展開状態は解除される
    }

    // MARK: - issue #82: 生成上限 429 メッセージ

    func testGenerationLimitMessageFormatsRetryTime() {
        XCTAssertEqual(FeedViewModel.generationLimitMessage(retryAfter: nil), "本日の生成上限に達しました")
        XCTAssertEqual(FeedViewModel.generationLimitMessage(retryAfter: 30), "本日の生成上限に達しました（まもなくに可能）")
        XCTAssertEqual(FeedViewModel.generationLimitMessage(retryAfter: 90), "本日の生成上限に達しました（約2分後に可能）")
        XCTAssertEqual(FeedViewModel.generationLimitMessage(retryAfter: 43200), "本日の生成上限に達しました（約12時間後に可能）")
        // 境界（3599秒）: web と揃えて「約60分後」ではなく「約1時間後」（review #1）。
        XCTAssertEqual(FeedViewModel.generationLimitMessage(retryAfter: 3599), "本日の生成上限に達しました（約1時間後に可能）")
    }

    func testBulkStarSurfaces429LimitMessage() async throws {
        // 一括 Star が 429（生成上限）に当たったら上限メッセージを出す（web とパリティ・review #2）。
        let mock = MockURLSession(data: Data(), statusCode: 429, headerFields: ["Retry-After": "43200"])
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]
        vm.selectedIds = ["a1", "a2"]

        await vm.bulkStar()

        XCTAssertEqual(vm.errorMessage, "本日の生成上限に達しました（約12時間後に可能）")
    }

    func testStarOn429SetsLimitMessageAndRestoresArticle() async throws {
        // 429 + Retry-After を返すクライアントで star を確定させると、記事が戻り上限メッセージが出る。
        let mock = MockURLSession(data: Data(), statusCode: 429, headerFields: ["Retry-After": "43200"])
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))   // 楽観削除 + 保留
        await vm.commitPending()                          // 確定 → 429

        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2"])   // 記事が戻る
        XCTAssertEqual(vm.errorMessage, "本日の生成上限に達しました（約12時間後に可能）")
        XCTAssertNil(vm.pendingAction)
    }

    func testToggleExpandTogglesExpandedId() {
        let vm = FeedViewModel(apiClient: makeClient(json: "{}"))

        vm.toggleExpand("a1")
        XCTAssertEqual(vm.expandedId, "a1")

        vm.toggleExpand("a1")
        XCTAssertNil(vm.expandedId)
    }

    // MARK: - issue #54: オフライン時の事前無効化

    func testIsOnlineReflectsInjectedNetworkMonitor() {
        let vm = FeedViewModel(apiClient: makeClient(json: "{}"), networkMonitor: StubNetworkMonitor(isOnline: false))

        XCTAssertFalse(vm.isOnline)
    }

    func testLoadFeedWhileOfflineDoesNotCallAPIAndSetsOfflineMessage() async throws {
        let mock = MockURLSession(data: Data(), statusCode: 200)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        let vm = FeedViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: false))

        await vm.loadFeed()

        XCTAssertNil(mock.lastRequest)   // ネットワークを一切呼ばない
        XCTAssertEqual(vm.errorMessage, "オフラインです。接続を確認してから、もう一度お試しください")
        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadFeedWhileOfflineKeepsExistingArticles() async throws {
        // ロード済み記事がある状態でオフラインの loadFeed を呼んでも、既存の一覧は消えない
        // （オフラインガードが articles 更新より前に return する順序の回帰防止）。
        let mock = MockURLSession(data: Data(), statusCode: 200)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        let vm = FeedViewModel(apiClient: client, networkMonitor: StubNetworkMonitor(isOnline: false))
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.loadFeed()

        XCTAssertNil(mock.lastRequest)
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2"])   // 既存一覧が保持される
    }

    func testLoadFeedWhileOnlineStillWorksWithInjectedNetworkMonitor() async throws {
        // 回帰防止: networkMonitor 注入後もオンライン時の既存挙動が壊れていないこと。
        let json = #"{"articles": [{"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"}], "date": "2026-05-31"}"#
        let vm = FeedViewModel(apiClient: makeClient(json: json), networkMonitor: StubNetworkMonitor(isOnline: true))

        await vm.loadFeed()

        XCTAssertEqual(vm.articles.count, 1)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - issue #53: ロード失敗と「本当に空」の空状態を区別する

    func testDisplayStateIsErrorWhenLoadFeedFailsWithEmptyArticles() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
    }

    func testDisplayStateIsContentWhenLoadFeedFailsButArticlesRemain() async throws {
        // リフレッシュ失敗時は既存の一覧を残す（articles はクリアしない）。
        // その場合は空状態ではなく一覧を優先して表示する。
        let vm = FeedViewModel(apiClient: makeClient(json: "", statusCode: 500))
        vm.articles = [sampleArticle(id: "a1")]

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .content)
    }

    func testDisplayStateIsEmptyWhenLoadFeedSucceedsWithNoArticles() async throws {
        let vm = FeedViewModel(apiClient: makeClient(json: #"{"articles": [], "date": "2026-05-31"}"#))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .empty)
    }

    func testDisplayStateIsLoadingWhileInitialLoadInProgress() {
        let vm = FeedViewModel(apiClient: makeClient(json: "{}"))
        vm.isLoading = true

        XCTAssertEqual(vm.displayState, .loading)
    }

    // MARK: - issue #58: インラインエラー表示（displayState .error）とアラートの二重表示防止

    func testShouldPresentErrorAlertFalseWhenListEmptyAndDisplayStateIsError() async throws {
        // 一覧が空でロード失敗＝インラインエラー表示中は、同じエラーのアラートを重ねて出さない。
        let vm = FeedViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertTrueWhenListNonEmptyAndErrorMessageSet() {
        // 一覧が非空のまま発生したエラー（一括Star失敗等）はインライン表示が無いのでアラートを出す。
        let vm = FeedViewModel(apiClient: makeClient(json: "{}"))
        vm.articles = [sampleArticle(id: "a1")]
        vm.errorMessage = "本日の生成上限に達しました"

        XCTAssertEqual(vm.displayState, .content)
        XCTAssertTrue(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertFalseWhenNoErrorMessage() {
        let vm = FeedViewModel(apiClient: makeClient(json: "{}"))

        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    // MARK: - star cancelled alert バグ修正: キャンセルはエラー表示・再挿入をしない

    func testCommitPendingCancellationDoesNotShowErrorOrReinsert() async throws {
        // トーストの .task がキャンセルされると、サスペンド中の commit() の POST が
        // URLError(.cancelled) を投げる。これをエラー表示・記事再挿入の対象にしないことを保証する。
        let requestStarted = XCTestExpectation(description: "request started")
        let mock = CancellationAwareMockURLSession(requestStarted: requestStarted)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1")]
        await vm.star(article: sampleArticle(id: "a1"))   // 保留のみ（API 未送信）

        let task = Task { await vm.commitPending() }
        await fulfillment(of: [requestStarted], timeout: 1.0)
        task.cancel()
        await task.value

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.articles.isEmpty)   // 再挿入されていない（幻の二重 Star を防ぐ）
    }

    func testCommitPendingRawCancellationErrorDoesNotShowErrorOrReinsert() async throws {
        // 上のテストは URLError(.cancelled) 経路のみを検証しており、`catch is CancellationError`
        // 分岐（素の CancellationError を投げる経路）は未検証だった（レビュー指摘）。
        let requestStarted = XCTestExpectation(description: "request started")
        let mock = CancellationAwareMockURLSession(requestStarted: requestStarted, cancellationBehavior: .rawCancellationError)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))
        vm.articles = [sampleArticle(id: "a1")]
        await vm.star(article: sampleArticle(id: "a1"))   // 保留のみ（API 未送信）

        let task = Task { await vm.commitPending() }
        await fulfillment(of: [requestStarted], timeout: 1.0)
        task.cancel()
        await task.value

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.articles.isEmpty)
    }

    // MARK: - 自動確定タイマーの FeedViewModel 所有化（トースト .task の自己破壊構造を解消）

    func testStageAutoCommitsAfterGracePeriodElapses() async throws {
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(
            apiClient: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock),
            undoGracePeriod: .milliseconds(50)
        )
        vm.articles = [sampleArticle(id: "a1")]

        await vm.star(article: sampleArticle(id: "a1"))
        XCTAssertNil(mock.lastRequest)   // 猶予中はまだ送信されない

        // 固定 sleep ではなく「いつか条件を満たす」形のポーリングにして CI 負荷でのフレークを避ける。
        await waitUntil { mock.lastRequest != nil }

        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a1/star")
        XCTAssertNil(vm.pendingAction)
    }

    func testUndoLastCancelsAutoCommitTimer() async throws {
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(
            apiClient: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock),
            undoGracePeriod: .milliseconds(50)
        )
        vm.articles = [sampleArticle(id: "a1")]

        await vm.star(article: sampleArticle(id: "a1"))
        vm.undoLast()

        // 「何も起きない」ことの確認なのでポーリングにはできない。猶予(50ms)に対し
        // 20倍の余白を確保し、CI 負荷下でも誤って早期リターンしないようにする。
        try await Task.sleep(for: .seconds(1))

        XCTAssertNil(mock.lastRequest)
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1"])   // 元の位置に復元済み
    }

    func testStagingNewActionRestartsFullGracePeriodForNewPendingAction() async throws {
        // A stage → 猶予内に B stage → A は即時確定送信、B は新たなフル猶予後に確定される
        // （旧 A タイマーがキャンセルされ、B の猶予が短縮されないこと）。
        //
        // タイマー再スタートの有無は「いつ B が確定するか」でしか区別できない（確定される記事自体は
        // どちらの実装でも最終的に a2/dismiss になる）ため、中間チェックの時刻選びが本質的に重要。
        // grace=800ms・A→B のステージ間隔=300ms のとき:
        //   - 再スタートしていない場合（バグ）の確定時刻 = B staging から 800-300=500ms 後
        //   - 再スタートした場合（正しい）の確定時刻     = B staging から 800ms 後
        // 中間チェックをその窓の中央（650ms）に置くことで両側に 150ms の余白を確保する
        // （旧実装は 200ms 猶予に対し 50/70ms 余白で CI 負荷によりフレークしていた・レビュー指摘）。
        // 確定側の最終待機はポーリングにし、正確な時刻に依存しないようにする。
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let vm = FeedViewModel(
            apiClient: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock),
            undoGracePeriod: .milliseconds(800)
        )
        vm.articles = [sampleArticle(id: "a1"), sampleArticle(id: "a2")]

        await vm.star(article: sampleArticle(id: "a1"))       // A staged, 800ms タイマー開始
        try await Task.sleep(for: .milliseconds(300))
        await vm.dismiss(article: sampleArticle(id: "a2"))    // B staged。A は stage() 内で即時確定。

        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a1/star")   // A は即時確定済み

        // B staging から 650ms 経過（バグ側の締切 500ms・正しい側の締切 800ms のちょうど中間、
        // 両側に 150ms の余白）。再スタートが効いていれば、この時点ではまだ B は未確定のはず。
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a1/star")   // まだ B は未確定
        XCTAssertNotNil(vm.pendingAction)

        // 確定側はポーリングで待つ（固定時刻に依存しない。正しい締切 800ms に対し 2 秒の余裕）。
        await waitUntil(timeout: .seconds(2)) {
            mock.lastRequest?.url?.path == "/articles/a2/dismiss"
        }
        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a2/dismiss")   // B が確定
        XCTAssertNil(vm.pendingAction)
    }

    // MARK: - loadFeed 経路のキャンセルフィルタ

    func testLoadFeedCancellationDoesNotSetErrorMessage() async throws {
        let requestStarted = XCTestExpectation(description: "request started")
        let mock = CancellationAwareMockURLSession(requestStarted: requestStarted)
        let vm = FeedViewModel(apiClient: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))

        let task = Task { await vm.loadFeed() }
        await fulfillment(of: [requestStarted], timeout: 1.0)
        task.cancel()
        await task.value

        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)   // 後始末（isLoading = false）はキャンセル経路でも必ず走る
    }
}

/// キャンセル時にどの例外型を投げるかを選べる file-private モック。共有 `MockURLSession`
/// （即時 return）ではキャンセルレースを再現できないため別途定義する。
private final class CancellationAwareMockURLSession: URLSessionProtocol {
    /// キャンセル時に投げる例外の型。
    enum CancellationBehavior {
        /// 実 `URLSession` の挙動を模す（既定）: Task キャンセルは `URLError(.cancelled)` になる。
        case urlErrorCancelled
        /// `commit()`/`loadFeed()` の `catch is CancellationError` 分岐を直接検証するための、
        /// 素の `CancellationError` を投げるモード。
        case rawCancellationError
    }

    /// リクエスト開始（`data(for:)` 呼び出し）を通知する。
    private let requestStarted: XCTestExpectation
    private let cancellationBehavior: CancellationBehavior

    init(requestStarted: XCTestExpectation, cancellationBehavior: CancellationBehavior = .urlErrorCancelled) {
        self.requestStarted = requestStarted
        self.cancellationBehavior = cancellationBehavior
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestStarted.fulfill()
        do {
            // キャンセルされるまでサスペンドし続ける（実通信のレイテンシを模す）。
            try await Task.sleep(for: .seconds(10))
        } catch {
            switch cancellationBehavior {
            case .urlErrorCancelled:
                throw URLError(.cancelled)
            case .rawCancellationError:
                throw CancellationError()
            }
        }
        // このテストでは常にキャンセルされる想定。fatalError はテストプロセス全体を
        // 落としてしまうため、通常の throw にする（呼び出し元は errorMessage 検証で自然に fail する）。
        throw UnexpectedCompletionError()
    }
}

/// `CancellationAwareMockURLSession` が想定外にキャンセルされず完了した場合に投げるエラー。
/// テストは通常の catch 経路で `errorMessage` が非 nil になり自然に fail する。
private struct UnexpectedCompletionError: Error {}

/// `condition` が真になるまで、または `timeout` に達するまで短い間隔でポーリングする。
///
/// タイマー系テストで固定 sleep 時間に依存すると CI 負荷でフレークしうるため、
/// 「いつかは条件を満たす」ことを広い timeout の中で確認する形に置き換える。
private func waitUntil(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(20),
    condition: () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        try? await Task.sleep(for: pollInterval)
    }
}
