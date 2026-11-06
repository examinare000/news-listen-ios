import XCTest
@testable import NewsListenApp

/// 呼び出しごとに異なるレスポンスを返すモックセッション。
///
/// `MockURLSession` は固定データしか返せないため、load→add のように
/// 複数回の通信で内容が変わるシナリオや、成功→失敗の遷移の検証に使う。
private final class SequentialSession: URLSessionProtocol {
    /// 先頭から順に返す（データ, ステータスコード）のキュー。
    private var responses: [(data: Data, statusCode: Int)]

    /// - Parameter responses: 呼び出し順に返すデータ列（すべて 200 で返す）。
    init(_ responses: [Data]) {
        self.responses = responses.map { ($0, 200) }
    }

    /// - Parameter results: 呼び出し順に返す（データ, ステータスコード）列。失敗遷移の検証用。
    init(results: [(data: Data, statusCode: Int)]) {
        self.responses = results
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let next: (data: Data, statusCode: Int) = responses.isEmpty ? (Data(), 200) : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: next.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (next.data, response)
    }
}

/// API 呼び出し回数をカウントする記録用モックセッション。
private final class CallRecordingSession: URLSessionProtocol {
    private(set) var callCount = 0

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        callCount += 1
        let successJSON = #"{"default_difficulty":"toeic_600","default_playback_speed":null}"#.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (successJSON, response)
    }
}

@MainActor
final class SettingsViewModelTests: XCTestCase {

    /// 各テストが使う保存庫。主体 A に束縛する（XCTestCase はテストごとに別インスタンスなので共有されない）。
    private lazy var library: OfflineLibrary = {
        let library = OfflineLibrary(store: .live(cacheManager: AudioCacheManager()))
        library.bind(subject: subjectA)
        return library
    }()

    /// `library` を包む `OfflineDownloads`（現在主体は A）。
    private lazy var downloads: OfflineDownloads = makeDownloads(for: library)

    private func makeDownloads(for library: OfflineLibrary) -> OfflineDownloads {
        OfflineDownloads(
            library: library,
            fetchEpisode: { _ in throw ApiFailure.server(status: 500) },
            downloadAudio: { _ in Data() },
            currentSubject: { subjectA }
        )
    }

    private func makeClient(session: URLSessionProtocol) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
    }

    private func makeClient(json: String, statusCode: Int = 200) -> APIClient {
        makeClient(session: MockURLSession(data: json.data(using: .utf8)!, statusCode: statusCode))
    }

    /// 残り回数を読む `FeedCuration`。`client` は `apiClient:` に渡すものと同じ client を渡す（nil は API 未設定）。
    private func makeCuration(client: APIClient?) -> FeedCuration {
        FeedCuration(gateway: .live(client: { client }), undoGracePeriod: .seconds(4), currentSubject: { nil })
    }

    /// ソースの操作を担う `SourceSubscriptions`。`client` は `apiClient:` に渡すものと同じ client を渡す（nil は API 未設定）。
    private func makeSources(client: APIClient?) -> SourceSubscriptions {
        SourceSubscriptions(gateway: .live(client: { client }))
    }

    // verifies: ios-check-12
    func testLoadSourcesFetchesFromAPI() async throws {
        let json = #"""
        {"sources": [
            {"name":"HackerNews","url":"https://hnrss.org/frontpage"},
            {"name":"Zenn","url":"https://zenn.dev/feed"}
        ]}
        """#
        let client = makeClient(json: json)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadSources()

        XCTAssertEqual(vm.sources.count, 2)
        XCTAssertEqual(vm.sources[0].name, "HackerNews")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    // verifies: ios-check-12
    func testAddSourceAppendsToList() async throws {
        let initialJSON = #"{"sources": []}"#.data(using: .utf8)!
        let afterAddJSON = #"{"sources": [{"name":"TechCrunch","url":"https://techcrunch.com/feed/"}]}"#.data(using: .utf8)!

        // 1回目（load）→空、2回目（add）→追加後のリスト。
        let client = makeClient(session: SequentialSession([initialJSON, afterAddJSON]))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))
        await vm.loadSources()
        await vm.addSource(name: "TechCrunch", url: "https://techcrunch.com/feed/")

        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertEqual(vm.sources[0].name, "TechCrunch")
    }

    // verifies: ios-check-12
    func testLoadSourcesSetsErrorMessageOnFailure() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadSources()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - T-T12c-02（verifies: CI-T12c, R4-S1c）
    // 現行文言の固定。SG-S1-2 = (b) により置換後も期待値を変えない。

    // verifies: ios-check-12
    func testLoadSources500SetsHTTPErrorMessage() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    // MARK: - T-T12c-04（verifies: CI-T12c, R4-S1g）
    // SG-S1-6: 射程外・挙動不変の固定（order.md:66）。文言の良し悪しは主張しない。

    private func makeTransportErrorClient(_ error: Error) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(mode: .transportError(error))
        )
    }

    // verifies: ios-check-12
    func testLoadSourcesCancelledURLErrorKeepsCurrentDisplay() async throws {
        let client = makeTransportErrorClient(URLError(.cancelled))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    // verifies: ios-check-12
    func testLoadSourcesRawCancellationErrorKeepsCurrentDisplay() async throws {
        let client = makeTransportErrorClient(CancellationError())
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, CancellationError().localizedDescription)
    }

    // verifies: ios-check-12
    func testAddSourceCancelledURLErrorKeepsCurrentDisplay() async throws {
        let client = makeTransportErrorClient(URLError(.cancelled))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.addSource(name: "n", url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    // verifies: ios-check-12
    func testUpdateSourceCancelledURLErrorKeepsCurrentDisplay() async throws {
        let client = makeTransportErrorClient(URLError(.cancelled))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.updateSource(oldURL: "https://example.com/old", name: "n", url: "https://example.com/new")

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    // verifies: ios-check-12
    func testRemoveSourceCancelledURLErrorKeepsCurrentDisplay() async throws {
        let client = makeTransportErrorClient(URLError(.cancelled))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.removeSource(url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    // MARK: - T-T12c-05（verifies: CI-T12c, R4-S1c）
    // 現行表示の固定。置換後も期待値を変えない。11 箇所の `ApiFailure` 節の付け忘れを検出する。

    // verifies: ios-check-12
    func testAddSource500SetsHTTPErrorMessage() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.addSource(name: "n", url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    // verifies: ios-check-12
    func testUpdateSource500SetsHTTPErrorMessage() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.updateSource(oldURL: "https://example.com/old", name: "n", url: "https://example.com/new")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    // verifies: ios-check-12
    func testRemoveSource500SetsHTTPErrorMessage() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.removeSource(url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    // verifies: ios-check-12
    func testLoadSourcesTransportFailureSetsURLErrorMessage() async throws {
        let client = makeTransportErrorClient(URLError(.notConnectedToInternet))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, URLError(.notConnectedToInternet).localizedDescription)
    }

    // verifies: ios-check-12
    func testLoadFeaturedSitesFetchesFromAPI() async throws {
        let json = #"""
        {"sites": [
            {"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":null,"description":null},
            {"id":"techcrunch","name":"TechCrunch","url":"https://techcrunch.com/feed/","thumbnail_url":null,"description":null}
        ]}
        """#
        let client = makeClient(json: json)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadFeaturedSites()

        XCTAssertEqual(vm.categorizedFeaturedSites.flatMap(\.sites).count, 2)
        XCTAssertEqual(vm.categorizedFeaturedSites.flatMap(\.sites)[0].id, "the-verge")
        XCTAssertNil(vm.errorMessage)
    }

    // verifies: ios-check-12
    func testSubscribeFeaturedUpdatesSourcesViaAddSource() async throws {
        // おすすめ購読は既存 addSource を再利用し、サーバが返す最新一覧で sources を更新する。
        let afterAddJSON = #"{"sources": [{"name":"TechCrunch","url":"https://techcrunch.com/feed/"}]}"#.data(using: .utf8)!
        let client = makeClient(session: SequentialSession([afterAddJSON]))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.addSource(name: "TechCrunch", url: "https://techcrunch.com/feed/")

        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertEqual(vm.sources[0].name, "TechCrunch")
    }

    // MARK: - RSS ソース編集 (issue #112)

    // verifies: ios-check-12
    func testUpdateSourceReplacesSourcesWithServerResponse() async throws {
        let initialJSON = #"""
        {"sources": [
            {"name":"HackerNews","url":"https://hnrss.org/frontpage"},
            {"name":"Zenn","url":"https://zenn.dev/feed"}
        ]}
        """#.data(using: .utf8)!
        // サーバは編集後も元の位置を保った一覧を返す（1件目のみ名称/URL 変更）。
        let afterUpdateJSON = #"""
        {"sources": [
            {"name":"HN Frontpage","url":"https://hnrss.org/frontpage.atom"},
            {"name":"Zenn","url":"https://zenn.dev/feed"}
        ]}
        """#.data(using: .utf8)!
        let client = makeClient(session: SequentialSession([initialJSON, afterUpdateJSON]))
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))
        await vm.loadSources()

        await vm.updateSource(
            oldURL: "https://hnrss.org/frontpage",
            name: "HN Frontpage",
            url: "https://hnrss.org/frontpage.atom"
        )

        XCTAssertEqual(vm.sources.count, 2)
        XCTAssertEqual(vm.sources[0].name, "HN Frontpage")
        XCTAssertEqual(vm.sources[0].url, "https://hnrss.org/frontpage.atom")
        XCTAssertEqual(vm.sources[1].name, "Zenn")
        XCTAssertNil(vm.errorMessage)
    }

    // verifies: ios-check-12
    func testUpdateSourceSetsErrorMessageOnFailure() async throws {
        // 読み込み済みの一覧を持った状態で更新を失敗させ、「失敗時 sources 不変」を実証する
        // （空のまま失敗させると空→空の確認にしかならないため）。
        let initialJSON = #"""
        {"sources": [{"name":"HackerNews","url":"https://hnrss.org/frontpage"}]}
        """#.data(using: .utf8)!
        let session = SequentialSession(results: [(initialJSON, 200), (Data(), 500)])
        let client = makeClient(session: session)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))
        await vm.loadSources()

        await vm.updateSource(
            oldURL: "https://hnrss.org/frontpage",
            name: "HN Frontpage",
            url: "https://hnrss.org/frontpage.atom"
        )

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.sources.count, 1, "失敗時は sources を変更しない")
        XCTAssertEqual(vm.sources[0].name, "HackerNews")
        XCTAssertEqual(vm.sources[0].url, "https://hnrss.org/frontpage")
    }

    // verifies: ios-check-12
    func testLoadFeaturedSitesSilentOnFailure() async throws {
        // 取得失敗時は categorizedFeaturedSites を空にし、errorMessage は汚さない（おすすめ欄は非表示になるだけ）。
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.categorizedFeaturedSites.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - おすすめサイト取得失敗の可視化 (issue #164)

    // verifies: ios-check-12
    func testLoadFeaturedSitesSetsLoadFailedFlagOnFailure() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSitesLoadFailed)
    }

    // verifies: ios-check-12
    func testLoadFeaturedSitesClearsLoadFailedFlagOnSuccess() async throws {
        let json = #"{"sites": []}"#
        let client = makeClient(json: json)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadFeaturedSites()

        XCTAssertFalse(vm.featuredSitesLoadFailed)
    }

    // MARK: - 生成残回数の取得 (issue #164 / ADR-061)

    // verifies: ios-check-12
    func testLoadGenerationQuotaFetchesFromAPI() async throws {
        let json = #"""
        {"limit":5,"used":2,"remaining":3,"reset_at":"2026-07-07T00:00:00Z"}
        """#
        let client = makeClient(json: json)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadGenerationQuota()

        XCTAssertEqual(vm.generationAllowance?.limit, 5)
        XCTAssertEqual(vm.generationAllowance?.remaining, 3)
        XCTAssertFalse(vm.generationQuotaLoadFailed)
    }

    // verifies: ios-check-12
    func testLoadGenerationQuotaSetsFailedFlagOnFailure() async throws {
        let client = makeClient(json: "", statusCode: 500)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadGenerationQuota()

        XCTAssertNil(vm.generationAllowance)
        XCTAssertTrue(vm.generationQuotaLoadFailed)
    }

    // T-T13-04（verifies: ios-contract-19, R-keep2）。
    // verifies: ios-check-12
    func testLoadGenerationQuota404GracefulDegradation() async throws {
        // 404 時は graceful degradation: 生成残回数セクションを非表示（failed=false）
        let client = makeClient(json: "", statusCode: 404)
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.loadGenerationQuota()

        XCTAssertNil(vm.generationAllowance)
        XCTAssertFalse(vm.generationQuotaLoadFailed, "404時はgraceful degradation。セクション非表示")
    }

    // verifies: ios-query-curation-03, ios-check-12
    func testLoadGenerationQuotaWithoutApiClientDoesNotCommunicate() async throws {
        // API 未設定なら読み込まない。残り回数の取得は GET なので、全要求を数える session で確かめ、
        // 同じ client を渡した VM が実際に通信することを正の対照にする。
        let session = CallRecordingSession()
        let client = makeClient(session: session)

        let unset = SettingsViewModel(apiClient: nil, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: nil))
        await unset.loadGenerationQuota()

        XCTAssertEqual(session.callCount, 0)
        XCTAssertNil(unset.generationAllowance)
        XCTAssertFalse(unset.generationQuotaLoadFailed)

        let configured = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))
        await configured.loadGenerationQuota()

        XCTAssertEqual(session.callCount, 1)
    }

    // MARK: - ダウンロード音声キャッシュの容量表示・全削除 (issue #52)

    /// `AudioCacheManagerTests.MockFileManager` を再利用し、キャッシュディレクトリを準備した
    /// `AudioCacheManager` を返す。
    private func makeCacheManager() -> AudioCacheManager {
        let mock = AudioCacheManagerTests.MockFileManager()
        mock.directories.insert("/mock-caches")
        mock.directories.insert("/mock-caches/NewsListenApp")
        return AudioCacheManager(fileManager: mock)
    }

    // verifies: ios-check-12
    func testLoadCacheSizeReflectsCacheManagerTotal() async throws {
        let cacheManager = makeCacheManager()
        try cacheManager.cache("audio1".data(using: .utf8)!, for: "podcast-1", subject: subjectA)
        try cacheManager.cache("audio2".data(using: .utf8)!, for: "podcast-2", subject: subjectA)
        let cacheLibrary = OfflineLibrary(store: .live(cacheManager: cacheManager))
        cacheLibrary.bind(subject: subjectA)
        let vm = SettingsViewModel(apiClient: nil, library: cacheLibrary, downloads: makeDownloads(for: cacheLibrary), curation: makeCuration(client: nil), sources: makeSources(client: nil))

        await vm.loadCacheSize()

        XCTAssertEqual(vm.cacheSizeBytes, 12)
    }

    // verifies: ios-check-12
    func testClearCacheResetsCacheSizeToZeroAndRemovesFiles() async throws {
        let cacheManager = makeCacheManager()
        try cacheManager.cache("audio1".data(using: .utf8)!, for: "podcast-1", subject: subjectA)
        try cacheManager.cache("audio-b".data(using: .utf8)!, for: "podcast-b", subject: subjectB)
        let cacheLibrary = OfflineLibrary(store: .live(cacheManager: cacheManager))
        cacheLibrary.bind(subject: subjectA)
        let vm = SettingsViewModel(apiClient: nil, library: cacheLibrary, downloads: makeDownloads(for: cacheLibrary), curation: makeCuration(client: nil), sources: makeSources(client: nil))
        await vm.loadCacheSize()
        XCTAssertEqual(vm.cacheSizeBytes, 6)

        await vm.clearCache()

        XCTAssertEqual(vm.cacheSizeBytes, 0)
        XCTAssertFalse(cacheManager.isCached("podcast-1", subject: subjectA))
        XCTAssertTrue(cacheManager.isCached("podcast-b", subject: subjectB), "他の主体の項目は残る")
    }

    // MARK: - savePreference（View が errorMessage へ直接書かないための窓口）

    // verifies: ios-check-12
    func testSavePreferenceClearsErrorMessageOnSuccess() async {
        let client = makeClient(json: "{}")
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))
        await vm.savePreference(failureMessage: "x") { throw ApiFailure.server(status: 500) }
        XCTAssertEqual(vm.errorMessage, "x", "前提: 直前の失敗で表示が出ている")

        await vm.savePreference(failureMessage: "x") {}

        XCTAssertNil(vm.errorMessage)
    }

    // verifies: ios-check-12
    func testSavePreferenceSetsFailureMessageForAnyError() async {
        struct Other: Error {}
        let client = makeClient(json: "{}")
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.savePreference(failureMessage: "設定の保存に失敗しました") { throw ApiFailure.server(status: 500) }
        XCTAssertEqual(vm.errorMessage, "設定の保存に失敗しました")

        await vm.savePreference(failureMessage: "別の文言") { throw Other() }
        XCTAssertEqual(vm.errorMessage, "別の文言", "ApiFailure 以外の error（キャンセル含む）も拾う")

        await vm.savePreference(failureMessage: "キャンセル") { throw CancellationError() }
        XCTAssertEqual(vm.errorMessage, "キャンセル")
    }

    // verifies: ios-check-12
    func testSavePreferenceShowsTheGivenFailureMessageSeparately() async {
        let client = makeClient(json: "{}")
        let vm = SettingsViewModel(apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client), sources: makeSources(client: client))

        await vm.savePreference(failureMessage: "設定の保存に失敗しました") { throw ApiFailure.server(status: 500) }
        let preference = vm.errorMessage
        await vm.savePreference(failureMessage: "学習目標の保存に失敗しました") { throw ApiFailure.server(status: 500) }
        let goal = vm.errorMessage

        XCTAssertEqual(preference, "設定の保存に失敗しました")
        XCTAssertEqual(goal, "学習目標の保存に失敗しました")
        XCTAssertNotEqual(preference, goal)
    }

    // MARK: - SourceSubscriptions との接続

    private enum SourceCall: Equatable { case list, add, update, remove, featured }

    private final class SourceCalls {
        var log: [SourceCall] = []
    }

    /// 呼出の列を記録する gateway。`add` は `afterAdd` を返し、`list` は `listed` を返す。
    private func recordingSources(calls: SourceCalls, afterAdd: [SourceEntry] = [], listed: [SourceEntry] = []) -> SourceSubscriptions {
        SourceSubscriptions(gateway: SourcesGateway(
            list: { @MainActor in calls.log.append(.list); return listed },
            add: { @MainActor _, _ in calls.log.append(.add); return afterAdd },
            update: { @MainActor _, _, _ in calls.log.append(.update); return afterAdd },
            remove: { @MainActor _ in calls.log.append(.remove) },
            featured: { @MainActor in calls.log.append(.featured); return [] }
        ))
    }

    // verifies: ios-dec-102
    func testAddThenRemoveCallsGatewayAddRemoveAndDropsRemovedURLLocally() async throws {
        let first = SourceEntry(name: "A", url: "https://a.com/feed")
        let second = SourceEntry(name: "B", url: "https://b.com/feed")
        let calls = SourceCalls()
        let client = makeClient(json: "{}")
        let vm = SettingsViewModel(
            apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client),
            sources: recordingSources(calls: calls, afterAdd: [first, second])
        )

        await vm.addSource(name: "A", url: first.url)
        XCTAssertEqual(vm.sources, [first, second], "追加の応答の一覧が表示される")
        await vm.removeSource(url: first.url)

        XCTAssertEqual(calls.log, [.add, .remove], "削除の後に list を呼ばず、追加の後の list は持ち越しで通信しない")
        XCTAssertEqual(vm.sources, [second])
    }

    // verifies: ios-rule-sources-04
    func testCanEditForwardsRoleToSources() {
        let client = makeClient(json: "{}")
        let vm = SettingsViewModel(
            apiClient: client, library: library, downloads: downloads, curation: makeCuration(client: client),
            sources: makeSources(client: client)
        )

        XCTAssertTrue(vm.canEdit(role: .admin))
        XCTAssertFalse(vm.canEdit(role: .user))
    }

    // verifies: ios-dec-103
    func testSourceOperationsWithoutApiClientDoNothing() async throws {
        let calls = SourceCalls()
        let vm = SettingsViewModel(
            apiClient: nil, library: library, downloads: downloads, curation: makeCuration(client: nil),
            sources: recordingSources(calls: calls)
        )

        await vm.loadSources()
        await vm.loadFeaturedSites()
        await vm.addSource(name: "n", url: "u")
        await vm.updateSource(oldURL: "o", name: "n", url: "u")
        await vm.removeSource(url: "u")

        XCTAssertEqual(calls.log, [], "API 未設定なら gateway を呼ばない")
        XCTAssertFalse(vm.isLoading)
        XCTAssertTrue(vm.sources.isEmpty)
    }
}
