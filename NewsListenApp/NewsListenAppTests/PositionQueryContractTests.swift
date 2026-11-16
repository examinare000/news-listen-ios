// verifies: ios-query-playback-06
import XCTest
import Combine
@testable import NewsListenApp

/// 位置の記録の query（`PositionRecords.unsent()`）が、書込 port に書かず、gateway へ送らず、engine とロック画面の状態を
/// 変えないことの契約テスト（ios-check-09）。同期の読みの直後・`await Task.yield()` の後・`objectWillChange` の購読が
/// 発火した後のそれぞれで確かめる。
@MainActor
final class PositionQueryContractTests: XCTestCase {

    private struct Observation: Equatable {
        let loadedURL: URL?
        let hasStartedPlayback: Bool
        let rate: Float
        let lastSeekSeconds: Double?
        let currentInfo: NowPlayingSnapshot?
    }

    private func observation(_ engine: AudioEngineDouble, _ spy: NowPlayingCenterSpy) -> Observation {
        Observation(
            loadedURL: engine.loadedURL, hasStartedPlayback: engine.hasStartedPlayback, rate: engine.rate,
            lastSeekSeconds: engine.lastSeekSeconds, currentInfo: spy.currentInfo)
    }

    // kills: unsent() が読んだついでに保存する・送信する・再生状態を動かす
    func testUnsentReadDoesNotWriteTheStoreOrSendAnythingEvenAfterYield() async throws {
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let backing = InMemoryPositionStore()
        backing.seed(
            [PositionRecord(subject: subjectA, episodeId: "a", seconds: 12, recordedAt: recordedAt, isSent: false)],
            for: subjectA)
        let recording = RecordingPositionStore(delegate: backing.store)
        let records = PositionRecords(store: recording.store)
        records.bind(subject: subjectA)

        let engine = AudioEngineDouble()
        let spy = NowPlayingCenterSpy()
        let gateway = RecordingPlaybackGateway(response: { EntryFixture.playable($0) })
        let session = PlaybackSession(engine: engine)
        let reporter = PositionReporter(
            updatePosition: gateway.updatePosition,
            markCompleted: gateway.markCompleted,
            onPositionSaved: { _ in },
            onCompletionRecorded: {},
            beginBackgroundTask: { {} },
            records: records,
            connectivity: makeSilentConnectivity())
        reporter.attach(session)
        let url = URL(string: "https://cdn.example.com/a.mp3")!
        let playable = try XCTUnwrap(PlayableEpisode(
            content: EntryFixture.content("a"), audioUrl: url.absoluteString, serverPosition: 0))
        session.start(episode: playable, url: url, resumePosition: 0, speed: 1.0)
        await engine.send(.ready)
        recording.resetCounts()
        gateway.resetCounts()
        let before = observation(engine, spy)

        func assertUntouched(_ moment: String, line: UInt = #line) {
            XCTAssertEqual(recording.writeCount, 0, "\(moment): store の書込が 0", line: line)
            XCTAssertEqual(gateway.writeCount, 0, "\(moment): gateway の送信が 0", line: line)
            XCTAssertEqual(observation(engine, spy), before, "\(moment): engine とロック画面の状態が不変", line: line)
        }

        // (1) 同期の読みの直後
        XCTAssertEqual(records.unsent().map(\.episodeId), ["a"], "Given: 未送信を読める")
        assertUntouched("同期の読みの直後")

        // (2) await Task.yield() の後
        await Task.yield()
        assertUntouched("yield の後")

        // (3) objectWillChange の購読が発火した後
        var fired = 0
        let cancellable = reporter.objectWillChange.sink { fired += 1 }
        _ = records.unsent()
        await Task.yield()
        assertUntouched("購読の後")
        XCTAssertEqual(fired, 0, "読みは変更通知を出さない")
        cancellable.cancel()

        // 対照: record は store に書く。
        records.record(episodeId: "b", seconds: 3, at: recordedAt.addingTimeInterval(1))
        XCTAssertEqual(recording.writeCount, 1)
    }
}
