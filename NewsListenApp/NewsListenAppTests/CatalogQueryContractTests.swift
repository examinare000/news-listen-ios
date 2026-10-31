// verifies: ios-query-catalog-01, ios-query-catalog-02
import XCTest
import Combine
@testable import NewsListenApp

/// 一覧の query（`reload()`・`rows`・`episode(id:)`）が書込み port に書かないことの契約テスト（ios-check-09）。
///
/// 一覧の応答を返す `ScriptedURLSession` を `RecordingURLSession` で包み、その `APIClient` から `CatalogGateway.live` で
/// `EpisodeCatalog` を組む。同期の読みの直後・`await Task.yield()` の後・`objectWillChange` の購読が発火した後のそれぞれで
/// `writeCount`（POST・PUT・PATCH・DELETE の数）が 0 のままであることを確かめる。
@MainActor
final class CatalogQueryContractTests: XCTestCase {

    private func makeCatalog() throws -> (catalog: EpisodeCatalog, session: RecordingURLSession) {
        let scripted = ScriptedURLSession()
        scripted.configure(
            method: "GET", path: "/podcasts", status: 200,
            body: try EntryFixture.podcastListJSON([EntryFixture.podcast("p1"), EntryFixture.podcast("p2")]))
        let session: RecordingURLSession = RecordingURLSession(delegate: scripted)
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
        return (EpisodeCatalog(gateway: CatalogGateway.live(apiClient: client)), session)
    }

    /// 3 つの query を 1 回ずつ呼ぶ。
    private func readAll(_ catalog: EpisodeCatalog) async throws {
        try await catalog.reload()
        _ = catalog.rows
        _ = catalog.episode(id: "p1")
    }

    func testQueriesWriteNothingAfterSynchronousReads() async throws {
        let (catalog, session) = try makeCatalog()

        try await readAll(catalog)

        XCTAssertEqual(catalog.rows.map(\.episodeId), ["p1", "p2"], "正方向の対照: 読みは実際に一覧を返している")
        XCTAssertNotNil(catalog.episode(id: "p1"))
        XCTAssertEqual(session.writeCount, 0)
    }

    func testQueriesWriteNothingAfterYield() async throws {
        let (catalog, session) = try makeCatalog()

        try await readAll(catalog)
        await Task.yield()

        XCTAssertEqual(catalog.rows.count, 2, "正方向の対照: 読みは実際に一覧を返している")
        XCTAssertEqual(session.writeCount, 0)
    }

    func testQueriesWriteNothingAfterObjectWillChangeFires() async throws {
        let (catalog, session) = try makeCatalog()
        var fired = 0
        let subscription = catalog.objectWillChange.sink { fired += 1 }
        defer { subscription.cancel() }

        try await catalog.reload()
        XCTAssertGreaterThan(fired, 0, "正方向の対照: reload で購読が発火している")
        _ = catalog.rows
        _ = catalog.episode(id: "p2")

        XCTAssertEqual(session.writeCount, 0)
    }
}
