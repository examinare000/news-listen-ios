import XCTest
@testable import NewsListenApp

final class LearningEngagementModelTests: XCTestCase {
    func testLearningDashboardDecodesEngagementFields() throws {
        let dashboard = try JSONDecoder().decode(
            LearningDashboard.self,
            from: Data(
                """
                {
                  "streak": {
                    "current_streak_days": 4,
                    "today_listened": true,
                    "last_listened_day": "2026-07-29"
                  },
                  "total_episodes": 12,
                  "vocabulary_acquired": 31,
                  "quiz": {
                    "quizzed_episodes": 2,
                    "average_correct_rate": 0.75,
                    "trend": [
                      {"graded_at": "2026-07-28T12:00:00Z", "correct_rate": 0.75}
                    ]
                  },
                  "monthly_activity": [{"month": "2026-07", "active_days": 8}],
                  "current_difficulty": "toeic_900",
                  "weekly_goal": {
                    "goal_episodes": 5,
                    "week": "2026-W31",
                    "completed_this_week": 3,
                    "history": [{"week": "2026-W30", "goal": 5, "completed": 4}]
                  },
                  "achievements": [
                    {"id": "first_episode_completed", "unlocked_at": "2026-07-29"}
                  ]
                }
                """.utf8
            )
        )

        XCTAssertEqual(dashboard.weeklyGoal?.goalEpisodes, 5)
        XCTAssertEqual(dashboard.weeklyGoal?.completedThisWeek, 3)
        XCTAssertEqual(dashboard.weeklyGoal?.history.first?.completed, 4)
        XCTAssertEqual(dashboard.achievements?.first?.id, "first_episode_completed")
        XCTAssertEqual(dashboard.quiz.averageCorrectRate, 0.75)
    }

    func testLearningDashboardDecodesOldServerResponseWithoutEngagementFields() throws {
        let dashboard = try JSONDecoder().decode(
            LearningDashboard.self,
            from: Data(
                """
                {
                  "streak": {
                    "current_streak_days": 0,
                    "today_listened": false,
                    "last_listened_day": null
                  },
                  "total_episodes": 0,
                  "vocabulary_acquired": 0,
                  "quiz": {
                    "quizzed_episodes": 0,
                    "average_correct_rate": null,
                    "trend": []
                  },
                  "monthly_activity": [],
                  "current_difficulty": "toeic_600"
                }
                """.utf8
            )
        )

        XCTAssertNil(dashboard.weeklyGoal)
        XCTAssertNil(dashboard.achievements)
    }

    func testVocabularyContractsDecodeBackendSchemaFields() throws {
        let list = try JSONDecoder().decode(
            VocabularyListResponse.self,
            from: Data(
                """
                {
                  "vocabulary": [{
                    "vocabulary_id": "pod-1__resilient",
                    "podcast_id": "pod-1",
                    "term": "resilient",
                    "meaning": "回復力のある",
                    "example": "The system is resilient.",
                    "registered_at": "2026-07-29T03:00:00+00:00"
                  }],
                  "count": 1
                }
                """.utf8
            )
        )
        let session = try JSONDecoder().decode(
            VocabularyTestSessionResponse.self,
            from: Data(
                """
                {
                  "items": [{
                    "vocabulary_id": "pod-1__resilient",
                    "term": "resilient",
                    "meaning": "回復力のある",
                    "example": "The system is resilient.",
                    "distractors": ["壊れやすい", "短期的な", "不透明な"]
                  }]
                }
                """.utf8
            )
        )
        let deleted = try JSONDecoder().decode(
            DeleteVocabularyResponse.self,
            from: Data(#"{"status":"deleted","vocabulary_id":"pod-1__resilient"}"#.utf8)
        )
        let result = try JSONDecoder().decode(
            VocabularyTestResultResponse.self,
            from: Data(#"{"updated":1}"#.utf8)
        )

        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.vocabulary.first?.meaning, "回復力のある")
        XCTAssertEqual(session.items.first?.distractors.count, 3)
        XCTAssertEqual(deleted.vocabularyId, "pod-1__resilient")
        XCTAssertEqual(result.updated, 1)
    }

    func testPreferencesDecodesWeeklyGoalAndRemainsCompatibleWhenMissing() throws {
        let current = try JSONDecoder().decode(
            Preferences.self,
            from: Data(
                #"{"default_difficulty":"toeic_900","default_playback_speed":1.25,"weekly_goal_episodes":7}"#.utf8
            )
        )
        let old = try JSONDecoder().decode(
            Preferences.self,
            from: Data(#"{"default_difficulty":"toeic_600","default_playback_speed":1.0}"#.utf8)
        )

        XCTAssertEqual(current.weeklyGoalEpisodes, 7)
        XCTAssertNil(old.weeklyGoalEpisodes)
    }

    func testWeeklyGoalPresentationShowsFactsAndClampsProgress() {
        let goal = WeeklyGoal(
            goalEpisodes: 5,
            week: "2026-W31",
            completedThisWeek: 7,
            history: []
        )

        XCTAssertEqual(goal.progressText, "今週 7/目標 5 本")
        XCTAssertEqual(goal.toProgress().fraction, 1)
    }

    func testAchievementCatalogMatchesWebLabelsExactly() {
        XCTAssertEqual(
            AchievementCatalog.all,
            [
                .init(
                    id: "first_episode_completed",
                    name: "初回エピソード完聴",
                    description: "はじめてエピソードを最後まで聴く"
                ),
                .init(
                    id: "first_quiz_correct",
                    name: "初回クイズ正解",
                    description: "はじめて理解度クイズに正解する"
                ),
                .init(id: "streak_7", name: "7 日連続聴取", description: "7 日間連続で聴く"),
                .init(id: "streak_30", name: "30 日連続聴取", description: "30 日間連続で聴く"),
                .init(id: "streak_100", name: "100 日連続聴取", description: "100 日間連続で聴く"),
                .init(
                    id: "completed_10",
                    name: "累計 10 本完聴",
                    description: "エピソードを累計 10 本聴き終える"
                ),
                .init(
                    id: "completed_50",
                    name: "累計 50 本完聴",
                    description: "エピソードを累計 50 本聴き終える"
                ),
            ]
        )
    }

    func testAchievementKeepsWireKeysOnDecodeAndEncode() throws {
        let decoded = try JSONDecoder().decode(
            Achievement.self,
            from: Data(#"{"id":"streak_7","unlocked_at":"2026-07-29"}"#.utf8)
        )
        XCTAssertEqual(decoded, Achievement(id: "streak_7", unlockedAt: "2026-07-29"))

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        XCTAssertEqual(object, ["id": "streak_7", "unlocked_at": "2026-07-29"])

        XCTAssertThrowsError(
            try JSONDecoder().decode(Achievement.self, from: Data(#"{"id":"streak_7"}"#.utf8))
        )
    }

    func testAdaptersMapWireModelsToDomainValues() {
        XCTAssertEqual(
            ListeningStreak(currentStreakDays: 4, todayListened: true, lastListenedDay: "2026-07-29").toStatus(),
            ListeningStreakStatus(days: 4, listenedToday: true, lastListenedDay: "2026-07-29")
        )
        XCTAssertEqual(
            ListeningStreak(currentStreakDays: 1, todayListened: false, lastListenedDay: nil).toStatus(),
            ListeningStreakStatus(days: 1, listenedToday: false, lastListenedDay: nil)
        )
        XCTAssertEqual(
            WeeklyGoal(goalEpisodes: 5, week: "2026-W31", completedThisWeek: 3, history: []).toProgress(),
            WeeklyProgress(completed: 3, goal: 5)
        )
        XCTAssertEqual(
            WeeklyGoalRecord(week: "2026-W30", goal: 7, completed: 2).toProgress(),
            WeeklyProgress(completed: 2, goal: 7)
        )
        XCTAssertEqual(
            VocabularyTestItem(
                vocabularyId: "vocab-1",
                term: "resilient",
                meaning: "回復力のある",
                example: "The system is resilient.",
                distractors: ["壊れやすい"]
            ).toWord(),
            VocabularyTestWord(
                id: "vocab-1",
                term: "resilient",
                meaning: "回復力のある",
                example: "The system is resilient.",
                distractors: ["壊れやすい"]
            )
        )

        var test = VocabularyTest()
        test.start(items: ["a", "b", "c"].map {
            VocabularyTestWord(id: $0, term: "t\($0)", meaning: "M\($0)", example: "e", distractors: ["x", "y", "z"])
        })
        _ = test.recordSelfAssessment(known: true)
        _ = test.recordSelfAssessment(known: false)
        _ = test.recordSelfAssessment(known: false)
        _ = test.recordRetestChoice("Mb")
        _ = test.finishRetestFeedback()
        _ = test.recordRetestChoice("x")
        _ = test.finishRetestFeedback()
        XCTAssertEqual(
            test.resultPayload,
            [
                VocabularyTestResultItem(vocabularyId: "a", selfKnown: true, retestCorrect: nil),
                VocabularyTestResultItem(vocabularyId: "b", selfKnown: false, retestCorrect: true),
                VocabularyTestResultItem(vocabularyId: "c", selfKnown: false, retestCorrect: false),
            ]
        )
    }
}
