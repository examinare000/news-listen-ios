// verifies: ios-query-curation-01, ios-query-curation-02, ios-query-curation-03
import XCTest
import Combine
@testable import NewsListenApp

/// `FeedCuration` の公開する状態（`cards`・`pending`・`lastFailure`）と `reload()`・`StarredArticles.list()`・
/// `generationAllowance()` を読んでも、書込み（POST・PUT・PATCH・DELETE）が 0 件であることの契約テスト。
/// `RecordingURLSession` を `APIClient` に被せ、`CurationGateway.live` を通して数える。
@MainActor
final class CurationQueryContractTests: XCTestCase {

    private let feedJSON = #"{"articles":[{"id":"a1","title":"X","url":"https://e.com","source":"s","score":0.5,"published_at":"2026-05-31T06:00:00Z"}],"date":"2026-05-31"}"#
    private let starredJSON = #"{"articles":[{"id":"a1","title":"X","url":"https://e.com","source":"s","score":0.5,"published_at":"2026-05-31T06:00:00Z"}]}"#
    private let quotaJSON = #"{"limit":5,"used":2,"remaining":3,"reset_at":"2026-07-07T00:00:00Z"}"#

    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() async throws {
        cancellables.removeAll()
        try await super.tearDown()
    }

    private func makeClient(json: String, statusCode: Int = 200) -> (APIClient, RecordingURLSession) {
        let recording = RecordingURLSession(delegate: MockURLSession(data: Data(json.utf8), statusCode: statusCode))
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: recording)
        return (client, recording)
    }

    private func makeCuration(_ client: APIClient) -> FeedCuration {
        FeedCuration(gateway: .live(client: { client }), undoGracePeriod: .seconds(60), currentSubject: { nil })
    }

    // verifies: ios-query-curation-01
    func testReadingStateAndReloadDoesNotWrite() async throws {
        let (client, recording) = makeClient(json: feedJSON)
        let curation = makeCuration(client)
        var received = 0
        curation.$cards.sink { _ in received += 1 }.store(in: &cancellables)

        _ = curation.cards
        _ = curation.pending
        _ = curation.lastFailure
        XCTAssertEqual(recording.writeCount, 0, "同期の読み")

        try await curation.reload()
        _ = curation.cards
        _ = curation.pending
        _ = curation.lastFailure
        XCTAssertEqual(curation.cards.map(\.id), ["a1"])
        XCTAssertEqual(recording.writeCount, 0, "await の後")

        XCTAssertGreaterThanOrEqual(received, 2, "購読が発火している")
        _ = curation.cards
        XCTAssertEqual(recording.writeCount, 0, "購読の発火の後")
    }

    // verifies: ios-query-curation-01
    func testReloadDoesNotCommitPending() async throws {
        let (client, recording) = makeClient(json: feedJSON)
        let curation = makeCuration(client)
        try await curation.reload()
        await curation.star(articleId: "a1", difficulty: nil)
        XCTAssertEqual(curation.pending?.articleId, "a1")

        try await curation.reload()

        XCTAssertEqual(curation.pending?.articleId, "a1", "再読込は保留を確定しない")
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-curation-02
    func testStarredListDoesNotWrite() async throws {
        let (client, recording) = makeClient(json: starredJSON)
        let starred = StarredArticles(gateway: .live(client: { client }))

        let list = try await starred.list()

        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-curation-03
    func testGenerationAllowanceDoesNotWriteAndMapsNotFoundToNil() async throws {
        let (client, recording) = makeClient(json: quotaJSON)
        let allowance = try await makeCuration(client).generationAllowance()
        XCTAssertEqual(allowance?.limit, 5)
        XCTAssertEqual(allowance?.remaining, 3)
        XCTAssertEqual(recording.writeCount, 0)

        let (missingClient, missingRecording) = makeClient(json: "", statusCode: 404)
        let missing = try await makeCuration(missingClient).generationAllowance()
        XCTAssertNil(missing)
        XCTAssertEqual(missingRecording.writeCount, 0)

        let (failingClient, _) = makeClient(json: "", statusCode: 500)
        do {
            _ = try await makeCuration(failingClient).generationAllowance()
            XCTFail("404 以外の失敗は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }
    }

    // verifies: ios-test-111
    func testReturnedCardsAreCopiesNotSharedStorage() async throws {
        let (client, _) = makeClient(json: feedJSON)
        let curation = makeCuration(client)
        try await curation.reload()

        var copy = curation.cards
        copy.removeAll()

        XCTAssertEqual(curation.cards.map(\.id), ["a1"])

        let (starredClient, _) = makeClient(json: starredJSON)
        let starred = StarredArticles(gateway: .live(client: { starredClient }))
        var listed = try await starred.list()
        listed.removeAll()
        let again = try await starred.list()
        XCTAssertEqual(again.count, 1)
    }
}
