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

    func testLoadSourcesFetchesFromAPI() async throws {
        let json = #"""
        {"sources": [
            {"name":"HackerNews","url":"https://hnrss.org/frontpage"},
            {"name":"Zenn","url":"https://zenn.dev/feed"}
        ]}
        """#
        let vm = SettingsViewModel(apiClient: makeClient(json: json), library: library, downloads: downloads)

        await vm.loadSources()

        XCTAssertEqual(vm.sources.count, 2)
        XCTAssertEqual(vm.sources[0].name, "HackerNews")
        XCTAssertFalse(vm.isLoading)
        XCTAssertNil(vm.errorMessage)
    }

    func testAddSourceAppendsToList() async throws {
        let initialJSON = #"{"sources": []}"#.data(using: .utf8)!
        let afterAddJSON = #"{"sources": [{"name":"TechCrunch","url":"https://techcrunch.com/feed/"}]}"#.data(using: .utf8)!

        // 1回目（load）→空、2回目（add）→追加後のリスト。
        let vm = SettingsViewModel(apiClient: makeClient(session: SequentialSession([initialJSON, afterAddJSON])), library: library, downloads: downloads)
        await vm.loadSources()
        await vm.addSource(name: "TechCrunch", url: "https://techcrunch.com/feed/")

        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertEqual(vm.sources[0].name, "TechCrunch")
    }

    func testLoadSourcesSetsErrorMessageOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.loadSources()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - T-T12c-02（verifies: CI-T12c, R4-S1c）
    // 現行文言の固定。SG-S1-2 = (b) により置換後も期待値を変えない。

    func testLoadSources500SetsHTTPErrorMessage() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

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

    func testLoadSourcesCancelledURLErrorKeepsCurrentDisplay() async throws {
        let vm = SettingsViewModel(apiClient: makeTransportErrorClient(URLError(.cancelled)), library: library, downloads: downloads)

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    func testLoadSourcesRawCancellationErrorKeepsCurrentDisplay() async throws {
        let vm = SettingsViewModel(apiClient: makeTransportErrorClient(CancellationError()), library: library, downloads: downloads)

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, CancellationError().localizedDescription)
    }

    func testAddSourceCancelledURLErrorKeepsCurrentDisplay() async throws {
        let vm = SettingsViewModel(apiClient: makeTransportErrorClient(URLError(.cancelled)), library: library, downloads: downloads)

        await vm.addSource(name: "n", url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    func testUpdateSourceCancelledURLErrorKeepsCurrentDisplay() async throws {
        let vm = SettingsViewModel(apiClient: makeTransportErrorClient(URLError(.cancelled)), library: library, downloads: downloads)

        await vm.updateSource(oldURL: "https://example.com/old", name: "n", url: "https://example.com/new")

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    func testRemoveSourceCancelledURLErrorKeepsCurrentDisplay() async throws {
        let vm = SettingsViewModel(apiClient: makeTransportErrorClient(URLError(.cancelled)), library: library, downloads: downloads)

        await vm.removeSource(url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    // MARK: - T-T12c-05（verifies: CI-T12c, R4-S1c）
    // 現行表示の固定。置換後も期待値を変えない。11 箇所の `ApiFailure` 節の付け忘れを検出する。

    func testAddSource500SetsHTTPErrorMessage() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.addSource(name: "n", url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testUpdateSource500SetsHTTPErrorMessage() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.updateSource(oldURL: "https://example.com/old", name: "n", url: "https://example.com/new")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testRemoveSource500SetsHTTPErrorMessage() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.removeSource(url: "https://example.com/feed")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testLoadSourcesTransportFailureSetsURLErrorMessage() async throws {
        let vm = SettingsViewModel(apiClient: makeTransportErrorClient(URLError(.notConnectedToInternet)), library: library, downloads: downloads)

        await vm.loadSources()

        XCTAssertEqual(vm.errorMessage, URLError(.notConnectedToInternet).localizedDescription)
    }

    func testLoadFeaturedSitesFetchesFromAPI() async throws {
        let json = #"""
        {"sites": [
            {"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":null,"description":null},
            {"id":"techcrunch","name":"TechCrunch","url":"https://techcrunch.com/feed/","thumbnail_url":null,"description":null}
        ]}
        """#
        let vm = SettingsViewModel(apiClient: makeClient(json: json), library: library, downloads: downloads)

        await vm.loadFeaturedSites()

        XCTAssertEqual(vm.featuredSites.count, 2)
        XCTAssertEqual(vm.featuredSites[0].id, "the-verge")
        XCTAssertNil(vm.errorMessage)
    }

    func testSubscribeFeaturedUpdatesSourcesViaAddSource() async throws {
        // おすすめ購読は既存 addSource を再利用し、サーバが返す最新一覧で sources を更新する。
        let afterAddJSON = #"{"sources": [{"name":"TechCrunch","url":"https://techcrunch.com/feed/"}]}"#.data(using: .utf8)!
        let vm = SettingsViewModel(apiClient: makeClient(session: SequentialSession([afterAddJSON])), library: library, downloads: downloads)

        await vm.addSource(name: "TechCrunch", url: "https://techcrunch.com/feed/")

        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertEqual(vm.sources[0].name, "TechCrunch")
    }

    // MARK: - RSS ソース編集 (issue #112)

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
        let vm = SettingsViewModel(apiClient: makeClient(session: SequentialSession([initialJSON, afterUpdateJSON])), library: library, downloads: downloads)
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

    func testUpdateSourceSetsErrorMessageOnFailure() async throws {
        // 読み込み済みの一覧を持った状態で更新を失敗させ、「失敗時 sources 不変」を実証する
        // （空のまま失敗させると空→空の確認にしかならないため）。
        let initialJSON = #"""
        {"sources": [{"name":"HackerNews","url":"https://hnrss.org/frontpage"}]}
        """#.data(using: .utf8)!
        let session = SequentialSession(results: [(initialJSON, 200), (Data(), 500)])
        let vm = SettingsViewModel(apiClient: makeClient(session: session), library: library, downloads: downloads)
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

    func testLoadFeaturedSitesSilentOnFailure() async throws {
        // 取得失敗時は featuredSites を空にし、errorMessage は汚さない（おすすめ欄は非表示になるだけ）。
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSites.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - おすすめサイト取得失敗の可視化 (issue #164)

    func testLoadFeaturedSitesSetsLoadFailedFlagOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSitesLoadFailed)
    }

    func testLoadFeaturedSitesClearsLoadFailedFlagOnSuccess() async throws {
        let json = #"{"sites": []}"#
        let vm = SettingsViewModel(apiClient: makeClient(json: json), library: library, downloads: downloads)

        await vm.loadFeaturedSites()

        XCTAssertFalse(vm.featuredSitesLoadFailed)
    }

    // MARK: - 生成残回数の取得 (issue #164 / ADR-061)

    func testLoadGenerationQuotaFetchesFromAPI() async throws {
        let json = #"""
        {"limit":5,"used":2,"remaining":3,"reset_at":"2026-07-07T00:00:00Z"}
        """#
        let vm = SettingsViewModel(apiClient: makeClient(json: json), library: library, downloads: downloads)

        await vm.loadGenerationQuota()

        XCTAssertEqual(vm.generationQuota?.limit, 5)
        XCTAssertEqual(vm.generationQuota?.remaining, 3)
        XCTAssertFalse(vm.generationQuotaLoadFailed)
    }

    func testLoadGenerationQuotaSetsFailedFlagOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500), library: library, downloads: downloads)

        await vm.loadGenerationQuota()

        XCTAssertNil(vm.generationQuota)
        XCTAssertTrue(vm.generationQuotaLoadFailed)
    }

    // T-T13-04（verifies: ios-contract-19, R-keep2）。
    func testLoadGenerationQuota404GracefulDegradation() async throws {
        // 404 時は graceful degradation: 生成残回数セクションを非表示（failed=false）
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 404), library: library, downloads: downloads)

        await vm.loadGenerationQuota()

        XCTAssertNil(vm.generationQuota)
        XCTAssertFalse(vm.generationQuotaLoadFailed, "404時はgraceful degradation。セクション非表示")
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

    func testLoadCacheSizeReflectsCacheManagerTotal() async throws {
        let cacheManager = makeCacheManager()
        try cacheManager.cache("audio1".data(using: .utf8)!, for: "podcast-1", subject: subjectA)
        try cacheManager.cache("audio2".data(using: .utf8)!, for: "podcast-2", subject: subjectA)
        let cacheLibrary = OfflineLibrary(store: .live(cacheManager: cacheManager))
        cacheLibrary.bind(subject: subjectA)
        let vm = SettingsViewModel(apiClient: nil, library: cacheLibrary, downloads: makeDownloads(for: cacheLibrary))

        await vm.loadCacheSize()

        XCTAssertEqual(vm.cacheSizeBytes, 12)
    }

    func testClearCacheResetsCacheSizeToZeroAndRemovesFiles() async throws {
        let cacheManager = makeCacheManager()
        try cacheManager.cache("audio1".data(using: .utf8)!, for: "podcast-1", subject: subjectA)
        try cacheManager.cache("audio-b".data(using: .utf8)!, for: "podcast-b", subject: subjectB)
        let cacheLibrary = OfflineLibrary(store: .live(cacheManager: cacheManager))
        cacheLibrary.bind(subject: subjectA)
        let vm = SettingsViewModel(apiClient: nil, library: cacheLibrary, downloads: makeDownloads(for: cacheLibrary))
        await vm.loadCacheSize()
        XCTAssertEqual(vm.cacheSizeBytes, 6)

        await vm.clearCache()

        XCTAssertEqual(vm.cacheSizeBytes, 0)
        XCTAssertFalse(cacheManager.isCached("podcast-1", subject: subjectA))
        XCTAssertTrue(cacheManager.isCached("podcast-b", subject: subjectB), "他の主体の項目は残る")
    }

    // MARK: - savePreference（View が errorMessage へ直接書かないための窓口）

    func testSavePreferenceClearsErrorMessageOnSuccess() async {
        let vm = SettingsViewModel(apiClient: makeClient(json: "{}"), library: library, downloads: downloads)
        await vm.savePreference(failureMessage: "x") { throw ApiFailure.server(status: 500) }
        XCTAssertEqual(vm.errorMessage, "x", "前提: 直前の失敗で表示が出ている")

        await vm.savePreference(failureMessage: "x") {}

        XCTAssertNil(vm.errorMessage)
    }

    func testSavePreferenceSetsFailureMessageForAnyError() async {
        struct Other: Error {}
        let vm = SettingsViewModel(apiClient: makeClient(json: "{}"), library: library, downloads: downloads)

        await vm.savePreference(failureMessage: "設定の保存に失敗しました") { throw ApiFailure.server(status: 500) }
        XCTAssertEqual(vm.errorMessage, "設定の保存に失敗しました")

        await vm.savePreference(failureMessage: "別の文言") { throw Other() }
        XCTAssertEqual(vm.errorMessage, "別の文言", "ApiFailure 以外の error（キャンセル含む）も拾う")

        await vm.savePreference(failureMessage: "キャンセル") { throw CancellationError() }
        XCTAssertEqual(vm.errorMessage, "キャンセル")
    }

    func testSavePreferenceShowsTheGivenFailureMessageSeparately() async {
        let vm = SettingsViewModel(apiClient: makeClient(json: "{}"), library: library, downloads: downloads)

        await vm.savePreference(failureMessage: "設定の保存に失敗しました") { throw ApiFailure.server(status: 500) }
        let preference = vm.errorMessage
        await vm.savePreference(failureMessage: "学習目標の保存に失敗しました") { throw ApiFailure.server(status: 500) }
        let goal = vm.errorMessage

        XCTAssertEqual(preference, "設定の保存に失敗しました")
        XCTAssertEqual(goal, "学習目標の保存に失敗しました")
        XCTAssertNotEqual(preference, goal)
    }
}
