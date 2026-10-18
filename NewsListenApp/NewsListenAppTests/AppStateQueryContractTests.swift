// verifies: ios-query-account-01
import XCTest
import Combine
@testable import NewsListenApp

/// `AppState` の現行の query（`session`・`currentUser`・`subjectStamp`・`isCurrentSubject(_:)`・
/// `lastCleanupIncomplete`・`isConfigured`）が、書込み port に書かないことの契約テスト。
/// 5 つの記録 double を既存の継ぎ目（`SessionStore`・`apiClientFactory`・`PreferenceRegistry`・
/// `AudioCacheManager`・`clearOfflineLibrary`）に被せて `AppState` を組み、
/// 同期の読み・`await` の後・Combine の購読の発火の後のそれぞれで書込みの合計が 0 であることを確かめる。
@MainActor
final class AppStateQueryContractTests: XCTestCase {

    private var ports: RecordingPorts!
    private var appState: AppState!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() async throws {
        try await super.setUp()
        let ports = RecordingPorts()
        self.ports = ports
        appState = AppState(
            sessionStore: ports.sessionStore,
            apiClientFactory: { token, onUnauthorized in
                APIClient(
                    baseURL: URL(string: "https://api.example.com")!,
                    apiKey: "key",
                    sessionToken: token,
                    session: ports.urlSession,
                    onUnauthorized: onUnauthorized
                )
            },
            preferences: PreferenceRegistry(defaults: ports.userDefaults),
            nowPlayingCenter: NowPlayingCenterSpy(),
            clearOfflineLibrary: { try ports.clearOfflineLibrary.run() }
        )
        appState.completeLogin(LoginResponse(token: "tA", user: AuthUser(username: "alice", role: "user", displayName: "Alice")))
        ports.resetCounts()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        appState = nil
        ports.removeSuite()
        ports = nil
        try await super.tearDown()
    }

    private func readAllQueries() {
        _ = appState.session
        _ = appState.currentUser
        let stamp = appState.subjectStamp
        _ = appState.isCurrentSubject(stamp)
        _ = appState.lastCleanupIncomplete
        _ = appState.isConfigured
    }

    /// 束ねた合計と、5 つの double を型を明示して数えた合計の両方が 0 であること。
    private func assertNoWrites(file: StaticString = #filePath, line: UInt = #line) {
        let defaults: RecordingUserDefaults = ports.userDefaults
        let store: RecordingSessionStore = ports.sessionStore
        let session: RecordingURLSession = ports.urlSession
        let files: RecordingFileManager = ports.fileManager
        let clear: RecordingClearOfflineLibrary = ports.clearOfflineLibrary
        XCTAssertEqual(ports.totalWrites, 0, file: file, line: line)
        XCTAssertEqual([defaults.writeCount, store.writeCount, session.writeCount, files.writeCount, clear.writeCount], [0, 0, 0, 0, 0], file: file, line: line)
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

    func testQueriesWriteNothingWhenSessionSubscriptionFires() async {
        appState.$session
            .sink { [unowned self] _ in self.readAllQueries() }
            .store(in: &cancellables)
        for _ in 0..<3 { await Task.yield() }

        assertNoWrites()
    }

    func testWritesThroughTheComposedAppStateAreCounted() async {
        appState.completeLogin(LoginResponse(token: "tB", user: AuthUser(username: "bob", role: "user", displayName: "Bob")))
        XCTAssertGreaterThanOrEqual(ports.sessionStore.writeCount, 1, "正の対照: Keychain 相当の保存が数えられる")

        ports.resetCounts()
        await appState.completeOnboarding()
        XCTAssertEqual(ports.urlSession.writeCount, 1, "正の対照: オンボーディング完了の POST が数えられる")
    }
}
