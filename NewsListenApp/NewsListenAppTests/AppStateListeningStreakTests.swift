import XCTest
@testable import NewsListenApp

@MainActor
final class AppStateListeningStreakTests: XCTestCase {
    private func makeAppState(json: String, statusCode: Int) -> AppState {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: MockURLSession(data: Data(json.utf8), statusCode: statusCode)
        )
        return AppState(sessionStore: InMemorySessionStore(), apiClientOverride: client)
    }

    func testRefreshListeningStreakStoresSuccessfulResponse() async {
        let appState = makeAppState(
            json: #"{"current_streak_days":0,"today_listened":false,"last_listened_day":"2026-07-03"}"#,
            statusCode: 200
        )

        await appState.refreshListeningStreak()

        XCTAssertEqual(appState.listeningStreak?.currentStreakDays, 0)
        XCTAssertEqual(appState.listeningStreak?.lastListenedDay, "2026-07-03")
        XCTAssertFalse(appState.listeningStreakLoadFailed)
    }

    func testRefreshListeningStreakTreats404AsUnavailableWithoutWarning() async {
        let appState = makeAppState(json: "", statusCode: 404)

        await appState.refreshListeningStreak()

        XCTAssertNil(appState.listeningStreak)
        XCTAssertFalse(appState.listeningStreakLoadFailed)
    }

    func testRefreshListeningStreakClearsValueAndSurfacesNon404Failure() async {
        let appState = makeAppState(json: "", statusCode: 500)

        await appState.refreshListeningStreak()

        XCTAssertNil(appState.listeningStreak)
        XCTAssertTrue(appState.listeningStreakLoadFailed)
    }

    func testRefreshListeningStreakPlaysStreakUpOnIncrease() async {
        let appState = AppState(
            sessionStore: InMemorySessionStore(),
            apiClientOverride: APIClient(
                baseURL: URL(string: "https://api.example.com")!,
                apiKey: "key",
                session: MockURLSession(
                    data: Data(#"{"current_streak_days":4,"today_listened":true,"last_listened_day":"2026-07-29"}"#.utf8),
                    statusCode: 200
                )
            )
        )
        // 旧値を設定：3日連続
        appState.listeningStreak = ListeningStreak(
            currentStreakDays: 3,
            todayListened: false,
            lastListenedDay: "2026-07-26"
        )
        DSFeedback.shared.lastPlayedVocabulary = nil

        await appState.refreshListeningStreak()

        XCTAssertEqual(appState.listeningStreak?.currentStreakDays, 4)
        XCTAssertEqual(DSFeedback.shared.lastPlayedVocabulary, .streakUp)
    }

    func testRefreshListeningStreakDoesNotPlayStreakUpOnInitialLoad() async {
        let appState = makeAppState(
            json: #"{"current_streak_days":5,"today_listened":true,"last_listened_day":"2026-07-29"}"#,
            statusCode: 200
        )
        DSFeedback.shared.lastPlayedVocabulary = nil

        await appState.refreshListeningStreak()

        XCTAssertEqual(appState.listeningStreak?.currentStreakDays, 5)
        // 初回ロード（previousStreakDays == nil）では streakUp を発火しない
        XCTAssertNil(DSFeedback.shared.lastPlayedVocabulary)
    }

    func testRefreshListeningStreakDoesNotPlayStreakUpWhenDecreaseOrSame() async {
        let appState = AppState(
            sessionStore: InMemorySessionStore(),
            apiClientOverride: APIClient(
                baseURL: URL(string: "https://api.example.com")!,
                apiKey: "key",
                session: MockURLSession(
                    data: Data(#"{"current_streak_days":2,"today_listened":false,"last_listened_day":"2026-07-27"}"#.utf8),
                    statusCode: 200
                )
            )
        )
        appState.listeningStreak = ListeningStreak(
            currentStreakDays: 3,
            todayListened: true,
            lastListenedDay: "2026-07-28"
        )
        DSFeedback.shared.lastPlayedVocabulary = nil

        await appState.refreshListeningStreak()

        XCTAssertEqual(appState.listeningStreak?.currentStreakDays, 2)
        // 減少時は streakUp を発火しない
        XCTAssertNil(DSFeedback.shared.lastPlayedVocabulary)
    }
}
