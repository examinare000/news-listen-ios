import XCTest
@testable import NewsListenApp

/// 通知を受けた時点の `PlaybackSession.state` と engine の状態を固定する特性化テスト。
///
/// 遷移の決定を domain へ移しても、通知の二重・欠落・順序違いが起きないことを守る。
/// `PlaybackSession` を参照するので domain だけを参照するテストファイルの集合には登録しない。
// verifies: ios-rule-playback-01, ios-dec-115
@MainActor
final class PlaybackSessionDeliveryTests: XCTestCase {

    // MARK: - 土台

    /// 通知を受けた瞬間の状態を写し取った 1 件。
    private struct Delivery {
        let event: SessionEvent
        let state: PlaybackState
        let engineLoaded: Bool
        let engineRate: Float
    }

    private final class Recorder {
        var deliveries: [Delivery] = []
        var events: [SessionEvent] { deliveries.map(\.event) }
    }

    private enum Stage {
        case loading, playing, buffering, paused
    }

    private struct Rig {
        let engine: AudioEngineDouble
        let session: PlaybackSession
        let recorder: Recorder
    }

    private let url = URL(string: "https://storage.example.com/a.mp3")!

    private func makeEpisode() throws -> PlayableEpisode {
        let content = EpisodeContent(
            id: "ep-a", title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
        return try XCTUnwrap(PlayableEpisode(content: content, audioUrl: url.absoluteString, serverPosition: 0))
    }

    private func makeRig() -> Rig {
        let engine = AudioEngineDouble()
        let session = PlaybackSession(engine: engine)
        let recorder = Recorder()
        session.observe { [weak session] event in
            guard let session else { return }
            recorder.deliveries.append(Delivery(
                event: event, state: session.state, engineLoaded: engine.isLoaded, engineRate: engine.rate
            ))
        }
        return Rig(engine: engine, session: session, recorder: recorder)
    }

    /// 位置 30・速度 1.5 で開始し、`stage` まで進める。
    private func drive(_ rig: Rig, to stage: Stage, episode: PlayableEpisode) async {
        rig.session.start(episode: episode, url: url, resumePosition: 30, speed: 1.5)
        if stage == .loading { return }
        await rig.engine.send(.ready)
        switch stage {
        case .buffering:
            await rig.engine.send(.buffering)
        case .paused:
            rig.session.pause()
        case .loading, .playing:
            break
        }
    }

    /// `from` 以降（トリガの後）に届いた `stateChanged` のうち、`matches` を満たすもの。
    private func deliveries(
        _ recorder: Recorder, from start: Int = 0, whereState matches: (PlaybackState) -> Bool
    ) -> [Delivery] {
        recorder.deliveries.dropFirst(start).filter {
            if case .stateChanged(let state) = $0.event { return matches(state) }
            return false
        }
    }

    private func isErrored(_ state: PlaybackState) -> Bool {
        if case .errored = state { return true }
        return false
    }

    private func isPlaying(_ state: PlaybackState) -> Bool {
        if case .playing = state { return true }
        return false
    }

    private func isPaused(_ state: PlaybackState) -> Bool {
        if case .paused = state { return true }
        return false
    }

    // MARK: - 通知の時点の state

    func testSessionStateAtEachNotificationEqualsTheNotifiedState() async throws {
        let e = try makeEpisode()
        let rig = makeRig()

        rig.session.start(episode: e, url: url, resumePosition: 30, speed: 1.5)
        await rig.engine.send(.ready)
        await rig.engine.send(.timeUpdate(seconds: 40, duration: 250))
        await rig.engine.send(.buffering)
        await rig.engine.send(.resumed)
        rig.session.seek(to: 60)
        rig.session.setSpeed(2.0)
        rig.session.pause()
        await rig.engine.send(.failed(description: "boom"))
        rig.session.play()

        let expected: [SessionEvent] = [
            .stateChanged(.loading(episode: e, resumePosition: 30, speed: 1.5)),
            .stateChanged(.paused(episode: e, position: 30, duration: 300, speed: 1.5)),
            .stateChanged(.playing(episode: e, position: 30, duration: 300, speed: 1.5)),
            .positionChanged(seconds: 40, duration: 250),
            .stateChanged(.buffering(episode: e, position: 40, duration: 250, speed: 1.5)),
            .stateChanged(.playing(episode: e, position: 40, duration: 250, speed: 1.5)),
            .stateChanged(.playing(episode: e, position: 60, duration: 250, speed: 1.5)),
            .stateChanged(.playing(episode: e, position: 60, duration: 250, speed: 2.0)),
            .stateChanged(.paused(episode: e, position: 60, duration: 250, speed: 2.0)),
            .stateChanged(.playing(episode: e, position: 60, duration: 250, speed: 2.0)),
            .stateChanged(.errored(episodeId: "ep-a", position: 60, reason: .engineFailed(description: "boom"))),
        ]
        XCTAssertEqual(rig.recorder.events, expected)
        XCTAssertFalse(rig.recorder.deliveries.isEmpty)

        for delivery in rig.recorder.deliveries {
            switch delivery.event {
            case .stateChanged(let notified):
                XCTAssertEqual(delivery.state, notified)
            case .positionChanged(let seconds, let duration):
                XCTAssertEqual(delivery.state.position, seconds)
                XCTAssertEqual(delivery.state.duration, duration)
            case .ended, .interruption:
                break
            }
        }
    }

    // MARK: - engine の状態との前後関係

    func testEngineIsUnloadedBeforeTheTerminalStateIsDelivered() async throws {
        let e = try makeEpisode()

        for stage in [Stage.loading, .playing, .buffering] {
            let rig = makeRig()
            await drive(rig, to: stage, episode: e)
            await rig.engine.send(.failed(description: "boom"))

            let errored = deliveries(rig.recorder, whereState: isErrored)
            XCTAssertEqual(errored.count, 1, "\(stage)")
            XCTAssertEqual(errored.map(\.engineLoaded), [false], "\(stage)")
        }

        // 保留つきの play: playing の通知の時点は読込済みで速度が掛かっている。errored の時点は未読込。
        let rig = makeRig()
        await drive(rig, to: .paused, episode: e)
        await rig.engine.send(.failed(description: "boom"))
        let mark = rig.recorder.deliveries.count
        rig.session.play()

        let playing = deliveries(rig.recorder, from: mark, whereState: isPlaying)
        XCTAssertEqual(playing.count, 1)
        XCTAssertEqual(playing.map(\.engineLoaded), [true])
        XCTAssertEqual(playing.map(\.engineRate), [1.5])
        let errored = deliveries(rig.recorder, from: mark, whereState: isErrored)
        XCTAssertEqual(errored.count, 1)
        XCTAssertEqual(errored.map(\.engineLoaded), [false])
    }

    func testEngineIsUnloadedWhenEndedIsDelivered() async throws {
        let e = try makeEpisode()

        let direct = makeRig()
        await drive(direct, to: .playing, episode: e)
        await direct.engine.send(.ended)

        let held = makeRig()
        await drive(held, to: .paused, episode: e)
        await held.engine.send(.ended)
        let heldMark = held.recorder.deliveries.count
        held.session.play()

        for (label, rig) in [("playing", direct), ("held", held)] {
            let endedStates = deliveries(rig.recorder, whereState: { $0.isEnded })
            XCTAssertEqual(endedStates.count, 1, label)
            XCTAssertEqual(endedStates.map(\.engineLoaded), [false], label)

            let endedEvents = rig.recorder.deliveries.filter {
                if case .ended = $0.event { return true }
                return false
            }
            XCTAssertEqual(endedEvents.count, 1, label)
            XCTAssertEqual(endedEvents.map(\.engineLoaded), [false], label)
            XCTAssertEqual(endedEvents.map(\.event), [.ended(episodeId: "ep-a")], label)
        }

        let heldPlaying = deliveries(held.recorder, from: heldMark, whereState: isPlaying)
        XCTAssertEqual(heldPlaying.map(\.engineLoaded), [true])
    }

    func testEnginePauseHappensBeforeThePausedNotification() async throws {
        let e = try makeEpisode()

        for stage in [Stage.loading, .playing, .buffering] {
            // interrupted
            let interrupted = makeRig()
            await drive(interrupted, to: stage, episode: e)
            XCTAssertNotEqual(interrupted.engine.rate, 0, "\(stage)")
            let interruptedMark = interrupted.recorder.deliveries.count
            await interrupted.engine.send(.interrupted)
            let pausedAfterInterrupt = deliveries(interrupted.recorder, from: interruptedMark, whereState: isPaused)
            XCTAssertEqual(pausedAfterInterrupt.count, 1, "\(stage)")
            XCTAssertEqual(pausedAfterInterrupt.map(\.engineRate), [0], "\(stage)")
            XCTAssertEqual(interrupted.recorder.events.last, .interruption(.began(wasPlaying: true)), "\(stage)")

            // outputDeviceLost
            let deviceLost = makeRig()
            await drive(deviceLost, to: stage, episode: e)
            XCTAssertNotEqual(deviceLost.engine.rate, 0, "\(stage)")
            let lostMark = deviceLost.recorder.deliveries.count
            await deviceLost.engine.send(.outputDeviceLost)
            let pausedAfterLoss = deliveries(deviceLost.recorder, from: lostMark, whereState: isPaused)
            XCTAssertEqual(pausedAfterLoss.count, 1, "\(stage)")
            XCTAssertEqual(pausedAfterLoss.map(\.engineRate), [0], "\(stage)")

            // pause()
            let direct = makeRig()
            await drive(direct, to: stage, episode: e)
            XCTAssertNotEqual(direct.engine.rate, 0, "\(stage)")
            let pauseMark = direct.recorder.deliveries.count
            direct.session.pause()
            let pausedAfterPause = deliveries(direct.recorder, from: pauseMark, whereState: isPaused)
            XCTAssertEqual(pausedAfterPause.count, 1, "\(stage)")
            XCTAssertEqual(pausedAfterPause.map(\.engineRate), [0], "\(stage)")
        }
    }

    // MARK: - 値が変わらない操作

    func testOperationsThatKeepTheValueEmitNoStateChangedButStillCommandTheEngine() async throws {
        let e = try makeEpisode()
        let rig = makeRig()
        await drive(rig, to: .playing, episode: e)
        let before = deliveries(rig.recorder, whereState: { _ in true }).count

        // double を直接動かして、session の指示で戻ることを観測する。
        rig.engine.seek(to: 99)
        rig.engine.setRate(0.5)
        rig.session.seek(to: 30)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 30)
        rig.session.setSpeed(1.5)
        XCTAssertEqual(rig.engine.rate, 1.5)

        XCTAssertEqual(deliveries(rig.recorder, whereState: { _ in true }).count, before)
        XCTAssertEqual(rig.session.state, .playing(episode: e, position: 30, duration: 300, speed: 1.5))

        // paused の同速度は engine を動かさない（rate は 0 のまま）。
        rig.session.pause()
        let afterPause = deliveries(rig.recorder, whereState: { _ in true }).count
        XCTAssertEqual(rig.engine.rate, 0)
        rig.session.setSpeed(1.5)
        XCTAssertEqual(rig.engine.rate, 0)
        XCTAssertEqual(deliveries(rig.recorder, whereState: { _ in true }).count, afterPause)
    }

    // MARK: - handler からの再入

    func testHandlerMayCallPlayInsideTheInterruptionEndedNotification() async throws {
        let e = try makeEpisode()
        let rig = makeRig()
        rig.session.observe { [weak session = rig.session] event in
            if case .interruption(.ended(shouldResume: true)) = event { session?.play() }
        }
        await drive(rig, to: .playing, episode: e)
        await rig.engine.send(.interrupted)
        XCTAssertEqual(rig.session.state, .paused(episode: e, position: 30, duration: 300, speed: 1.5))
        let playingBefore = deliveries(rig.recorder, whereState: isPlaying).count

        await rig.engine.send(.interruptionEnded(shouldResume: true))

        let playing = deliveries(rig.recorder, whereState: isPlaying)
        XCTAssertEqual(playing.count - playingBefore, 1)
        XCTAssertEqual(rig.session.state, .playing(episode: e, position: 30, duration: 300, speed: 1.5))
        XCTAssertEqual(rig.engine.rate, 1.5)
        let tail = Array(rig.recorder.events.suffix(2))
        XCTAssertEqual(tail, [
            .interruption(.ended(shouldResume: true)),
            .stateChanged(.playing(episode: e, position: 30, duration: 300, speed: 1.5)),
        ])
    }
}
