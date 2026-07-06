import XCTest
@testable import NewsListenApp

/// 初回オンボーディング「おすすめサイト追加」ステップのロジックのテスト（issue #164）。
///
/// 従来 `OnboardingSourcesView` の `@State` + `.task` に直書きされ、取得失敗も
/// 購読失敗も完全にサイレントだったロジックを ``OnboardingSourcesViewModel`` に切り出し、
/// 失敗を可視化できるようにする。
@MainActor
final class OnboardingSourcesViewModelTests: XCTestCase {

    private func makeClient(json: String, statusCode: Int = 200) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(json.utf8), statusCode: statusCode)
        )
    }

    func testLoadFeaturedSitesFetchesFromAPI() async throws {
        let json = #"""
        {"sites": [
            {"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":null,"description":null}
        ]}
        """#
        let vm = OnboardingSourcesViewModel(apiClient: makeClient(json: json))

        await vm.loadFeaturedSites()

        XCTAssertEqual(vm.featuredSites.count, 1)
        XCTAssertEqual(vm.featuredSites[0].id, "the-verge")
        XCTAssertNil(vm.loadErrorMessage)
    }

    func testLoadFeaturedSitesSetsErrorMessageOnFailure() async throws {
        let vm = OnboardingSourcesViewModel(apiClient: makeClient(json: "", statusCode: 500))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.featuredSites.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
    }

    func testSubscribeAddsIDOnSuccess() async throws {
        let vm = OnboardingSourcesViewModel(apiClient: makeClient(json: #"{"sources": []}"#))
        let site = FeaturedSite(id: "hn", name: "HackerNews", url: "https://hnrss.org/frontpage", thumbnailURL: nil, description: nil)

        await vm.subscribe(site)

        XCTAssertTrue(vm.addedIDs.contains("hn"))
        XCTAssertNil(vm.subscribeErrorMessage)
    }

    func testSubscribeTreats409AsAlreadySubscribed() async throws {
        let vm = OnboardingSourcesViewModel(apiClient: makeClient(json: "", statusCode: 409))
        let site = FeaturedSite(id: "hn", name: "HackerNews", url: "https://hnrss.org/frontpage", thumbnailURL: nil, description: nil)

        await vm.subscribe(site)

        XCTAssertTrue(vm.addedIDs.contains("hn"))
        XCTAssertNil(vm.subscribeErrorMessage)
    }

    func testSubscribeSetsErrorMessageOnOtherFailure() async throws {
        let vm = OnboardingSourcesViewModel(apiClient: makeClient(json: "", statusCode: 500))
        let site = FeaturedSite(id: "hn", name: "HackerNews", url: "https://hnrss.org/frontpage", thumbnailURL: nil, description: nil)

        await vm.subscribe(site)

        XCTAssertFalse(vm.addedIDs.contains("hn"))
        XCTAssertNotNil(vm.subscribeErrorMessage)
    }
}
