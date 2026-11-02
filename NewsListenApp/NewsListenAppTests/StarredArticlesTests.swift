import XCTest
@testable import NewsListenApp

/// Star 済み記事の一覧と解除を持つ `StarredArticles`（application）のテスト。closure の gateway で呼出を記録する。
@MainActor
final class StarredArticlesTests: XCTestCase {

    private func card(_ id: String) -> ArticleCardModel {
        ArticleCardModel(id: id, title: id, url: "https://example.com/\(id)", source: "s", score: 0.5, publishedAt: "2026-05-31T06:00:00Z")
    }

    private final class Calls {
        var feed = 0
        var star = 0
        var dismiss = 0
        var allowance = 0
        var starred = 0
        var unstarred: [String] = []
    }

    private func makeGateway(
        calls: Calls,
        starred: @escaping () async throws -> [ArticleCardModel] = { [] },
        unstar: @escaping (String) async throws -> Void = { _ in }
    ) -> CurationGateway {
        CurationGateway(
            fetchFeed: { @MainActor in calls.feed += 1; return [] },
            star: { @MainActor _, _ in calls.star += 1 },
            dismiss: { @MainActor _ in calls.dismiss += 1 },
            fetchStarred: { @MainActor in
                calls.starred += 1
                return try await starred()
            },
            unstar: { @MainActor id in
                calls.unstarred.append(id)
                try await unstar(id)
            },
            fetchAllowance: { @MainActor in calls.allowance += 1; return nil }
        )
    }

    // MARK: - unstar（ios-test-010）

    // verifies: ios-cmd-curation-04, ios-rule-curation-04
    func testUnstarTreatsStarNotFoundAsSuccess() async throws {
        let calls = Calls()
        let starred = StarredArticles(gateway: makeGateway(calls: calls, unstar: { _ in throw ApiFailure.notFound(subject: .star) }))

        try await starred.unstar(articleId: "a1")

        XCTAssertEqual(calls.unstarred, ["a1"])
    }

    // verifies: ios-cmd-curation-04, ios-rule-curation-04
    func testUnstarRethrowsOtherFailuresIncludingCancellation() async throws {
        let failures: [Error] = [ApiFailure.server(status: 500), CancellationError(), URLError(.cancelled), ApiFailure.notFound(subject: .quota)]
        for failure in failures {
            let starred = StarredArticles(gateway: makeGateway(calls: Calls(), unstar: { _ in throw failure }))
            do {
                try await starred.unstar(articleId: "a1")
                XCTFail("\(failure) は投げる")
            } catch let error as ApiFailure {
                XCTAssertEqual(error, failure as? ApiFailure)
            } catch let error as URLError {
                XCTAssertEqual(error.code, .cancelled)
            } catch is CancellationError {
                // 素のキャンセルもそのまま投げる。
            } catch {
                XCTFail("変換せずに投げる: \(error)")
            }
        }
    }

    // MARK: - list・生成（ios-query-curation-02）

    // verifies: ios-query-curation-02
    func testInitDoesNotCallGateway() {
        let calls = Calls()
        _ = StarredArticles(gateway: makeGateway(calls: calls))

        XCTAssertEqual(calls.feed + calls.star + calls.dismiss + calls.allowance + calls.starred + calls.unstarred.count, 0)
    }

    // verifies: ios-query-curation-02
    func testListReturnsGatewayResultAsIs() async throws {
        let calls = Calls()
        let starred = StarredArticles(gateway: makeGateway(calls: calls, starred: { [self] in [card("s1"), card("s2")] }))

        let list = try await starred.list()

        XCTAssertEqual(list.map(\.id), ["s1", "s2"])
        XCTAssertEqual(calls.starred, 1)
        XCTAssertTrue(calls.unstarred.isEmpty)
    }

    // verifies: ios-query-curation-02
    func testListRethrowsGatewayFailure() async throws {
        let starred = StarredArticles(gateway: makeGateway(calls: Calls(), starred: { throw ApiFailure.server(status: 500) }))

        do {
            _ = try await starred.list()
            XCTFail("失敗は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }
}
