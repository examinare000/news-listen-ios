// verifies: ios-query-playback-07, ios-query-playback-08, ios-query-playback-09
import XCTest
import Combine
@testable import NewsListenApp

/// 再開位置の query（`PositionRecords.candidate(for:)`・`otherDevicePosition(for:)`、`PlaybackCoordinator.resumeChoice`）が、
/// 書込 port に書かず、gateway へ送らず、engine とロック画面の状態を変えないことの契約テスト（ios-check-09）。
/// 同期の読みの直後・`await Task.yield()` の後・`objectWillChange` の購読が発火した後のそれぞれで確かめる。
@MainActor
final class ResumeQueryContractTests: XCTestCase {

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

    // kills: candidate・otherDevicePosition・resumeChoice の読みが、保存する・送信する・再生状態を動かす・変更通知を出す
    func testResumeQueriesDoNotWriteTheStoreOrSendAnythingEvenAfterYield() async throws {
        // 組み立て: rig の store は固定なので使わず、書込と送信を数える double を直接組む。
        let backing = InMemoryPositionStore()
        let recording = RecordingPositionStore(delegate: backing.store)
        let records = PositionRecords(store: recording.store)
        records.bind(subject: subjectA)
        let engine = AudioEngineDouble()
        let spy = NowPlayingCenterSpy()
        let library = OfflineLibrary(store: .live(cacheManager: AudioCacheManager(fileManager: AudioCacheManagerTests.MockFileManager())))
        library.bind(subject: subjectA)
        let gateway = RecordingPlaybackGateway(response: { EntryFixture.playable($0) })
        let reporter = PositionReporter(
            updatePosition: gateway.updatePosition,
            markCompleted: gateway.markCompleted,
            onPositionSaved: { _ in },
            onCompletionRecorded: {},
            beginBackgroundTask: { {} },
            records: records,
            connectivity: makeSilentConnectivity())
        let coordinator = PlaybackCoordinator(
            engine: engine,
            nowPlayingCenter: spy,
            library: library,
            reporter: reporter,
            positionRecords: records,
            fetchEpisode: gateway.fetchEpisode,
            isOnline: { true },
            defaultSpeed: { 1.0 },
            lockScreenSubtitle: { "sub:\($0)" },
            beginBackgroundTask: { {} })

        // Given: 開始して ready → 再生 → 一時停止（記録）→ 新しい値（差 ≥ 15 秒）を取り込む → 確認を出す。
        try library.save(Data([1, 2, 3]), for: "e", subject: subjectA)
        let server = EntryFixture.playableValue("e", serverPosition: 30, serverRecordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        await coordinator.startEpisode(.playable(server))
        await engine.send(.ready)
        await engine.send(.timeUpdate(seconds: 100, duration: 300))
        coordinator.togglePlayPause()
        let otherDeviceAt = Date().addingTimeInterval(3600)
        records.absorb([EntryFixture.playable("e", serverPosition: 200, serverRecordedAt: otherDeviceAt)])
        coordinator.toggleFromScreen()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(records.otherDevicePosition(for: "e"), 200, "Given: 別の端末から取り込んだ印がある")
        XCTAssertEqual(
            coordinator.resumeChoice,
            ResumeChoice(episodeId: "e", thisDeviceSeconds: 100, otherDeviceSeconds: 200),
            "Given: 確認が出ている")
        recording.resetCounts()
        gateway.resetCounts()
        let before = observation(engine, spy)

        func assertUntouched(_ moment: String, line: UInt = #line) {
            XCTAssertEqual(recording.writeCount, 0, "\(moment): store の書込が 0", line: line)
            XCTAssertEqual(gateway.writeCount, 0, "\(moment): gateway の送信が 0", line: line)
            XCTAssertEqual(observation(engine, spy), before, "\(moment): engine とロック画面の状態が不変", line: line)
        }

        // (1) 同期の読みの直後
        XCTAssertEqual(records.candidate(for: server), 200, "候補は新しい方（端末の記録）")
        XCTAssertEqual(records.otherDevicePosition(for: "e"), 200)
        XCTAssertNotNil(coordinator.resumeChoice)
        assertUntouched("同期の読みの直後")

        // (2) await Task.yield() の後
        await Task.yield()
        assertUntouched("yield の後")

        // (3) objectWillChange の購読が発火した後
        var fired = 0
        let cancellable = coordinator.objectWillChange.sink { fired += 1 }
        _ = records.candidate(for: server)
        _ = records.otherDevicePosition(for: "e")
        _ = coordinator.resumeChoice
        await Task.yield()
        assertUntouched("購読の後")
        XCTAssertEqual(fired, 0, "読みは変更通知を出さない")
        cancellable.cancel()

        // 対照: absorb は store に書く。
        records.absorb([EntryFixture.playable("e", serverPosition: 250, serverRecordedAt: otherDeviceAt.addingTimeInterval(1))])
        XCTAssertEqual(recording.writeCount, 1)
    }
}
