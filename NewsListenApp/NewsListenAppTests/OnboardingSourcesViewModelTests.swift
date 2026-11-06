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

    private func makeSources(client: APIClient?) -> SourceSubscriptions {
        SourceSubscriptions(gateway: .live(client: { client }))
    }

    /// 主体の源は実物の `AppState`（`SubjectStamp` はテストから作れない）。`isCurrentSubject` は常に true で、主体は動かさない。
    private func makeOnboarding(client: APIClient?) -> OnboardingProgress {
        let state = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(LoginReceipt(
            token: "tA",
            subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)
        ))
        return OnboardingProgress.live(client: { client }, subjectStamp: { state.subjectStamp }, isCurrentSubject: { _ in true })
    }

    private func makeViewModel(client: APIClient?) -> OnboardingSourcesViewModel {
        OnboardingSourcesViewModel(sources: makeSources(client: client), onboarding: makeOnboarding(client: client))
    }

    private func hnSite() -> FeaturedSiteCard {
        FeaturedSiteCard(id: "hn", name: "HackerNews", url: "https://hnrss.org/frontpage", thumbnailURL: nil, description: nil, category: .tech)
    }

    // verifies: ios-check-12
    func testLoadFeaturedSitesFetchesFromAPI() async throws {
        let json = #"""
        {"sites": [
            {"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":null,"description":null}
        ]}
        """#
        let vm = makeViewModel(client: makeClient(json: json))

        await vm.loadFeaturedSites()

        XCTAssertEqual(vm.categorizedSites.flatMap(\.sites).count, 1)
        XCTAssertEqual(vm.categorizedSites.flatMap(\.sites)[0].id, "the-verge")
        XCTAssertNil(vm.loadErrorMessage)
    }

    // verifies: ios-check-12
    func testLoadFeaturedSitesSetsErrorMessageOnFailure() async throws {
        let vm = makeViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.loadFeaturedSites()

        XCTAssertTrue(vm.categorizedSites.isEmpty)
        XCTAssertNotNil(vm.loadErrorMessage)
    }

    // verifies: ios-check-12
    func testSubscribeAddsIDOnSuccess() async throws {
        let vm = makeViewModel(client: makeClient(json: #"{"sources": []}"#))
        let site = hnSite()

        await vm.subscribe(site)

        XCTAssertTrue(vm.addedIDs.contains("hn"))
        XCTAssertNil(vm.subscribeErrorMessage)
    }

    // T-T13-04（verifies: ios-contract-19, R-keep2）。
    // verifies: ios-check-12
    func testSubscribeTreats409AsAlreadySubscribed() async throws {
        let vm = makeViewModel(client: makeClient(json: "", statusCode: 409))
        let site = hnSite()

        await vm.subscribe(site)

        XCTAssertTrue(vm.addedIDs.contains("hn"))
        XCTAssertNil(vm.subscribeErrorMessage)
    }

    // verifies: ios-check-12
    func testSubscribeSetsErrorMessageOnOtherFailure() async throws {
        let vm = makeViewModel(client: makeClient(json: "", statusCode: 500))
        let site = hnSite()

        await vm.subscribe(site)

        XCTAssertFalse(vm.addedIDs.contains("hn"))
        XCTAssertNotNil(vm.subscribeErrorMessage)
    }

    // verifies: ios-cmd-sources-03
    func testFinishMarksOnboardingCompleted() async throws {
        let onboarding = makeOnboarding(client: makeClient(json: #"{"onboarding_completed":true}"#))
        let vm = OnboardingSourcesViewModel(sources: makeSources(client: nil), onboarding: onboarding)
        XCTAssertNil(onboarding.isCompleted)

        await vm.finish()

        XCTAssertEqual(onboarding.isCompleted, true)
    }

    // verifies: ios-check-12
    func testLoadFailureMessageIsExactlyTheExistingWording() async throws {
        let vm = makeViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.loadFeaturedSites()

        XCTAssertEqual(vm.loadErrorMessage, "おすすめサイトの取得に失敗しました")
        XCTAssertFalse(vm.isLoading)
    }

    // verifies: ios-check-12
    func testSubscribeFailureMessageIsExactlyTheExistingWording() async throws {
        let vm = makeViewModel(client: makeClient(json: "", statusCode: 500))

        await vm.subscribe(hnSite())

        XCTAssertEqual(vm.subscribeErrorMessage, "購読に失敗しました。もう一度お試しください。")
    }
}
