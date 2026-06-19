import XCTest
@testable import NewsListenApp

/// 呼び出しごとに異なるレスポンスを返すモックセッション。
///
/// `MockURLSession` は固定データしか返せないため、load→add のように
/// 複数回の通信で内容が変わるシナリオの検証に使う。
private final class SequentialSession: URLSessionProtocol {
    /// 先頭から順に返す応答データのキュー。
    private var responses: [Data]

    /// - Parameter responses: 呼び出し順に返すデータ列。
    init(_ responses: [Data]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let data = responses.isEmpty ? Data() : responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
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

    func testLoadFeaturedSitesSilentOnFailure() async throws {
        // 取得失敗時は featuredSites を空にし、errorMessage は汚さない（おすすめ欄は非表示になるだけ）。
        let vm = SettingsViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSites.isEmpty)
        XCTAssertNil(vm.errorMessage)
    }
}
