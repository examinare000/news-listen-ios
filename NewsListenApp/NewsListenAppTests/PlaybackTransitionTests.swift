import XCTest
@testable import NewsListenApp

/// 再生の遷移の決定（`PlaybackTransition.next`）の表駆動テスト。
///
/// 期待値は再生 Spec §3.6.2・§3.6.3 の表から手で書く（production の関数を呼んで作らない）。
/// domain の型だけを使い、application の型や I/O には触れない
/// （ios-check-08 の domain だけを参照するテストファイルの集合に入る）。
// verifies: ios-rule-playback-01, ios-test-047, ios-test-117, ios-check-07
final class PlaybackTransitionTests: XCTestCase {

    // MARK: - 土台

    private enum ExpectedOutcome: Equatable {
        /// 表の「—」。状態不変・保留不変・効果なし。
        case nothing
        case moves(state: PlaybackState, pending: PendingEngineOutcome, effects: [PlaybackEffect])
    }

    private struct TransitionCell {
        let state: PlaybackState
        let input: PlaybackInput
        let expected: ExpectedOutcome
    }

    private var episode: PlayableEpisode!

    override func setUpWithError() throws {
        let content = EpisodeContent(
            id: "ep-a", title: "題", japaneseIntroText: "導入", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: 300,
            segments: nil, vocabulary: nil, quiz: nil, sourceArticles: nil, sourceKind: nil
        )
        episode = try XCTUnwrap(PlayableEpisode(content: content, audioUrl: "https://example.com/a.mp3", serverPosition: 0))
    }

    // 状態の fixture: 位置 30・総時間 200・速度 1.5（loading は resume 30・総時間 300）。入力の値はこれらと異なる。

    private func loading(resume: Double = 30, speed: Float = 1.5) -> PlaybackState {
        .loading(episode: episode, resumePosition: resume, speed: speed)
    }

    private func playing(_ position: Double = 30, duration: Double = 200, speed: Float = 1.5) -> PlaybackState {
        .playing(episode: episode, position: position, duration: duration, speed: speed)
    }

    private func buffering(_ position: Double = 30, duration: Double = 200, speed: Float = 1.5) -> PlaybackState {
        .buffering(episode: episode, position: position, duration: duration, speed: speed)
    }

    private func paused(_ position: Double = 30, duration: Double = 200, speed: Float = 1.5) -> PlaybackState {
        .paused(episode: episode, position: position, duration: duration, speed: speed)
    }

    private func endedState(duration: Double = 200) -> PlaybackState {
        .ended(episode: episode, duration: duration)
    }

    private func erroredState(description: String? = "old") -> PlaybackState {
        .errored(episodeId: "ep-a", position: 30, reason: .engineFailed(description: description))
    }

    private func changed(_ state: PlaybackState) -> PlaybackEffect {
        .notify(.stateChanged(state))
    }

    private func command(_ command: EngineCommand) -> PlaybackEffect {
        .engine(command)
    }

    private var allStates: [PlaybackState] {
        [.idle, loading(), playing(), buffering(), paused(), endedState(), erroredState()]
    }

    private let allInputs: [PlaybackInput] = [
        .play, .pause, .seek(60), .seekRelative(15), .setSpeed(2.0),
        .engineReady, .engineResumed, .engineBuffering, .enginePaused, .engineEnded,
        .engineFailed("boom"), .engineTimeUpdate(40, 250), .engineInterrupted,
        .engineInterruptionEnded(true), .engineOutputDeviceLost,
    ]

    private let heldBoth = PendingEngineOutcome(failed: .some("held"), ended: true)

    private var allPendings: [PendingEngineOutcome] {
        [
            PendingEngineOutcome.none,
            PendingEngineOutcome(failed: .some("held"), ended: false),
            PendingEngineOutcome(failed: .some(nil), ended: false),
            PendingEngineOutcome(failed: nil, ended: true),
            heldBoth,
        ]
    }

    /// 表の「—」でない 45 セル（保留なしで駆動する）。
    private func movingCells() -> [TransitionCell] {
        let ld = loading()
        let pl = playing()
        let bf = buffering()
        let pa = paused()
        let ed = endedState()
        let er = erroredState()
        let paused300 = paused(30, duration: 300)
        let playing300 = playing(30, duration: 300)
        let ended300 = endedState(duration: 300)
        let endedNotice = PlaybackEffect.notify(.ended(episodeId: "ep-a"))
        let began = PlaybackEffect.notify(.interruption(.began(wasPlaying: true)))
        let beganIdle = PlaybackEffect.notify(.interruption(.began(wasPlaying: false)))
        let resumeAllowed = PlaybackEffect.notify(.interruption(.ended(shouldResume: true)))

        var cells: [TransitionCell] = []
        func add(
            _ state: PlaybackState, _ input: PlaybackInput, to result: PlaybackState, _ effects: [PlaybackEffect],
            pending: PendingEngineOutcome = PendingEngineOutcome.none
        ) {
            cells.append(TransitionCell(
                state: state, input: input, expected: .moves(state: result, pending: pending, effects: effects)
            ))
        }

        // 操作 16
        add(pa, .play, to: pl, [command(.setRate(1.5)), changed(pl)])

        add(ld, .pause, to: paused300, [command(.pause), changed(paused300)])
        add(pl, .pause, to: pa, [command(.pause), changed(pa)])
        add(bf, .pause, to: pa, [command(.pause), changed(pa)])

        add(ld, .seek(60), to: loading(resume: 60), [command(.seek(60)), changed(loading(resume: 60))])
        add(pl, .seek(60), to: playing(60), [command(.seek(60)), changed(playing(60))])
        add(bf, .seek(60), to: buffering(60), [command(.seek(60)), changed(buffering(60))])
        add(pa, .seek(60), to: paused(60), [command(.seek(60)), changed(paused(60))])

        add(ld, .seekRelative(15), to: loading(resume: 45), [command(.seek(45)), changed(loading(resume: 45))])
        add(pl, .seekRelative(15), to: playing(45), [command(.seek(45)), changed(playing(45))])
        add(bf, .seekRelative(15), to: buffering(45), [command(.seek(45)), changed(buffering(45))])
        add(pa, .seekRelative(15), to: paused(45), [command(.seek(45)), changed(paused(45))])

        add(ld, .setSpeed(2.0), to: loading(speed: 2.0), [command(.setRate(2.0)), changed(loading(speed: 2.0))])
        add(pl, .setSpeed(2.0), to: playing(speed: 2.0), [command(.setRate(2.0)), changed(playing(speed: 2.0))])
        add(bf, .setSpeed(2.0), to: buffering(speed: 2.0), [command(.setRate(2.0)), changed(buffering(speed: 2.0))])
        add(pa, .setSpeed(2.0), to: paused(speed: 2.0), [changed(paused(speed: 2.0))])

        // engine の事象 29
        add(ld, .engineReady, to: playing300, [changed(paused300), changed(playing300)])

        add(ld, .engineResumed, to: playing300, [changed(paused300), changed(playing300)])
        add(bf, .engineResumed, to: pl, [changed(pl)])

        add(pl, .engineBuffering, to: bf, [changed(bf)])

        add(bf, .enginePaused, to: pa, [changed(pa)])

        add(ld, .engineEnded, to: ended300,
            [changed(paused300), changed(playing300), command(.unload), changed(ended300), endedNotice])
        add(pl, .engineEnded, to: ed, [command(.unload), changed(ed), endedNotice])
        add(bf, .engineEnded, to: ed, [changed(pl), command(.unload), changed(ed), endedNotice])
        add(pa, .engineEnded, to: pa, [], pending: PendingEngineOutcome(failed: nil, ended: true))

        let failedBoom = erroredState(description: "boom")
        add(ld, .engineFailed("boom"), to: failedBoom, [command(.unload), changed(failedBoom)])
        add(pl, .engineFailed("boom"), to: failedBoom, [command(.unload), changed(failedBoom)])
        add(bf, .engineFailed("boom"), to: failedBoom, [command(.unload), changed(failedBoom)])
        add(pa, .engineFailed("boom"), to: pa, [], pending: PendingEngineOutcome(failed: .some("boom"), ended: false))

        let tickPlaying = playing(40, duration: 250)
        let tickBuffering = buffering(40, duration: 250)
        let tickPaused = paused(40, duration: 250)
        let tick = PlaybackEffect.notify(.positionChanged(seconds: 40, duration: 250))
        add(pl, .engineTimeUpdate(40, 250), to: tickPlaying, [.updateState(tickPlaying), tick])
        add(bf, .engineTimeUpdate(40, 250), to: tickBuffering, [.updateState(tickBuffering), tick])
        add(pa, .engineTimeUpdate(40, 250), to: tickPaused, [.updateState(tickPaused), tick])

        add(ld, .engineInterrupted, to: paused300, [command(.pause), changed(paused300), began])
        add(pl, .engineInterrupted, to: pa, [command(.pause), changed(pa), began])
        add(bf, .engineInterrupted, to: pa, [command(.pause), changed(pa), began])
        add(pa, .engineInterrupted, to: pa, [beganIdle])

        for state in [ld, pl, bf, pa, ed, er] {
            add(state, .engineInterruptionEnded(true), to: state, [resumeAllowed])
        }

        add(ld, .engineOutputDeviceLost, to: paused300, [command(.pause), changed(paused300)])
        add(pl, .engineOutputDeviceLost, to: pa, [command(.pause), changed(pa)])
        add(bf, .engineOutputDeviceLost, to: pa, [command(.pause), changed(pa)])

        return cells
    }

    /// 7 状態 × 15 入力の 105 セル。`movingCells` に無い組合せは「—」。
    private func makeCells() -> [TransitionCell] {
        let moving = movingCells()
        return allStates.flatMap { state in
            allInputs.map { input in
                let hit = moving.first { $0.state == state && $0.input == input }
                return TransitionCell(state: state, input: input, expected: hit?.expected ?? .nothing)
            }
        }
    }

    private func expectedResult(_ cell: TransitionCell) -> PlaybackTransitionResult {
        switch cell.expected {
        case .nothing:
            return PlaybackTransitionResult(state: cell.state, pending: PendingEngineOutcome.none, effects: [])
        case .moves(let state, let pending, let effects):
            return PlaybackTransitionResult(state: state, pending: pending, effects: effects)
        }
    }

    private func kind(_ state: PlaybackState) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .buffering: return "buffering"
        case .paused: return "paused"
        case .ended: return "ended"
        case .errored: return "errored"
        }
    }

    private func check(
        _ state: PlaybackState, _ input: PlaybackInput, to result: PlaybackState, _ effects: [PlaybackEffect],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = PlaybackTransition.next(state: state, pending: PendingEngineOutcome.none, input: input)
        XCTAssertEqual(
            actual, PlaybackTransitionResult(state: result, pending: PendingEngineOutcome.none, effects: effects),
            "\(state) × \(input)", file: file, line: line
        )
    }

    // MARK: - 105 セル

    // verifies: ios-rule-playback-01, ios-test-047
    func testT047_everyCellOfTheOperationAndEngineEventTablesMatches() {
        let cells = makeCells()
        XCTAssertEqual(cells.count, 105)
        XCTAssertEqual(cells.filter { $0.expected != .nothing }.count, 45)

        for cell in cells {
            let actual = PlaybackTransition.next(state: cell.state, pending: PendingEngineOutcome.none, input: cell.input)
            XCTAssertEqual(actual, expectedResult(cell), "\(cell.state) × \(cell.input)")
        }
    }

    // verifies: ios-rule-playback-01, ios-test-047
    func testT047_transitionKindsAreExactlyTheTableEdgesPlusInPlaceUpdates() {
        var edges = Set<String>()
        for cell in makeCells() {
            var previous = kind(cell.state)
            for effect in PlaybackTransition.next(state: cell.state, pending: PendingEngineOutcome.none, input: cell.input).effects {
                switch effect {
                case .notify(.stateChanged(let next)):
                    edges.insert("\(previous)→\(kind(next))")
                    previous = kind(next)
                case .updateState(let next):
                    previous = kind(next)
                case .engine, .notify:
                    break
                }
            }
        }

        let expected: Set<String> = [
            "loading→paused", "loading→errored", "paused→playing", "paused→paused",
            "playing→paused", "playing→buffering", "buffering→playing", "buffering→paused",
            "playing→ended", "playing→errored", "buffering→errored",
            "loading→loading", "playing→playing", "buffering→buffering",
        ]
        XCTAssertEqual(expected.count, 14)
        XCTAssertEqual(edges, expected)
    }

    // verifies: ios-rule-playback-01
    func testStateChangedNeverRepeatsAndFinalStateIsTheLastCommittedState() {
        var driven = 0
        for pending in allPendings {
            for cell in makeCells() {
                driven += 1
                let result = PlaybackTransition.next(state: cell.state, pending: pending, input: cell.input)
                var current = cell.state
                for effect in result.effects {
                    switch effect {
                    case .notify(.stateChanged(let next)):
                        XCTAssertNotEqual(next, current, "重複: \(cell.state) × \(cell.input) × \(pending)")
                        current = next
                    case .updateState(let next):
                        current = next
                    case .engine, .notify:
                        break
                    }
                }
                XCTAssertEqual(result.state, current, "\(cell.state) × \(cell.input) × \(pending)")
            }
        }
        XCTAssertEqual(driven, 105 * 5)
    }

    // MARK: - 保留

    // verifies: ios-rule-playback-01
    func testPausedFailedAndEndedAreHeldAndTheLatestFailureWins() {
        let pa = paused()
        let cases: [(start: PendingEngineOutcome, input: PlaybackInput, expected: PendingEngineOutcome)] = [
            (PendingEngineOutcome(failed: .some("a"), ended: false), .engineFailed("b"),
             PendingEngineOutcome(failed: .some("b"), ended: false)),
            (PendingEngineOutcome(failed: .some("a"), ended: false), .engineFailed(nil),
             PendingEngineOutcome(failed: .some(nil), ended: false)),
            (PendingEngineOutcome(failed: .some(nil), ended: false), .engineFailed("b"),
             PendingEngineOutcome(failed: .some("b"), ended: false)),
            (PendingEngineOutcome(failed: .some("a"), ended: true), .engineFailed("b"),
             PendingEngineOutcome(failed: .some("b"), ended: true)),
            (PendingEngineOutcome(failed: .some("a"), ended: false), .engineEnded,
             PendingEngineOutcome(failed: .some("a"), ended: true)),
            (PendingEngineOutcome(failed: nil, ended: true), .engineEnded,
             PendingEngineOutcome(failed: nil, ended: true)),
        ]
        XCTAssertEqual(cases.count, 6)

        for item in cases {
            let result = PlaybackTransition.next(state: pa, pending: item.start, input: item.input)
            XCTAssertEqual(
                result, PlaybackTransitionResult(state: pa, pending: item.expected, effects: []),
                "\(item.start) × \(item.input)"
            )
        }
    }

    // verifies: ios-rule-playback-01
    func testPlayWithHeldOutcomeEntersPlayingThenErroredOrEnded() {
        let pa = paused()
        let pl = playing()
        let resume: [PlaybackEffect] = [command(.setRate(1.5)), changed(pl)]
        let endedTail: [PlaybackEffect] = [
            command(.unload), changed(endedState()), .notify(.ended(episodeId: "ep-a")),
        ]
        let heldError = erroredState(description: "held")
        let silentError = erroredState(description: nil)

        let cases: [(pending: PendingEngineOutcome, final: PlaybackState, effects: [PlaybackEffect])] = [
            (PendingEngineOutcome.none, pl, resume),
            (PendingEngineOutcome(failed: .some("held"), ended: false), heldError,
             resume + [command(.unload), changed(heldError)]),
            (PendingEngineOutcome(failed: .some(nil), ended: false), silentError,
             resume + [command(.unload), changed(silentError)]),
            (PendingEngineOutcome(failed: nil, ended: true), endedState(), resume + endedTail),
            (heldBoth, heldError, resume + [command(.unload), changed(heldError)]),
        ]
        XCTAssertEqual(cases.count, 5)

        for item in cases {
            let result = PlaybackTransition.next(state: pa, pending: item.pending, input: .play)
            XCTAssertEqual(
                result,
                PlaybackTransitionResult(state: item.final, pending: PendingEngineOutcome.none, effects: item.effects),
                "\(item.pending)"
            )
        }
    }

    // verifies: ios-rule-playback-01
    func testHeldOutcomeIsPassedThroughEverywhereExceptPausedPlayAndPausedFailed() {
        let held = heldBoth
        let pa = paused()
        var passedThrough = 0

        for cell in makeCells() {
            let result = PlaybackTransition.next(state: cell.state, pending: held, input: cell.input)
            let expected = expectedResult(cell)

            if cell.state == pa && cell.input == .play {
                continue
            }
            if cell.state == pa && cell.input == .engineFailed("boom") {
                continue
            }
            passedThrough += 1
            XCTAssertEqual(result.state, expected.state, "\(cell.state) × \(cell.input)")
            XCTAssertEqual(result.effects, expected.effects, "\(cell.state) × \(cell.input)")
            XCTAssertEqual(result.pending, held, "\(cell.state) × \(cell.input)")
        }
        XCTAssertEqual(passedThrough, 103)

        // 対照: 保留が効く 2 つの入口。
        let playResult = PlaybackTransition.next(state: pa, pending: held, input: .play)
        let withoutHeld = PlaybackTransition.next(state: pa, pending: PendingEngineOutcome.none, input: .play)
        XCTAssertNotEqual(playResult.effects, withoutHeld.effects)
        XCTAssertEqual(Array(playResult.effects.prefix(withoutHeld.effects.count)), withoutHeld.effects)
        XCTAssertEqual(playResult.effects.last, changed(erroredState(description: "held")))
        XCTAssertEqual(playResult.pending, PendingEngineOutcome.none)

        let failResult = PlaybackTransition.next(state: pa, pending: held, input: .engineFailed("boom"))
        XCTAssertEqual(failResult.state, pa)
        XCTAssertEqual(failResult.effects, [])
        XCTAssertEqual(failResult.pending, PendingEngineOutcome(failed: .some("boom"), ended: true))
        XCTAssertNotEqual(failResult.pending, held)
    }

    // MARK: - 重複・丸め・速度

    // verifies: ios-rule-playback-01
    func testSameValueOperationsEmitNoStateChangedButStillCommandTheEngine() {
        let ld = loading()
        let pl = playing()
        let bf = buffering()
        let pa = paused()

        check(ld, .seek(30), to: ld, [command(.seek(30))])
        check(pl, .seek(30), to: pl, [command(.seek(30))])
        check(bf, .seek(30), to: bf, [command(.seek(30))])
        check(pa, .seek(30), to: pa, [command(.seek(30))])

        check(ld, .setSpeed(1.5), to: ld, [command(.setRate(1.5))])
        check(pl, .setSpeed(1.5), to: pl, [command(.setRate(1.5))])
        check(bf, .setSpeed(1.5), to: bf, [command(.setRate(1.5))])
        check(pa, .setSpeed(1.5), to: pa, [])

        // 上限に丸まって同じ値になる seek も engine への指示だけ。
        let atEnd = playing(200)
        check(atEnd, .seek(999), to: atEnd, [command(.seek(200))])
        let loadingAtEnd = loading(resume: 300)
        check(loadingAtEnd, .seek(999), to: loadingAtEnd, [command(.seek(300))])
    }

    // verifies: ios-rule-playback-01
    func testSpeedOutsideTheChoicesIsIgnoredSeekIsClampedAndDurationUpdatesOnlyWhenPositive() {
        // 選択肢に無い速度は全状態で「—」。
        for state in allStates {
            for speed: Float in [0.6, 3.0] {
                check(state, .setSpeed(speed), to: state, [])
            }
        }

        // 下限 0。
        check(loading(), .seek(-5), to: loading(resume: 0), [command(.seek(0)), changed(loading(resume: 0))])
        check(playing(), .seek(-5), to: playing(0), [command(.seek(0)), changed(playing(0))])
        check(buffering(), .seek(-5), to: buffering(0), [command(.seek(0)), changed(buffering(0))])
        check(paused(), .seek(-5), to: paused(0), [command(.seek(0)), changed(paused(0))])

        // 上限: loading は durationSeconds（300）、他は状態の総時間（200）。
        check(loading(), .seek(999), to: loading(resume: 300), [command(.seek(300)), changed(loading(resume: 300))])
        check(playing(), .seek(999), to: playing(200), [command(.seek(200)), changed(playing(200))])
        check(buffering(), .seek(999), to: buffering(200), [command(.seek(200)), changed(buffering(200))])
        check(paused(), .seek(999), to: paused(200), [command(.seek(200)), changed(paused(200))])

        // 総時間 0 は下限だけで丸める。
        check(
            paused(30, duration: 0), .seek(999), to: paused(999, duration: 0),
            [command(.seek(999)), changed(paused(999, duration: 0))]
        )

        // timeUpdate の総時間は正のときだけ置き換える。
        for reported in [0.0, -1.0] {
            let tick = PlaybackEffect.notify(.positionChanged(seconds: 40, duration: 200))
            check(playing(), .engineTimeUpdate(40, reported), to: playing(40), [.updateState(playing(40)), tick])
            check(buffering(), .engineTimeUpdate(40, reported), to: buffering(40), [.updateState(buffering(40)), tick])
            check(paused(), .engineTimeUpdate(40, reported), to: paused(40), [.updateState(paused(40)), tick])
        }
    }

    // MARK: - 純関数であること

    // verifies: ios-check-07, ios-test-117
    func testT117_mutatingTheReturnedEffectsDoesNotChangeTheNextCallAndCallsAreRepeatable() {
        var mutated = 0
        for cell in makeCells() where cell.expected != .nothing {
            let first = PlaybackTransition.next(state: cell.state, pending: heldBoth, input: cell.input)
            XCTAssertEqual(
                first, PlaybackTransition.next(state: cell.state, pending: heldBoth, input: cell.input),
                "\(cell.state) × \(cell.input)"
            )
            guard !first.effects.isEmpty else { continue }

            var effects = first.effects
            effects.removeAll()
            effects.append(.engine(.unload))
            mutated += 1

            let second = PlaybackTransition.next(state: cell.state, pending: heldBoth, input: cell.input)
            XCTAssertEqual(second, first, "\(cell.state) × \(cell.input)")
            XCTAssertNotEqual(effects, second.effects)
        }
        XCTAssertEqual(mutated, 43)
    }
}
