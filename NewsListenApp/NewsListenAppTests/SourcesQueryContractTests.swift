// verifies: ios-query-sources-01, ios-query-sources-02
import XCTest
@testable import NewsListenApp

/// `SourceSubscriptions` の `list()`・`featured()`・`canEdit(role:)` と、`OnboardingProgress` の `isCompleted`・`refresh()` を
/// 読んでも書込み（POST・PUT・PATCH・DELETE）が 0 件であることの契約テスト。
/// `RecordingURLSession` を `APIClient` に被せ、`SourcesGateway.live`・`OnboardingProgress.live` を通して数える。
@MainActor
final class SourcesQueryContractTests: XCTestCase {

    private let sourcesJSON = #"{"sources":[{"name":"HackerNews","url":"https://hnrss.org/frontpage"}]}"#
    private let sitesJSON = #"{"sites":[{"id":"the-verge","name":"The Verge","url":"https://www.theverge.com/rss/index.xml","thumbnail_url":null,"description":null}]}"#
    private let onboardingJSON = #"{"onboarding_completed":false}"#

    private func makeClient(json: String, statusCode: Int = 200) -> (APIClient, RecordingURLSession) {
        let recording = RecordingURLSession(delegate: MockURLSession(data: Data(json.utf8), statusCode: statusCode))
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: recording)
        return (client, recording)
    }

    private func makeProgress(_ client: APIClient) -> OnboardingProgress {
        let state = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        state.completeLogin(LoginReceipt(
            token: "tA",
            subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)
        ))
        return OnboardingProgress.live(
            client: { client },
            subjectStamp: { state.subjectStamp },
            isCurrentSubject: { state.isCurrentSubject($0) }
        )
    }

    // verifies: ios-query-sources-01, ios-check-09
    func testListDoesNotWrite() async throws {
        let (client, recording) = makeClient(json: sourcesJSON)
        let subscriptions = SourceSubscriptions(gateway: .live(client: { client }))

        let list = try await subscriptions.list()

        XCTAssertEqual(list.map(\.name), ["HackerNews"], "読みが実際に通信している")
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-sources-01, ios-check-09
    func testFeaturedDoesNotWrite() async throws {
        let (client, recording) = makeClient(json: sitesJSON)
        let subscriptions = SourceSubscriptions(gateway: .live(client: { client }))

        let groups = try await subscriptions.featured()

        XCTAssertFalse(groups.isEmpty)
        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-sources-01
    func testCanEditDoesNotWrite() {
        let (client, recording) = makeClient(json: sourcesJSON)
        let subscriptions = SourceSubscriptions(gateway: .live(client: { client }))

        XCTAssertTrue(subscriptions.canEdit(role: .admin))
        XCTAssertFalse(subscriptions.canEdit(role: .user))

        XCTAssertEqual(recording.writeCount, 0)
    }

    // verifies: ios-query-sources-02, ios-check-09
    func testReadingIsCompletedAndRefreshDoNotWrite() async {
        let (client, recording) = makeClient(json: onboardingJSON)
        let progress = makeProgress(client)

        _ = progress.isCompleted
        XCTAssertEqual(recording.writeCount, 0, "同期の読み")

        await progress.refresh()
        _ = progress.isCompleted

        XCTAssertEqual(progress.isCompleted, false, "JSON どおりの値が入る")
        XCTAssertEqual(recording.writeCount, 0, "await の後")
    }

    // verifies: ios-cmd-sources-03
    func testCompleteWritesOnceAsPositiveControl() async {
        let (client, recording) = makeClient(json: #"{"onboarding_completed":true}"#)
        let progress = makeProgress(client)

        await progress.complete()

        XCTAssertEqual(recording.writeCount, 1)
        XCTAssertEqual(progress.isCompleted, true)
    }
}
