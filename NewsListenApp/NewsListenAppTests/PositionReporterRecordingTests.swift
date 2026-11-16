import Combine
import XCTest
import os
@testable import NewsListenApp

/// `PositionReporter` が位置を「記録してから送る」契約のテスト（契機・時刻・再送・離脱・応答の取り込み）。
///
/// 注入した時計・gateway double・`InMemoryPositionStore` 上の `PositionRecords`（主体 A を束縛）で観測する。
/// 時計は秒単位でしか進めない（記録の時刻はミリ秒に切り捨てられるので、小数の誤差で時刻が衝突しない）。
/// Task の完了は固定時間ではなく、呼出の到着を待って確かめる。「送らない」は静止（`settle`）の後の呼出列で確かめる。
@MainActor
final class PositionReporterRecordingTests: XCTestCase {

    // MARK: - 土台

    private struct Update: Equatable {
        let id: String
        let seconds: Double
        let recordedAt: Date
    }

    private enum Call: Equatable {
        case update(String, Double)
        case mark(String)
        case completionRecorded
    }

    private final class Gateway: @unchecked Sendable {
        private struct State {
            var calls: [Call] = []
            var updates: [Update] = []
            var saved: [Episode] = []
            var updateError: Error?
            var holdIds: Set<String> = []
            var parked: [Int: CheckedContinuation<Void, Never>] = [:]
            var released: Set<Int> = []
            var holdMark = false
            var markReleased = false
            var markWaiter: CheckedContinuation<Void, Never>?
            /// 応答（位置と記録時刻）。既定は送った位置・時刻なし。
            var respond: @Sendable (Update) -> (Double, Date?) = { ($0.seconds, nil) }
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        var calls: [Call] { lock.withLock { $0.calls } }
        var updates: [Update] { lock.withLock { $0.updates } }
        var saved: [Episode] { lock.withLock { $0.saved } }
        var updateError: Error? {
            get { lock.withLock { $0.updateError } }
            set { lock.withLock { $0.updateError = newValue } }
        }
        var holdMark: Bool {
            get { lock.withLock { $0.holdMark } }
            set { lock.withLock { $0.holdMark = newValue } }
        }
        var respond: @Sendable (Update) -> (Double, Date?) {
            get { lock.withLock { $0.respond } }
            set { lock.withLock { $0.respond = newValue } }
        }

        func hold(_ id: String) { lock.withLock { _ = $0.holdIds.insert(id) } }
        func unhold(_ id: String) { lock.withLock { _ = $0.holdIds.remove(id) } }

        /// `updates` の `index` 番目の呼出（保留中でも、これから保留に入るものでもよい）の応答を返す。
        func release(_ index: Int) {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock { state in
                state.released.insert(index)
                return state.parked.removeValue(forKey: index)
            }
            waiter?.resume()
        }

        func updatePosition(_ id: String, _ seconds: Double, _ recordedAt: Date) async throws -> Episode {
            let update = Update(id: id, seconds: seconds, recordedAt: recordedAt)
            let (index, shouldHold) = lock.withLock { state -> (Int, Bool) in
                state.calls.append(.update(id, seconds))
                state.updates.append(update)
                return (state.updates.count - 1, state.holdIds.contains(id))
            }
            if shouldHold {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = lock.withLock { state in
                        if state.released.contains(index) { return true }
                        state.parked[index] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            let (error, respond) = lock.withLock { ($0.updateError, $0.respond) }
            if let error { throw error }
            let (position, time) = respond(update)
            return Self.response(id: id, seconds: position, recordedAt: time)
        }

        func markCompleted(_ id: String) async throws {
            lock.withLock { $0.calls.append(.mark(id)) }
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

        func positionSaved(_ episode: Episode) { lock.withLock { $0.saved.append(episode) } }

        func completionRecorded() async { lock.withLock { $0.calls.append(.completionRecorded) } }

        static func response(id: String, seconds: Double, recordedAt: Date?) -> Episode {
            .playable(PlayableEpisode(
                content: EntryFixture.content(id), audioUrl: "https://example.com/\(id).mp3",
                serverPosition: seconds, serverRecordedAt: recordedAt)!)
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
        let store = InMemoryPositionStore()
        let records: PositionRecords
        let connectivity = PassthroughSubject<Bool, Never>()
        let url = URL(string: "https://storage.example.com/a.mp3")!

        init(bound: SubjectKey? = subjectA) {
            let gateway = self.gateway
            let clock = self.clock
            session = PlaybackSession(engine: engine)
            records = PositionRecords(store: store.store)
            records.bind(subject: bound)
            reporter = PositionReporter(
                updatePosition: { id, seconds, at in try await gateway.updatePosition(id, seconds, at) },
                markCompleted: { id in try await gateway.markCompleted(id) },
                onPositionSaved: { gateway.positionSaved($0) },
                onCompletionRecorded: { await gateway.completionRecorded() },
                beginBackgroundTask: { {} },
                records: records,
                connectivity: connectivity.eraseToAnyPublisher(),
                now: { clock.now })
            reporter.attach(session)
        }

        func episode(_ id: String, durationSeconds: Int = 300) -> PlayableEpisode {
            PlayableEpisode(
                content: EntryFixture.content(id, duration: durationSeconds),
                audioUrl: url.absoluteString, serverPosition: 0)!
        }

        func startPlaying(_ id: String, resume: Double = 0) async {
            session.start(episode: episode(id), url: url, resumePosition: resume, speed: 1.0)
            await engine.send(.ready)
        }

        func tick(_ position: Double, duration: Double = 300) async {
            await engine.send(.timeUpdate(seconds: position, duration: duration))
        }

        func finish(_ id: String, position: Double = 299, duration: Double = 300) async {
            await startPlaying(id)
            await tick(position, duration: duration)
            await engine.send(.ended)
        }

        /// 再生中の `id` が `position` にいる状態で、位置を記録して送る（flush）。
        func play(_ id: String, at position: Double) async {
            await startPlaying(id)
            await tick(position)
        }

        var livePosition: Double? {
            switch session.state {
            case .playing(_, let position, _, _), .paused(_, let position, _, _), .buffering(_, let position, _, _):
                return position
            default:
                return nil
            }
        }
    }

    private func waitUntil(
        _ what: String, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if !condition() { XCTFail("待ち条件が満たされなかった: \(what)", file: file, line: line) }
    }

    private func waitForUpdates(_ rig: Rig, _ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("update が \(count) 件", file: file, line: line) { rig.gateway.updates.count >= count }
    }

    /// 動き出す Task が尽きるのを、固定回数の yield と短い sleep で待つ（「それ以上は起きない」の確認用）。
    private func settle() async {
        for _ in 0..<25 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func unsentSummary(_ rig: Rig) -> [String] {
        rig.records.unsent().map { "\($0.episodeId):\(Int($0.seconds))" }
    }

    // MARK: - 契機と記録の時刻

    // verifies: ios-rule-playback-07, ios-cmd-playback-23
    // kills: 記録の時刻を送信の時点で取る／送信の時刻と記録の時刻が違う
    func testPeriodicTickRecordsWithTheClockTimeAtTheTrigger() async throws {
        let rig = Rig()
        await rig.startPlaying("a")

        rig.clock.advance(15)
        let firstTrigger = rig.clock.now
        await rig.tick(15)
        await waitForUpdates(rig, 1)
        XCTAssertEqual(rig.gateway.updates, [Update(id: "a", seconds: 15, recordedAt: firstTrigger)])
        XCTAssertEqual(rig.store.stored(for: subjectA).first?.recordedAt, firstTrigger)

        // 送信を保留して時計を進めても、記録の時刻は契機の時点のまま。
        rig.gateway.hold("a")
        rig.clock.advance(15)
        let secondTrigger = rig.clock.now
        await rig.tick(30)
        await waitForUpdates(rig, 2)
        rig.clock.advance(100)

        XCTAssertEqual(rig.gateway.updates[1].recordedAt, secondTrigger)
        XCTAssertEqual(rig.store.stored(for: subjectA).first?.recordedAt, secondTrigger)
        XCTAssertEqual(rig.store.stored(for: subjectA).first?.isSent, false, "応答前は未送信")
        rig.gateway.release(1)
    }

    // verifies: ios-rule-playback-07
    // kills: engine 起因の一時停止・buffering からの一時停止を記録しない／二重に記録する
    func testPauseTransitionRecordsOnceIncludingEngineInitiatedPause() async throws {
        let userPause = Rig()
        await userPause.play("a", at: 2)
        userPause.session.pause()
        await waitForUpdates(userPause, 1)
        await settle()
        XCTAssertEqual(userPause.gateway.updates.map(\.seconds), [2])

        let interrupted = Rig()
        await interrupted.play("a", at: 8)
        await interrupted.engine.send(.interrupted)
        await waitForUpdates(interrupted, 1)
        await settle()
        XCTAssertEqual(interrupted.gateway.updates.map(\.seconds), [8])

        let buffering = Rig()
        await buffering.play("a", at: 9)
        await buffering.engine.send(.buffering)
        await buffering.engine.send(.paused)
        await waitForUpdates(buffering, 1)
        await settle()
        XCTAssertEqual(buffering.gateway.updates.map(\.seconds), [9])
        XCTAssertEqual(buffering.store.stored(for: subjectA).count, 1)
    }

    // verifies: ios-rule-playback-07, shared-session-05
    // kills: 背景・停止・キューからの削除・別エピソードの開始のどれかで記録しない
    func testFlushRecordsForBackgroundStopAndSwitchTriggers() async throws {
        let triggers: [(String, @MainActor (PlaybackEntryRig) async throws -> Void)] = [
            ("flushPosition", { rig in rig.viewModel.flushPosition() }),
            ("stop", { rig in rig.viewModel.stop() }),
            ("removeFromQueue", { rig in rig.viewModel.removeFromQueue(id: "a") }),
            ("別エピソードの開始", { rig in try await rig.play("b") }),
        ]
        for (label, trigger) in triggers {
            let rig = PlaybackEntryRig()
            try await rig.play("a")
            await rig.engine.send(.timeUpdate(seconds: 30, duration: 300))

            try await trigger(rig)
            await waitUntil("\(label): 送信") { rig.gateway.updates.count >= 1 }
            await settle()

            XCTAssertEqual(rig.gateway.updates.map(\.id), ["a"], label)
            XCTAssertEqual(rig.gateway.updates.map(\.seconds), [30], label)
            XCTAssertEqual(rig.gateway.recordedAts.count, 1, label)
            XCTAssertEqual(rig.store.stored(for: subjectA).map(\.episodeId), ["a"], "\(label): 記録が 1 件")
            XCTAssertEqual(rig.store.stored(for: subjectA).first?.seconds, 30, label)
        }
    }

    // verifies: ios-rule-playback-07, shared-session-05
    // kills: idle・loading・ended・errored で記録する／束縛なしで記録し、束縛後の同じ位置を送らない
    func testNoRecordInIdleLoadingEndedErroredAndWhileUnbound() async throws {
        let idle = Rig()
        idle.reporter.flush()

        let loading = Rig()
        loading.session.start(episode: loading.episode("a"), url: loading.url, resumePosition: 0, speed: 1.0)
        loading.reporter.flush()

        let ended = Rig()
        await ended.finish("a")
        ended.reporter.flush()

        let errored = Rig()
        await errored.play("a", at: 5)
        await errored.engine.send(.failed(description: "boom"))
        errored.reporter.flush()

        await settle()
        for (label, rig) in [("idle", idle), ("loading", loading), ("ended", ended)] {
            XCTAssertEqual(rig.store.writeCount, 0, label)
            XCTAssertTrue(rig.gateway.updates.isEmpty, label)
        }
        XCTAssertEqual(errored.store.writeCount, 0, "errored")
        XCTAssertTrue(errored.gateway.updates.isEmpty, "errored")

        // 束縛なし: 記録も送信もしない。その間に「記録済みの位置」を更新しない。
        let unbound = Rig(bound: nil)
        await unbound.play("a", at: 20)
        unbound.reporter.flush()
        await settle()
        XCTAssertEqual(unbound.store.writeCount, 0)
        XCTAssertTrue(unbound.gateway.updates.isEmpty)

        // 対照: 同じ位置のまま A を束縛して flush すれば、記録して送る。
        unbound.records.bind(subject: subjectA)
        unbound.reporter.flush()
        await waitForUpdates(unbound, 1)
        XCTAssertEqual(unbound.gateway.updates.map(\.seconds), [20])
        XCTAssertEqual(unbound.store.stored(for: subjectA).first?.seconds, 20)
    }

    // MARK: - 完聴

    // verifies: ios-rule-playback-07, shared-session-07
    // kills: 位置の記録を通信の後に回す／完聴の位置を二重に送る／再送が完聴の記録に割り込む／離脱後も完聴の位置を送る
    func testCompletionRecordsDurationBeforeTheNetworkCallAndSendsItOnce() async throws {
        // (i) 呼出の直後に記録があり、順は mark → update → completionRecorded。
        let basic = Rig()
        await basic.finish("a")
        let completedAt = basic.clock.now
        basic.reporter.listenCompleted(id: "a")
        XCTAssertEqual(basic.store.stored(for: subjectA).map(\.seconds), [300], "呼出の直後に記録がある")
        XCTAssertEqual(basic.store.stored(for: subjectA).first?.isSent, false)
        await waitUntil("完聴の記録") { basic.gateway.calls.contains(.completionRecorded) }
        XCTAssertEqual(basic.gateway.calls, [.mark("a"), .update("a", 300), .completionRecorded])
        XCTAssertEqual(basic.gateway.updates.first?.recordedAt, completedAt)
        await settle()
        XCTAssertEqual(basic.gateway.updates.count, 1)

        // (ii) markCompleted を保留中の再送では、完聴の位置は送られない。保留を解くと 1 回だけ送られる。
        let held = Rig()
        held.gateway.holdMark = true
        await held.finish("a")
        held.reporter.listenCompleted(id: "a")
        await waitUntil("mark の呼出") { held.gateway.calls.contains(.mark("a")) }
        held.reporter.resendUnsent()
        await settle()
        XCTAssertTrue(held.gateway.updates.isEmpty, "完聴の記録は記録した時点で送信中の印が付く")
        held.gateway.releaseMark()
        await waitUntil("完聴の記録") { held.gateway.calls.contains(.completionRecorded) }
        await settle()
        XCTAssertEqual(held.gateway.updates.map(\.id), ["a"])
        XCTAssertEqual(held.gateway.updates.map(\.seconds), [300])

        // (iii) 別エピソード b の未送信は、完聴の位置の送信を始めた後に 1 回再送される。
        let other = Rig()
        other.records.record(episodeId: "b", seconds: 40, at: other.clock.now)
        other.clock.advance(1)
        await other.finish("a")
        other.reporter.listenCompleted(id: "a")
        await waitUntil("完聴の記録と b の再送") {
            other.gateway.calls.contains(.completionRecorded) && other.gateway.updates.count >= 2
        }
        await settle()
        XCTAssertEqual(other.gateway.updates.filter { $0.id == "b" }.count, 1)
        XCTAssertEqual(other.gateway.updates.filter { $0.id == "a" }.count, 1)
        let calls = other.gateway.calls
        let mark = try XCTUnwrap(calls.firstIndex(of: .mark("a")))
        let update = try XCTUnwrap(calls.firstIndex(of: .update("a", 300)))
        let recorded = try XCTUnwrap(calls.firstIndex(of: .completionRecorded))
        XCTAssertLessThan(mark, update)
        XCTAssertLessThan(update, recorded)

        // (iv) markCompleted を保留中に離脱したら、位置は送らない。完聴の記録は完了する。
        let leaving = Rig()
        leaving.gateway.holdMark = true
        await leaving.finish("a")
        leaving.reporter.listenCompleted(id: "a")
        await waitUntil("mark の呼出") { leaving.gateway.calls.contains(.mark("a")) }
        leaving.records.bind(subject: nil)
        leaving.gateway.releaseMark()
        await waitUntil("完聴の記録") { leaving.gateway.calls.contains(.completionRecorded) }
        await settle()
        XCTAssertTrue(leaving.gateway.updates.isEmpty, "離脱後に旧主体の位置を送らない")

        // (v) 値が 0（完聴の位置が分からない）なら、記録も位置の送信もしない。
        let noValue = Rig()
        await noValue.startPlaying("a")
        noValue.reporter.listenCompleted(id: "a")
        await waitUntil("完聴の記録") { noValue.gateway.calls.contains(.completionRecorded) }
        await settle()
        XCTAssertEqual(noValue.gateway.calls, [.mark("a"), .completionRecorded])
        XCTAssertEqual(noValue.store.writeCount, 0)
    }

    // MARK: - 再送

    // verifies: ios-contract-13, ios-cmd-playback-25
    // kills: 失敗で記録を捨てる／次の送信で再送しない
    func testFailedSendKeepsTheRecordUnsentAndTheNextSendRetriesIt() async throws {
        let rig = Rig()
        rig.gateway.updateError = ApiFailure.network(URLError(.notConnectedToInternet))
        await rig.play("a", at: 10)
        rig.reporter.flush()
        await waitForUpdates(rig, 1)
        await settle()
        XCTAssertEqual(unsentSummary(rig), ["a:10"], "失敗した記録は未送信のまま")

        rig.gateway.updateError = nil
        await rig.play("b", at: 20)
        rig.reporter.flush()
        await waitUntil("a の再送") { rig.gateway.updates.contains { $0.id == "a" && $0.seconds == 10 } && rig.gateway.updates.count >= 3 }
        await settle()
        XCTAssertTrue(rig.records.unsent().isEmpty, "再送が成功して未送信が空になる")
        XCTAssertEqual(rig.gateway.updates.filter { $0.id == "a" }.count, 2, "a は失敗の 1 回と再送の 1 回")
    }

    // verifies: ios-cmd-playback-25
    // kills: 接続復帰で再送しない／起動直後の初期値で再送する／同じ値の重複で再送する
    func testReconnectResendsUnsentOnce() async throws {
        let rig = Rig()
        rig.gateway.updateError = ApiFailure.network(URLError(.notConnectedToInternet))
        rig.records.record(episodeId: "a", seconds: 12, at: rig.clock.now)

        rig.connectivity.send(true)  // 起動時の初期値。送らない。
        await settle()
        XCTAssertTrue(rig.gateway.updates.isEmpty)
        rig.connectivity.send(false)
        await settle()
        XCTAssertTrue(rig.gateway.updates.isEmpty)

        rig.connectivity.send(true)
        await waitForUpdates(rig, 1)
        rig.connectivity.send(true)  // 重複。送らない。
        await settle()
        XCTAssertEqual(rig.gateway.updates.count, 1)
        XCTAssertEqual(rig.gateway.updates.first?.id, "a")
        XCTAssertEqual(rig.gateway.updates.first?.seconds, 12)
    }

    // verifies: ios-cmd-playback-25, shared-leave-13
    // kills: 別主体の記録を現在の主体で送る
    func testStartupResendSendsOnlyTheBoundSubjectsRecords() async throws {
        let rig = Rig(bound: nil)
        let t = rig.clock.now
        rig.store.seed([PositionRecord(subject: subjectA, episodeId: "ea", seconds: 1, recordedAt: t, isSent: false)], for: subjectA)
        rig.store.seed([PositionRecord(subject: subjectB, episodeId: "eb", seconds: 2, recordedAt: t, isSent: false)], for: subjectB)
        rig.records.bind(subject: subjectA)

        rig.reporter.resendUnsent()
        await waitForUpdates(rig, 1)
        await settle()

        XCTAssertEqual(rig.gateway.updates.map(\.id), ["ea"])
    }

    // verifies: ios-cmd-playback-25
    // kills: 再送が再送を起動して止まらない／同一パスで同じ記録を再試行する／1 件の失敗で残りを止める
    func testResendWalksTheSnapshotOnceAndNeverRecursesWhenEverySendFails() async throws {
        let rig = Rig()
        rig.gateway.updateError = ApiFailure.network(URLError(.notConnectedToInternet))
        rig.records.record(episodeId: "a", seconds: 1, at: rig.clock.now)
        rig.clock.advance(1)
        rig.records.record(episodeId: "b", seconds: 2, at: rig.clock.now)

        rig.reporter.resendUnsent()
        await waitForUpdates(rig, 2)
        await settle()
        await settle()

        XCTAssertEqual(rig.gateway.updates.map(\.id), ["a", "b"], "各 1 回ずつ、記録の古い順に送って止まる")
        XCTAssertEqual(unsentSummary(rig), ["a:1", "b:2"])
    }

    // verifies: ios-cmd-playback-25, shared-leave-14
    // kills: 走査の途中で離脱しても残りの旧主体の記録を送る／照合が正方向でも送らない
    func testResendStopsWhenTheBoundSubjectChangesBetweenSends() async throws {
        func scenario(leaveWhileFirstIsInFlight: Bool) async throws -> [String] {
            let rig = Rig()
            rig.records.record(episodeId: "a", seconds: 1, at: rig.clock.now)
            rig.clock.advance(1)
            rig.records.record(episodeId: "b", seconds: 2, at: rig.clock.now)
            rig.gateway.hold("a")

            rig.reporter.resendUnsent()
            await waitForUpdates(rig, 1)
            if leaveWhileFirstIsInFlight { rig.records.bind(subject: nil) }
            rig.gateway.release(0)
            await settle()
            return rig.gateway.updates.map(\.id)
        }
        let afterLeaving = try await scenario(leaveWhileFirstIsInFlight: true)
        XCTAssertEqual(afterLeaving, ["a"], "離脱の後、2 件目は送られない")
        let withoutLeaving = try await scenario(leaveWhileFirstIsInFlight: false)
        XCTAssertEqual(withoutLeaving, ["a", "b"], "対照: 離脱しなければ 2 件とも送られる")

        // 新しい記録の送信も、送信の直前に主体を確かめる（Task が走る前に離脱した場合）。
        func direct(leave: Bool) async -> Int {
            let rig = Rig()
            await rig.play("a", at: 20)
            rig.reporter.flush()
            if leave { rig.records.bind(subject: nil) }
            await settle()
            return rig.gateway.updates.count
        }
        let sentAfterLeaving = await direct(leave: true)
        XCTAssertEqual(sentAfterLeaving, 0, "送信の Task が走る前に離脱したら送らない")
        let sentWithoutLeaving = await direct(leave: false)
        XCTAssertEqual(sentWithoutLeaving, 1, "対照: 離脱しなければ 1 件送られる")
    }

    // MARK: - 失敗の分類

    // verifies: ios-contract-13
    // kills: 404・422 を一時的な失敗として再送し続ける／他の失敗を恒久として送信済みにする／恒久でも記録を消す
    func testPermanentFailureMarksSentAndKeepsTheRecordFor404And422OnlyAndOthersStayUnsent() async throws {
        let permanent: [ApiFailure] = [.unknown(status: 404), .unknown(status: 422)]
        let transient: [ApiFailure] = [
            .unauthorized, .forbidden, .rateLimited(retryAfter: nil), .server(status: 500),
            .network(URLError(.timedOut)), .decoding,
        ]
        for failure in permanent + transient {
            let rig = Rig()
            rig.gateway.updateError = failure
            await rig.play("a", at: 10)
            rig.reporter.flush()
            await waitForUpdates(rig, 1)
            await settle()

            let isPermanent = permanent.contains(failure)
            XCTAssertEqual(rig.records.unsent().isEmpty, isPermanent, "\(failure)")
            XCTAssertEqual(rig.store.stored(for: subjectA).count, 1, "\(failure): 記録は消さない")
            XCTAssertEqual(rig.store.stored(for: subjectA).first?.isSent, isPermanent, "\(failure)")
            XCTAssertEqual(rig.reporter.lastSyncFailure, failure, "最後に終わった送信の失敗が見える")
        }
    }

    // MARK: - 送信中の記録と応答

    // verifies: ios-cmd-playback-24
    // kills: 古い応答で新しい記録を送信済みにする／同じ key の記録を重ねて送る／置換済みの予約が印を残す
    func testNewRecordWhileOlderResponseIsInFlightStaysUnsent() async throws {
        // (i) 時刻の違う新しい記録は別に送られ、古い応答で新しい記録は送信済みにならない。
        let rig = Rig()
        rig.gateway.hold("a")
        await rig.play("a", at: 10)
        rig.reporter.flush()
        await waitForUpdates(rig, 1)
        rig.clock.advance(1)
        await rig.tick(20)
        rig.reporter.flush()
        await waitForUpdates(rig, 2)

        rig.gateway.release(0)
        await settle()
        XCTAssertEqual(unsentSummary(rig), ["a:20"], "古い記録への応答で新しい記録は未送信のまま")
        rig.gateway.release(1)
        await waitUntil("新しい記録の応答") { rig.records.unsent().isEmpty }

        // (ii) 同じ key（同じ時刻）の記録は、送信中は送られず、次の新しい送信の後の再送で 1 回送られる。
        let same = Rig()
        same.gateway.hold("a")
        await same.play("a", at: 10)
        same.reporter.flush()
        await waitForUpdates(same, 1)
        await same.tick(20)
        same.reporter.flush()
        await settle()
        XCTAssertEqual(same.gateway.updates.map(\.seconds), [10], "同じ key の新しい記録は送信を予定しない")

        await same.play("b", at: 5)
        same.reporter.flush()
        await waitForUpdates(same, 2)
        await settle()
        XCTAssertEqual(same.gateway.updates.map(\.id), ["a", "b"], "送信中の key は再送の対象に入らない")

        same.gateway.release(0)
        await settle()
        XCTAssertEqual(unsentSummary(same), ["a:20"], "位置の違う記録は送信済みにならない")
        same.gateway.unhold("a")
        await same.play("c", at: 7)
        same.reporter.flush()
        await waitUntil("a の新しい記録の再送") { same.gateway.updates.contains { $0.id == "a" && $0.seconds == 20 } }
        await settle()
        XCTAssertEqual(same.gateway.updates.filter { $0.id == "a" && $0.seconds == 20 }.count, 1)

        // (iii) 再送の予約済みで送信前の記録が同じ key で置き換わっても、印は外れ、次の再送で新しい記録が送られる。
        let reserved = Rig()
        reserved.records.record(episodeId: "a", seconds: 10, at: reserved.clock.now)
        reserved.records.record(episodeId: "b", seconds: 20, at: reserved.clock.now)
        reserved.gateway.hold("a")
        reserved.reporter.resendUnsent()
        await waitForUpdates(reserved, 1)

        await reserved.play("b", at: 30)
        reserved.reporter.flush()
        await settle()
        XCTAssertEqual(reserved.gateway.updates.map(\.id), ["a"], "予約中の key の新しい記録は直接は送られない")

        reserved.gateway.release(0)
        await settle()
        XCTAssertEqual(reserved.gateway.updates.map(\.id), ["a"], "置き換わった古い b の予約は飛ばされる")

        reserved.reporter.resendUnsent()
        await waitForUpdates(reserved, 2)
        await settle()
        XCTAssertEqual(reserved.gateway.updates.map { "\($0.id):\(Int($0.seconds))" }, ["a:10", "b:30"])
    }

    // verifies: ios-cmd-playback-24, ios-dec-65
    // kills: 取り込んだ応答でライブのセッションの位置・seek を動かす／取り込んだ記録が一覧に渡らない
    func testNewerResponseReplacesTheRecordButNeverMovesTheLiveSession() async throws {
        let rig = Rig()
        rig.gateway.respond = { update in (99, update.recordedAt.addingTimeInterval(5)) }
        await rig.play("a", at: 10)
        let seekBefore = rig.engine.lastSeekSeconds

        rig.reporter.flush()
        await waitUntil("応答の取り込み") { rig.store.stored(for: subjectA).first?.seconds == 99 }

        let stored = try XCTUnwrap(rig.store.stored(for: subjectA).first)
        XCTAssertEqual(stored.recordedAt, rig.clock.now.addingTimeInterval(5))
        XCTAssertTrue(stored.isSent)
        XCTAssertEqual(rig.gateway.saved.count, 1, "新しい応答は一覧へ渡る")
        XCTAssertEqual(rig.livePosition, 10, "再生中のセッションの位置は動かない")
        XCTAssertEqual(rig.engine.lastSeekSeconds, seekBefore, "engine の seek も動かない")
    }

    // verifies: ios-cmd-playback-24, ios-dec-135
    // kills: 遅れて届いた古い応答で一覧を巻き戻す
    func testOutOfOrderResponsesDoNotRollTheListBack() async throws {
        let rig = Rig()
        rig.gateway.respond = { update in (update.seconds, update.recordedAt) }
        rig.gateway.hold("a")
        await rig.play("a", at: 10)
        rig.reporter.flush()
        await waitForUpdates(rig, 1)
        rig.clock.advance(1)
        let t2 = rig.clock.now
        await rig.tick(20)
        rig.reporter.flush()
        await waitForUpdates(rig, 2)

        rig.gateway.release(1)
        await waitUntil("新しい応答") { rig.gateway.saved.count == 1 }
        rig.gateway.release(0)
        await settle()

        XCTAssertEqual(rig.gateway.saved.count, 1, "古い応答は一覧へ渡さない")
        guard case .playable(let saved) = try XCTUnwrap(rig.gateway.saved.first) else { return XCTFail("playable") }
        XCTAssertEqual(saved.serverRecordedAt, t2)
    }

    // verifies: ios-cmd-playback-24, shared-leave-14
    // kills: 離脱後に届いた旧主体の応答が次の主体の記録・一覧を書き換える
    func testResponseArrivingAfterLeaveDoesNotTouchTheNextSubject() async throws {
        let rig = Rig()
        rig.gateway.respond = { update in (99, update.recordedAt.addingTimeInterval(9)) }
        rig.gateway.hold("a")
        await rig.play("a", at: 10)
        rig.reporter.flush()
        await waitForUpdates(rig, 1)

        rig.records.bind(subject: subjectB)
        let bRecord = try XCTUnwrap(rig.records.record(episodeId: "a", seconds: 50, at: rig.clock.now.addingTimeInterval(1)))
        rig.gateway.release(0)
        await settle()

        XCTAssertTrue(rig.gateway.saved.isEmpty, "一覧へ渡さない")
        XCTAssertEqual(rig.records.unsent(), [bRecord], "B の記録は変わらない")
        XCTAssertEqual(rig.store.stored(for: subjectB), [bRecord])
    }

    // verifies: ios-rule-playback-07, shared-dec-19
    // kills: 巻き戻した位置を記録しない／完聴を再び送る
    func testRewindPositionIsRecordedAndCompletionIsNotMarkedAgain() async throws {
        let rig = Rig()
        await rig.finish("a")
        rig.reporter.listenCompleted(id: "a")
        await waitUntil("完聴の記録") { rig.gateway.calls.contains(.completionRecorded) }
        await settle()

        await rig.startPlaying("a", resume: 30)
        await rig.tick(30)
        rig.session.pause()
        await waitForUpdates(rig, 2)
        await settle()

        XCTAssertEqual(rig.gateway.updates.map(\.seconds), [300, 30], "巻き戻した位置も記録して送る")
        XCTAssertEqual(rig.gateway.calls.filter { $0 == .mark("a") }.count, 1)
    }
}
