import XCTest
@testable import NewsListenApp

/// `AppState.refreshPreferences()` のサイレント失敗解消（issue #164）のテスト。
///
/// 失敗しても `defaultDifficulty` 等のローカル値は保持する既存仕様は変えず、
/// 失敗の有無だけを `preferencesSyncFailed` で可視化する。
@MainActor
final class AppStatePreferencesTests: XCTestCase {

    private func makeAppState(session: URLSessionProtocol) -> AppState {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        return AppState(sessionStore: InMemorySessionStore(), apiClientOverride: client)
    }

    func testRefreshPreferencesSetsFailedFlagOnFailure() async {
        let appState = makeAppState(session: MockURLSession(data: Data(), statusCode: 500))

        await appState.refreshPreferences()

        XCTAssertTrue(appState.preferencesSyncFailed)
    }

    func testRefreshPreferencesPreservesLocalValueOnFailure() async {
        // UserDefaults.standard は実機/CI の履歴を引き継ぐ共有ストアのため、
        // 「"toeic_900"になる」ではなく「refreshPreferences 前後で変化しない」ことを検証する。
        let appState = makeAppState(session: MockURLSession(data: Data(), statusCode: 500))
        let before = appState.defaultDifficulty

        await appState.refreshPreferences()

        XCTAssertEqual(appState.defaultDifficulty, before)
    }

    func testRefreshPreferencesClearsFailedFlagOnSuccess() async {
        let json = #"{"default_difficulty":"toeic_600","default_playback_speed":1.25}"#
        let appState = makeAppState(session: MockURLSession(data: Data(json.utf8), statusCode: 200))

        await appState.refreshPreferences()

        XCTAssertFalse(appState.preferencesSyncFailed)
        XCTAssertEqual(appState.defaultDifficulty, "toeic_600")
    }
}
