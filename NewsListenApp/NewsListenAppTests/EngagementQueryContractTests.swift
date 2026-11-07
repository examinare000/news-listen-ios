// verifies: ios-query-learning-01, ios-query-learning-02, ios-query-learning-03, ios-test-028, ios-test-112
import XCTest
import Combine
@testable import NewsListenApp

/// `EngagementStore` の query（`dashboard()`・`unseenAchievements(in:)`・`streak`・`streakLoadFailed`）が
/// 書込み port に書かないことの契約テスト（ios-check-09）と、ダッシュボードの写し（adapter）のテスト。
///
/// 応答を返す `ScriptedURLSession` を `RecordingURLSession` で包み、その `APIClient` から `LearningGateway.live` を組む
/// （`LearningQueryContractTests` と同じ形）。既読の保存先は `RecordingUserDefaults` の `PreferenceRegistry`。
@MainActor
final class EngagementQueryContractTests: XCTestCase {

    private var scripted: ScriptedURLSession!
    private var recording: RecordingURLSession!
    private var ports: RecordingPorts!
    private var appState: AppState!
    private var store: EngagementStore!

    override func setUp() {
        super.setUp()
        scripted = ScriptedURLSession()
        ports = RecordingPorts(urlSessionDelegate: scripted)
        recording = ports.urlSession
        let client = APIClient(baseURL: URL(string: "https://api.example.com")!, apiKey: "key", session: recording)
        let registry = PreferenceRegistry(defaults: ports.userDefaults)
        appState = makeSubjectAwareAppState(sessionStore: InMemorySessionStore(token: "tA"))
        appState.completeLogin(
            LoginReceipt(token: "tA", subject: Subject(username: "alice", displayName: "Alice", role: Role(rawValue: "user"), key: nil)))
        let state: AppState = appState
        store = EngagementStore(
            gateway: LearningGateway.live(apiClient: client),
            seenStore: registry.seenAchievements,
            subjectStamp: { state.subjectStamp },
            isCurrentSubject: { _ in true }
        )
        ports.resetCounts()
    }

    override func tearDown() {
        ports.removeSuite()
        super.tearDown()
    }

    // MARK: fixtures

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func fullDashboardObject(totalEpisodes: Int = 12) -> [String: Any] {
        [
            "streak": ["current_streak_days": 4, "today_listened": true, "last_listened_day": "2026-07-29"],
            "total_episodes": totalEpisodes,
            "vocabulary_acquired": 31,
            "quiz": [
                "quizzed_episodes": 2,
                "average_correct_rate": 0.75,
                "trend": [
                    ["graded_at": "2026-07-28T12:00:00Z", "correct_rate": 0.75],
                    ["graded_at": "2026-07-29T08:30:00Z", "correct_rate": 0.5],
                ],
            ] as [String: Any],
            "monthly_activity": [["month": "2026-06", "active_days": 8], ["month": "2026-07", "active_days": 11]],
            "current_difficulty": "toeic_900",
            "weekly_goal": [
                "goal_episodes": 5,
                "week": "2026-W31",
                "completed_this_week": 3,
                "history": [
                    ["week": "2026-W30", "goal": 5, "completed": 4],
                    ["week": "2026-W29", "goal": 7, "completed": 2],
                ],
            ] as [String: Any],
            "achievements": [
                ["id": "first_episode_completed", "unlocked_at": "2026-07-29"],
                ["id": "mystery_future_badge", "unlocked_at": "2026-07-30"],
            ],
        ]
    }

    /// `weekly_goal`・`achievements` を持たない旧 server の応答。
    private func oldServerDashboardObject() -> [String: Any] {
        [
            "streak": ["current_streak_days": 0, "today_listened": false, "last_listened_day": NSNull()],
            "total_episodes": 0,
            "vocabulary_acquired": 0,
            "quiz": ["quizzed_episodes": 0, "average_correct_rate": NSNull(), "trend": [Any]()] as [String: Any],
            "monthly_activity": [Any](),
            "current_difficulty": "toeic_600",
        ]
    }

    private func serveDashboard(_ object: [String: Any]) {
        scripted.configure(method: "GET", path: "/users/me/learning-dashboard", status: 200, body: json(object))
    }

    private func serveStreak(days: Int) {
        scripted.configure(
            method: "GET", path: "/users/me/listening-streak", status: 200,
            body: json(["current_streak_days": days, "today_listened": true, "last_listened_day": "2026-07-29"]))
    }

    private func requestCount(path: String) -> Int {
        scripted.sentRequests.filter { $0.httpMethod == "GET" && $0.url?.path == path }.count
    }

    private func achievements(_ ids: [String]) -> [Achievement] {
        ids.map { Achievement(id: $0, unlockedAt: "2026-07-29") }
    }

    private func summaryWithAchievements(_ ids: [String]) -> LearningDashboardSummary {
        LearningDashboardSummary(
            streak: ListeningStreakStatus(days: 1, listenedToday: false, lastListenedDay: "2026-07-01"),
            weekly: nil, weeklyHistory: [], achievements: achievements(ids), monthlyListeningDays: [],
            completedCount: 0, masteredVocabularyCount: 0, currentLevel: "toeic_600",
            quizzedEpisodeCount: 0, averageCorrectRate: nil, quizTrend: [])
    }

    // MARK: dashboard() の写し（CI-9）

    // CI-9（T-Q1。ios-test-028）: 応答の全項目を写す。週名と目標・実績を取り違えず、カタログに無い id を落とさない。
    func testDashboardMapsEveryFieldOfTheResponse() async throws {
        serveDashboard(fullDashboardObject())

        let summary = try await store.dashboard()

        XCTAssertEqual(summary.streak, ListeningStreakStatus(days: 4, listenedToday: true, lastListenedDay: "2026-07-29"))
        XCTAssertEqual(summary.weekly, WeeklyProgress(completed: 3, goal: 5))
        XCTAssertEqual(summary.weeklyHistory, [
            WeeklyHistoryEntry(week: "2026-W30", progress: WeeklyProgress(completed: 4, goal: 5)),
            WeeklyHistoryEntry(week: "2026-W29", progress: WeeklyProgress(completed: 2, goal: 7)),
        ])
        XCTAssertEqual(summary.achievements, [
            Achievement(id: "first_episode_completed", unlockedAt: "2026-07-29"),
            Achievement(id: "mystery_future_badge", unlockedAt: "2026-07-30"),
        ], "カタログに無い id も残す")
        XCTAssertEqual(summary.monthlyListeningDays, [
            MonthlyListening(month: "2026-06", days: 8),
            MonthlyListening(month: "2026-07", days: 11),
        ])
        XCTAssertEqual(summary.completedCount, 12)
        XCTAssertEqual(summary.masteredVocabularyCount, 31)
        XCTAssertEqual(summary.currentLevel, "toeic_900")
        XCTAssertEqual(summary.quizzedEpisodeCount, 2)
        XCTAssertEqual(summary.averageCorrectRate, 0.75)
        XCTAssertEqual(summary.quizTrend, [
            QuizTrendEntry(date: "2026-07-28T12:00:00Z", rate: 0.75),
            QuizTrendEntry(date: "2026-07-29T08:30:00Z", rate: 0.5),
        ], "順序と文字列をそのまま写す")
    }

    // CI-9（T-Q5。ios-test-028）: 旧 server の応答でも壊れず、読むだけで書かず、streak を変えない。
    func testDashboardOfOldServerHasNilWeeklyAndEmptyListsAndWritesNothing() async throws {
        serveDashboard(oldServerDashboardObject())

        let summary = try await store.dashboard()

        XCTAssertNil(summary.weekly)
        XCTAssertEqual(summary.weeklyHistory, [])
        XCTAssertEqual(summary.achievements, [])
        XCTAssertNil(summary.averageCorrectRate)
        XCTAssertEqual(summary.quizTrend, [])
        XCTAssertEqual(recording.writeCount, 0)
        XCTAssertEqual(ports.userDefaults.writeCount, 0)
        XCTAssertEqual(requestCount(path: "/users/me/learning-dashboard"), 1, "対照: GET は届いている")
        XCTAssertNil(store.streak, "dashboard() は streak を変えない")
        XCTAssertFalse(store.streakLoadFailed)
    }

    // CI-10（T-Q2）: 失敗は `ApiFailure` のまま投げ、状態を変えない。
    func testDashboardFailureThrowsApiFailureAndLeavesStreakStateUntouched() async throws {
        serveStreak(days: 2)
        await store.refreshStreak()
        serveDashboard(fullDashboardObject())
        _ = try await store.dashboard()
        scripted.configure(method: "GET", path: "/users/me/learning-dashboard", status: 500, body: json([String: String]()))

        do {
            _ = try await store.dashboard()
            XCTFail("500 は投げる")
        } catch {
            XCTAssertEqual(error as? ApiFailure, .server(status: 500))
        }

        XCTAssertEqual(store.streak?.days, 2)
        XCTAssertFalse(store.streakLoadFailed)
    }

    // CI-8（T-Q3）: streak・streakLoadFailed を読むだけでは書かない（同期の読み・await の後・購読の発火の後）。
    func testReadingStreakStateWritesNothingEvenAfterAwaitAndPublish() async {
        serveStreak(days: 3)
        var fired = 0
        var observed: [Int?] = []
        let subscription = store.$streak.sink { value in
            fired += 1
            observed.append(value?.days)
        }
        defer { subscription.cancel() }

        _ = store.streak
        _ = store.streakLoadFailed
        XCTAssertEqual(recording.writeCount + ports.userDefaults.writeCount, 0)

        await store.refreshStreak()
        _ = store.streak
        _ = store.streakLoadFailed
        await Task.yield()

        XCTAssertEqual(recording.writeCount, 0)
        XCTAssertEqual(ports.userDefaults.writeCount, 0)
        XCTAssertEqual(store.streak?.days, 3, "正方向の対照: 読みは実際に値を返している")
        XCTAssertEqual(requestCount(path: "/users/me/listening-streak"), 1, "対照: GET が届いている")
        XCTAssertGreaterThanOrEqual(fired, 2, "対照: $streak が発火している")
        XCTAssertEqual(observed.last ?? nil, 3)
    }

    // CI-11（T-Q4。ios-test-112）: 呼出ごとに取得し、戻り値を書き換えても次の結果は変わらない。
    func testDashboardFetchesFreshEachCallAndCallerMutationDoesNotLeak() async throws {
        serveDashboard(fullDashboardObject(totalEpisodes: 12))
        var held = try await store.dashboard()
        XCTAssertEqual(held.completedCount, 12)

        held = summaryWithAchievements(["streak_7"])
        serveDashboard(fullDashboardObject(totalEpisodes: 20))
        let second = try await store.dashboard()

        XCTAssertEqual(second.completedCount, 20, "2 回目は新しい応答の値")
        XCTAssertEqual(held.completedCount, 0, "対照: 呼出元が書き換えた値は呼出元のもの")
        XCTAssertEqual(requestCount(path: "/users/me/learning-dashboard"), 2)
    }

    // CI-12（T-Q6）: 未表示を読んでも書かない。対照: 既読の記録は書く。
    func testUnseenAchievementsWritesNothingButMarkingWritesOnce() {
        let dashboard = summaryWithAchievements(["a", "b"])

        let first = store.unseenAchievements(in: dashboard)
        let second = store.unseenAchievements(in: dashboard)

        XCTAssertEqual(first.map(\.id), ["a", "b"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(ports.userDefaults.writeCount, 0)

        store.markAchievementsSeen(["a"])

        XCTAssertEqual(ports.userDefaults.writeCount, 1, "対照: 記録は書く")
    }
}
