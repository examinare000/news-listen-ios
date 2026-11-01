// verifies: ios-query-prefs-01
import XCTest
import Combine
@testable import NewsListenApp

/// `PreferencesStore` の公開する状態 8 つ（`defaultDifficulty`・`defaultPlaybackSpeed`・`weeklyGoal`・`articleOpenMode`・
/// `timeFormat`・`soundEnabled`・`hapticsEnabled`・`syncFailed`）を読んでも、書込み port に書かないことの契約テスト。
/// `RecordingUserDefaults` を `PreferenceRegistry(defaults:)` に、`RecordingURLSession` を gateway の `APIClient` に被せ、
/// 同期の読み・`await` の後・Combine の購読の発火の後のそれぞれで、書込みの増分が 0 であることを確かめる。
@MainActor
final class PreferencesQueryContractTests: XCTestCase {

    private var ports: RecordingPorts!
    private var store: PreferencesStore!
    private var state: AppState!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        let ports = RecordingPorts(
            sessionToken: "tA",
            urlSessionDelegate: MockURLSession(data: Data("{}".utf8), statusCode: 200)
        )
        self.ports = ports
        let made = makeAppStateWithPreferences(
            session: ports.urlSession,
            sessionStore: InMemorySessionStore(token: "tA"),
            defaults: ports.userDefaults
        )
        state = made.state
        store = made.store
        state.completeLogin(LoginReceipt(token: "tA", subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)))
        ports.resetCounts()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        store = nil
        state = nil
        ports.removeSuite()
        ports = nil
        try await super.tearDown()
    }

    private func readAllQueries() {
        _ = store.defaultDifficulty
        _ = store.defaultPlaybackSpeed
        _ = store.weeklyGoal
        _ = store.articleOpenMode
        _ = store.timeFormat
        _ = store.soundEnabled
        _ = store.hapticsEnabled
        _ = store.syncFailed
    }

    private func assertNoWrites(file: StaticString = #filePath, line: UInt = #line) {
        let defaults: RecordingUserDefaults = ports.userDefaults
        let session: RecordingURLSession = ports.urlSession
        XCTAssertEqual(defaults.writeCount, 0, "UserDefaults への書込み", file: file, line: line)
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

    func testQueriesWriteNothingWhenStoreSubscriptionFires() async {
        store.objectWillChange
            .sink { [unowned self] _ in self.readAllQueries() }
            .store(in: &cancellables)
        store.setTimeFormat(store.timeFormat)
        ports.resetCounts()
        store.objectWillChange.send()
        for _ in 0..<3 { await Task.yield() }

        assertNoWrites()
    }

    func testWritesThroughTheComposedStoreAreCounted() async throws {
        store.setSoundEnabled(false)
        XCTAssertEqual(ports.userDefaults.writeCount, 1, "正の対照: 端末設定の保存が数えられる")

        ports.resetCounts()
        try await store.setDefaultDifficulty(.toeic900)
        XCTAssertEqual(ports.urlSession.writeCount, 1, "正の対照: 設定の更新要求（PUT）が数えられる")
        XCTAssertGreaterThanOrEqual(ports.userDefaults.writeCount, 1)
    }
}
