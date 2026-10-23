import XCTest
import os
@testable import NewsListenApp

/// `PositionReporter`（位置の送信と完聴の記録）の契約テスト。
///
/// 時計は注入し、gateway の呼出列を記録する double で観測する。Task の完了は固定時間の sleep ではなく、
/// 記録の到着を待って確かめる。「送らない」は、その後の確定的な送信を区切りに置き、呼出列全体の一致で確かめる。
@MainActor
final class PositionReporterTests: XCTestCase {

    // MARK: - 土台

    private enum Call: Equatable {
        case update(String, Double)
        case mark(String)
        case completionRecorded
        case backgroundBegan
        case backgroundEnded
    }

    private struct SyncError: Error {}

    private final class Gateway: @unchecked Sendable {
        private struct State {
            var calls: [Call] = []
            var saved: [Episode] = []
            var markError: Error?
            var updateError: Error?
            var holdMark = false
            var markReleased = false
            var markWaiter: CheckedContinuation<Void, Never>?
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        var calls: [Call] { lock.withLock { $0.calls } }
        var saved: [Episode] { lock.withLock { $0.saved } }
        var markError: Error? {
            get { lock.withLock { $0.markError } }
            set { lock.withLock { $0.markError = newValue } }
        }
        var updateError: Error? {
            get { lock.withLock { $0.updateError } }
            set { lock.withLock { $0.updateError = newValue } }
        }
        var holdMark: Bool {
            get { lock.withLock { $0.holdMark } }
            set { lock.withLock { $0.holdMark = newValue } }
        }

        private func record(_ call: Call) {
            lock.withLock { $0.calls.append(call) }
        }

        func updatePosition(_ id: String, _ seconds: Double) async throws -> Episode {
            record(.update(id, seconds))
            if let error = lock.withLock({ $0.updateError }) { throw error }
            return Self.response(id: id, seconds: seconds)
        }

        func markCompleted(_ id: String) async throws {
            record(.mark(id))
            if lock.withLock({ $0.holdMark }) {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = lock.withLock { state in
                        if state.markReleased { return true }
                        state.markWaiter = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            if let error = lock.withLock({ $0.markError }) { throw error }
        }

        func releaseMark() {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock { state in
                state.markReleased = true
                let waiter = state.markWaiter
                state.markWaiter = nil
                return waiter
            }
            waiter?.resume()
        }

        func positionSaved(_ episode: Episode) {
            lock.withLock { $0.saved.append(episode) }
        }

        func completionRecorded() async {
            record(.completionRecorded)
        }

        func beginBackgroundTask() -> () -> Void {
            record(.backgroundBegan)
            return { [self] in record(.backgroundEnded) }
        }

        static func response(id: String, seconds: Double) -> Episode {
            let content = EpisodeContent(
                id: id, title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
                createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
                segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
            )
            return .playable(PlayableEpisode(content: content, audioUrl: "https://example.com/a.mp3", serverPosition: seconds)!)
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))
        var now: Date { lock.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    @MainActor
    private struct Rig {
        let engine = AudioEngineDouble()
        let session: PlaybackSession
        let reporter: PositionReporter
        let gateway = Gateway()
        let clock = Clock()
        let url = URL(string: "https://storage.example.com/a.mp3")!

        init() {
            let gateway = self.gateway
            let clock = self.clock
            session = PlaybackSession(engine: engine)
            reporter = PositionReporter(
                updatePosition: { id, seconds in try await gateway.updatePosition(id, seconds) },
                markCompleted: { id in try await gateway.markCompleted(id) },
                onPositionSaved: { gateway.positionSaved($0) },
                onCompletionRecorded: { await gateway.completionRecorded() },
                beginBackgroundTask: { gateway.beginBackgroundTask() },
                now: { clock.now }
            )
            reporter.attach(session)
        }

        func episode(_ id: String, durationSeconds: Int = 300) -> PlayableEpisode {
            let content = EpisodeContent(
                id: id, title: "題 \(id)", japaneseIntroText: "導入", difficulty: "toeic_900",
                createdAt: "2026-05-31T06:00:00Z", durationSeconds: durationSeconds,
                segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
            )
            return PlayableEpisode(content: content, audioUrl: url.absoluteString, serverPosition: 0)!
        }

        /// 開始 → ready（paused → playing）まで進める。
        func startPlaying(_ episode: PlayableEpisode, resume: Double = 0) async {
            session.start(episode: episode, url: url, resumePosition: resume, speed: 1.0)
            await engine.send(.ready)
        }

        func tick(_ position: Double, duration: Double = 300) async {
            await engine.send(.timeUpdate(seconds: position, duration: duration))
        }

        /// 完聴まで進める（ended の状態が総時間を持つ）。
        func finish(_ episode: PlayableEpisode, position: Double = 299, duration: Double = 300) async {
            await startPlaying(episode)
            await tick(position, duration: duration)
            await engine.send(.ended)
        }
    }

    /// 記録が `count` 件以上になるまで待つ（上限 3 秒。固定時間の待ちではない）。
    private func waitForCalls(_ gateway: Gateway, count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while gateway.calls.count < count, Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if gateway.calls.count < count {
            XCTFail("呼出が \(count) 件に達しない: \(gateway.calls)", file: file, line: line)
        }
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    // MARK: - ios-test-092 (a): 周期

    // verifies: ios-contract-13（ios-test-092 (a)）
    // kills: 開始直後に送る／15 秒未満で送る／送信後に起点を戻さない
    func testT092a_periodicSendHappensOncePerFifteenSecondsAndNeverRightAfterStart() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        await rig.startPlaying(a)  // 起点 = 開始直後の now()
        XCTAssertTrue(rig.gateway.calls.isEmpty, "開始直後には送らない")

        rig.clock.advance(14)
        await rig.tick(14)
        rig.clock.advance(1)
        await rig.tick(15)  // 15 秒ちょうどで 1 回
        await waitForCalls(rig.gateway, count: 1)

        rig.clock.advance(10)
        await rig.tick(25)  // 起点から 10 秒なので送らない
        rig.clock.advance(5)
        await rig.tick(30)  // 起点から 15 秒で 2 回目
        await waitForCalls(rig.gateway, count: 2)
        await settle()

        XCTAssertEqual(rig.gateway.calls, [.update("a", 15), .update("a", 30)])
    }

    // verifies: ios-contract-13（ios-test-092 (a)。buffering から戻っても起点を変えない）
    // kills: resumed のたびに起点を now() に戻す
    func testT092a_returningFromBufferingKeepsThePeriodOrigin() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        await rig.startPlaying(a)

        rig.clock.advance(10)
        await rig.engine.send(.buffering)
        rig.clock.advance(4)
        await rig.engine.send(.resumed)
        rig.clock.advance(1)
        await rig.tick(15)  // 開始から 15 秒。起点が resumed で動いていれば送られない

        await waitForCalls(rig.gateway, count: 1)
        XCTAssertEqual(rig.gateway.calls, [.update("a", 15)])
    }

    // verifies: ios-contract-13（ios-test-092 (a)。paused から playing に入ると起点を now() にする）
    // kills: 再開しても古い起点のまま数える
    func testT092a_resumingFromPausedRestartsThePeriodOrigin() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        await rig.startPlaying(a)
        await rig.tick(2)
        rig.session.pause()  // 遷移の送信（位置 2）
        await waitForCalls(rig.gateway, count: 1)

        rig.clock.advance(100)
        rig.session.play()  // 起点を now() に
        rig.clock.advance(14)
        await rig.tick(10)  // 起点から 14 秒。古い起点なら送ってしまう
        rig.clock.advance(1)
        await rig.tick(12)  // 15 秒で送る

        await waitForCalls(rig.gateway, count: 2)
        await settle()
        XCTAssertEqual(rig.gateway.calls, [.update("a", 2), .update("a", 12)])
    }

    // MARK: - ios-test-092 (b): 一時停止

    // verifies: ios-contract-13（ios-test-092 (b)）
    // kills: 一時停止の遷移で送らない／loading → paused でも送る／一時停止中の positionChanged で送る
    func testT092b_pausingSendsOnceAndPausedPeriodNeverSendsEvenAsTheClockAdvances() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        await rig.startPlaying(a)  // loading → paused → playing の間は送らない
        XCTAssertTrue(rig.gateway.calls.isEmpty)

        await rig.tick(20)
        rig.session.pause()
        await waitForCalls(rig.gateway, count: 1)

        rig.clock.advance(100)
        await rig.tick(30)  // paused 中は位置を更新するだけ
        rig.clock.advance(100)
        await rig.tick(31)

        rig.reporter.flush()  // 区切り: 更新された現在位置 31 を送る
        await waitForCalls(rig.gateway, count: 2)
        XCTAssertEqual(rig.gateway.calls, [.update("a", 20), .update("a", 31)])
    }

    // verifies: ios-contract-13（ios-test-092 (b)。engine 由来の一時停止と buffering → paused も同じ）
    func testT092b_engineInitiatedPauseAndBufferingToPausedAlsoSendOnce() async throws {
        let interrupted = Rig()
        await interrupted.startPlaying(interrupted.episode("a"))
        await interrupted.tick(8)
        await interrupted.engine.send(.interrupted)
        await waitForCalls(interrupted.gateway, count: 1)
        await settle()
        XCTAssertEqual(interrupted.gateway.calls, [.update("a", 8)])

        let buffering = Rig()
        await buffering.startPlaying(buffering.episode("a"))
        await buffering.tick(9)
        await buffering.engine.send(.buffering)
        await buffering.engine.send(.paused)
        await waitForCalls(buffering.gateway, count: 1)
        await settle()
        XCTAssertEqual(buffering.gateway.calls, [.update("a", 9)])
    }

    // verifies: ios-contract-13（ios-test-092 (b)。buffering 中の positionChanged は更新だけ）
    func testT092b_positionChangesWhileBufferingOnlyUpdateTheCurrentPosition() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        await rig.engine.send(.buffering)
        rig.clock.advance(100)
        await rig.tick(40)

        rig.reporter.flush()  // buffering でも送る。更新された位置 40
        await waitForCalls(rig.gateway, count: 1)
        await settle()
        XCTAssertEqual(rig.gateway.calls, [.update("a", 40)])
    }

    // MARK: - ios-test-092 (c): flush

    // verifies: ios-contract-13（ios-test-092 (c)）
    func testT092c_flushSendsOnPlayingBufferingAndPausedButNotTwiceForTheSamePosition() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        await rig.tick(5)

        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 1)
        rig.reporter.flush()  // 同じ位置は再送しない

        await rig.engine.send(.buffering)
        await rig.tick(6)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 2)

        rig.session.pause()  // 位置 6 は送信済みなので送らない
        await rig.tick(7)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 3)
        await settle()

        XCTAssertEqual(rig.gateway.calls, [.update("a", 5), .update("a", 6), .update("a", 7)])
    }

    // verifies: ios-contract-13（ios-test-092 (c)。送る状態でなければ flush は何もしない）
    func testT092c_flushDoesNothingInIdleLoadingEndedAndErrored() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        let b = rig.episode("b")

        rig.reporter.flush()  // idle

        rig.session.start(episode: a, url: rig.url, resumePosition: 12, speed: 1.0)
        rig.reporter.flush()  // loading（resumePosition 12 があっても送らない）

        await rig.engine.send(.ready)
        await rig.tick(299)
        await rig.engine.send(.ended)
        rig.reporter.flush()  // ended

        rig.session.fail(episodeId: "a", reason: .offlineUncached)
        rig.reporter.flush()  // errored

        // 区切り: 確定的な送信
        await rig.startPlaying(b)
        await rig.tick(3)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 1)
        await settle()

        XCTAssertEqual(rig.gateway.calls, [.update("b", 3)], "idle・loading・ended・errored の flush は送らない")
    }

    // MARK: - ios-test-092 (d): 巻き戻し

    // verifies: ios-contract-13（ios-test-092 (d)。shared-dec-19）
    // kills: 送った値より小さい位置を送らない
    func testT092d_rewoundPositionIsAlsoSentOnPauseAndFlush() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        await rig.tick(50)
        rig.session.pause()  // 50
        await waitForCalls(rig.gateway, count: 1)

        rig.session.play()
        await rig.tick(30)  // 巻き戻し
        rig.session.pause()  // 30 を送る
        await waitForCalls(rig.gateway, count: 2)

        rig.session.play()
        await rig.tick(20)
        rig.reporter.flush()  // 20 を送る
        await waitForCalls(rig.gateway, count: 3)
        await settle()

        XCTAssertEqual(rig.gateway.calls, [.update("a", 50), .update("a", 30), .update("a", 20)])
    }

    // verifies: ios-contract-13（ios-test-092 (d)。同じ位置は周期でも再送しない）
    func testT092d_periodicSendDoesNotRepeatTheSamePosition() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        await rig.tick(10)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 1)

        rig.clock.advance(15)
        await rig.tick(10)  // 15 秒たったが直近に送った値と同じ
        rig.clock.advance(100)
        await rig.tick(20)  // 区切り: 位置が変わっていれば送る
        await waitForCalls(rig.gateway, count: 2)
        await settle()

        XCTAssertEqual(rig.gateway.calls, [.update("a", 10), .update("a", 20)])
    }

    // verifies: ios-contract-13（loading で新しい再生の基準に戻る: 送信済みの位置が消える）
    func testNewLoadingResetsTheSentPositionBaseline() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        await rig.tick(20)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 1)

        // 同じ位置 20 から始まる別の再生。基準が戻っていれば、同じ値でも送る。
        await rig.startPlaying(rig.episode("b"), resume: 20)
        rig.reporter.flush()

        await waitForCalls(rig.gateway, count: 2)
        XCTAssertEqual(rig.gateway.calls, [.update("a", 20), .update("b", 20)])
    }

    // MARK: - ios-test-092 (e)〜(j): 完聴

    // verifies: ios-contract-13（ios-test-092 (e)・(j)）
    // kills: markCompleted と位置の書込の順の入れ替え／background task の欠落・二重
    func testT092e_completionRunsInOrderInsideOneBackgroundTask() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        await rig.finish(a)

        rig.reporter.listenCompleted(id: "a")

        await waitForCalls(rig.gateway, count: 5)
        XCTAssertEqual(rig.gateway.calls, [
            .backgroundBegan, .mark("a"), .update("a", 300), .completionRecorded, .backgroundEnded,
        ])
    }

    // verifies: ios-contract-13（ios-test-092 (e)。2 回目は何もせず、次の loading の後はまた送る）
    func testT092e_secondCompletionInTheSamePlaybackIsIgnoredAndALaterPlaybackSendsAgain() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        await rig.finish(a)
        rig.reporter.listenCompleted(id: "a")
        rig.reporter.listenCompleted(id: "a")  // 同じ再生の 2 回目

        // 区切り: 同じエピソードをもう一度聴き終える。
        await rig.finish(a)
        rig.reporter.listenCompleted(id: "a")

        await waitForCalls(rig.gateway, count: 10)
        await settle()
        let group: [Call] = [.backgroundBegan, .mark("a"), .update("a", 300), .completionRecorded, .backgroundEnded]
        XCTAssertEqual(rig.gateway.calls, group + group, "2 回目は増えず、次の loading の後はまた送る")
    }

    // verifies: ios-contract-13（ios-test-092 (e)。呼出時に id と値が確定する）
    // kills: Task の中で Reporter の状態を読む（次の loading で基準が戻る）
    func testT092e_valuesAreFixedWhenListenCompletedIsCalledEvenIfTheNextLoadingArrivesFirst() async throws {
        let rig = Rig()
        let a = rig.episode("a", durationSeconds: 300)
        let b = rig.episode("b", durationSeconds: 500)
        await rig.finish(a)

        rig.reporter.listenCompleted(id: "a")
        // Task が動く前に次のエピソードの loading が来る（キャッシュ済みの次を開始した形）。
        rig.session.start(episode: b, url: rig.url, resumePosition: 0, speed: 1.0)

        await waitForCalls(rig.gateway, count: 5)
        await settle()
        XCTAssertEqual(rig.gateway.calls, [
            .backgroundBegan, .mark("a"), .update("a", 300), .completionRecorded, .backgroundEnded,
        ])
    }

    // verifies: ios-contract-13（ios-test-092 (e)。Reporter を手放しても完聴の一連の送信は最後まで行われる）
    // kills: `self?.apply(await 送信)` の形（self が nil だと送信ごと評価されない）
    func testT092e_completionStillRunsToTheEndWhenTheReporterIsReleasedBeforeTheTaskRuns() async throws {
        let engine = AudioEngineDouble()
        let session = PlaybackSession(engine: engine)
        let gateway = Gateway()
        let url = URL(string: "https://storage.example.com/a.mp3")!
        weak var released: PositionReporter?
        do {
            let reporter = PositionReporter(
                updatePosition: { id, seconds in try await gateway.updatePosition(id, seconds) },
                markCompleted: { id in try await gateway.markCompleted(id) },
                onPositionSaved: { gateway.positionSaved($0) },
                onCompletionRecorded: { await gateway.completionRecorded() },
                beginBackgroundTask: { gateway.beginBackgroundTask() }
            )
            released = reporter
            reporter.attach(session)
            let content = EpisodeContent(
                id: "a", title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
                createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
                segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
            )
            let episode = PlayableEpisode(content: content, audioUrl: url.absoluteString, serverPosition: 0)!
            session.start(episode: episode, url: url, resumePosition: 0, speed: 1.0)
            await engine.send(.ready)
            await engine.send(.timeUpdate(seconds: 299, duration: 300))
            await engine.send(.ended)
            reporter.listenCompleted(id: "a")
        }
        XCTAssertNil(released, "前提: Task が動く前に Reporter は解放されている")

        await waitForCalls(gateway, count: 5)
        XCTAssertEqual(gateway.calls, [
            .backgroundBegan, .mark("a"), .update("a", 300), .completionRecorded, .backgroundEnded,
        ])
        XCTAssertEqual(gateway.saved.count, 1)
    }

    // verifies: ios-contract-13（ios-test-092 (f)。総時間 0 なら完聴時点の位置）
    func testT092f_unknownDurationFallsBackToTheCurrentPosition() async throws {
        let rig = Rig()
        let a = rig.episode("a", durationSeconds: 0)
        await rig.startPlaying(a)
        await rig.tick(42, duration: 0)
        await rig.engine.send(.ended)

        rig.reporter.listenCompleted(id: "a")

        await waitForCalls(rig.gateway, count: 5)
        XCTAssertEqual(rig.gateway.calls, [
            .backgroundBegan, .mark("a"), .update("a", 42), .completionRecorded, .backgroundEnded,
        ])
    }

    // verifies: ios-contract-13（ios-test-092 (f)。どちらも 0 なら位置の書込を飛ばす。markCompleted は送る）
    func testT092f_bothZeroSkipsThePositionWriteButStillMarksCompleted() async throws {
        let rig = Rig()
        let a = rig.episode("a", durationSeconds: 0)
        await rig.startPlaying(a)
        await rig.engine.send(.ended)

        rig.reporter.listenCompleted(id: "a")

        await waitForCalls(rig.gateway, count: 4)
        await settle()
        XCTAssertEqual(rig.gateway.calls, [.backgroundBegan, .mark("a"), .completionRecorded, .backgroundEnded])
    }

    // verifies: ios-contract-13（ios-test-092 (g)）
    // kills: markCompleted の失敗で位置の書込を止める／lastSyncFailure を最後の送信の結果にしない
    func testT092g_failedMarkCompletedStillWritesPositionAndLastSyncFailureIsTheLastFinishedSend() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        rig.gateway.markError = ApiFailure.server(status: 500)
        rig.gateway.updateError = ApiFailure.rateLimited(retryAfter: nil)
        await rig.finish(a)

        rig.reporter.listenCompleted(id: "a")

        await waitForCalls(rig.gateway, count: 5)
        XCTAssertEqual(rig.gateway.calls, [
            .backgroundBegan, .mark("a"), .update("a", 300), .completionRecorded, .backgroundEnded,
        ], "markCompleted が失敗しても位置の書込以降を続ける")
        XCTAssertEqual(rig.reporter.lastSyncFailure, .rateLimited(retryAfter: nil), "最後に終わった送信（位置の書込）の失敗")
    }

    // verifies: ios-contract-13（ios-test-092 (g)。成功で nil に戻り、ApiFailure 以外の error は無視する）
    func testT092g_lastSyncFailureClearsOnSuccessAndIgnoresNonApiFailureErrors() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        XCTAssertNil(rig.reporter.lastSyncFailure)

        rig.gateway.updateError = ApiFailure.server(status: 503)
        await rig.tick(5)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 1)
        await eventually { rig.reporter.lastSyncFailure == .server(status: 503) }
        XCTAssertEqual(rig.reporter.lastSyncFailure, .server(status: 503))

        rig.gateway.updateError = SyncError()  // ApiFailure 以外は無視（直前の値のまま）
        await rig.tick(6)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 2)
        await settle()
        XCTAssertEqual(rig.reporter.lastSyncFailure, .server(status: 503), "ほかの error は無視する")

        rig.gateway.updateError = nil  // 成功で nil
        await rig.tick(7)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 3)
        await eventually { rig.reporter.lastSyncFailure == nil }
        XCTAssertNil(rig.reporter.lastSyncFailure)
    }

    // verifies: ios-contract-13（ios-test-092 (h)）
    func testT092h_savedPositionResponseIsHandedToOnPositionSavedOnce() async throws {
        let rig = Rig()
        await rig.startPlaying(rig.episode("a"))
        await rig.tick(33)

        rig.reporter.flush()

        await waitForCalls(rig.gateway, count: 1)
        await eventually { rig.gateway.saved.count == 1 }
        await settle()
        XCTAssertEqual(rig.gateway.saved, [Gateway.response(id: "a", seconds: 33)])
    }

    // verifies: ios-contract-13（ios-test-092 (i)）
    // kills: listenCompleted が送信の完了を待つ／markCompleted の完了前に位置を書く
    func testT092i_listenCompletedReturnsImmediatelyWhileMarkCompletedIsHeld() async throws {
        let rig = Rig()
        rig.gateway.holdMark = true
        await rig.finish(rig.episode("a"))

        rig.reporter.listenCompleted(id: "a")  // 同期の関数で、保留中でもすぐ戻る

        await waitForCalls(rig.gateway, count: 2)
        await settle()
        XCTAssertEqual(rig.gateway.calls, [.backgroundBegan, .mark("a")], "markCompleted の完了前には位置を書かない")

        rig.gateway.releaseMark()
        await waitForCalls(rig.gateway, count: 5)
        XCTAssertEqual(rig.gateway.calls, [
            .backgroundBegan, .mark("a"), .update("a", 300), .completionRecorded, .backgroundEnded,
        ])
    }

    // MARK: - ended・errored・idle は送らない

    // verifies: ios-contract-13（ended・errored・idle に入った: 送らない。停止の前に送るのは Coordinator）
    func testEnteringEndedErroredAndIdleNeverSends() async throws {
        let rig = Rig()
        let a = rig.episode("a")
        let b = rig.episode("b")

        await rig.startPlaying(a)
        await rig.tick(50)
        await rig.engine.send(.ended)  // ended

        await rig.startPlaying(a)
        await rig.tick(60)
        await rig.engine.send(.failed(description: "boom"))  // errored

        await rig.startPlaying(a)
        await rig.tick(70)
        rig.session.stop()  // idle

        // 区切り
        await rig.startPlaying(b)
        await rig.tick(3)
        rig.reporter.flush()
        await waitForCalls(rig.gateway, count: 1)
        await settle()

        XCTAssertEqual(rig.gateway.calls, [.update("b", 3)])
    }

    private func eventually(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
