import XCTest
@testable import NewsListenApp

/// `PlaybackSession`（再生状態の union と engine の駆動）の契約テスト。
///
/// oracle は公開操作・状態・通知・`AudioEngineDouble` の状態に限る。engine の呼出回数は assert しない。
@MainActor
final class PlaybackSessionTests: XCTestCase {

    // MARK: - 土台

    private final class EventLog {
        var events: [SessionEvent] = []
        var states: [PlaybackState] {
            events.compactMap { if case .stateChanged(let s) = $0 { return s } else { return nil } }
        }
        var interruptions: [InterruptionPhase] {
            events.compactMap { if case .interruption(let p) = $0 { return p } else { return nil } }
        }
        var endedIds: [String] {
            events.compactMap { if case .ended(let id) = $0 { return id } else { return nil } }
        }
    }

    private enum Phase: CaseIterable {
        case loading, playing, buffering, paused, ended, errored
    }

    private let url = URL(string: "https://storage.example.com/a.mp3")!

    private func makeEpisode(
        id: String = "ep-a", durationSeconds: Int = 300, serverPosition: Double = 0
    ) throws -> PlayableEpisode {
        let content = EpisodeContent(
            id: id, title: "題 \(id)", japaneseIntroText: "導入 \(id)", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: durationSeconds,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
        return try XCTUnwrap(PlayableEpisode(content: content, audioUrl: url.absoluteString, serverPosition: serverPosition))
    }

    @MainActor
    private struct Rig {
        let engine: AudioEngineDouble
        let session: PlaybackSession
        let log: EventLog
        let url: URL

        @discardableResult
        func start(_ episode: PlayableEpisode, resume: Double = 0, speed: Float = 1.0) -> String? {
            session.start(episode: episode, url: url, resumePosition: resume, speed: speed)
        }

        /// 開始から `phase` の状態まで進める（`ended`・`errored` は engine の事象で）。
        func drive(to phase: Phase, episode: PlayableEpisode, resume: Double = 0, speed: Float = 1.0) async {
            start(episode, resume: resume, speed: speed)
            switch phase {
            case .loading:
                return
            case .errored:
                await engine.send(.failed(description: "boom"))
                return
            default:
                break
            }
            await engine.send(.ready)
            switch phase {
            case .buffering:
                await engine.send(.buffering)
            case .paused:
                session.pause()
            case .ended:
                await engine.send(.ended)
            default:
                break
            }
        }
    }

    private func makeRig() -> Rig {
        let engine = AudioEngineDouble()
        let session = PlaybackSession(engine: engine)
        let log = EventLog()
        session.observe { log.events.append($0) }
        return Rig(engine: engine, session: session, log: log, url: url)
    }

    /// 手渡した事象を処理する Task に実行の機会を与える（固定時間の sleep は使わない）。
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func loading(_ e: PlayableEpisode, resume: Double = 0, speed: Float = 1.0) -> PlaybackState {
        .loading(episode: e, resumePosition: resume, speed: speed)
    }

    private func playing(_ e: PlayableEpisode, at position: Double = 0, duration: Double? = nil, speed: Float = 1.0) -> PlaybackState {
        .playing(episode: e, position: position, duration: duration ?? Double(e.content.durationSeconds), speed: speed)
    }

    private func paused(_ e: PlayableEpisode, at position: Double = 0, duration: Double? = nil, speed: Float = 1.0) -> PlaybackState {
        .paused(episode: e, position: position, duration: duration ?? Double(e.content.durationSeconds), speed: speed)
    }

    private func buffering(_ e: PlayableEpisode, at position: Double = 0, duration: Double? = nil, speed: Float = 1.0) -> PlaybackState {
        .buffering(episode: e, position: position, duration: duration ?? Double(e.content.durationSeconds), speed: speed)
    }

    // MARK: - ios-test-071: 分母 16 の辺

    // verifies: ios-contract-01（ios-test-071。辺 1〜5）
    func testT071_edges1to5FromIdleThroughLoadingToPaused() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        XCTAssertEqual(rig.session.state, .idle)

        // 1: idle → loading（start）
        rig.start(a, resume: 10, speed: 1.5)
        XCTAssertEqual(rig.session.state, loading(a, resume: 10, speed: 1.5))

        // 2: loading → paused（engine ready。直後に 4 が続く）。loading での pause() も同じ辺。
        let pausedByOperation = makeRig()
        pausedByOperation.start(a, resume: 10)
        pausedByOperation.session.pause()
        XCTAssertEqual(pausedByOperation.session.state, paused(a, at: 10), "loading での pause: 位置は resumePosition、総時間は durationSeconds")

        // 4: paused → playing（play()）
        pausedByOperation.session.play()
        XCTAssertEqual(pausedByOperation.session.state, playing(a, at: 10))

        // 5: paused → paused（seek / seekRelative）
        let seeking = makeRig()
        await seeking.drive(to: .paused, episode: a)
        seeking.session.seek(to: 40)
        XCTAssertEqual(seeking.session.state, paused(a, at: 40))
        seeking.session.seekRelative(-15)
        XCTAssertEqual(seeking.session.state, paused(a, at: 25))
        seeking.session.seekRelative(30)
        XCTAssertEqual(seeking.session.state, paused(a, at: 55))

        // 6: paused → loading（start）
        let b = try makeEpisode(id: "ep-b")
        seeking.start(b, resume: 5)
        XCTAssertEqual(seeking.session.state, loading(b, resume: 5))
    }

    // verifies: ios-contract-01（ios-test-071。辺 2・3・4 の engine 事象）
    func testT071_readyEmitsPausedThenPlayingAsTwoStateChanges() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        rig.start(a, resume: 12, speed: 1.25)
        let before = rig.log.events.count

        await rig.engine.send(.ready)

        let added = Array(rig.log.events.dropFirst(before))
        XCTAssertEqual(added, [
            .stateChanged(paused(a, at: 12, speed: 1.25)),
            .stateChanged(playing(a, at: 12, speed: 1.25)),
        ], "ready は paused → playing の 2 回。位置は resumePosition、総時間は durationSeconds")
    }

    // verifies: ios-contract-01（ios-test-071。辺 3・12・13）
    func testT071_engineFailedFromLoadingPlayingAndBufferingErrors() async throws {
        let a = try makeEpisode()
        for phase in [Phase.loading, .playing, .buffering] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a, resume: 7)
            await rig.engine.send(.failed(description: "boom"))
            XCTAssertEqual(
                rig.session.state,
                .errored(episodeId: a.content.id, position: 7, reason: .engineFailed(description: "boom")),
                "\(phase)"
            )
        }
    }

    // verifies: ios-contract-01（ios-test-071。辺 7〜11）
    func testT071_edges7to11PlayingBufferingPausedAndEnded() async throws {
        let a = try makeEpisode()

        // 7: playing → paused（pause）
        let pausing = makeRig()
        await pausing.drive(to: .playing, episode: a)
        pausing.session.pause()
        XCTAssertEqual(pausing.session.state, paused(a))

        // 8: playing → buffering、9: buffering → playing（resumed）
        let buf = makeRig()
        await buf.drive(to: .playing, episode: a)
        await buf.engine.send(.buffering)
        XCTAssertEqual(buf.session.state, buffering(a))
        await buf.engine.send(.resumed)
        XCTAssertEqual(buf.session.state, playing(a))

        // 10: buffering → paused（pause）
        await buf.engine.send(.buffering)
        buf.session.pause()
        XCTAssertEqual(buf.session.state, paused(a))

        // 11: playing → ended（engine ended）
        let finishing = makeRig()
        await finishing.drive(to: .playing, episode: a)
        await finishing.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await finishing.engine.send(.ended)
        XCTAssertEqual(finishing.session.state, .ended(episode: a, duration: 300))
        XCTAssertEqual(finishing.log.endedIds, [a.content.id])
    }

    // verifies: ios-contract-01（ios-test-071。辺 14〜16）
    func testT071_edges14to16StartFromEndedAndErrored() async throws {
        let a = try makeEpisode()
        let b = try makeEpisode(id: "ep-b")

        // 14: ended → loading（次のエピソード）
        let ended = makeRig()
        await ended.drive(to: .ended, episode: a)
        ended.start(b)
        XCTAssertEqual(ended.session.state, loading(b))

        // 15: errored → loading（同じエピソード）
        let retry = makeRig()
        await retry.drive(to: .errored, episode: a)
        retry.start(a)
        XCTAssertEqual(retry.session.state, loading(a))

        // 16: errored → loading（別のエピソード）
        let other = makeRig()
        await other.drive(to: .errored, episode: a)
        other.start(b, resume: 3)
        XCTAssertEqual(other.session.state, loading(b, resume: 3))
    }

    // verifies: ios-contract-01（ios-test-071。表の外: loading / playing / buffering / paused からの start）
    func testT071_startFromLoadedStatesIsOutsideTheTableAndInsertsIdleOnlyForLoadingPlayingBuffering() async throws {
        let a = try makeEpisode()
        let b = try makeEpisode(id: "ep-b")
        for phase in [Phase.loading, .playing, .buffering, .paused] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            let before = rig.log.states.count

            rig.start(b)

            let added = Array(rig.log.states.dropFirst(before))
            if phase == .paused {
                XCTAssertEqual(added, [loading(b)], "paused からは idle の通知を出さない（辺 6）")
            } else {
                XCTAssertEqual(added, [.idle, loading(b)], "\(phase) からは stop と同じ後始末（idle の通知）を挟む")
            }
            XCTAssertEqual(rig.engine.loadedURL, url)
            XCTAssertTrue(rig.engine.isLoaded)
        }
    }

    // verifies: ios-contract-01（ios-test-071。表の外の例: 状態が変わらない）
    func testT071_outOfTableCombinationsLeaveTheStateUnchanged() async throws {
        let a = try makeEpisode()

        // ended での play()
        let ended = makeRig()
        await ended.drive(to: .ended, episode: a)
        let endedState = ended.session.state
        let endedEvents = ended.log.events.count
        ended.session.play()
        XCTAssertEqual(ended.session.state, endedState)
        XCTAssertEqual(ended.log.events.count, endedEvents, "通知も出ない")
        XCTAssertFalse(ended.engine.isLoaded)

        // errored での play()（ios-deriv-29。再試行は Coordinator）
        let errored = makeRig()
        await errored.drive(to: .errored, episode: a)
        let erroredState = errored.session.state
        let erroredEvents = errored.log.events.count
        errored.session.play()
        XCTAssertEqual(errored.session.state, erroredState)
        XCTAssertEqual(errored.log.events.count, erroredEvents)
        XCTAssertFalse(errored.engine.isLoaded)

        // paused での resumed・buffering
        let pausedRig = makeRig()
        await pausedRig.drive(to: .paused, episode: a)
        await pausedRig.engine.send(.resumed)
        XCTAssertEqual(pausedRig.session.state, paused(a), "paused の resumed は状態を動かさない")
        await pausedRig.engine.send(.buffering)
        XCTAssertEqual(pausedRig.session.state, paused(a), "paused の buffering は状態を動かさない")

        // playing での paused 事象（ios-dec-20）
        let playingRig = makeRig()
        await playingRig.drive(to: .playing, episode: a)
        await playingRig.engine.send(.paused)
        XCTAssertEqual(playingRig.session.state, playing(a), "playing の paused 事象は状態を動かさない")
    }

    // MARK: - ios-test-071: idle の事象・古い読み込みの channel の事象（手渡しの手順）

    // verifies: ios-contract-01（ios-test-071。idle での engine の事象は捨てる）
    // kills: 購読 Task の cancel の確認と idle で事象を無視する規則の両方を抜いた実装
    // 検出の限界: 手渡した事象を処理する Task のジョブが assert より前に走ることは main executor の順序に依存する。
    // 崩れた場合は偽 green の方向にだけ働く（正の対照が 20 回の待ちで事象が適用されることを示す）。
    func testT071_eventHandedOffBeforeStopIsNotAppliedWhileIdle() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        rig.start(a)
        await rig.engine.send(.ready)  // playing。消費者は unfolding で次を待つ状態になる
        let channel = try XCTUnwrap(rig.engine.currentChannel)
        XCTAssertEqual(channel.yield(.failed(description: "stale")), .handedOff, "Given の成立: 待機中の消費者へ直接手渡した")

        // await を挟まずに stop する（手渡された事象を処理する Task はまだ走っていない）。
        rig.session.stop()
        let afterStop = rig.log.events.count
        await settle()

        XCTAssertEqual(rig.session.state, .idle)
        XCTAssertEqual(rig.log.events.count, afterStop, "stop の後に通知が増えない")

        // 正の対照: stop も start もしなければ、同じ手渡しで事象が適用される。
        let control = makeRig()
        control.start(a)
        await control.engine.send(.ready)
        let liveChannel = try XCTUnwrap(control.engine.currentChannel)
        XCTAssertEqual(liveChannel.yield(.failed(description: "live")), .handedOff)
        await settle()
        XCTAssertEqual(
            control.session.state,
            .errored(episodeId: a.content.id, position: 0, reason: .engineFailed(description: "live")),
            "待ちが足りて事象が適用されうる（本体の「状態不変」が空振りでない）"
        )
    }

    // verifies: ios-contract-01（ios-test-071。古い読み込みの channel の事象は捨てる）
    // kills: 購読 Task の `Task.isCancelled` の確認の削除
    func testT071_eventHandedOffBeforeNextStartIsNotAppliedToTheNextLoad() async throws {
        let a = try makeEpisode()
        let b = try makeEpisode(id: "ep-b")
        let rig = makeRig()
        rig.start(a)
        await rig.engine.send(.ready)
        let oldChannel = try XCTUnwrap(rig.engine.currentChannel)
        XCTAssertEqual(oldChannel.yield(.failed(description: "stale")), .handedOff, "Given の成立: 待機中の消費者へ直接手渡した")

        // await を挟まずに次の start（前の購読 Task を cancel して load する）。
        rig.start(b)
        await rig.engine.send(.ready)  // b の channel で処理を待つ

        XCTAssertEqual(rig.session.state, playing(b), "古い failed が新しい読み込みに適用されない")
        XCTAssertTrue(rig.engine.isLoaded)
        XCTAssertFalse(rig.log.states.contains { if case .errored = $0 { return true } else { return false } })
    }

    // MARK: - ios-test-077: engine を正しく動かしたか

    // verifies: ios-contract-01（ios-test-077）
    // kills: play → setRate の順の入れ替え（double の play() は速度を 1.0 に戻す）・seek の抜け
    func testT077_startDrivesTheEngineInTheDocumentedOrder() throws {
        let a = try makeEpisode()
        let rig = makeRig()

        rig.start(a, resume: 30, speed: 1.5)

        XCTAssertEqual(rig.engine.loadedURL, url)
        XCTAssertTrue(rig.engine.hasStartedPlayback)
        XCTAssertEqual(rig.engine.rate, 1.5, "play の後に setRate する（逆順だと 1.0 に戻る）")
        XCTAssertEqual(rig.engine.lastSeekSeconds, 30)
    }

    // verifies: ios-contract-01（ios-test-077）
    func testT077_startWithoutResumePositionDoesNotSeek() throws {
        let a = try makeEpisode()
        let rig = makeRig()

        rig.start(a, resume: 0, speed: 1.0)

        XCTAssertTrue(rig.engine.hasStartedPlayback)
        XCTAssertNil(rig.engine.lastSeekSeconds, "再開位置 0 では seek しない")
    }

    // verifies: ios-contract-01（ios-test-077）
    func testT077_pauseAndPlayFollowTheEngineRateAndSeekIsClamped() async throws {
        let a = try makeEpisode(durationSeconds: 100)
        let rig = makeRig()
        await rig.drive(to: .playing, episode: a, speed: 1.25)

        rig.session.pause()
        XCTAssertEqual(rig.engine.rate, 0)

        rig.session.play()
        XCTAssertEqual(rig.engine.rate, 1.25, "paused からの play() は setRate で再開する（速度が 1.0 に戻らない）")

        rig.session.seek(to: 500)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 100, "丸めた値で seek する")
        rig.session.seek(to: -4)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 0)
    }

    // verifies: ios-contract-01（ios-test-077）
    func testT077_engineIsUnloadedAfterEndedAndErrored() async throws {
        let a = try makeEpisode()
        let ended = makeRig()
        await ended.drive(to: .ended, episode: a)
        XCTAssertFalse(ended.engine.isLoaded)
        XCTAssertFalse(PlaybackRules.isLoaded(ended.session.state))

        let errored = makeRig()
        await errored.drive(to: .errored, episode: a)
        XCTAssertFalse(errored.engine.isLoaded)
        XCTAssertFalse(PlaybackRules.isLoaded(errored.session.state))

        for phase in [Phase.loading, .playing, .buffering, .paused] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            XCTAssertTrue(rig.engine.isLoaded, "\(phase)")
            XCTAssertTrue(PlaybackRules.isLoaded(rig.session.state), "\(phase)")
        }
    }

    // verifies: ios-contract-01（操作 × 状態の表。操作できない状態では何もしない）
    func testOperationsAreNoOpsOutsideTheirStates() async throws {
        let a = try makeEpisode()

        // play(): paused 以外では何もしない。
        for phase in [Phase.loading, .playing, .buffering] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            let state = rig.session.state
            let events = rig.log.events.count
            rig.session.play()
            XCTAssertEqual(rig.session.state, state, "\(phase)")
            XCTAssertEqual(rig.log.events.count, events, "\(phase)")
        }

        // pause(): paused・ended・errored・idle では何もしない。
        for phase in [Phase.paused, .ended, .errored] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            let state = rig.session.state
            rig.session.pause()
            XCTAssertEqual(rig.session.state, state, "\(phase)")
        }
        let idle = makeRig()
        idle.session.pause()
        idle.session.play()
        idle.session.seek(to: 10)
        idle.session.seekRelative(5)
        idle.session.setSpeed(2.0)
        XCTAssertEqual(idle.session.state, .idle)
        XCTAssertTrue(idle.log.events.isEmpty)

        // seek / setSpeed: ended・errored では何もしない。
        for phase in [Phase.ended, .errored] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            let state = rig.session.state
            rig.session.seek(to: 10)
            rig.session.seekRelative(5)
            rig.session.setSpeed(2.0)
            XCTAssertEqual(rig.session.state, state, "\(phase)")
        }
    }

    // MARK: - ios-test-080 の Session 側（ios-contract-09）と setSpeed の表

    // verifies: ios-contract-09（開始ごとの速度・setSpeed の無視）
    func testSetSpeedFollowsTheTableAndIgnoresValuesOutsideTheChoices() async throws {
        let a = try makeEpisode()

        // loading・playing・buffering: 速度を更新し engine へも渡す。
        for phase in [Phase.loading, .playing, .buffering] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            rig.session.setSpeed(2.0)
            XCTAssertEqual(rig.session.state.speed, 2.0, "\(phase)")
            XCTAssertEqual(rig.engine.rate, 2.0, "\(phase)")
        }

        // paused: 速度だけ更新し engine は呼ばない（rate は 0 のまま）。再開で新しい速度になる。
        let pausedRig = makeRig()
        await pausedRig.drive(to: .paused, episode: a)
        pausedRig.session.setSpeed(2.0)
        XCTAssertEqual(pausedRig.session.state.speed, 2.0)
        XCTAssertEqual(pausedRig.engine.rate, 0)
        pausedRig.session.play()
        XCTAssertEqual(pausedRig.engine.rate, 2.0)

        // 選択肢にない値は無視する。
        let rig = makeRig()
        await rig.drive(to: .playing, episode: a, speed: 1.5)
        rig.session.setSpeed(3.3)
        XCTAssertEqual(rig.session.state.speed, 1.5)
        XCTAssertEqual(rig.engine.rate, 1.5)
    }

    // verifies: ios-contract-09（start に無い速度が来たら 1.0。ios-deriv-32）
    func testStartWithSpeedOutsideTheChoicesFallsBackToNormalSpeed() throws {
        let a = try makeEpisode()
        let rig = makeRig()

        rig.start(a, speed: 3.3)

        XCTAssertEqual(rig.session.state, loading(a, speed: 1.0))
        XCTAssertEqual(rig.engine.rate, 1.0)
    }

    // MARK: - ios-test-072: stop

    // verifies: ios-contract-02（ios-test-072）
    // MARK: shared-session-11
    func testT072SharedSession11_stopFromEverySixStatesReturnsToIdleAndUnloadsTheEngine() async throws {
        let a = try makeEpisode()
        for phase in Phase.allCases {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            let before = rig.log.states.count

            rig.session.stop()

            XCTAssertEqual(rig.session.state, .idle, "\(phase)")
            XCTAssertFalse(rig.engine.isLoaded, "\(phase)")
            XCTAssertFalse(PlaybackRules.isLoaded(rig.session.state), "\(phase)")
            XCTAssertEqual(Array(rig.log.states.dropFirst(before)), [.idle], "\(phase): idle の通知は 1 回")
        }
    }

    // verifies: ios-contract-02（ios-test-072。idle での stop は冪等）
    // MARK: shared-session-11
    func testT072SharedSession11_stopWhileIdleChangesNeitherTheEngineNorNotifications() async throws {
        let rig = makeRig()

        rig.session.stop()
        rig.session.stop()

        XCTAssertEqual(rig.session.state, .idle)
        XCTAssertTrue(rig.log.events.isEmpty)
        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertNil(rig.engine.loadedURL)
        XCTAssertEqual(rig.engine.rate, 0)
    }

    // MARK: - ios-test-073: engine 由来の一時停止と割り込み

    // verifies: ios-contract-03（ios-test-073。paused 事象は buffering のときだけ）
    func testT073_pausedEventOnlyMovesBufferingToPaused() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .buffering, episode: a)
        await rig.engine.send(.paused)
        XCTAssertEqual(rig.session.state, paused(a))

        for phase in [Phase.loading, .playing, .paused] {
            let other = makeRig()
            await other.drive(to: phase, episode: a)
            let state = other.session.state
            await other.engine.send(.paused)
            XCTAssertEqual(other.session.state, state, "\(phase) の paused 事象は状態を動かさない")
        }
    }

    // verifies: ios-contract-03（ios-test-073。interrupted・outputDeviceLost の表駆動）
    func testT073_interruptedAndOutputDeviceLostPauseLoadingPlayingAndBuffering() async throws {
        let a = try makeEpisode()
        for phase in [Phase.loading, .playing, .buffering] {
            let interrupted = makeRig()
            await interrupted.drive(to: phase, episode: a, resume: 4, speed: 1.5)
            await interrupted.engine.send(.interrupted)
            XCTAssertTrue(interrupted.session.state.isPausedState, "\(phase): interrupted で paused")
            XCTAssertEqual(interrupted.engine.rate, 0, "\(phase): engine も pause する")
            XCTAssertEqual(interrupted.log.interruptions, [.began(wasPlaying: true)], "\(phase)")

            let lost = makeRig()
            await lost.drive(to: phase, episode: a, resume: 4, speed: 1.5)
            await lost.engine.send(.outputDeviceLost)
            XCTAssertTrue(lost.session.state.isPausedState, "\(phase): outputDeviceLost で paused")
            XCTAssertEqual(lost.engine.rate, 0, "\(phase)")
            XCTAssertTrue(lost.log.interruptions.isEmpty, "\(phase): outputDeviceLost は割り込みの通知を出さない")
        }
    }

    // verifies: ios-contract-03（ios-test-073。paused での interrupted は wasPlaying: false を通知するだけ）
    func testT073_interruptedWhilePausedNotifiesNotPlayingAndKeepsTheState() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .paused, episode: a)

        await rig.engine.send(.interrupted)
        XCTAssertEqual(rig.session.state, paused(a))
        XCTAssertEqual(rig.log.interruptions, [.began(wasPlaying: false)])

        await rig.engine.send(.outputDeviceLost)
        XCTAssertEqual(rig.session.state, paused(a), "paused の outputDeviceLost は何もしない")
        XCTAssertEqual(rig.log.interruptions, [.began(wasPlaying: false)])
    }

    // verifies: ios-contract-03（ios-test-073。interruptionEnded は 1 回通知し、Session は自分から再開しない。ios-dec-25）
    func testT073_interruptionEndedIsNotifiedOnceAndTheSessionDoesNotResumeItself() async throws {
        let a = try makeEpisode()
        for phase in [Phase.loading, .playing, .buffering, .paused] {
            let rig = makeRig()
            await rig.drive(to: phase, episode: a)
            await rig.engine.send(.interrupted)
            let state = rig.session.state

            await rig.engine.send(.interruptionEnded(shouldResume: true))

            XCTAssertEqual(rig.session.state, state, "\(phase): 割り込みの終了で自分から再開しない")
            XCTAssertEqual(rig.engine.rate, 0, "\(phase)")
            XCTAssertEqual(rig.log.interruptions.filter { $0 == .ended(shouldResume: true) }.count, 1, "\(phase)")
        }
        let denied = makeRig()
        await denied.drive(to: .playing, episode: a)
        await denied.engine.send(.interruptionEnded(shouldResume: false))
        XCTAssertEqual(denied.log.interruptions, [.ended(shouldResume: false)])
        XCTAssertEqual(denied.session.state, playing(a), "playing での interruptionEnded は状態を変えない")
    }

    // verifies: ios-contract-03（ios-test-073。loading での seek は resumePosition を置き換える。ios-deriv-22）
    func testT073_seekWhileLoadingReplacesTheResumePositionAndStaysLoading() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        rig.start(a, resume: 10, speed: 1.25)

        rig.session.seek(to: 25)

        XCTAssertEqual(rig.session.state, loading(a, resume: 25, speed: 1.25))
        XCTAssertEqual(rig.engine.lastSeekSeconds, 25)

        rig.session.seekRelative(-15)
        XCTAssertEqual(rig.session.state, loading(a, resume: 10, speed: 1.25), "seekRelative の基準は resumePosition")
        XCTAssertEqual(rig.engine.lastSeekSeconds, 10)
    }

    // MARK: - ios-test-074: 読み込みの警告

    // verifies: ios-contract-04（ios-test-074）
    func testT074_startReturnsTheLoadWarningAsIsAndStaysLoading() throws {
        let a = try makeEpisode()
        let rig = makeRig()
        rig.engine.nextLoadWarning = "session failed"

        let warning = rig.start(a)

        XCTAssertEqual(warning, "session failed")
        XCTAssertEqual(rig.session.state, loading(a), "警告は状態を変えない")
    }

    // verifies: ios-contract-04（ios-test-074）
    func testT074_startWithoutWarningReturnsNil() throws {
        let a = try makeEpisode()
        let rig = makeRig()

        XCTAssertNil(rig.start(a))
        XCTAssertEqual(rig.session.state, loading(a))
    }

    // MARK: - ios-test-075: 総時間と位置の丸め

    // verifies: ios-contract-05（ios-test-075）
    func testT075_durationStartsFromContentAndTimeUpdateReplacesItOnlyWhenPositive() async throws {
        let a = try makeEpisode(durationSeconds: 300)
        let rig = makeRig()
        await rig.drive(to: .playing, episode: a)
        XCTAssertEqual(rig.session.state.duration, 300, "総時間は durationSeconds で始まる")
        let stateChangesBefore = rig.log.states.count

        await rig.engine.send(.timeUpdate(seconds: 10, duration: 0))
        XCTAssertEqual(rig.session.state, playing(a, at: 10, duration: 300), "d = 0 では置き換わらない")

        await rig.engine.send(.timeUpdate(seconds: 20, duration: 400))
        XCTAssertEqual(rig.session.state, playing(a, at: 20, duration: 400), "d > 0 で置き換わる")

        XCTAssertEqual(rig.log.states.count, stateChangesBefore, "timeUpdate は stateChanged を出さない")
        XCTAssertEqual(
            Array(rig.log.events.suffix(2)),
            [.positionChanged(seconds: 10, duration: 300), .positionChanged(seconds: 20, duration: 400)],
            "timeUpdate は positionChanged だけを出す"
        )
    }

    // verifies: ios-contract-05（ios-test-075。分かっている間は [0, 総時間]）
    func testT075_seekIsClampedToTheKnownDuration() async throws {
        let a = try makeEpisode(durationSeconds: 300)
        let rig = makeRig()
        await rig.drive(to: .playing, episode: a)
        await rig.engine.send(.timeUpdate(seconds: 50, duration: 400))

        rig.session.seek(to: 500)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 400)
        XCTAssertEqual(rig.session.state.position, 400)

        rig.session.seek(to: -5)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 0)
        XCTAssertEqual(rig.session.state.position, 0)

        rig.session.seek(to: 100)
        rig.session.seekRelative(-15)
        XCTAssertEqual(rig.session.state.position, 85)
        rig.session.seekRelative(30)
        XCTAssertEqual(rig.session.state.position, 115)
    }

    // verifies: ios-contract-05（ios-test-075。総時間が 0 の間は上限で丸めない）
    func testT075_seekIsNotClampedAboveWhileDurationIsUnknown() async throws {
        let a = try makeEpisode(durationSeconds: 0)
        let rig = makeRig()
        await rig.drive(to: .playing, episode: a)
        XCTAssertEqual(rig.session.state.duration, 0)

        rig.session.seek(to: 9_999)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 9_999, "下限 0 だけで、上限では丸めない")

        rig.session.seek(to: -1)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 0)

        await rig.engine.send(.timeUpdate(seconds: 5, duration: 0))
        XCTAssertEqual(rig.session.state.duration, 0, "どちらも 0 の間は不明のまま")
    }

    // MARK: - ios-test-076: fail

    // verifies: ios-contract-06（ios-test-076）
    // MARK: shared-session-12
    func testT076SharedSession12_failFromEveryStateErrorsWithPositionZeroAndStartRecovers() async throws {
        let a = try makeEpisode()
        let b = try makeEpisode(id: "ep-b")
        let reasons: [PlaybackErrorReason] = [.offlineUncached, .invalidSource, .fetchFailed(.server(status: 500))]

        var index = 0
        for phase in Phase.allCases {
            let reason = reasons[index % reasons.count]
            index += 1
            let rig = makeRig()
            await rig.drive(to: phase, episode: a, resume: 9)

            rig.session.fail(episodeId: b.content.id, reason: reason)

            XCTAssertEqual(rig.session.state, .errored(episodeId: b.content.id, position: 0, reason: reason), "\(phase)")
            XCTAssertFalse(rig.engine.isLoaded, "\(phase)")

            rig.start(b)
            XCTAssertEqual(rig.session.state, loading(b), "\(phase): fail の後の start で loading へ進める")
        }

        let idle = makeRig()
        idle.session.fail(episodeId: "ep-x", reason: .offlineUncached)
        XCTAssertEqual(idle.session.state, .errored(episodeId: "ep-x", position: 0, reason: .offlineUncached))
        XCTAssertFalse(idle.engine.isLoaded)
    }

    // verifies: ios-contract-06（ios-test-076。errored からの fail は値を置き換える）
    // MARK: shared-session-12
    func testT076SharedSession12_failOnErroredReplacesTheValue() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .errored, episode: a)

        rig.session.fail(episodeId: "ep-z", reason: .invalidSource)

        XCTAssertEqual(rig.session.state, .errored(episodeId: "ep-z", position: 0, reason: .invalidSource))
        XCTAssertEqual(rig.log.states.last, .errored(episodeId: "ep-z", position: 0, reason: .invalidSource))
    }

    // MARK: - ios-test-078: engine の失敗・終了と保留

    // verifies: ios-contract-07（ios-test-078）
    func testT078_failedOnLoadedStatesConvergesToErroredWithThePreviousPosition() async throws {
        let a = try makeEpisode()

        let loadingRig = makeRig()
        loadingRig.start(a, resume: 7)
        await loadingRig.engine.send(.failed(description: "load failed"))
        XCTAssertEqual(loadingRig.session.state, .errored(episodeId: a.content.id, position: 7, reason: .engineFailed(description: "load failed")))
        XCTAssertFalse(loadingRig.engine.isLoaded)

        let playingRig = makeRig()
        await playingRig.drive(to: .playing, episode: a)
        await playingRig.engine.send(.timeUpdate(seconds: 40, duration: 300))
        await playingRig.engine.send(.failed(description: nil))
        XCTAssertEqual(playingRig.session.state, .errored(episodeId: a.content.id, position: 40, reason: .engineFailed(description: nil)))

        // play() を続けて呼んでも 1 状態に収束する（errored での play() は何もしない）。
        let events = playingRig.log.events.count
        playingRig.session.play()
        playingRig.session.play()
        XCTAssertEqual(playingRig.session.state, .errored(episodeId: a.content.id, position: 40, reason: .engineFailed(description: nil)))
        XCTAssertEqual(playingRig.log.events.count, events)
    }

    // verifies: ios-contract-07（ios-test-078。paused で届いた failed は保留し、次の play() で playing → errored）
    func testT078_failedWhilePausedIsHeldAndAppliedRightAfterTheNextPlay() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .paused, episode: a)

        await rig.engine.send(.failed(description: "late"))
        XCTAssertEqual(rig.session.state, paused(a), "保留中は状態を変えない")

        let before = rig.log.states.count
        rig.session.play()

        XCTAssertEqual(Array(rig.log.states.dropFirst(before)), [
            playing(a),
            .errored(episodeId: a.content.id, position: 0, reason: .engineFailed(description: "late")),
        ])
        XCTAssertFalse(rig.engine.isLoaded)
    }

    // verifies: ios-contract-07（ios-test-078。paused で届いた ended は次の play() で playing → ended）
    func testT078_endedWhilePausedIsHeldAndAppliedRightAfterTheNextPlayWithOneEndedNotification() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .paused, episode: a)

        await rig.engine.send(.ended)
        XCTAssertEqual(rig.session.state, paused(a))
        XCTAssertTrue(rig.log.endedIds.isEmpty, "保留中は ended を通知しない")

        let before = rig.log.events.count
        rig.session.play()

        XCTAssertEqual(Array(rig.log.events.dropFirst(before)), [
            .stateChanged(playing(a)),
            .stateChanged(.ended(episode: a, duration: 300)),
            .ended(episodeId: a.content.id),
        ])
        XCTAssertEqual(rig.log.endedIds, [a.content.id], "SessionEvent.ended は 1 回")
    }

    // verifies: ios-contract-07（ios-test-078。buffering で届いた ended は playing → ended）
    func testT078_endedWhileBufferingGoesThroughPlayingToEnded() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .buffering, episode: a)
        let before = rig.log.events.count

        await rig.engine.send(.ended)

        XCTAssertEqual(Array(rig.log.events.dropFirst(before)), [
            .stateChanged(playing(a)),
            .stateChanged(.ended(episode: a, duration: 300)),
            .ended(episodeId: a.content.id),
        ])
        XCTAssertFalse(rig.engine.isLoaded)
    }

    // verifies: ios-contract-07（ios-test-078。loading で届いた ended は ready と同じに進めてから playing の欄）
    func testT078_endedWhileLoadingAdvancesLikeReadyThenEnds() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        rig.start(a)
        let before = rig.log.states.count

        await rig.engine.send(.ended)

        XCTAssertEqual(Array(rig.log.states.dropFirst(before)), [
            paused(a),
            playing(a),
            .ended(episode: a, duration: 300),
        ])
        XCTAssertEqual(rig.log.endedIds, [a.content.id])
    }

    // verifies: ios-contract-07（ios-test-078。両方が保留されていれば failed を先に扱う）
    func testT078_bothHeldFailedWinsOverEnded() async throws {
        let a = try makeEpisode()
        let rig = makeRig()
        await rig.drive(to: .paused, episode: a)
        await rig.engine.send(.ended)
        await rig.engine.send(.failed(description: "both"))

        rig.session.play()

        XCTAssertEqual(rig.session.state, .errored(episodeId: a.content.id, position: 0, reason: .engineFailed(description: "both")))
        XCTAssertTrue(rig.log.endedIds.isEmpty, "failed を先に扱うので ended は通知しない")
    }

    // verifies: ios-contract-07（ios-test-078。保留は start・stop・fail で消える）
    func testT078_heldFailureIsClearedByStartStopAndFail() async throws {
        let a = try makeEpisode()
        let b = try makeEpisode(id: "ep-b")

        let viaStart = makeRig()
        await viaStart.drive(to: .paused, episode: a)
        await viaStart.engine.send(.failed(description: "held"))
        viaStart.start(b)
        await viaStart.engine.send(.ready)
        XCTAssertEqual(viaStart.session.state, playing(b), "start が保留を消す")
        viaStart.session.pause()
        viaStart.session.play()
        XCTAssertEqual(viaStart.session.state, playing(b), "次の play() でも保留の失敗は現れない")

        let viaStop = makeRig()
        await viaStop.drive(to: .paused, episode: a)
        await viaStop.engine.send(.failed(description: "held"))
        viaStop.session.stop()
        viaStop.start(b)
        await viaStop.engine.send(.ready)
        viaStop.session.pause()
        viaStop.session.play()
        XCTAssertEqual(viaStop.session.state, playing(b), "stop が保留を消す")

        let viaFail = makeRig()
        await viaFail.drive(to: .paused, episode: a)
        await viaFail.engine.send(.ended)
        viaFail.session.fail(episodeId: a.content.id, reason: .offlineUncached)
        viaFail.start(b)
        await viaFail.engine.send(.ready)
        viaFail.session.pause()
        viaFail.session.play()
        XCTAssertEqual(viaFail.session.state, playing(b), "fail が保留を消す")
        XCTAssertTrue(viaFail.log.endedIds.isEmpty)
    }
}

private extension PlaybackState {
    var isPausedState: Bool {
        if case .paused = self { return true }
        return false
    }
}
