// verifies: ios-query-notify-01
import XCTest
import Combine
@testable import NewsListenApp

/// `PushRegistration.pendingEpisodeId` を読んでも、書込み port に書かないことの契約テスト。
/// `RecordingURLSession` を `PushGateway.live(apiClient:)` の `APIClient` に被せ、同期の読み・`await` の後・
/// Combine の購読の発火の後のそれぞれで、書込みの合計が 0 であることを確かめる。
@MainActor
final class PushQueryContractTests: XCTestCase {

    private var ports: RecordingPorts!
    private var push: PushRegistration!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        let ports = RecordingPorts(
            sessionToken: "tA",
            urlSessionDelegate: MockURLSession(data: Data("{}".utf8), statusCode: 200)
        )
        self.ports = ports
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            sessionToken: "tA",
            session: ports.urlSession
        )
        // `SubjectStamp` は `AppState.swift` の外から作れないので、本物の `AppState` から借りる。
        let stamp = makeSubjectAwareAppState().subjectStamp
        push = PushRegistration(
            gateway: { PushGateway.live(apiClient: client) },
            isAuthenticated: { true },
            subjectStamp: { stamp },
            isCurrentSubject: { _ in true }
        )
        push.openEpisode(id: "pod123")
        ports.resetCounts()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        push = nil
        ports.removeSuite()
        ports = nil
        try await super.tearDown()
    }

    private func readAllQueries() {
        _ = push.pendingEpisodeId
    }

    private func assertNoWrites(file: StaticString = #filePath, line: UInt = #line) {
        let session: RecordingURLSession = ports.urlSession
        XCTAssertEqual(ports.totalWrites, 0, file: file, line: line)
        XCTAssertEqual(session.writeCount, 0, "通信の書込みメソッド", file: file, line: line)
    }

    func testQueriesWriteNothingAfterSynchronousReads() {
        readAllQueries()

        assertNoWrites()
    }

    func testQueriesWriteNothingAfterAwait() async {
        readAllQueries()
        for _ in 0..<3 { await Task.yield() }

        assertNoWrites()
    }

    func testQueriesWriteNothingWhenPendingEpisodeSubscriptionFires() async {
        push.$pendingEpisodeId
            .sink { [unowned self] _ in self.readAllQueries() }
            .store(in: &cancellables)
        push.openEpisode(id: "pod456")
        for _ in 0..<3 { await Task.yield() }

        assertNoWrites()
    }

    func testWritesThroughTheComposedPushRegistrationAreCounted() async {
        push.didReceiveDeviceToken("devicetokenhex")
        await push.registerIfPossible()

        XCTAssertEqual(ports.urlSession.writeCount, 1, "正の対照: 端末トークンの登録（POST）が数えられる")
    }
}
