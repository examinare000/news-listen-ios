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

@MainActor
final class SettingsViewModelTests: XCTestCase {

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
        let vm = SettingsViewModel(apiClient: makeClient(json: json))

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
        let vm = SettingsViewModel(apiClient: makeClient(session: SequentialSession([initialJSON, afterAddJSON])))
        await vm.loadSources()
        await vm.addSource(name: "TechCrunch", url: "https://techcrunch.com/feed/")

        XCTAssertEqual(vm.sources.count, 1)
        XCTAssertEqual(vm.sources[0].name, "TechCrunch")
    }

    func testLoadSourcesSetsErrorMessageOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadSources()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadFeaturedSitesFetchesFromAPI() async throws {
        let json = #"""
        {"sites": [
            {"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":null,"description":null},
            {"id":"techcrunch","name":"TechCrunch","url":"https://techcrunch.com/feed/","thumbnail_url":null,"description":null}
        ]}
        """#
        let vm = SettingsViewModel(apiClient: makeClient(json: json))

        await vm.loadFeaturedSites()

        XCTAssertEqual(vm.featuredSites.count, 2)
        XCTAssertEqual(vm.featuredSites[0].id, "the-verge")
        XCTAssertNil(vm.errorMessage)
    }

    func testSubscribeFeaturedUpdatesSourcesViaAddSource() async throws {
        // おすすめ購読は既存 addSource を再利用し、サーバが返す最新一覧で sources を更新する。
        let afterAddJSON = #"{"sources": [{"name":"TechCrunch","url":"https://techcrunch.com/feed/"}]}"#.data(using: .utf8)!
        let vm = SettingsViewModel(apiClient: makeClient(session: SequentialSession([afterAddJSON])))

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
        let vm = SettingsViewModel(apiClient: makeClient(session: SequentialSession([initialJSON, afterUpdateJSON])))
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
        let vm = SettingsViewModel(apiClient: makeClient(session: session))
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
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSites.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - おすすめサイト取得失敗の可視化 (issue #164)

    func testLoadFeaturedSitesSetsLoadFailedFlagOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSitesLoadFailed)
    }

    func testLoadFeaturedSitesClearsLoadFailedFlagOnSuccess() async throws {
        let json = #"{"sites": []}"#
        let vm = SettingsViewModel(apiClient: makeClient(json: json))

        await vm.loadFeaturedSites()

        XCTAssertFalse(vm.featuredSitesLoadFailed)
    }

    // MARK: - デフォルト難易度・再生速度のサーバー同期失敗の可視化 (issue #164)

    func testSyncDefaultDifficultySetsErrorMessageOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500))

        let ok = await vm.syncDefaultDifficulty("toeic_600")

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.errorMessage, "設定の保存に失敗しました")
    }

    func testSyncDefaultDifficultySucceedsAndClearsErrorMessage() async throws {
        let json = #"{"default_difficulty":"toeic_600","default_playback_speed":null}"#
        let vm = SettingsViewModel(apiClient: makeClient(json: json))

        let ok = await vm.syncDefaultDifficulty("toeic_600")

        XCTAssertTrue(ok)
        XCTAssertNil(vm.errorMessage)
    }

    func testSyncDefaultPlaybackSpeedSetsErrorMessageOnFailure() async throws {
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500))

        let ok = await vm.syncDefaultPlaybackSpeed(1.5)

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.errorMessage, "設定の保存に失敗しました")
    }

    func testSyncDefaultPlaybackSpeedSucceedsAndClearsErrorMessage() async throws {
        let json = #"{"default_difficulty":null,"default_playback_speed":1.5}"#
        let vm = SettingsViewModel(apiClient: makeClient(json: json))

        let ok = await vm.syncDefaultPlaybackSpeed(1.5)

        XCTAssertTrue(ok)
        XCTAssertNil(vm.errorMessage)
    }
}
