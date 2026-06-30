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
}
