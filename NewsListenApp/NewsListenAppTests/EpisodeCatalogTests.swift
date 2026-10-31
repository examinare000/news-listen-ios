// verifies: ios-query-catalog-01, ios-query-catalog-02, ios-cmd-catalog-01, ios-rule-catalog-02
import XCTest
import Combine
import os
@testable import NewsListenApp

/// `EpisodeCatalog`（一覧の保持・id からの引き当て・位置の応答の反映）と `CatalogGateway.live` の振る舞いテスト。
/// `CatalogGateway` は stub の closure か、`APIClient` 越しの通信 double で差し替える。
@MainActor
final class EpisodeCatalogTests: XCTestCase {

    // MARK: - helper

    private func content(
        _ id: String,
        title: String? = nil,
        intro: String = "導入",
        segments: [TranscriptSegment]? = nil
    ) -> EpisodeContent {
        EpisodeContent(
            id: id, title: title ?? "題 \(id)", japaneseIntroText: intro, difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
            segments: segments, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
    }

    private func playable(
        _ id: String,
        title: String? = nil,
        serverPosition: Double = 0,
        segments: [TranscriptSegment]? = nil
    ) throws -> Episode {
        let body = try XCTUnwrap(PlayableEpisode(
            content: content(id, title: title, segments: segments),
            audioUrl: "https://cdn.example.com/\(id).mp3",
            serverPosition: serverPosition))
        return .playable(body)
    }

    private func catalog(returning episodes: [Episode]) -> EpisodeCatalog {
        EpisodeCatalog(gateway: CatalogGateway(fetchEpisodes: { episodes }))
    }

    private func apiClient(session: URLSessionProtocol) -> APIClient {
        APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: session)
    }

    private func listJSON(_ podcasts: [Podcast]) throws -> Data {
        try EntryFixture.podcastListJSON(podcasts)
    }

    /// 呼出回数を数える（closure は非 isolated なのでロックで守る）。
    private final class CallCounter: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        var count: Int { lock.withLock { $0 } }
        func increment() { lock.withLock { $0 += 1 } }
    }

    /// 呼ぶたびに用意した結果を順に返す（尽きたら最後の結果）。
    private final class ScriptedFetch: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: 0)
        private let outcomes: [Result<[Episode], Error>]
        init(_ outcomes: [Result<[Episode], Error>]) { self.outcomes = outcomes }

        func fetch() async throws -> [Episode] {
            let index: Int = lock.withLock { count in
                defer { count += 1 }
                return min(count, outcomes.count - 1)
            }
            return try outcomes[index].get()
        }
    }

    // MARK: - reload の成功（adapter 経由）

    func testReloadMapsPodcastListResponseToRowsWithBadgePerKind() async throws {
        let responseBody = try listJSON([
            EntryFixture.podcast("p1"),
            EntryFixture.podcast("p2", status: "processing"),
            EntryFixture.podcast("p3", status: "failed", errorMessage: "generation failed"),
        ])
        let client = apiClient(session: MockURLSession(data: responseBody, statusCode: 200))
        let catalog = EpisodeCatalog(gateway: CatalogGateway.live(apiClient: client))

        try await catalog.reload()
        let rows: [EpisodeRow] = catalog.rows

        XCTAssertEqual(rows.map(\.episodeId), ["p1", "p2", "p3"])
        XCTAssertEqual(rows.map(\.badge), [.none, .generating, .failed(detail: "generation failed")])
        XCTAssertEqual(rows[0], EpisodeRow(
            episodeId: "p1", title: "題 p1", difficulty: "toeic_900", durationSeconds: 300,
            createdAt: "2026-05-31T06:00:00Z", badge: .none))
    }

    func testReloadFailureKeepsRowsAndThrowsApiFailure() async throws {
        let session = ScriptedURLSession()
        session.configure(method: "GET", path: "/podcasts", status: 200, body: try listJSON([EntryFixture.podcast("p1")]))
        let catalog = EpisodeCatalog(gateway: CatalogGateway.live(apiClient: apiClient(session: session)))
        try await catalog.reload()
        let rowsBefore = catalog.rows
        let episodeBefore = catalog.episode(id: "p1")
        XCTAssertEqual(rowsBefore.map(\.episodeId), ["p1"], "Given: 1 回目の取得は成功している")

        session.configure(method: "GET", path: "/podcasts", status: 500)
        do {
            try await catalog.reload()
            XCTFail("500 では throw するはず")
        } catch {
            XCTAssertTrue(error is ApiFailure, "取得の失敗は ApiFailure のまま届く: \(error)")
        }

        XCTAssertEqual(catalog.rows, rowsBefore)
        XCTAssertEqual(catalog.episode(id: "p1"), episodeBefore)
    }

    func testReloadRethrowsCancellationErrorUnchangedAndKeepsRows() async throws {
        let a = try playable("a")
        let fetch = ScriptedFetch([.success([a]), .failure(CancellationError())])
        let catalog = EpisodeCatalog(gateway: CatalogGateway(fetchEpisodes: { try await fetch.fetch() }))
        try await catalog.reload()

        do {
            try await catalog.reload()
            XCTFail("CancellationError を投げるはず")
        } catch {
            XCTAssertTrue(error is CancellationError, "変換せずそのまま投げる: \(error)")
        }

        XCTAssertEqual(catalog.rows.map(\.episodeId), ["a"])
    }

    func testReloadReplacesPreviousContentsWholesale() async throws {
        let first = try [playable("a"), playable("b")]
        let second = try [playable("c")]
        let fetch = ScriptedFetch([.success(first), .success(second)])
        let catalog = EpisodeCatalog(gateway: CatalogGateway(fetchEpisodes: { try await fetch.fetch() }))

        try await catalog.reload()
        try await catalog.reload()

        XCTAssertEqual(catalog.rows.map(\.episodeId), ["c"])
        XCTAssertNil(catalog.episode(id: "a"), "取得のたびに丸ごと置き換える")
    }

    func testReloadNotifiesObjectWillChange() async throws {
        let catalog = catalog(returning: try [playable("a")])
        var fired = 0
        let subscription = catalog.objectWillChange.sink { fired += 1 }
        defer { subscription.cancel() }

        try await catalog.reload()

        XCTAssertGreaterThan(fired, 0)
    }

    // MARK: - 生成直後

    func testNewCatalogIsEmptyAndDoesNotFetch() {
        let counter = CallCounter()
        let catalog = EpisodeCatalog(gateway: CatalogGateway(fetchEpisodes: {
            counter.increment()
            return []
        }))

        XCTAssertEqual(catalog.rows, [])
        XCTAssertNil(catalog.episode(id: "a"))
        XCTAssertEqual(counter.count, 0)
    }

    // MARK: - 位置の応答の反映（applyPositionSaved）

    func testApplyPositionSavedReplacesSameIdAndKeepsOthersAndOrder() async throws {
        let a = try playable("a", title: "旧")
        let b = try playable("b")
        let catalog = catalog(returning: [a, b])
        try await catalog.reload()
        let bBefore = catalog.rows[1]

        let updated = try playable("a", title: "新", serverPosition: 42)
        catalog.applyPositionSaved(updated)

        XCTAssertEqual(catalog.episode(id: "a"), updated)
        XCTAssertEqual(catalog.rows.map(\.episodeId), ["a", "b"], "順序は変えない")
        XCTAssertEqual(catalog.rows[0].title, "新", "rows も作り直される")
        XCTAssertEqual(catalog.rows[1], bBefore)
        XCTAssertEqual(catalog.episode(id: "b"), b)
    }

    func testApplyPositionSavedIgnoresIdNotInCatalog() async throws {
        let a = try playable("a")
        let b = try playable("b")
        let catalog = catalog(returning: [a, b])
        try await catalog.reload()
        let rowsBefore = catalog.rows

        catalog.applyPositionSaved(try playable("z", serverPosition: 7))

        XCTAssertEqual(catalog.rows, rowsBefore, "一覧に無い id は追加しない")
        XCTAssertEqual(catalog.episode(id: "a"), a)
        XCTAssertEqual(catalog.episode(id: "b"), b)
        XCTAssertNil(catalog.episode(id: "z"))
    }

    func testApplyPositionSavedLastWriteWins() async throws {
        let catalog = catalog(returning: try [playable("a")])
        try await catalog.reload()

        let first = try playable("a", serverPosition: 90)
        let second = try playable("a", serverPosition: 10)
        catalog.applyPositionSaved(first)
        catalog.applyPositionSaved(second)

        XCTAssertEqual(catalog.episode(id: "a"), second, "位置の大小で選ばず、後から届いた応答が勝つ")
    }

    // MARK: - バッジの判定

    func testRowBadgeIsDerivedFromEpisodeKind() async throws {
        let ok = try playable("ok")
        let generating = Episode.generating(GeneratingEpisode(content: content("gen")))
        let failedWithMessage = Episode.failed(FailedEpisode(content: content("f1"), reportedMessage: "x"))
        let failedWithoutMessage = Episode.failed(FailedEpisode(content: content("f2"), reportedMessage: nil))
        let catalog = catalog(returning: [ok, generating, failedWithMessage, failedWithoutMessage])

        try await catalog.reload()

        XCTAssertEqual(
            catalog.rows.map(\.badge),
            [.none, .generating, .failed(detail: "x"), .failed(detail: "")])
    }

    // MARK: - 値の写し

    func testRowsCopyIsIndependentFromCatalog() async throws {
        let catalog = catalog(returning: try [playable("a"), playable("b")])
        try await catalog.reload()

        var copy = catalog.rows
        copy.removeAll()

        XCTAssertEqual(copy, [])
        XCTAssertEqual(catalog.rows.map(\.episodeId), ["a", "b"])
    }

    func testEpisodeLookupReturnsEpisodeOrNilAndResultIsIndependentValue() async throws {
        let segment = TranscriptSegment(speaker: "A", text: "hello")
        let a = try playable("a", segments: [segment])
        let b = try playable("b")
        let catalog = catalog(returning: [a, b])
        try await catalog.reload()

        let found: Episode? = catalog.episode(id: "a")
        let missing: Episode? = catalog.episode(id: "zz")
        var segments = try XCTUnwrap(found?.content.segments)
        segments.removeAll()
        let again = catalog.episode(id: "a")

        XCTAssertEqual(found, a)
        XCTAssertNil(missing)
        XCTAssertEqual(segments, [])
        XCTAssertEqual(again?.content.segments, [segment])
    }

    // MARK: - 行の写し

    func testRowTitleUsesDisplayTitleAndIdEqualsEpisodeId() async throws {
        let episode = try XCTUnwrap(PlayableEpisode(
            content: EpisodeContent(
                id: "blank", title: "   ", japaneseIntroText: "導入", difficulty: "toeic_900",
                createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
                segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil),
            audioUrl: "https://cdn.example.com/blank.mp3", serverPosition: 0))
        let catalog = catalog(returning: [.playable(episode)])

        try await catalog.reload()

        XCTAssertEqual(catalog.rows[0].title, "導入", "題が空白だけなら導入文が題になる（EpisodeContent.displayTitle）")
        XCTAssertEqual(catalog.rows[0].id, catalog.rows[0].episodeId)
    }
}
