import XCTest
@testable import NewsListenApp

@MainActor
final class LearningEngagementAPIClientTests: XCTestCase {
    func testFetchLearningDashboardUsesGetEndpoint() async throws {
        let mock = MockURLSession(data: oldDashboardJSON, statusCode: 200)
        let client = makeClient(mock)

        _ = try await client.fetchLearningDashboard()

        XCTAssertEqual(mock.lastRequest?.url?.path, "/users/me/learning-dashboard")
        XCTAssertEqual(mock.lastRequest?.httpMethod, "GET")
    }

    func testSaveAndListVocabularyFollowBackendContract() async throws {
        let savedJSON = Data(
            """
            {
              "vocabulary_id":"pod-1__term",
              "podcast_id":"pod-1",
              "term":"Term",
              "meaning":"意味",
              "example":"Example.",
              "registered_at":"2026-07-29T00:00:00Z"
            }
            """.utf8
        )
        let saveMock = MockURLSession(data: savedJSON, statusCode: 200)

        _ = try await makeClient(saveMock).saveVocabulary(podcastId: "pod-1", term: "Term")

        XCTAssertEqual(saveMock.lastRequest?.url?.path, "/vocabulary")
        XCTAssertEqual(saveMock.lastRequest?.httpMethod, "POST")
        let body = try XCTUnwrap(saveMock.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["podcast_id": "pod-1", "term": "Term"])

        let listMock = MockURLSession(
            data: Data(#"{"vocabulary":[],"count":0}"#.utf8),
            statusCode: 200
        )
        _ = try await makeClient(listMock).fetchVocabulary()
        XCTAssertEqual(listMock.lastRequest?.url?.path, "/vocabulary")
        XCTAssertEqual(listMock.lastRequest?.httpMethod, "GET")
    }

    func testDeleteVocabularyUsesDeleteWithIdentifier() async throws {
        let mock = MockURLSession(
            data: Data(#"{"status":"deleted","vocabulary_id":"pod-1__term"}"#.utf8),
            statusCode: 200
        )

        _ = try await makeClient(mock).deleteVocabulary(id: "pod-1__term")

        XCTAssertEqual(mock.lastRequest?.url?.path, "/vocabulary/pod-1__term")
        XCTAssertEqual(mock.lastRequest?.httpMethod, "DELETE")
    }

    func testTestSessionAndResultUseDedicatedEndpointsAndArrayBody() async throws {
        let sessionMock = MockURLSession(data: Data(#"{"items":[]}"#.utf8), statusCode: 200)
        _ = try await makeClient(sessionMock).fetchVocabularyTestSession()
        XCTAssertEqual(sessionMock.lastRequest?.url?.path, "/vocabulary/test-session")
        XCTAssertEqual(sessionMock.lastRequest?.httpMethod, "GET")

        let resultMock = MockURLSession(data: Data(#"{"updated":1}"#.utf8), statusCode: 200)
        _ = try await makeClient(resultMock).submitVocabularyTestResult([
            VocabularyTestResultItem(
                vocabularyId: "pod-1__term",
                selfKnown: true,
                retestCorrect: nil
            ),
        ])

        XCTAssertEqual(resultMock.lastRequest?.url?.path, "/vocabulary/test-result")
        XCTAssertEqual(resultMock.lastRequest?.httpMethod, "POST")
        let data = try XCTUnwrap(resultMock.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 1)
        XCTAssertEqual(json[0]["vocabulary_id"] as? String, "pod-1__term")
        XCTAssertEqual(json[0]["self_known"] as? Bool, true)
        XCTAssertTrue(json[0]["retest_correct"] is NSNull)
    }

    func testUpdatePreferencesSendsWeeklyGoal() async throws {
        let mock = MockURLSession(
            data: Data(
                #"{"default_difficulty":"toeic_600","default_playback_speed":1.0,"weekly_goal_episodes":10}"#.utf8
            ),
            statusCode: 200
        )

        let preferences = try await makeClient(mock).updatePreferences(
            defaultDifficulty: nil,
            defaultPlaybackSpeed: nil,
            weeklyGoalEpisodes: 10
        )

        let data = try XCTUnwrap(mock.lastRequest?.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["weekly_goal_episodes"] as? Int, 10)
        XCTAssertEqual(preferences.weeklyGoalEpisodes, 10)
    }

    private func makeClient(_ session: MockURLSession) -> APIClient {
        APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
    }

    private var oldDashboardJSON: Data {
        Data(
            """
            {
              "streak":{"current_streak_days":0,"today_listened":false,"last_listened_day":null},
              "total_episodes":0,
              "vocabulary_acquired":0,
              "quiz":{"quizzed_episodes":0,"average_correct_rate":null,"trend":[]},
              "monthly_activity":[],
              "current_difficulty":"toeic_600"
            }
            """.utf8
        )
    }
}
