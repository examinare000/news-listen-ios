import XCTest
@testable import NewsListenApp

/// `Podcast/Playback/Domain/` の純関数（`PlaybackRules`）と `PlaybackState` の派生値を検証する。
///
/// domain の型だけを使い、application の型・FileManager・URLSession・UserDefaults には触れない
/// （ios-check-08 の domain だけを参照するテストファイルの集合に入る）。
final class PlaybackRulesTests: XCTestCase {

    private func episode(durationSeconds: Int = 600) throws -> PlayableEpisode {
        let content = EpisodeContent(
            id: "ep-1", title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: durationSeconds,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
        return try XCTUnwrap(PlayableEpisode(content: content, audioUrl: "https://example.com/a.mp3", serverPosition: 0))
    }

    // MARK: - resolveResumePosition（shared-resume-01〜07）

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-01
    func testSharedResume01_unplayedStartsFromTheBeginning() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 0, durationSeconds: 600), 0)
    }

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-02
    func testSharedResume02_resumesFromTheServerPosition() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 120, durationSeconds: 600), 120)
    }

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-03
    func testSharedResume03_positionEqualToDurationMinusTwoCountsAsCompleted() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 598, durationSeconds: 600), 0)
    }

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-04
    func testSharedResume04_positionOutsideTheTailWindowResumes() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 597.5, durationSeconds: 600), 597.5)
    }

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-05
    func testSharedResume05_positionAtOrBeyondDurationCountsAsCompleted() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 600, durationSeconds: 600), 0)
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 700, durationSeconds: 600), 0)
    }

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-06
    func testSharedResume06_unknownDurationSkipsTheWindowCheck() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: 120, durationSeconds: 0), 120)
    }

    // verifies: ios-contract-08（ios-test-079）
    // MARK: shared-resume-07
    func testSharedResume07_negativePositionStartsFromTheBeginning() {
        XCTAssertEqual(PlaybackRules.resolveResumePosition(serverSeconds: -5, durationSeconds: 600), 0)
    }

    // MARK: - clampPosition

    // verifies: ios-contract-05（ios-test-075 の式。ios-rule-playback-05）
    func testClampPositionKeepsTheRangeWhenDurationIsKnown() {
        let cases: [(seconds: Double, duration: Double, expected: Double)] = [
            (-3, 100, 0),
            (0, 100, 0),
            (40, 100, 40),
            (100, 100, 100),
            (130, 100, 100),
        ]
        for c in cases {
            XCTAssertEqual(PlaybackRules.clampPosition(c.seconds, duration: c.duration), c.expected, "\(c)")
        }
    }

    // verifies: ios-contract-05（ios-test-075 の式。ios-rule-playback-05）
    func testClampPositionOnlyFloorsAtZeroWhenDurationIsUnknown() {
        XCTAssertEqual(PlaybackRules.clampPosition(-3, duration: 0), 0)
        XCTAssertEqual(PlaybackRules.clampPosition(5_000, duration: 0), 5_000, "総時間が 0 の間は上限で丸めない")
    }

    // MARK: - resolvePlaybackSource

    // verifies: ios-contract-10（ios-test-081 の式。ios-rule-playback-03）
    func testResolvePlaybackSourceCoversAllFourCombinations() {
        let cases: [(hasCached: Bool, isOnline: Bool, expected: PlaybackSource)] = [
            (true, true, .cached),
            (true, false, .cached),
            (false, true, .network),
            (false, false, .unavailable),
        ]
        for c in cases {
            XCTAssertEqual(PlaybackRules.resolvePlaybackSource(hasCached: c.hasCached, isOnline: c.isOnline), c.expected, "\(c)")
        }
    }

    // MARK: - isLoaded と派生値

    // verifies: ios-contract-01（ios-deriv-04）
    func testIsLoadedIsTrueOnlyForLoadingPlayingBufferingAndPaused() throws {
        let e = try episode()
        let cases: [(PlaybackState, Bool)] = [
            (.idle, false),
            (.loading(episode: e, resumePosition: 0, speed: 1), true),
            (.playing(episode: e, position: 1, duration: 600, speed: 1), true),
            (.buffering(episode: e, position: 1, duration: 600, speed: 1), true),
            (.paused(episode: e, position: 1, duration: 600, speed: 1), true),
            (.ended(episode: e, duration: 600), false),
            (.errored(episodeId: "ep-1", position: 0, reason: .offlineUncached), false),
        ]
        for (state, expected) in cases {
            XCTAssertEqual(PlaybackRules.isLoaded(state), expected, "\(state)")
        }
    }

    // verifies: ios-contract-01・ios-contract-05（派生値。各テストの状態の観測で使う）
    func testDerivedValuesFollowTheStateTable() throws {
        let e = try episode(durationSeconds: 321)
        XCTAssertNil(PlaybackState.idle.episodeId)
        XCTAssertEqual(PlaybackState.idle.position, 0)
        XCTAssertEqual(PlaybackState.idle.duration, 0)
        XCTAssertNil(PlaybackState.idle.speed)
        XCTAssertFalse(PlaybackState.idle.isEnded)

        let loading = PlaybackState.loading(episode: e, resumePosition: 12, speed: 1.5)
        XCTAssertEqual(loading.episodeId, "ep-1")
        XCTAssertEqual(loading.position, 12, "loading の位置は resumePosition")
        XCTAssertEqual(loading.duration, 321, "loading の総時間は content.durationSeconds")
        XCTAssertEqual(loading.speed, 1.5)

        let playing = PlaybackState.playing(episode: e, position: 30, duration: 400, speed: 2)
        XCTAssertEqual(playing.position, 30)
        XCTAssertEqual(playing.duration, 400)
        XCTAssertEqual(playing.speed, 2)

        let ended = PlaybackState.ended(episode: e, duration: 400)
        XCTAssertEqual(ended.episodeId, "ep-1")
        XCTAssertEqual(ended.position, 400, "ended の位置は duration")
        XCTAssertNil(ended.speed)
        XCTAssertTrue(ended.isEnded)

        let errored = PlaybackState.errored(episodeId: "ep-9", position: 7, reason: .invalidSource)
        XCTAssertEqual(errored.episodeId, "ep-9")
        XCTAssertEqual(errored.position, 7)
        XCTAssertEqual(errored.duration, 0)
        XCTAssertNil(errored.speed)
        XCTAssertFalse(errored.isEnded)
    }
}
