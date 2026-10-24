// verifies: ios-query-playback-01, ios-query-playback-02, ios-query-playback-03, ios-query-playback-04, ios-query-playback-05
import XCTest
import Combine
@testable import NewsListenApp

/// 再生の query（`nowPlaying()`・`upNext()`・公開する状態 5 つ・`OfflineLibrary.savedIds`・`OfflineLibrary.usage()`・
/// `PositionReporter.lastSyncFailure`）が、書込み port に書かず、engine とロック画面の状態を変えないことの契約テスト（ios-check-09）。
///
/// Coordinator を再生中（`playing`）まで進めてから記録 double の数を戻し、同期の読みの直後・`await Task.yield()` の後・
/// `objectWillChange` の購読が発火した後のそれぞれで確かめる。
/// 呼出回数は公開せず、engine は `AudioEngineDouble` の状態、ロック画面は `NowPlayingCenterSpy` の状態で見る（ios-dec-07）。
@MainActor
final class PlaybackQueryContractTests: XCTestCase {

    private struct Observation: Equatable {
        let loadedURL: URL?
        let hasStartedPlayback: Bool
        let rate: Float
        let lastSeekSeconds: Double?
        let currentInfo: NowPlayingSnapshot?
        let lastElapsedElapsed: Double?
        let lastElapsedDuration: Double?
    }

    private var engine: AudioEngineDouble!
    private var spy: NowPlayingCenterSpy!
    private var files: RecordingFileManager!
    private var gateway: RecordingPlaybackGateway!
    private var library: OfflineLibrary!
    private var downloads: OfflineDownloads!
    private var downloadCalls: ClosureCallCounter!
    private var reporter: PositionReporter!
    private var coordinator: PlaybackCoordinator!
    private var cancellables: Set<AnyCancellable> = []

    /// `OfflineDownloads` に渡す取り直し・取得の closure の呼出を数える（closure は非 isolated なのでロックで守る）。
    private final class ClosureCallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var fetches = 0
        private var downloads = 0
        var fetchCount: Int { lock.withLock { fetches } }
        var downloadCount: Int { lock.withLock { downloads } }
        func recordFetch() { lock.withLock { fetches += 1 } }
        func recordDownload() { lock.withLock { downloads += 1 } }
        func reset() { lock.withLock { fetches = 0; downloads = 0 } }
    }

    private func episode(_ id: String) throws -> Episode {
        let content = EpisodeContent(
            id: id, title: "題 \(id)", japaneseIntroText: "導入", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
        return .playable(try XCTUnwrap(PlayableEpisode(content: content, audioUrl: "https://cdn.example.com/\(id).mp3", serverPosition: 0)))
    }

    override func setUp() async throws {
        try await super.setUp()
        let engine = AudioEngineDouble()
        let spy = NowPlayingCenterSpy()
        let files = RecordingFileManager(delegate: AudioCacheManagerTests.MockFileManager())
        let library = OfflineLibrary(store: .live(cacheManager: AudioCacheManager(fileManager: files)))
        let a = try episode("a")
        let b = try episode("b")
        let c = try episode("c")
        let gateway = RecordingPlaybackGateway(response: { id in
            // 取り直しの応答は使われない（キャッシュ済みで始める）。同じ内容を返す。
            id == "a" ? a : b
        })
        let downloadCalls = ClosureCallCounter()
        let downloads = OfflineDownloads(
            library: library,
            fetchEpisode: { _ in downloadCalls.recordFetch(); return c },
            downloadAudio: { _ in downloadCalls.recordDownload(); return Data([4, 5, 6]) }
        )
        XCTAssertEqual(files.writeCount, 0, "Given: OfflineDownloads を組んだだけでは保存庫に書かない")
        XCTAssertEqual(downloadCalls.fetchCount + downloadCalls.downloadCount, 0, "Given: 組んだだけでは closure を呼ばない")
        let reporter = PositionReporter(
            updatePosition: gateway.updatePosition,
            markCompleted: gateway.markCompleted,
            onPositionSaved: { _ in },
            onCompletionRecorded: {},
            beginBackgroundTask: { return {} }
        )
        let coordinator = PlaybackCoordinator(
            engine: engine,
            nowPlayingCenter: spy,
            library: library,
            reporter: reporter,
            fetchEpisode: gateway.fetchEpisode,
            isOnline: { true },
            defaultSpeed: { 1.0 },
            lockScreenSubtitle: { "sub:\($0)" },
            beginBackgroundTask: { return {} }
        )
        self.engine = engine
        self.spy = spy
        self.files = files
        self.gateway = gateway
        self.library = library
        self.downloads = downloads
        self.downloadCalls = downloadCalls
        self.reporter = reporter
        self.coordinator = coordinator

        try library.save(Data([1, 2, 3]), for: "a")
        await coordinator.startEpisode(a)
        await engine.send(.ready)
        await engine.send(.timeUpdate(seconds: 12, duration: 300))
        await coordinator.addToQueue(b)
        XCTAssertEqual(coordinator.session.episodeId, "a", "Given: 再生中（playing）まで進めた")
        let receipt: DownloadReceipt = try await downloads.download(episodeId: "c")
        XCTAssertEqual(receipt, .saved, "Given: c を保存済みにした（state(for:) の downloaded の読みを含める）")
        gateway.resetCounts()
        files.resetCounts()
        downloadCalls.reset()
    }

    override func tearDown() async throws {
        cancellables.removeAll()
        coordinator = nil
        reporter = nil
        library = nil
        downloads = nil
        downloadCalls = nil
        gateway = nil
        files = nil
        spy = nil
        engine = nil
        try await super.tearDown()
    }

    private func observation() -> Observation {
        Observation(
            loadedURL: engine.loadedURL,
            hasStartedPlayback: engine.hasStartedPlayback,
            rate: engine.rate,
            lastSeekSeconds: engine.lastSeekSeconds,
            currentInfo: spy.currentInfo,
            lastElapsedElapsed: spy.lastElapsedUpdate?.elapsed,
            lastElapsedDuration: spy.lastElapsedUpdate?.duration
        )
    }

    private func readAllQueries() {
        _ = coordinator.nowPlaying()
        _ = coordinator.upNext()
        _ = coordinator.session
        _ = coordinator.presentation
        _ = coordinator.queue
        _ = coordinator.notice
        _ = coordinator.isAdvancing
        _ = library.savedIds
        _ = library.usage()
        _ = reporter.lastSyncFailure
        _ = downloads.state(for: "a")
        _ = downloads.state(for: "c")
        _ = downloads.downloadingIds
    }

    private func assertNoWritesAndUnchanged(
        since before: Observation, file: StaticString = #filePath, line: UInt = #line
    ) {
        let gateway: RecordingPlaybackGateway = self.gateway
        let files: RecordingFileManager = self.files
        let downloadCalls: ClosureCallCounter = self.downloadCalls
        XCTAssertEqual(gateway.writeCount, 0, "gateway の書込み（位置・完聴）が 0", file: file, line: line)
        XCTAssertEqual(files.writeCount, 0, "保存庫の書込みが 0", file: file, line: line)
        XCTAssertEqual(downloadCalls.fetchCount, 0, "OfflineDownloads の取り直しの呼出が 0", file: file, line: line)
        XCTAssertEqual(downloadCalls.downloadCount, 0, "OfflineDownloads の取得の呼出が 0", file: file, line: line)
        XCTAssertEqual(observation(), before, "engine とロック画面の状態が不変", file: file, line: line)
    }

    // (1) 同期の読みの直後
    func testQueriesWriteNothingAndLeaveEngineAndLockScreenUntouchedAfterSynchronousReads() {
        let before = observation()
        XCTAssertNotNil(before.currentInfo, "Given: ロック画面に表示がある")

        readAllQueries()

        assertNoWritesAndUnchanged(since: before)
    }

    // (2) await Task.yield() の後
    func testQueriesWriteNothingAndLeaveEngineAndLockScreenUntouchedAfterAwait() async {
        let before = observation()

        readAllQueries()
        await Task.yield()

        assertNoWritesAndUnchanged(since: before)
    }

    // (3) objectWillChange の購読が発火した後
    func testQueriesWriteNothingAndLeaveEngineAndLockScreenUntouchedWhenObjectWillChangeSubscriptionsFire() async {
        var fired = 0
        coordinator.objectWillChange
            .sink { [unowned self] _ in
                fired += 1
                self.readAllQueries()
            }
            .store(in: &cancellables)
        library.objectWillChange
            .sink { [unowned self] _ in self.readAllQueries() }
            .store(in: &cancellables)
        reporter.objectWillChange
            .sink { [unowned self] _ in self.readAllQueries() }
            .store(in: &cancellables)
        downloads.objectWillChange
            .sink { [unowned self] _ in self.readAllQueries() }
            .store(in: &cancellables)
        let before = observation()

        coordinator.minimizePlayer()  // @Published の presentation が変わり、購読が発火する（gateway・engine・ロック画面には触れない）
        await Task.yield()

        XCTAssertGreaterThanOrEqual(fired, 1, "正の対照: 購読が発火した")
        assertNoWritesAndUnchanged(since: before)
    }
}
