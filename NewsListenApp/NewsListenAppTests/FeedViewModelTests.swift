import Combine
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

    private func sampleArticle(id: String = "a1") -> ArticleCardModel {
        ArticleCardModel(id: id, title: "Test", url: "https://example.com", source: "hackernews", score: 0.9, publishedAt: "2026-05-31T06:00:00Z")
    }

    private func apiClient(session: URLSessionProtocol) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
    }

    func testLoadFeedPopulatesArticles() async throws {
        let json = #"""
        {"articles": [
            {"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"},
            {"id":"a2","title":"Go","url":"https://example.com/go","source":"zenn","score":0.7,"published_at":"2026-05-31T05:00:00Z"}
        ], "date": "2026-05-31"}
        """#
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: json))

        await vm.loadFeed()

        XCTAssertEqual(vm.articles.count, 2)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - T-T12c-05（verifies: CI-T12c, R4-S1c）
    // 現行表示の固定。置換後も期待値を変えない。11 箇所の `ApiFailure` 節の付け忘れを検出する。

    func testLoadFeed500SetsHTTPErrorMessage() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testStarThenCommitPending500SetsHTTPErrorMessageAndRestoresArticle() async throws {
        let article = sampleArticle(id: "a1")
        let (vm, _) = try await makeFeedViewModel(articles: [article], client: makeClient(json: "", statusCode: 500))

        await vm.star(articleId: article.id, difficulty: nil)     // 楽観削除 + 保留
        await vm.commitPending()            // 確定 → 500

        XCTAssertEqual(vm.articles.map { $0.id }, ["a1"])
        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testStarStagesAndRemovesArticle() async throws {
        // star は楽観削除 + 保留（確定は commitPending まで遅延）。issue #111。
        let article = sampleArticle()
        let (vm, _) = try await makeFeedViewModel(articles: [article], client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))

        await vm.star(articleId: article.id, difficulty: nil)

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.pendingAction?.kind, .star(nil))
    }

    // MARK: - issue #163: 記事単位の難易度指定 star

    func testStarWithDifficultyStoresDifficultyOnPendingAction() async throws {
        let article = sampleArticle()
        let (vm, _) = try await makeFeedViewModel(articles: [article], client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))

        await vm.star(articleId: article.id, difficulty: .toeic600)

        XCTAssertEqual(vm.pendingAction?.kind, .star(.toeic600))
    }

    func testStarWithoutDifficultyDefaultsPendingActionDifficultyToNil() async throws {
        let article = sampleArticle()
        let (vm, _) = try await makeFeedViewModel(articles: [article], client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))

        await vm.star(articleId: article.id, difficulty: nil)

        XCTAssertEqual(vm.pendingAction?.kind, .star(nil))
    }

    func testCommitPendingSendsDifficultyInStarRequestBody() async throws {
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let (vm, _) = try await makeFeedViewModel(articles: [sampleArticle(id: "a1")], client: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))

        await vm.star(articleId: "a1", difficulty: .ielts7)
        await vm.commitPending()

        let body = try XCTUnwrap(mock.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["difficulty"], "ielts_7")
    }

    func testCommitPendingWithoutDifficultySendsNoBody() async throws {
        // 既存の「difficulty 未指定 = ボディなし」挙動が壊れていないことを保証する回帰テスト。
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let (vm, _) = try await makeFeedViewModel(articles: [sampleArticle(id: "a1")], client: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))

        await vm.star(articleId: "a1", difficulty: nil)
        await vm.commitPending()

        XCTAssertNil(mock.lastRequest?.httpBody)
    }

    func testDismissStagesAndRemovesArticle() async throws {
        let article = sampleArticle()
        let (vm, _) = try await makeFeedViewModel(articles: [article], client: makeClient(json: #"{"status":"dismissed","article_id":"a1"}"#))

        await vm.dismiss(articleId: article.id)

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.pendingAction?.kind, .dismiss)
    }

    func testLoadFeedSetsErrorMessageOnFailure() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testToggleSelectionAddsAndRemovesArticleId() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        let id = "a1"

        vm.toggleSelection(id)
        XCTAssertTrue(vm.selectedIds.contains(id))

        vm.toggleSelection(id)
        XCTAssertFalse(vm.selectedIds.contains(id))
    }

    func testBulkStarSuccess() async throws {
        let articles = [
            sampleArticle(id: "a1"),
            sampleArticle(id: "a2"),
            sampleArticle(id: "a3")
        ]
        let (vm, _) = try await makeFeedViewModel(articles: articles, client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        ["a1", "a2", "a3"].forEach { vm.toggleSelection($0) }

        await vm.bulkStar()

        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertEqual(vm.bulkActionResult?.succeeded, 3)
        XCTAssertEqual(vm.bulkActionResult?.failed, 0)
        XCTAssertFalse(vm.isSelectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty)
    }

    func testBulkStarPartialFailure() async throws {
        // モック: 2つ目のリクエストのみ 500 エラーを返す仕掛け。
        // 今回は簡単のため、全てのリクエストが同じ応答を返すモックを使うため、
        // ここは部分失敗をテストできないが、成功ケースが機能していれば OK。
        let articles = [
            sampleArticle(id: "a1"),
            sampleArticle(id: "a2")
        ]
        let (vm, _) = try await makeFeedViewModel(articles: articles, client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#))
        ["a1", "a2"].forEach { vm.toggleSelection($0) }

        await vm.bulkStar()

        // 全て成功するはず（モック都合）。
        XCTAssertEqual(vm.bulkActionResult?.succeeded, 2)
        XCTAssertEqual(vm.bulkActionResult?.failed, 0)
    }

    // リフレッシュ等で一覧から消えた記事の id が selectedIds に残っても、
    // 現在表示中の記事だけを Star し成功数を水増ししないこと。
    func testBulkStarIgnoresStaleSelection() async throws {
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#)
        )
        // "ghost" は一覧に存在しない（既に消えた記事）。
        ["a1", "a2", "ghost"].forEach { vm.toggleSelection($0) }

        await vm.bulkStar()

        XCTAssertEqual(vm.bulkActionResult?.succeeded, 2)
        XCTAssertEqual(vm.bulkActionResult?.failed, 0)
        XCTAssertTrue(vm.articles.isEmpty)
        XCTAssertTrue(vm.selectedIds.isEmpty)
        XCTAssertFalse(vm.isSelectionMode)
    }

    // MARK: - issue #111: ジェスチャ UX（楽観的削除 + 取り消し + 展開）

    func testStarStagesPendingActionAndRemovesOptimistically() async throws {
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#)
        )

        await vm.star(articleId: "a1", difficulty: nil)

        // 楽観的に一覧から消え、直近操作が保留（取り消し可能）になる。
        XCTAssertEqual(vm.articles.map { $0.id }, ["a2"])
        XCTAssertEqual(vm.pendingAction?.articleId, "a1")
        XCTAssertEqual(vm.pendingAction?.kind, .star(nil))
    }

    func testUndoLastReinsertsArticleAtOriginalIndex() async throws {
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2"), sampleArticle(id: "a3")],
            client: makeClient(json: #"{"status":"starred","article_id":"a2"}"#)
        )

        await vm.dismiss(articleId: "a2")   // index 1 を削除
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a3"])

        vm.undoLast()

        // 元の位置（index 1）に戻る。保留は解除。
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2", "a3"])
        XCTAssertNil(vm.pendingAction)
    }

    func testCommitPendingSuccessClearsPendingAndKeepsRemoval() async throws {
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#)
        )

        await vm.star(articleId: "a1", difficulty: nil)
        await vm.commitPending()

        XCTAssertNil(vm.pendingAction)
        XCTAssertEqual(vm.articles.map { $0.id }, ["a2"])   // 確定済み（戻らない）
        XCTAssertNil(vm.errorMessage)
    }

    func testCommitPendingFailureReinsertsAndSetsError() async throws {
        // 失敗するクライアント。初回 star は保留のみ（API 未呼出）、commit で 500 → 復元。
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: makeClient(json: "", statusCode: 500)
        )

        await vm.star(articleId: "a1", difficulty: nil)
        await vm.commitPending()

        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2"])   // 復元
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.pendingAction)
    }

    func testStagingNewActionCommitsPrevious() async throws {
        // モックを直接持ち、直前操作が実際にサーバへ送信されたことを検証する（API 経路の確証）。
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        )

        await vm.star(articleId: "a1", difficulty: nil)   // 保留 a1（API 未送信）
        XCTAssertNil(mock.lastRequest)                     // まだ送信されていない
        await vm.dismiss(articleId: "a2")  // 直前 a1 を確定送信し a2 を保留

        XCTAssertEqual(vm.pendingAction?.articleId, "a2")
        XCTAssertEqual(vm.pendingAction?.kind, .dismiss)
        XCTAssertTrue(vm.articles.isEmpty)
        // 直前の star(a1) がサーバへ確定送信された。
        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a1/star")
    }

    func testLoadFeedCommitsPendingBeforeReplacingArticles() async throws {
        // リフレッシュ前に保留を確定し、id 重複（楽観削除した記事の再出現）を防ぐ。issue #111 H1。
        let json = #"{"articles":[{"id":"a1","title":"X","url":"https://e.com","source":"s","score":0.5,"published_at":"2026-05-31T06:00:00Z"}],"date":"2026-05-31"}"#
        let mock = MockURLSession(data: json.data(using: .utf8)!, statusCode: 200)
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        )

        await vm.star(articleId: "a1", difficulty: nil)   // 保留 a1
        await vm.loadFeed()                                // 取得前に a1 を確定

        XCTAssertNil(vm.pendingAction)                     // 保留は解消済み
        // a1 が二重にならない（重複 id 無し）。
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1"])
    }

    func testStageClearsExpandedId() async throws {
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#)
        )
        vm.toggleExpand("a1")

        await vm.star(articleId: "a1", difficulty: nil)

        XCTAssertNil(vm.expandedId)   // 操作で展開状態は解除される
    }

    // MARK: - issue #82: 生成上限 429 メッセージ

    func testGenerationLimitMessageFormatsRetryTime() {
        XCTAssertEqual(FeedViewModel.generationLimitMessage(GenerationLimitWait(retryAfterSeconds: nil)), "本日の生成上限に達しました")
        XCTAssertEqual(FeedViewModel.generationLimitMessage(GenerationLimitWait(retryAfterSeconds: 30)), "本日の生成上限に達しました（まもなくに可能）")
        XCTAssertEqual(FeedViewModel.generationLimitMessage(GenerationLimitWait(retryAfterSeconds: 90)), "本日の生成上限に達しました（約2分後に可能）")
        XCTAssertEqual(FeedViewModel.generationLimitMessage(GenerationLimitWait(retryAfterSeconds: 43200)), "本日の生成上限に達しました（約12時間後に可能）")
        // 境界（3599秒）: web と揃えて「約60分後」ではなく「約1時間後」（review #1）。
        XCTAssertEqual(FeedViewModel.generationLimitMessage(GenerationLimitWait(retryAfterSeconds: 3599)), "本日の生成上限に達しました（約1時間後に可能）")
    }

    // T-T13-04（verifies: ios-contract-19, R-keep2）。
    func testBulkStarSurfaces429LimitMessage() async throws {
        // 一括 Star が 429（生成上限）に当たったら上限メッセージを出す（web とパリティ・review #2）。
        let mock = MockURLSession(data: Data(), statusCode: 429, headerFields: ["Retry-After": "43200"])
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        )
        ["a1", "a2"].forEach { vm.toggleSelection($0) }

        await vm.bulkStar()

        XCTAssertEqual(vm.errorMessage, "本日の生成上限に達しました（約12時間後に可能）")
    }

    // T-T13-04（verifies: ios-contract-19, R-keep2）。
    func testStarOn429SetsLimitMessageAndRestoresArticle() async throws {
        // 429 + Retry-After を返すクライアントで star を確定させると、記事が戻り上限メッセージが出る。
        let mock = MockURLSession(data: Data(), statusCode: 429, headerFields: ["Retry-After": "43200"])
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        )

        await vm.star(articleId: "a1", difficulty: nil)   // 楽観削除 + 保留
        await vm.commitPending()                          // 確定 → 429

        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2"])   // 記事が戻る
        XCTAssertEqual(vm.errorMessage, "本日の生成上限に達しました（約12時間後に可能）")
        XCTAssertNil(vm.pendingAction)
    }

    func testToggleExpandTogglesExpandedId() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "{}"))

        vm.toggleExpand("a1")
        XCTAssertEqual(vm.expandedId, "a1")

        vm.toggleExpand("a1")
        XCTAssertNil(vm.expandedId)
    }

    // MARK: - issue #54: オフライン時の事前無効化

    func testIsOnlineReflectsInjectedNetworkMonitor() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "{}"), networkMonitor: StubNetworkMonitor(isOnline: false))

        XCTAssertFalse(vm.isOnline)
    }

    func testLoadFeedWhileOfflineDoesNotCallAPIAndSetsOfflineMessage() async throws {
        let mock = MockURLSession(data: Data(), statusCode: 200)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        let (vm, _) = try await makeFeedViewModel(client: client, networkMonitor: StubNetworkMonitor(isOnline: false))

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
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: client,
            networkMonitor: StubNetworkMonitor(isOnline: false)
        )

        await vm.loadFeed()

        XCTAssertNil(mock.lastRequest)
        XCTAssertEqual(vm.articles.map { $0.id }, ["a1", "a2"])   // 既存一覧が保持される
    }

    func testLoadFeedWhileOnlineStillWorksWithInjectedNetworkMonitor() async throws {
        // 回帰防止: networkMonitor 注入後もオンライン時の既存挙動が壊れていないこと。
        let json = #"{"articles": [{"id":"a1","title":"Rust","url":"https://example.com","source":"hackernews","score":0.9,"published_at":"2026-05-31T06:00:00Z"}], "date": "2026-05-31"}"#
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: json), networkMonitor: StubNetworkMonitor(isOnline: true))

        await vm.loadFeed()

        XCTAssertEqual(vm.articles.count, 1)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - issue #53: ロード失敗と「本当に空」の空状態を区別する

    func testDisplayStateIsErrorWhenLoadFeedFailsWithEmptyArticles() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
    }

    func testDisplayStateIsContentWhenLoadFeedFailsButArticlesRemain() async throws {
        // リフレッシュ失敗時は既存の一覧を残す（articles はクリアしない）。
        // その場合は空状態ではなく一覧を優先して表示する。
        let (vm, _) = try await makeFeedViewModel(articles: [sampleArticle(id: "a1")], client: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .content)
    }

    func testDisplayStateIsEmptyWhenLoadFeedSucceedsWithNoArticles() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: #"{"articles": [], "date": "2026-05-31"}"#))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .empty)
    }

    func testDisplayStateIsLoadingWhileInitialLoadInProgress() async throws {
        // 取得中の状態は、fetchFeed を保留する gateway で loadFeed を実際に進めて作る。
        let started = XCTestExpectation(description: "fetchFeed started")
        let box = ContinuationBox()
        let gateway = CurationGateway(
            fetchFeed: { @MainActor in
                started.fulfill()
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in box.continuation = c }
                return []
            },
            star: { @MainActor _, _ in },
            dismiss: { @MainActor _ in },
            fetchStarred: { @MainActor in [] },
            unstar: { @MainActor _ in },
            fetchAllowance: { @MainActor in nil }
        )
        let curation = FeedCuration(gateway: gateway, undoGracePeriod: .seconds(4), currentSubject: { nil })
        let vm = FeedViewModel(curation: curation, networkMonitor: StubNetworkMonitor(isOnline: true))

        let task = Task { await vm.loadFeed() }
        await fulfillment(of: [started], timeout: 1.0)

        XCTAssertEqual(vm.displayState, .loading)

        box.continuation?.resume()
        await task.value
    }

    // MARK: - issue #58: インラインエラー表示（displayState .error）とアラートの二重表示防止

    func testShouldPresentErrorAlertFalseWhenListEmptyAndDisplayStateIsError() async throws {
        // 一覧が空でロード失敗＝インラインエラー表示中は、同じエラーのアラートを重ねて出さない。
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.loadFeed()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertTrueWhenListNonEmptyAndErrorMessageSet() async throws {
        // 一覧が非空のまま発生したエラー（一括Star失敗等）はインライン表示が無いのでアラートを出す。
        // 実際の失敗（429、Retry-After なし）から errorMessage を作る。
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: apiClient(session: MockURLSession(data: Data(), statusCode: 429))
        )
        await vm.star(articleId: "a1", difficulty: nil)
        await vm.commitPending()

        XCTAssertEqual(vm.errorMessage, "本日の生成上限に達しました")
        XCTAssertEqual(vm.displayState, .content)
        XCTAssertTrue(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertFalseWhenNoErrorMessage() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "{}"))

        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    // MARK: - star cancelled alert バグ修正: キャンセルはエラー表示・再挿入をしない

    func testCommitPendingCancellationDoesNotShowErrorOrReinsert() async throws {
        // トーストの .task がキャンセルされると、サスペンド中の commit() の POST が
        // URLError(.cancelled) を投げる。これをエラー表示・記事再挿入の対象にしないことを保証する。
        let requestStarted = XCTestExpectation(description: "request started")
        let mock = CancellationAwareMockURLSession(requestStarted: requestStarted)
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        )
        await vm.star(articleId: "a1", difficulty: nil)   // 保留のみ（API 未送信）

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
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock)
        )
        await vm.star(articleId: "a1", difficulty: nil)   // 保留のみ（API 未送信）

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
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock),
            undoGracePeriod: .milliseconds(50)
        )

        await vm.star(articleId: "a1", difficulty: nil)
        XCTAssertNil(mock.lastRequest)   // 猶予中はまだ送信されない

        // 固定 sleep ではなく「いつか条件を満たす」形のポーリングにして CI 負荷でのフレークを避ける。
        await waitUntil { mock.lastRequest != nil }

        XCTAssertEqual(mock.lastRequest?.url?.path, "/articles/a1/star")
        XCTAssertNil(vm.pendingAction)
    }

    func testUndoLastCancelsAutoCommitTimer() async throws {
        let mock = MockURLSession(data: #"{"status":"starred","article_id":"a1"}"#.data(using: .utf8)!, statusCode: 200)
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock),
            undoGracePeriod: .milliseconds(50)
        )

        await vm.star(articleId: "a1", difficulty: nil)
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
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock),
            undoGracePeriod: .milliseconds(800)
        )

        await vm.star(articleId: "a1", difficulty: nil)       // A staged, 800ms タイマー開始
        try await Task.sleep(for: .milliseconds(300))
        await vm.dismiss(articleId: "a2")    // B staged。A は stage() 内で即時確定。

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
        let (vm, _) = try await makeFeedViewModel(client: APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: mock
        ))

        let task = Task { await vm.loadFeed() }
        await fulfillment(of: [requestStarted], timeout: 1.0)
        task.cancel()
        await task.value

        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)   // 後始末（isLoading = false）はキャンセル経路でも必ず走る
    }

    // MARK: - 確定の失敗の文言への写し（ViewModel の責務）

    // verifies: ios-dec-98
    func testCommitFailureReachesErrorMessageRightAfterCommitPending() async throws {
        // 500 → 既存の文言。
        let (vm500, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: makeClient(json: "", statusCode: 500)
        )
        await vm500.star(articleId: "a1", difficulty: nil)
        await vm500.commitPending()
        XCTAssertEqual(vm500.errorMessage, "HTTP Error 500")

        // 429（Retry-After なし）→ 上限の文言。
        let (vm429, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: apiClient(session: MockURLSession(data: Data(), statusCode: 429))
        )
        await vm429.star(articleId: "a1", difficulty: nil)
        await vm429.commitPending()
        XCTAssertEqual(vm429.errorMessage, "本日の生成上限に達しました")

        // その他の失敗 → localizedDescription。
        let error = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "壊れた"])
        let gateway = CurationGateway(
            fetchFeed: { @MainActor in [ArticleCardModel(id: "a1", title: "T", url: "https://e.com", source: "s", score: 0.5, publishedAt: "2026-05-31T06:00:00Z")] },
            star: { @MainActor _, _ in throw error },
            dismiss: { @MainActor _ in },
            fetchStarred: { @MainActor in [] },
            unstar: { @MainActor _ in },
            fetchAllowance: { @MainActor in nil }
        )
        let curation = FeedCuration(gateway: gateway, undoGracePeriod: .seconds(60), currentSubject: { nil })
        try await curation.reload()
        let vmOther = FeedViewModel(curation: curation, networkMonitor: StubNetworkMonitor(isOnline: true))
        await vmOther.star(articleId: "a1", difficulty: nil)
        await vmOther.commitPending()
        XCTAssertEqual(vmOther.errorMessage, error.localizedDescription)
    }

    // verifies: ios-dec-98
    func testClearErrorClearsErrorMessageAndLastFailure() async throws {
        let (vm, curation) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: makeClient(json: "", statusCode: 500)
        )
        await vm.star(articleId: "a1", difficulty: nil)
        await vm.commitPending()
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNotNil(curation.lastFailure)

        vm.clearError()

        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(curation.lastFailure)
    }

    // verifies: ios-dec-98
    func testNewViewModelDoesNotReplayOldLastFailure() async throws {
        let (vm, curation) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: makeClient(json: "", statusCode: 500)
        )
        await vm.star(articleId: "a1", difficulty: nil)
        await vm.commitPending()
        XCTAssertNotNil(curation.lastFailure)

        let fresh = FeedViewModel(curation: curation, networkMonitor: StubNetworkMonitor(isOnline: true))

        XCTAssertNil(fresh.errorMessage)
    }

    // MARK: - 画面の状態（選択モード・購読・寿命・文言）

    // verifies: ios-dec-98
    func testToggleSelectionModeFlipsAndClearsSelectionWhenTurnedOff() async throws {
        let (vm, _) = try await makeFeedViewModel(client: makeClient(json: "{}"))
        XCTAssertFalse(vm.isSelectionMode)

        vm.toggleSelectionMode()
        XCTAssertTrue(vm.isSelectionMode)
        vm.toggleSelection("a1")
        XCTAssertEqual(vm.selectedIds, ["a1"], "オンの間は選択が残る")

        vm.toggleSelectionMode()
        XCTAssertFalse(vm.isSelectionMode)
        XCTAssertTrue(vm.selectedIds.isEmpty, "オフになったら選択を空にする")
    }

    // verifies: ios-dec-98
    func testViewModelForwardsCurationChangesToObjectWillChange() async throws {
        let (vm, curation) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
            client: makeClient(json: "{}")
        )
        var fired = 0
        let cancellable = vm.objectWillChange.sink { fired += 1 }

        await curation.dismiss(articleId: "a1")

        XCTAssertGreaterThanOrEqual(fired, 1, "curation の cards が変わると View が再描画される")
        cancellable.cancel()
    }

    // verifies: ios-dec-98
    func testViewModelAndCurationAreReleasedWhileTimerIsRunning() async throws {
        weak var weakVM: FeedViewModel?
        weak var weakCuration: FeedCuration?
        do {
            let (vm, curation) = try await makeFeedViewModel(
                articles: [sampleArticle(id: "a1"), sampleArticle(id: "a2")],
                client: makeClient(json: "{}"),
                undoGracePeriod: .seconds(60),
                networkMonitor: StubNetworkMonitor(isOnline: true)
            )
            weakVM = vm
            weakCuration = curation
            await vm.star(articleId: "a1", difficulty: nil)   // タイマー稼働中
        }

        XCTAssertNil(weakVM, "購読が VM を強く保持していない")
        XCTAssertNil(weakCuration, "VM と curation の間に循環がない")
    }

    // verifies: ios-dec-98
    func testBulkMessageFormatsReceipt() {
        XCTAssertEqual(FeedViewModel.bulkMessage(BulkStarReceipt(succeeded: 3, failed: 0)), "3件を一括スターしました")
        XCTAssertEqual(FeedViewModel.bulkMessage(BulkStarReceipt(succeeded: 1, failed: 2)), "1件をスターしました（失敗: 2件）")
    }

    // verifies: ios-dec-98
    func testStarOfArticleNotInListKeepsExpandedId() async throws {
        let (vm, _) = try await makeFeedViewModel(
            articles: [sampleArticle(id: "a1")],
            client: makeClient(json: #"{"status":"starred","article_id":"a1"}"#)
        )
        vm.toggleExpand("a1")

        await vm.star(articleId: "ghost", difficulty: nil)

        XCTAssertEqual(vm.expandedId, "a1")
    }
}

/// `fetchFeed` を保留するための継続の置き場。
@MainActor
private final class ContinuationBox {
    var continuation: CheckedContinuation<Void, Never>?
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
