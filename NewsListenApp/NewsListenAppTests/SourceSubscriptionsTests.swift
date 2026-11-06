import XCTest
@testable import NewsListenApp

/// RSS ソースの一覧・追加・更新・削除・おすすめの購読を持つ `SourceSubscriptions`（application）と、
/// その adapter（`SourcesGateway.live`）のテスト。closure の gateway で呼出の列と引数を記録する。
@MainActor
final class SourceSubscriptionsTests: XCTestCase {

    private enum Call: Equatable { case list, add, update, remove, featured }

    /// gateway の呼出の列・引数と、次に返す（または投げる）応答。呼出のたびに読むので、テストの途中で差し替えられる。
    private final class Calls {
        var log: [Call] = []
        var added: [(name: String, url: String)] = []
        var updated: [(oldURL: String, name: String, url: String)] = []
        var removed: [String] = []
        var listResult: Result<[SourceEntry], Error> = .success([])
        var addResult: Result<[SourceEntry], Error> = .success([])
        var updateResult: Result<[SourceEntry], Error> = .success([])
        var removeResult: Result<Void, Error> = .success(())
        var featuredResult: Result<[FeaturedSiteCard], Error> = .success([])
    }

    private func makeGateway(calls: Calls) -> SourcesGateway {
        SourcesGateway(
            list: { @MainActor in
                calls.log.append(.list)
                return try calls.listResult.get()
            },
            add: { @MainActor name, url in
                calls.log.append(.add)
                calls.added.append((name, url))
                return try calls.addResult.get()
            },
            update: { @MainActor oldURL, name, url in
                calls.log.append(.update)
                calls.updated.append((oldURL, name, url))
                return try calls.updateResult.get()
            },
            remove: { @MainActor url in
                calls.log.append(.remove)
                calls.removed.append(url)
                try calls.removeResult.get()
            },
            featured: { @MainActor in
                calls.log.append(.featured)
                return try calls.featuredResult.get()
            }
        )
    }

    private func entry(_ key: String) -> SourceEntry {
        SourceEntry(name: "name-\(key)", url: "https://example.com/\(key)")
    }

    private func site(_ id: String) -> FeaturedSiteCard {
        FeaturedSiteCard(id: id, name: "site-\(id)", url: "https://example.com/feed/\(id)", thumbnailURL: nil, description: nil, category: .tech)
    }

    private func makeClient(json: String, statusCode: Int = 200) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(json.utf8), statusCode: statusCode)
        )
    }

    // MARK: - command（追加・更新・削除）

    // verifies: ios-cmd-sources-01, ios-test-023
    func testAddUpdateRemoveEachCallGatewayOnceWithMatchingArguments() async throws {
        let calls = Calls()
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        try await subscriptions.add(name: "N1", url: "https://e.com/1")
        try await subscriptions.update(oldURL: "https://e.com/1", name: "N2", url: "https://e.com/2")
        try await subscriptions.remove(url: "https://e.com/2")

        XCTAssertEqual(calls.log, [.add, .update, .remove])
        XCTAssertEqual(calls.added.map(\.name), ["N1"])
        XCTAssertEqual(calls.added.map(\.url), ["https://e.com/1"])
        XCTAssertEqual(calls.updated.map(\.oldURL), ["https://e.com/1"])
        XCTAssertEqual(calls.updated.map(\.name), ["N2"])
        XCTAssertEqual(calls.updated.map(\.url), ["https://e.com/2"])
        XCTAssertEqual(calls.removed, ["https://e.com/2"])
    }

    // verifies: ios-test-023
    func testCommandsRethrowApiFailureAndLeaveCarriedListUntouched() async throws {
        let calls = Calls()
        let carried = [entry("carried")]
        calls.addResult = .success(carried)
        calls.listResult = .success([entry("fetched")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))
        try await subscriptions.add(name: "n", url: "u")

        calls.addResult = .failure(ApiFailure.conflict)
        await assertThrows(ApiFailure.conflict) { try await subscriptions.add(name: "n2", url: "u2") }
        calls.updateResult = .failure(ApiFailure.validation)
        await assertThrows(ApiFailure.validation) { try await subscriptions.update(oldURL: "a", name: "b", url: "c") }
        calls.removeResult = .failure(ApiFailure.server(status: 500))
        await assertThrows(ApiFailure.server(status: 500)) { try await subscriptions.remove(url: "a") }
        calls.addResult = .failure(ApiFailure.server(status: 500))
        await assertThrows(ApiFailure.server(status: 500)) { try await subscriptions.subscribe(site("s")) }

        let listed = try await subscriptions.list()
        XCTAssertEqual(listed, carried, "失敗した command は持ち越しに触らない")
        XCTAssertEqual(calls.log.filter { $0 == .list }.count, 0)
    }

    private func assertThrows(
        _ expected: ApiFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("\(expected) を投げる", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ApiFailure, expected, file: file, line: line)
        }
    }

    // MARK: - query は書かない

    // verifies: ios-check-09, ios-test-023
    func testListAndFeaturedNeverCallWriteGatewayOperations() async throws {
        let calls = Calls()
        calls.listResult = .success([entry("a")])
        calls.featuredResult = .success([site("1")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        _ = try await subscriptions.list()
        _ = try await subscriptions.featured()

        XCTAssertEqual(calls.log, [.list, .featured])
    }

    // verifies: ios-rule-sources-01, ios-test-023
    func testFeaturedThroughLiveGatewayGroupsByCategoryInServerOrder() async throws {
        let json = #"""
        {"sites": [
            {"id":"1","name":"A","url":"https://a.com/feed","thumbnail_url":null,"description":null},
            {"id":"2","name":"B","url":"https://b.com/feed","thumbnail_url":null,"description":null,"category":"unknown"},
            {"id":"3","name":"C","url":"https://c.com/feed","thumbnail_url":null,"description":null,"category":"business"}
        ]}
        """#
        let client = makeClient(json: json)
        let subscriptions = SourceSubscriptions(gateway: .live(client: { client }))

        let groups = try await subscriptions.featured()

        XCTAssertEqual(groups.map(\.category), [.tech, .business])
        XCTAssertEqual(groups[0].sites.map(\.id), ["1", "2"], "category 欠落・未知は tech に入り、順はサーバー順")
        XCTAssertEqual(groups[1].sites.map(\.id), ["3"])
    }

    // MARK: - subscribe

    // verifies: ios-cmd-sources-02, ios-test-024
    func testSubscribePassesSiteNameAndURLAndKeepsResponseForNextList() async throws {
        let calls = Calls()
        let l1 = [entry("l1")]
        calls.addResult = .success(l1)
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))
        let target = site("hn")

        try await subscriptions.subscribe(target)
        let listed = try await subscriptions.list()

        XCTAssertEqual(calls.added.map(\.name), [target.name])
        XCTAssertEqual(calls.added.map(\.url), [target.url])
        XCTAssertEqual(listed, l1)
        XCTAssertFalse(calls.log.contains(.list), "応答の一覧を返すので GET しない")
    }

    // verifies: ios-rule-sources-02, ios-test-024
    func testSubscribeTreatsConflictAsSuccessAndKeepsCarriedList() async throws {
        let calls = Calls()
        let l1 = [entry("l1")]
        calls.addResult = .success(l1)
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))
        try await subscriptions.add(name: "n", url: "u")
        calls.addResult = .failure(ApiFailure.conflict)

        try await subscriptions.subscribe(site("dup"))
        let listed = try await subscriptions.list()

        XCTAssertEqual(listed, l1, "409 は成功で、持ち越しに触らない")
        XCTAssertFalse(calls.log.contains(.list))
    }

    // verifies: ios-test-024
    func testSubscribeRethrowsOtherFailureAndKeepsNoCarriedList() async throws {
        let calls = Calls()
        calls.addResult = .failure(ApiFailure.server(status: 500))
        calls.listResult = .success([entry("fetched")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        await assertThrows(ApiFailure.server(status: 500)) { try await subscriptions.subscribe(site("x")) }
        let listed = try await subscriptions.list()

        XCTAssertEqual(listed, [entry("fetched")], "持ち越しが無いので GET")
        XCTAssertEqual(calls.log, [.add, .list])
    }

    // MARK: - canEdit

    // verifies: ios-rule-sources-04, ios-test-052
    func testCanEditIsTrueOnlyForAdminWithoutCommunication() {
        let calls = Calls()
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        XCTAssertTrue(subscriptions.canEdit(role: .admin))
        XCTAssertFalse(subscriptions.canEdit(role: .user))
        XCTAssertFalse(subscriptions.canEdit(role: Role(rawValue: "x")))
        XCTAssertEqual(calls.log, [])
    }

    // MARK: - 値の独立性

    // verifies: ios-check-07, ios-test-119
    func testMutatingReturnedListDoesNotAffectNextListWhenFetched() async throws {
        let calls = Calls()
        calls.listResult = .success([entry("a")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        var first = try await subscriptions.list()
        first.append(entry("extra"))
        let second = try await subscriptions.list()

        XCTAssertEqual(second, [entry("a")])
    }

    // verifies: ios-check-07, ios-test-119
    func testMutatingReturnedListDoesNotAffectNextListWhenCarried() async throws {
        let calls = Calls()
        calls.addResult = .success([entry("a")])
        calls.listResult = .success([entry("a")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))
        try await subscriptions.add(name: "n", url: "u")

        var first = try await subscriptions.list()
        first.append(entry("extra"))
        let second = try await subscriptions.list()

        XCTAssertEqual(second, [entry("a")])
    }

    // MARK: - 通信の回数（一覧の持ち越し）

    // verifies: ios-dec-102
    func testListThenRemoveCallsListThenRemove() async throws {
        let calls = Calls()
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        _ = try await subscriptions.list()
        try await subscriptions.remove(url: "u")

        XCTAssertEqual(calls.log, [.list, .remove])
    }

    // verifies: ios-dec-102
    func testAddThenListThenRemoveThenListCallsAddRemoveList() async throws {
        let calls = Calls()
        let fromAdd = [entry("from-add")]
        calls.addResult = .success(fromAdd)
        calls.listResult = .success([entry("fetched")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        try await subscriptions.add(name: "n", url: "u")
        let first = try await subscriptions.list()
        try await subscriptions.remove(url: "u")
        let second = try await subscriptions.list()

        XCTAssertEqual(calls.log, [.add, .remove, .list])
        XCTAssertEqual(first, fromAdd)
        XCTAssertEqual(second, [entry("fetched")])
    }

    // verifies: ios-dec-102
    func testUpdateThenListThenListReleasesCarriedListAfterFirstList() async throws {
        let calls = Calls()
        let fromUpdate = [entry("from-update")]
        calls.updateResult = .success(fromUpdate)
        calls.listResult = .success([entry("fetched")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        try await subscriptions.update(oldURL: "o", name: "n", url: "u")
        let first = try await subscriptions.list()
        let second = try await subscriptions.list()

        XCTAssertEqual(calls.log, [.update, .list])
        XCTAssertEqual(first, fromUpdate)
        XCTAssertEqual(second, [entry("fetched")], "手放した後の list は GET の結果")
    }

    // verifies: ios-dec-102
    func testSubscribeTwiceThenListKeepsLatestResponseWithoutFetching() async throws {
        let calls = Calls()
        let first = [entry("first")]
        let second = [entry("first"), entry("second")]
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        calls.addResult = .success(first)
        try await subscriptions.subscribe(site("1"))
        calls.addResult = .success(second)
        try await subscriptions.subscribe(site("2"))
        let listed = try await subscriptions.list()

        XCTAssertEqual(calls.log, [.add, .add])
        XCTAssertEqual(listed, second)
    }

    // verifies: ios-dec-102
    func testConflictSubscribeThenListFetchesBecauseNothingIsCarried() async throws {
        let calls = Calls()
        calls.addResult = .failure(ApiFailure.conflict)
        calls.listResult = .success([entry("fetched")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        try await subscriptions.subscribe(site("dup"))
        let listed = try await subscriptions.list()

        XCTAssertEqual(calls.log, [.add, .list])
        XCTAssertEqual(listed, [entry("fetched")])
    }

    // verifies: ios-dec-102
    func testFeaturedIsNeverCarriedAndFetchesEachTime() async throws {
        let calls = Calls()
        calls.featuredResult = .success([site("1")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        _ = try await subscriptions.featured()
        _ = try await subscriptions.featured()

        XCTAssertEqual(calls.log, [.featured, .featured])
    }

    // verifies: ios-dec-102
    func testListTwiceFetchesTwiceBecauseFetchedResultIsNotCarried() async throws {
        let calls = Calls()
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))

        _ = try await subscriptions.list()
        _ = try await subscriptions.list()

        XCTAssertEqual(calls.log, [.list, .list])
    }

    // verifies: ios-dec-102
    func testRemoveDiscardsCarriedListSoNextListFetches() async throws {
        let calls = Calls()
        calls.addResult = .success([entry("stale")])
        calls.listResult = .success([entry("fresh")])
        let subscriptions = SourceSubscriptions(gateway: makeGateway(calls: calls))
        try await subscriptions.add(name: "n", url: "u")

        try await subscriptions.remove(url: "u")
        let listed = try await subscriptions.list()

        XCTAssertEqual(listed, [entry("fresh")], "古い持ち越しを返さない")
        XCTAssertEqual(calls.log, [.add, .remove, .list])
    }

    // MARK: - gateway の adapter

    // verifies: ios-test-023
    func testLiveGatewayMapsResponsesToReadModels() async throws {
        let sourcesJSON = #"{"sources": [{"name":"HackerNews","url":"https://hnrss.org/frontpage"}]}"#
        let sourcesGateway = SourcesGateway.live(client: { [self] in makeClient(json: sourcesJSON) })

        let listed = try await sourcesGateway.list()
        let added = try await sourcesGateway.add("HackerNews", "https://hnrss.org/frontpage")
        let updated = try await sourcesGateway.update("old", "HackerNews", "https://hnrss.org/frontpage")
        try await sourcesGateway.remove("https://hnrss.org/frontpage")

        let expected = [SourceEntry(name: "HackerNews", url: "https://hnrss.org/frontpage")]
        XCTAssertEqual(listed, expected)
        XCTAssertEqual(added, expected)
        XCTAssertEqual(updated, expected)

        let sitesJSON = #"""
        {"sites": [{"id":"s1","name":"Site","url":"https://s.com/feed","thumbnail_url":"https://s.com/t.png","description":"d","category":"business"}]}
        """#
        let featuredGateway = SourcesGateway.live(client: { [self] in makeClient(json: sitesJSON) })

        let cards = try await featuredGateway.featured()

        XCTAssertEqual(cards, [
            FeaturedSiteCard(id: "s1", name: "Site", url: "https://s.com/feed", thumbnailURL: "https://s.com/t.png", description: "d", category: .business)
        ])
    }

    // verifies: ios-dec-103
    func testLiveGatewayWithoutClientReadsEmptyAndWritesSucceed() async throws {
        let gateway = SourcesGateway.live(client: { nil })
        let subscriptions = SourceSubscriptions(gateway: gateway)

        let listed = try await gateway.list()
        let featured = try await gateway.featured()
        let added = try await gateway.add("n", "u")
        let updated = try await gateway.update("o", "n", "u")
        try await gateway.remove("u")
        try await subscriptions.subscribe(site("1"))

        XCTAssertEqual(listed, [])
        XCTAssertEqual(featured, [])
        XCTAssertEqual(added, [])
        XCTAssertEqual(updated, [])
    }

    private final class CountingSession: URLSessionProtocol {
        private(set) var requestCount = 0
        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"sources": []}"#.utf8), response)
        }
    }

    private final class ClientHolder {
        var client: APIClient?
    }

    // verifies: ios-dec-103
    func testLiveGatewayResolvesClientOnEveryCall() async throws {
        let sessionA = CountingSession()
        let sessionB = CountingSession()
        let holder = ClientHolder()
        holder.client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: sessionA)
        let gateway = SourcesGateway.live(client: { holder.client })

        _ = try await gateway.list()
        holder.client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: sessionB)
        _ = try await gateway.list()

        XCTAssertEqual(sessionA.requestCount, 1)
        XCTAssertEqual(sessionB.requestCount, 1, "client を替えた後の呼出は新しい client に届く")
    }
}
