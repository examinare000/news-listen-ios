import XCTest
import os
@testable import NewsListenApp

/// `PlaybackCoordinator`（再生の use case の判断）の契約テスト。
///
/// テストは Session のオブジェクトに触れない。`coordinator.session`（Session の写し）・`queue`・`presentation`・`notice`・
/// `isAdvancing` と、port の double（engine・ロック画面 spy・gateway の記録・保留できる `fetchEpisode`）の状態だけを oracle にする。
/// Task の完了は固定時間の sleep ではなく、状態や記録の到着を待って確かめる。
@MainActor
final class PlaybackCoordinatorTests: XCTestCase {

    // MARK: - double

    private struct Update: Equatable {
        let id: String
        let seconds: Double
    }

    /// Reporter の gateway（位置の書込・完聴の記録）を記録する。
    private final class GatewayLog: @unchecked Sendable {
        private struct State {
            var updates: [Update] = []
            var marks: [String] = []
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())
        var updates: [Update] { lock.withLock { $0.updates } }
        var marks: [String] { lock.withLock { $0.marks } }

        func updatePosition(_ id: String, _ seconds: Double) -> Episode {
            lock.withLock { $0.updates.append(Update(id: id, seconds: seconds)) }
            return PlaybackCoordinatorTests.playable(id, serverPosition: seconds)
        }

        func markCompleted(_ id: String) {
            lock.withLock { $0.marks.append(id) }
        }
    }

    /// 保留できる `fetchEpisode`。`calls` は「待ちに入った（または即時に返した）」時点で記録される。
    private final class FetchDouble: @unchecked Sendable {
        private struct State {
            var calls: [String] = []
            var responses: [String: Episode] = [:]
            var failures: [String: Error] = [:]
            var holds: Set<String> = []
            var parked: [String: [CheckedContinuation<Error?, Never>]] = [:]
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())
        var calls: [String] { lock.withLock { $0.calls } }

        func count(_ id: String) -> Int { calls.filter { $0 == id }.count }
        func respond(_ id: String, with episode: Episode) { lock.withLock { $0.responses[id] = episode } }
        func fail(_ id: String, with error: Error) { lock.withLock { $0.failures[id] = error } }
        func hold(_ id: String) { lock.withLock { _ = $0.holds.insert(id) } }

        func release(_ id: String, throwing error: Error? = nil) {
            let continuation: CheckedContinuation<Error?, Never>? = lock.withLock { state in
                guard var waiting = state.parked[id], !waiting.isEmpty else { return nil }
                let first = waiting.removeFirst()
                state.parked[id] = waiting
                return first
            }
            continuation?.resume(returning: error)
        }

        func fetch(_ id: String) async throws -> Episode {
            let outcome: Error? = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
                let immediate: Bool = lock.withLock { state in
                    state.calls.append(id)
                    if state.holds.contains(id) {
                        state.parked[id, default: []].append(continuation)
                        return false
                    }
                    return true
                }
                if immediate { continuation.resume(returning: nil) }
            }
            if let outcome { throw outcome }
            let (response, failure) = lock.withLock { ($0.responses[id], $0.failures[id]) }
            if let failure { throw failure }
            guard let response else { throw ApiFailure.unknown(status: 404) }
            return response
        }
    }

    private final class Environment: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: (online: true, speed: Float(1.0), background: 0, ended: 0))
        var online: Bool {
            get { lock.withLock { $0.online } }
            set { lock.withLock { $0.online = newValue } }
        }
        var speed: Float {
            get { lock.withLock { $0.speed } }
            set { lock.withLock { $0.speed = newValue } }
        }
        var backgroundBegan: Int { lock.withLock { $0.background } }
        var backgroundEnded: Int { lock.withLock { $0.ended } }
        func beginBackground() -> () -> Void {
            lock.withLock { $0.background += 1 }
            return { [self] in lock.withLock { $0.ended += 1 } }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 2_000_000))
        var now: Date { lock.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { lock.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    @MainActor
    private final class Rig {
        let engine = AudioEngineDouble()
        let spy: NowPlayingCenterSpy
        let library: OfflineLibrary
        let gateway = GatewayLog()
        let fetch = FetchDouble()
        let environment = Environment()
        let clock = Clock()
        let reporter: PositionReporter
        let coordinator: PlaybackCoordinator

        init(spy: NowPlayingCenterSpy = NowPlayingCenterSpy()) {
            self.spy = spy
            library = OfflineLibrary(store: .live(cacheManager: AudioCacheManager(fileManager: AudioCacheManagerTests.MockFileManager())))
            let gateway = self.gateway
            let fetch = self.fetch
            let environment = self.environment
            let clock = self.clock
            reporter = PositionReporter(
                updatePosition: { id, seconds in gateway.updatePosition(id, seconds) },
                markCompleted: { id in gateway.markCompleted(id) },
                onPositionSaved: { _ in },
                onCompletionRecorded: {},
                beginBackgroundTask: { environment.beginBackground() },
                now: { clock.now }
            )
            coordinator = PlaybackCoordinator(
                engine: engine,
                nowPlayingCenter: spy,
                library: library,
                reporter: reporter,
                fetchEpisode: { id in try await fetch.fetch(id) },
                isOnline: { environment.online },
                defaultSpeed: { environment.speed },
                lockScreenSubtitle: { "sub:\($0)" },
                beginBackgroundTask: { environment.beginBackground() }
            )
        }

        /// 保存庫に音声を置く（`cached` として解決される）。
        func cached(_ episode: Episode) throws {
            try library.save(Data([1, 2, 3]), for: episode.id)
        }

        /// キャッシュ済みとして開始し、`ready`（playing）まで進める。
        func play(_ episode: Episode, expandsPlayer: Bool = true) async throws {
            try cached(episode)
            await coordinator.startEpisode(episode, expandsPlayer: expandsPlayer)
            await engine.send(.ready)
        }
    }

    // MARK: - fixture

    fileprivate nonisolated static func content(_ id: String, duration: Int = 300, rich: Bool = false) -> EpisodeContent {
        EpisodeContent(
            id: id, title: "題 \(id)", japaneseIntroText: "導入 \(id)", difficulty: "toeic_900",
            createdAt: "2026-05-31T06:00:00Z", durationSeconds: duration,
            segments: rich ? [TranscriptSegment(speaker: "A", text: "hello", role: "fact")] : nil,
            vocabulary: rich ? [VocabularyEntry(term: "t", meaningJa: "意味", example: "e")] : nil,
            quiz: rich ? [QuizQuestion(question: "q", options: ["x", "y"])] : nil,
            sourceArticles: rich ? [PodcastSourceArticle(articleId: "s1", title: "t", url: "https://example.com", source: "src")] : [],
            sourceKind: rich ? "featured" : nil
        )
    }

    fileprivate nonisolated static func playable(
        _ id: String, url: String? = nil, serverPosition: Double = 0, duration: Int = 300, rich: Bool = false
    ) -> Episode {
        .playable(PlayableEpisode(
            content: content(id, duration: duration, rich: rich),
            audioUrl: url ?? "https://cdn.example.com/\(id).mp3",
            serverPosition: serverPosition
        )!)
    }

    private func generating(_ id: String) -> Episode {
        .generating(GeneratingEpisode(content: Self.content(id)))
    }

    private func playableValue(_ episode: Episode) -> PlayableEpisode {
        guard case .playable(let value) = episode else { preconditionFailure("playable ではない: \(episode)") }
        return value
    }

    private func loading(_ episode: Episode, resume: Double = 0, speed: Float = 1.0) -> PlaybackState {
        .loading(episode: playableValue(episode), resumePosition: resume, speed: speed)
    }

    private func queueIds(_ coordinator: PlaybackCoordinator) -> [String] {
        coordinator.queue.items.map(\.id)
    }

    private func assertSharedInvariant(
        _ coordinator: PlaybackCoordinator, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        if coordinator.session != .idle {
            XCTAssertEqual(coordinator.session.episodeId, coordinator.queue.current?.id, "shared-inv-01 \(message)", file: file, line: line)
        }
    }

    private func eventually(
        _ message: String = "条件が成立しない", file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if !condition() { XCTFail(message, file: file, line: line) }
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }

    // MARK: - ios-test-080: 開始ごとの速度

    // verifies: ios-contract-09（ios-test-080）
    // kills: 速度を最初の 1 回しか読まない／setSpeed の値を次の開始に持ち越す／play の後の setRate 抜け
    func testT080_everyStartTakesTheDefaultSpeedAgain() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        rig.environment.speed = 1.5
        try rig.cached(a)
        try rig.cached(b)

        await rig.coordinator.startEpisode(a)
        XCTAssertEqual(rig.coordinator.session.speed, 1.5)
        XCTAssertEqual(rig.engine.rate, 1.5)

        rig.coordinator.setSpeed(2.0)
        XCTAssertEqual(rig.coordinator.session.speed, 2.0)
        XCTAssertEqual(rig.engine.rate, 2.0)

        await rig.coordinator.startEpisode(b)
        XCTAssertEqual(rig.coordinator.session.speed, 1.5, "次の開始で既定の速度に戻る")
        XCTAssertEqual(rig.engine.rate, 1.5)

        rig.environment.speed = 0.75
        await rig.coordinator.startEpisode(a)
        XCTAssertEqual(rig.coordinator.session.speed, 0.75, "既定速度は開始のたびに読み直す")
    }

    // MARK: - ios-test-081: 再生元の解決（手動の開始）

    // verifies: ios-contract-10（ios-test-081。unavailable）
    // MARK: shared-session-13
    func testT081SharedSession13_unavailableChangesNothingAndOnlySetsTheNotice() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        try await rig.play(a)
        rig.environment.online = false
        let sessionBefore = rig.coordinator.session
        let presentationBefore = rig.coordinator.presentation

        await rig.coordinator.startEpisode(b)

        XCTAssertEqual(rig.fetch.calls, [], "fetchEpisode は 0 回")
        XCTAssertEqual(queueIds(rig.coordinator), ["a"])
        XCTAssertEqual(rig.coordinator.session, sessionBefore, "a の再生が続く。error 状態にならない")
        XCTAssertEqual(rig.coordinator.presentation, presentationBefore)
        XCTAssertEqual(rig.coordinator.notice, .failure(.offlineUncached))
        XCTAssertEqual(rig.engine.loadedURL, rig.library.url("a"), "読み込み済みは a のまま")
    }

    // verifies: ios-contract-10（ios-test-081。開始前の判定: 再生可能でない・URL にならない）
    // MARK: shared-session-13
    func testT081SharedSession13_notPlayableOrInvalidUrlChangesNothingAndSetsInvalidSourceNotice() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        try await rig.play(a)
        let sessionBefore = rig.coordinator.session

        await rig.coordinator.startEpisode(generating("g"))
        XCTAssertEqual(rig.coordinator.notice, .failure(.invalidSource))
        XCTAssertEqual(queueIds(rig.coordinator), ["a"])
        XCTAssertEqual(rig.coordinator.session, sessionBefore)

        rig.coordinator.dismissError()
        await rig.coordinator.startEpisode(Self.playable("bad", url: "https://[bad"))
        XCTAssertEqual(rig.coordinator.notice, .failure(.invalidSource), "audioUrl が URL にならない")
        XCTAssertEqual(queueIds(rig.coordinator), ["a"])
        XCTAssertEqual(rig.coordinator.session, sessionBefore)
        XCTAssertEqual(rig.fetch.calls, [])
    }

    // verifies: ios-contract-10（ios-test-081。network は取り直して、同じ 1 つの Episode から開始の 4 値を作る）
    // kills: 取り直した Episode と保持している Episode の値を混ぜる
    func testT081_networkRefetchesOnceAndStartsFromTheRefetchedEpisode() async throws {
        let rig = Rig()
        let held = Self.playable("a", url: "https://cdn.example.com/stale.mp3", serverPosition: 10)
        let fresh = Self.playable("a", url: "https://cdn.example.com/fresh.mp3", serverPosition: 50)
        rig.fetch.respond("a", with: fresh)

        await rig.coordinator.startEpisode(held)

        XCTAssertEqual(rig.fetch.calls, ["a"], "fetchEpisode は 1 回")
        XCTAssertEqual(rig.engine.loadedURL, URL(string: "https://cdn.example.com/fresh.mp3"))
        XCTAssertEqual(rig.coordinator.session, loading(fresh, resume: 50), "エピソード・URL・再開位置は取り直した 1 つから")
    }

    // verifies: ios-contract-10（ios-test-081。取り直しの失敗では保持している URL。ios-review/gate-09）
    func testT081_refetchFailureFallsBackToTheHeldEpisode() async throws {
        let rig = Rig()
        let held = Self.playable("a", url: "https://cdn.example.com/stale.mp3", serverPosition: 10)
        rig.fetch.fail("a", with: ApiFailure.server(status: 500))

        await rig.coordinator.startEpisode(held)

        XCTAssertEqual(rig.fetch.calls, ["a"])
        XCTAssertEqual(rig.engine.loadedURL, URL(string: "https://cdn.example.com/stale.mp3"))
        XCTAssertEqual(rig.coordinator.session, loading(held, resume: 10))
        XCTAssertNil(rig.coordinator.notice, "取り直しの失敗は利用者に見せない")
    }

    // verifies: ios-contract-10（ios-test-081。取り直した値が再生できないときも保持している Episode）
    func testT081_refetchedEpisodeThatIsNotPlayableFallsBackToTheHeldEpisode() async throws {
        let rig = Rig()
        let held = Self.playable("a", url: "https://cdn.example.com/stale.mp3")
        rig.fetch.respond("a", with: generating("a"))

        await rig.coordinator.startEpisode(held)

        XCTAssertEqual(rig.engine.loadedURL, URL(string: "https://cdn.example.com/stale.mp3"))
        XCTAssertEqual(rig.coordinator.session, loading(held))
    }

    // verifies: ios-contract-10（ios-test-081。cached は取り直さず、保存庫の URL と保持している再開位置）
    func testT081_cachedDoesNotFetchAndUsesTheLibraryUrl() async throws {
        let rig = Rig()
        let a = Self.playable("a", url: "https://cdn.example.com/remote.mp3", serverPosition: 120)
        try rig.cached(a)

        await rig.coordinator.startEpisode(a)

        XCTAssertEqual(rig.fetch.calls, [], "fetchEpisode は 0 回")
        XCTAssertEqual(rig.engine.loadedURL, rig.library.url("a"))
        XCTAssertNotEqual(rig.engine.loadedURL, URL(string: "https://cdn.example.com/remote.mp3"))
        XCTAssertEqual(rig.coordinator.session, loading(a, resume: 120))
    }

    // verifies: ios-contract-10（ios-test-081。startEpisode(id:) も fetchEpisode は 1 回）
    func testT081_startEpisodeByIdFetchesExactlyOnceAndStartsTheResolvedEpisode() async throws {
        let rig = Rig()
        let resolved = Self.playable("x", url: "https://cdn.example.com/x-fresh.mp3", serverPosition: 20)
        rig.fetch.respond("x", with: resolved)

        try await rig.coordinator.startEpisode(id: "x")

        XCTAssertEqual(rig.fetch.calls, ["x"], "解決した Episode を再取得の結果として使い、2 回目を呼ばない")
        XCTAssertEqual(rig.engine.loadedURL, URL(string: "https://cdn.example.com/x-fresh.mp3"))
        XCTAssertEqual(rig.coordinator.session, loading(resolved, resume: 20))
        XCTAssertEqual(rig.coordinator.queue.current?.id, "x")
        XCTAssertEqual(rig.coordinator.presentation, .expanded)
    }

    // verifies: ios-contract-10（ios-test-081。startEpisode(id:) の解決失敗は error をそのまま投げ、何も変えない）
    func testT081_startEpisodeByIdFailureRethrowsAndChangesNothing() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        try await rig.play(a)
        rig.fetch.fail("y", with: ApiFailure.server(status: 503))
        let sessionBefore = rig.coordinator.session

        do {
            try await rig.coordinator.startEpisode(id: "y")
            XCTFail("throw されるはず")
        } catch let error as ApiFailure {
            XCTAssertEqual(error, .server(status: 503), "受けた error をそのまま投げる")
        }

        XCTAssertEqual(queueIds(rig.coordinator), ["a"])
        XCTAssertEqual(rig.coordinator.session, sessionBefore)
        XCTAssertNil(rig.coordinator.notice)
    }

    // MARK: - ios-test-082: 自動で次へ進むときの失敗

    private func twoEpisodeRig(next: Episode, thirdIsQueued: Bool = false) async throws -> Rig {
        let rig = Rig()
        let a = Self.playable("a")
        try await rig.play(a)
        await rig.coordinator.addToQueue(next)
        if thirdIsQueued { await rig.coordinator.addToQueue(Self.playable("c")) }
        return rig
    }

    // verifies: ios-contract-11（ios-test-082 (0)）
    func testT082_nextThatIsNotPlayableOrHasNoUrlStaysCurrentAsErroredInvalidSource() async throws {
        for next in [generating("b"), Self.playable("b", url: "https://[bad")] {
            let rig = try await twoEpisodeRig(next: next)

            await rig.engine.send(.ended)
            await eventually("errored になる") { rig.coordinator.session == .errored(episodeId: "b", position: 0, reason: .invalidSource) }

            XCTAssertEqual(rig.coordinator.queue.current?.id, "b", "先にキューを進めるので、失敗したエピソードが現在になる")
            XCTAssertEqual(rig.coordinator.notice, .failure(.invalidSource))
            assertSharedInvariant(rig.coordinator)
        }
    }

    // verifies: ios-contract-11（ios-test-082 (1)）
    func testT082_nextOfflineAndUncachedErrorsWithoutFetching() async throws {
        let rig = try await twoEpisodeRig(next: Self.playable("b"))
        rig.environment.online = false

        await rig.engine.send(.ended)
        await eventually("errored になる") { rig.coordinator.session == .errored(episodeId: "b", position: 0, reason: .offlineUncached) }

        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.fetch.calls, [], "fetchEpisode は 0 回")
        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertEqual(rig.coordinator.notice, .failure(.offlineUncached))
        assertSharedInvariant(rig.coordinator)
    }

    // verifies: ios-contract-11（ios-test-082 (2)）
    func testT082_engineFailureOfTheNextEpisodeDoesNotAdvanceToTheOneAfter() async throws {
        let b = Self.playable("b")
        let rig = try await twoEpisodeRig(next: b, thirdIsQueued: true)
        try rig.cached(b)

        await rig.engine.send(.ended)
        await eventually("b が開始される") { rig.coordinator.session == self.loading(b) }
        await rig.engine.send(.failed(description: "decode error"))

        XCTAssertEqual(rig.coordinator.session, .errored(episodeId: "b", position: 0, reason: .engineFailed(description: "decode error")))
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b", "c へ進まない")
        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), ["c"])
        XCTAssertFalse(rig.engine.isLoaded)
        assertSharedInvariant(rig.coordinator)
    }

    // verifies: ios-contract-11（ios-test-082 (3)。retry と togglePlayPause は「再生元の用意」からやり直す）
    func testT082_retryAndTogglePlayPauseRestartFromPreparingTheSource() async throws {
        let b = Self.playable("b")
        let rig = try await twoEpisodeRig(next: b)
        rig.fetch.respond("b", with: b)

        await rig.engine.send(.ended)
        await eventually("b が開始される") { rig.coordinator.session == self.loading(b) }
        XCTAssertEqual(rig.fetch.count("b"), 1)
        await rig.engine.send(.failed(description: "x"))
        XCTAssertEqual(rig.coordinator.session.episodeId, "b")

        await rig.coordinator.retry()
        XCTAssertEqual(rig.fetch.count("b"), 2, "再生元の用意（取り直し）からやり直す")
        XCTAssertEqual(rig.coordinator.session, loading(b))
        XCTAssertEqual(rig.coordinator.presentation, .expanded, "retry の表示形態は expandsPlayer: false の規則（不変）")

        await rig.engine.send(.failed(description: "again"))
        rig.coordinator.togglePlayPause()
        await eventually("togglePlayPause が retry になる") { rig.coordinator.session == self.loading(b) }
        XCTAssertEqual(rig.fetch.count("b"), 3)
    }

    // verifies: ios-contract-11（ios-test-082 (3)。retry が開始前の判定に落ちたら notice が入り直す）
    // kills: errored の値が同じときの stateChanged に頼って notice を置く
    func testT082_retryThatFallsToTheStartCheckSetsTheNoticeAgainEvenAfterDismissError() async throws {
        let rig = try await twoEpisodeRig(next: Self.playable("b"))
        rig.environment.online = false
        await rig.engine.send(.ended)
        await eventually("errored になる") { rig.coordinator.session == .errored(episodeId: "b", position: 0, reason: .offlineUncached) }
        rig.coordinator.dismissError()
        XCTAssertNil(rig.coordinator.notice)
        XCTAssertEqual(rig.coordinator.session, .errored(episodeId: "b", position: 0, reason: .offlineUncached), "dismissError は errored を変えない")

        await rig.coordinator.retry()  // また開始前の判定（offlineUncached）に落ちる。errored の値は前と同じ

        XCTAssertEqual(rig.coordinator.notice, .failure(.offlineUncached), "Coordinator が notice を自分で置く")
        XCTAssertEqual(rig.coordinator.session, .errored(episodeId: "b", position: 0, reason: .offlineUncached))
        XCTAssertEqual(rig.fetch.calls, [])
    }

    // verifies: ios-contract-11（ios-test-082 (4)。errored の間は時計を進めても位置の送信 0）
    func testT082_noPositionIsSentWhileErroredEvenIfTheClockAdvances() async throws {
        let rig = try await twoEpisodeRig(next: Self.playable("b"))
        rig.environment.online = false
        await rig.engine.send(.ended)
        await eventually("errored になる") { rig.coordinator.session.episodeId == "b" && !PlaybackRules.isLoaded(rig.coordinator.session) }
        await eventually("完聴の送信が終わる") { rig.gateway.marks == ["a"] && !rig.gateway.updates.isEmpty }
        await settle()
        let sent = rig.gateway.updates

        rig.clock.advance(300)
        await settle()
        rig.reporter.flush()
        await settle()

        XCTAssertEqual(rig.gateway.updates, sent, "errored の間は位置を送らない")
    }

    // MARK: - ios-test-083: 公開操作（shared-session-04）

    // verifies: ios-contract-12（ios-test-083。startEpisode(_:expandsPlayer:)・addToQueue・playNext・seek・setSpeed の後の不変条件と写し）
    // MARK: shared-session-04
    func testT083SharedSession04_startQueueAndPlaybackOperationsKeepTheSessionMirrorAndInvariant() async throws {
        let rig = Rig()
        let a = Self.playable("a", serverPosition: 120)
        let b = Self.playable("b")
        let c = Self.playable("c")
        let d = Self.playable("d")

        // startEpisode(_:expandsPlayer:)
        try rig.cached(a)
        await rig.coordinator.startEpisode(a)
        XCTAssertEqual(rig.coordinator.session, loading(a, resume: 120))
        assertSharedInvariant(rig.coordinator, "startEpisode")
        await rig.engine.send(.ready)

        // addToQueue / playNext は idle でないので、キューだけ変わる。
        await rig.coordinator.addToQueue(b)
        await rig.coordinator.addToQueue(c)
        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), ["b", "c"])
        await rig.coordinator.playNext(d)
        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), ["d", "b", "c"])
        XCTAssertEqual(rig.coordinator.session.episodeId, "a", "再生は続く")
        assertSharedInvariant(rig.coordinator, "addToQueue / playNext")

        // seek / setSpeed
        rig.coordinator.seek(to: 40)
        XCTAssertEqual(rig.coordinator.session.position, 40)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 40)
        rig.coordinator.setSpeed(2.0)
        XCTAssertEqual(rig.coordinator.session.speed, 2.0)
        assertSharedInvariant(rig.coordinator, "seek / setSpeed")

        // moveUpNext: upNext [d, b, c] の先頭を 2 の位置へ → [b, d, c]
        rig.coordinator.moveUpNext(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), ["b", "d", "c"])
        assertSharedInvariant(rig.coordinator, "moveUpNext")

        // removeFromQueue（待機列の要素）はキューだけ。
        rig.coordinator.removeFromQueue(id: "d")
        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), ["b", "c"])
        XCTAssertEqual(rig.coordinator.session.episodeId, "a")
        assertSharedInvariant(rig.coordinator, "removeFromQueue（待機列）")
    }

    // verifies: ios-contract-12（ios-test-083。addToQueue / playNext は idle のとき開始する。開始できなくてもキューに残る）
    // MARK: shared-session-04
    func testT083SharedSession04_addToQueueAndPlayNextStartOnlyWhileIdle() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        try rig.cached(a)
        try rig.cached(b)

        await rig.coordinator.addToQueue(a)  // idle なので開始する
        XCTAssertEqual(rig.coordinator.session, loading(a))
        XCTAssertEqual(rig.coordinator.queue.current?.id, "a")
        assertSharedInvariant(rig.coordinator)

        let other = Rig()
        try other.cached(b)
        await other.coordinator.playNext(b)  // idle なので開始する
        XCTAssertEqual(other.coordinator.session, loading(b))
        XCTAssertEqual(other.coordinator.queue.current?.id, "b")
        assertSharedInvariant(other.coordinator)

        // 開始できなくても、キューに足したことは残る。
        let offline = Rig()
        offline.environment.online = false
        await offline.coordinator.addToQueue(Self.playable("z"))
        XCTAssertEqual(queueIds(offline.coordinator), ["z"])
        XCTAssertEqual(offline.coordinator.session, .idle)
        XCTAssertEqual(offline.coordinator.notice, .failure(.offlineUncached))
    }

    // verifies: ios-contract-12（ios-test-083。startEpisode(id:) の成功と失敗）
    // MARK: shared-session-04
    func testT083SharedSession04_startEpisodeByIdSuccessMirrorsTheSession() async throws {
        let rig = Rig()
        let x = Self.playable("x")
        rig.fetch.respond("x", with: x)

        try await rig.coordinator.startEpisode(id: "x")

        XCTAssertEqual(rig.coordinator.session, loading(x))
        assertSharedInvariant(rig.coordinator)
    }

    // verifies: ios-contract-12（ios-test-083。replayCurrent の 3 場合）
    // MARK: shared-session-04
    func testT083SharedSession04_replayCurrentRestartsFromZeroKeepsThePresentationAndHandlesNoCurrentAndOffline() async throws {
        // 現在あり: ended の a を再開位置 0 で始める。表示形態は不変。
        let rig = Rig()
        let a = Self.playable("a", serverPosition: 120)
        try await rig.play(a, expandsPlayer: false)
        rig.coordinator.minimizePlayer()
        await rig.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await rig.engine.send(.ended)
        await eventually("ended になる") { rig.coordinator.session.isEnded }
        let queueBefore = rig.coordinator.queue

        await rig.coordinator.replayCurrent()

        XCTAssertEqual(rig.coordinator.session, loading(a, resume: 0), "再開位置は 0（serverPosition を使わない）")
        XCTAssertEqual(rig.coordinator.presentation, .mini, "表示形態は不変")
        XCTAssertEqual(rig.coordinator.queue, queueBefore, "キューは変えない")
        assertSharedInvariant(rig.coordinator)

        // 現在なし: 何もしない。
        let empty = Rig()
        await empty.coordinator.replayCurrent()
        XCTAssertEqual(empty.coordinator.session, .idle)
        XCTAssertEqual(empty.coordinator.presentation, .hidden)
        XCTAssertNil(empty.coordinator.notice)
        XCTAssertEqual(empty.fetch.calls, [])

        // オフライン未キャッシュ: ended のまま・notice だけ。
        let offline = Rig()
        let z = Self.playable("z")
        try await offline.play(z)
        await offline.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await offline.engine.send(.ended)
        await eventually("ended になる") { offline.coordinator.session.isEnded }
        try offline.library.remove("z")
        offline.environment.online = false
        let endedState = offline.coordinator.session

        await offline.coordinator.replayCurrent()

        XCTAssertEqual(offline.coordinator.session, endedState, "ended の表示は残る")
        XCTAssertEqual(offline.coordinator.notice, .failure(.offlineUncached))
    }

    // verifies: ios-contract-12（ios-test-083。removeFromQueue（現在）は位置を送り、停止し、次の要素を現在にするが自動では始めない）
    // MARK: shared-session-04
    func testT083SharedSession04_removingTheCurrentEpisodeFlushesStopsAndLeavesTheNextOneIdle() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        try await rig.play(a)
        await rig.coordinator.addToQueue(b)
        await rig.engine.send(.timeUpdate(seconds: 40, duration: 300))

        rig.coordinator.removeFromQueue(id: "a")
        await eventually("位置を送る") { rig.gateway.updates == [Update(id: "a", seconds: 40)] }

        XCTAssertEqual(rig.coordinator.session, .idle)
        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b", "次の要素が現在になる")
        XCTAssertEqual(rig.coordinator.presentation, .expanded, "表示形態は変えない")
        await settle()
        XCTAssertEqual(rig.fetch.calls, [], "自動では再生しない")
        XCTAssertNil(rig.engine.loadedURL)

        // idle のときの現在の要素の削除は、取り除くだけ（位置を送らず、停止もしない）。
        rig.coordinator.removeFromQueue(id: "b")
        XCTAssertTrue(rig.coordinator.queue.isEmpty)
        XCTAssertEqual(rig.coordinator.session, .idle)
        await settle()
        XCTAssertEqual(rig.gateway.updates, [Update(id: "a", seconds: 40)], "新たに送らない")
    }

    // verifies: ios-contract-12（ios-test-083。dismissError・minimizePlayer・expandPlayer・stopForLogout の後の不変条件）
    // MARK: shared-session-04
    func testT083SharedSession04_dismissErrorAndPresentationOperationsKeepTheInvariant() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        try await rig.play(a)
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(rig.coordinator.notice, .failure(.engineFailed(description: "boom")), "errored に入ったら notice を置く")

        rig.coordinator.dismissError()
        XCTAssertNil(rig.coordinator.notice)
        XCTAssertEqual(rig.coordinator.session, .errored(episodeId: "a", position: 0, reason: .engineFailed(description: "boom")))
        assertSharedInvariant(rig.coordinator, "dismissError")

        rig.coordinator.minimizePlayer()
        rig.coordinator.expandPlayer()
        assertSharedInvariant(rig.coordinator, "minimize / expand")

        rig.coordinator.stopForLogout()
        XCTAssertEqual(rig.coordinator.session, .idle)
        assertSharedInvariant(rig.coordinator, "stopForLogout")
    }

    // verifies: ios-contract-12（notice の規則: 警告で置き、開始の確定で消す）
    func testNoticeIsSetByLoadWarningAndClearedWhenAStartIsConfirmed() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        try rig.cached(a)
        try rig.cached(b)
        rig.engine.nextLoadWarning = "audio session failed"

        await rig.coordinator.startEpisode(a)
        XCTAssertEqual(rig.coordinator.notice, .loadWarning("audio session failed"))
        XCTAssertEqual(rig.coordinator.session, loading(a), "警告は状態を変えない")

        await rig.coordinator.startEpisode(b)
        XCTAssertNil(rig.coordinator.notice, "開始が確定したとき notice を消す")
    }

    // verifies: ios-contract-12（ios-test-083。nowPlaying() の 9 field と導出値 6）
    // MARK: shared-session-04
    func testT083SharedSession04_nowPlayingIsDerivedFromTheCurrentEpisodeAndNilWhenIdle() async throws {
        let rig = Rig()
        XCTAssertNil(rig.coordinator.nowPlaying(), "idle で nil")
        let rich = Self.playable("r", duration: 321, rich: true)
        let plain = Self.playable("p", duration: 90)
        try await rig.play(rich)
        await rig.coordinator.addToQueue(plain)

        let nowPlaying = try XCTUnwrap(rig.coordinator.nowPlaying())
        let content = rich.content
        XCTAssertEqual(nowPlaying.episodeId, "r")
        XCTAssertEqual(nowPlaying.id, "r")
        XCTAssertEqual(nowPlaying.displayTitle, content.displayTitle)
        XCTAssertEqual(nowPlaying.japaneseIntroText, content.japaneseIntroText)
        XCTAssertEqual(nowPlaying.segments, content.segments)
        XCTAssertEqual(nowPlaying.vocabulary, content.vocabulary)
        XCTAssertEqual(nowPlaying.quiz, content.quiz)
        XCTAssertEqual(nowPlaying.difficulty, content.difficulty)
        XCTAssertEqual(nowPlaying.sourceArticles, content.sourceArticles)
        XCTAssertEqual(nowPlaying.sourceKind, content.sourceKind)
        XCTAssertTrue(nowPlaying.hasTranscript)
        XCTAssertTrue(nowPlaying.hasVocabulary)
        XCTAssertTrue(nowPlaying.hasQuiz)
        XCTAssertTrue(nowPlaying.hasSourceArticles)
        XCTAssertTrue(nowPlaying.showsCcBySaLicense)
        XCTAssertEqual(nowPlaying.hasTranscript, content.hasTranscript)
        XCTAssertEqual(nowPlaying.hasVocabulary, content.hasVocabulary)
        XCTAssertEqual(nowPlaying.hasQuiz, content.hasQuiz)
        XCTAssertEqual(nowPlaying.hasSourceArticles, content.hasSourceArticles)
        XCTAssertEqual(nowPlaying.showsCcBySaLicense, content.showsCcBySaLicense)
        XCTAssertEqual(
            nowPlaying.queueEntry,
            QueueEntry(episodeId: "r", introText: content.japaneseIntroText, difficulty: content.difficulty, durationSeconds: 321)
        )

        // 導出値が定数でないこと: 空の内容のエピソードでは 5 つの Bool がすべて false。
        let upNext = rig.coordinator.upNext()
        let plainEntry = try XCTUnwrap(upNext.first)
        rig.coordinator.removeFromQueue(id: "r")  // 現在を取り除く → p が現在（idle）
        XCTAssertNil(rig.coordinator.nowPlaying(), "idle のときは queue.current があっても nil")
        try rig.cached(plain)
        await rig.coordinator.startEpisode(plain)
        let plainNow = try XCTUnwrap(rig.coordinator.nowPlaying())
        XCTAssertFalse(plainNow.hasTranscript)
        XCTAssertFalse(plainNow.hasVocabulary)
        XCTAssertFalse(plainNow.hasQuiz)
        XCTAssertFalse(plainNow.hasSourceArticles)
        XCTAssertFalse(plainNow.showsCcBySaLicense)
        XCTAssertEqual(plainNow.queueEntry, plainEntry, "queueEntry は upNext() の行と同じ形")
    }

    // verifies: ios-contract-12（ios-test-083。upNext() は [QueueEntry]）
    // MARK: shared-session-04
    func testT083SharedSession04_upNextReturnsQueueEntriesOfTheWaitingEpisodes() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b", duration: 111, rich: true)
        let c = Self.playable("c", duration: 222)
        try await rig.play(a)
        await rig.coordinator.addToQueue(b)
        await rig.coordinator.addToQueue(c)

        let entries: [QueueEntry] = rig.coordinator.upNext()

        XCTAssertEqual(entries, [
            QueueEntry(episodeId: "b", introText: b.content.japaneseIntroText, difficulty: b.content.difficulty, durationSeconds: 111),
            QueueEntry(episodeId: "c", introText: c.content.japaneseIntroText, difficulty: c.content.difficulty, durationSeconds: 222),
        ])
    }

    // verifies: ios-contract-12（ios-test-083。ios-check-07 PB (1): queue のコピーを書き換えても Coordinator は変わらない）
    // MARK: shared-session-04
    func testT083SharedSession04_pb1MutatingACopyOfTheQueueDoesNotChangeTheCoordinator() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        let c = Self.playable("c")
        try await rig.play(a)
        await rig.coordinator.addToQueue(b)
        await rig.coordinator.addToQueue(c)
        let queueBefore = rig.coordinator.queue
        let nowPlayingBefore = rig.coordinator.nowPlaying()
        let upNextBefore = rig.coordinator.upNext()

        var copy = rig.coordinator.queue
        copy.remove(id: "b")
        _ = copy.advance()
        copy.remove(id: "a")

        XCTAssertEqual(rig.coordinator.queue, queueBefore)
        XCTAssertEqual(rig.coordinator.nowPlaying(), nowPlayingBefore)
        XCTAssertEqual(rig.coordinator.upNext(), upNextBefore)
    }

    // verifies: ios-contract-12（ios-test-083。ios-check-07 PB (2): 渡した配列を後から書き換えてもキューは変わらない）
    // MARK: shared-session-04
    func testT083SharedSession04_pb2MutatingThePassedArrayAfterwardsDoesNotChangeTheQueue() async throws {
        let rig = Rig()
        var episodes = [Self.playable("a"), Self.playable("b")]
        try rig.cached(episodes[0])
        await rig.coordinator.startEpisode(episodes[0])
        await rig.coordinator.addToQueue(episodes[1])
        let queueBefore = rig.coordinator.queue

        episodes[0] = Self.playable("changed")
        episodes.append(Self.playable("extra"))
        episodes.removeAll()

        XCTAssertEqual(rig.coordinator.queue, queueBefore)
        XCTAssertEqual(queueIds(rig.coordinator), ["a", "b"])
    }

    // verifies: ios-contract-12（ios-test-083。ios-check-07 PB (3): upNext() の戻り値を書き換えても次の upNext() は変わらない）
    // MARK: shared-session-04
    func testT083SharedSession04_pb3MutatingTheReturnedUpNextArrayDoesNotChangeTheNextUpNext() async throws {
        let rig = Rig()
        try await rig.play(Self.playable("a"))
        await rig.coordinator.addToQueue(Self.playable("b"))
        await rig.coordinator.addToQueue(Self.playable("c"))
        let before = rig.coordinator.upNext()

        var returned = rig.coordinator.upNext()
        returned.removeAll()
        returned.append(QueueEntry(episodeId: "x", introText: "i", difficulty: "d", durationSeconds: 1))

        XCTAssertEqual(rig.coordinator.upNext(), before)
        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), ["b", "c"])
    }

    // MARK: - ios-test-085: 表示形態

    // verifies: ios-contract-12（ios-test-085。初期・開始）
    func testT085_presentationStartsHiddenAndFollowsTheExpandsPlayerRule() async throws {
        let rig = Rig()
        XCTAssertEqual(rig.coordinator.presentation, .hidden)
        let a = Self.playable("a")
        let b = Self.playable("b")
        try rig.cached(a)
        try rig.cached(b)

        await rig.coordinator.startEpisode(a, expandsPlayer: false)
        XCTAssertEqual(rig.coordinator.presentation, .mini, "hidden から expandsPlayer: false → mini")

        await rig.coordinator.startEpisode(b, expandsPlayer: false)
        XCTAssertEqual(rig.coordinator.presentation, .mini, "mini からの expandsPlayer: false は不変")

        await rig.coordinator.startEpisode(a, expandsPlayer: true)
        XCTAssertEqual(rig.coordinator.presentation, .expanded)

        await rig.coordinator.startEpisode(b, expandsPlayer: false)
        XCTAssertEqual(rig.coordinator.presentation, .expanded, "expanded からの expandsPlayer: false は不変")

        let direct = Rig()
        try direct.cached(a)
        await direct.coordinator.startEpisode(a)
        XCTAssertEqual(direct.coordinator.presentation, .expanded, "expandsPlayer の既定は true")
    }

    // verifies: ios-contract-12（ios-test-085。開始前に再生不可・解決失敗は不変）
    func testT085_presentationIsUnchangedWhenTheStartCheckOrTheResolutionFails() async throws {
        let rig = Rig()
        await rig.coordinator.startEpisode(generating("g"))
        XCTAssertEqual(rig.coordinator.presentation, .hidden)

        rig.environment.online = false
        await rig.coordinator.startEpisode(Self.playable("u"))
        XCTAssertEqual(rig.coordinator.presentation, .hidden)

        rig.environment.online = true
        rig.fetch.fail("y", with: ApiFailure.server(status: 500))
        do { try await rig.coordinator.startEpisode(id: "y") } catch {}
        XCTAssertEqual(rig.coordinator.presentation, .hidden)
    }

    // verifies: ios-contract-12（ios-test-085。minimizePlayer・expandPlayer・stopForLogout）
    func testT085_minimizeExpandAndLogoutFollowThePresentationRules() async throws {
        let rig = Rig()
        rig.coordinator.minimizePlayer()
        XCTAssertEqual(rig.coordinator.presentation, .hidden, "hidden での minimize は不変")
        rig.coordinator.expandPlayer()
        XCTAssertEqual(rig.coordinator.presentation, .hidden, "nowPlaying() が nil なら expand は不変")

        try await rig.play(Self.playable("a"))
        XCTAssertEqual(rig.coordinator.presentation, .expanded)
        rig.coordinator.minimizePlayer()
        XCTAssertEqual(rig.coordinator.presentation, .mini)
        rig.coordinator.minimizePlayer()
        XCTAssertEqual(rig.coordinator.presentation, .mini)
        rig.coordinator.expandPlayer()
        XCTAssertEqual(rig.coordinator.presentation, .expanded)

        rig.coordinator.stopForLogout()
        XCTAssertEqual(rig.coordinator.presentation, .hidden)
    }

    // verifies: ios-contract-12（ios-test-085。待機列が尽きた ended は不変、自動で次へ進む開始は expandsPlayer: false の規則）
    func testT085_endedWithEmptyQueueKeepsThePresentationAndAutoAdvanceDoesNotExpand() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        try await rig.play(a)
        await rig.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await rig.engine.send(.ended)
        await eventually("ended になる") { rig.coordinator.session.isEnded }
        await settle()
        XCTAssertEqual(rig.coordinator.presentation, .expanded, "待機列が尽きた ended で不変")

        let advancing = Rig()
        let first = Self.playable("a")
        let second = Self.playable("b")
        try await advancing.play(first)
        try advancing.cached(second)
        await advancing.coordinator.addToQueue(second)
        advancing.coordinator.minimizePlayer()

        await advancing.engine.send(.ended)
        await eventually("b が開始される") { advancing.coordinator.session == self.loading(second) }

        XCTAssertEqual(advancing.coordinator.presentation, .mini, "自動で次へ進む開始は expanded にしない")
    }

    // MARK: - ios-test-086: ロック画面・リモートコマンド

    // verifies: ios-contract-12（ios-test-086。コマンド 7 種 × 操作できる状態の戻り値と効果）
    func testT086_remoteCommandsWhileOperableReturnSuccessAndOperateTheSession() async throws {
        let a = Self.playable("a")
        let rig = Rig()
        try await rig.play(a)
        await rig.engine.send(.timeUpdate(seconds: 100, duration: 300))

        XCTAssertEqual(rig.spy.invoke(.pause), .success)
        XCTAssertTrue(rig.coordinator.session.isPausedForTest)
        XCTAssertEqual(rig.spy.invoke(.pause), .success, "paused での pause も success（何もしない）")
        XCTAssertEqual(rig.spy.invoke(.play), .success)
        XCTAssertEqual(rig.coordinator.session.speed, 1.0)
        XCTAssertFalse(rig.coordinator.session.isPausedForTest)
        XCTAssertEqual(rig.spy.invoke(.play), .success, "playing での play も success")
        XCTAssertEqual(rig.spy.invoke(.togglePlayPause), .success)
        XCTAssertTrue(rig.coordinator.session.isPausedForTest)
        XCTAssertEqual(rig.spy.invoke(.togglePlayPause), .success)
        XCTAssertFalse(rig.coordinator.session.isPausedForTest)

        XCTAssertEqual(rig.spy.invoke(.skipBackward), .success)
        XCTAssertEqual(rig.coordinator.session.position, 85, "100 − 15（PlaybackConstants.skipBackwardSeconds）")
        XCTAssertEqual(rig.spy.invoke(.skipForward), .success)
        XCTAssertEqual(rig.coordinator.session.position, 115, "85 + 30（PlaybackConstants.skipForwardSeconds）")
        XCTAssertEqual(rig.spy.invoke(.changePosition(200)), .success)
        XCTAssertEqual(rig.coordinator.session.position, 200)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 200)
        XCTAssertEqual(rig.spy.invoke(.changeRate(1.75)), .success)
        XCTAssertEqual(rig.coordinator.session.speed, 1.75)
    }

    // verifies: ios-contract-12（ios-test-086。操作できない状態の戻り値: idle・ended・errored）
    func testT086_remoteCommandsWhileNotOperableReturnTheDocumentedFailures() async throws {
        let expected: [(RemoteCommand, RemoteCommandResult)] = [
            (.play, .noSuchContent), (.pause, .noSuchContent), (.togglePlayPause, .noSuchContent),
            (.skipBackward, .noSuchContent), (.skipForward, .noSuchContent),
            (.changePosition(30), .commandFailed), (.changeRate(1.5), .noSuchContent),
        ]

        // idle（登録は stopForLogout までは残る）
        let idle = Rig()
        try await idle.play(Self.playable("a"))
        idle.coordinator.removeFromQueue(id: "a")
        XCTAssertEqual(idle.coordinator.session, .idle)
        XCTAssertEqual(idle.spy.activeRegistrationCount, 1, "Given: handler は有効なまま")
        for (command, result) in expected { XCTAssertEqual(idle.spy.invoke(command), result, "idle: \(command)") }
        XCTAssertEqual(idle.coordinator.session, .idle)

        // ended
        let ended = Rig()
        try await ended.play(Self.playable("a"))
        await ended.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await ended.engine.send(.ended)
        await eventually("ended になる") { ended.coordinator.session.isEnded }
        for (command, result) in expected { XCTAssertEqual(ended.spy.invoke(command), result, "ended: \(command)") }
        XCTAssertTrue(ended.coordinator.session.isEnded)

        // errored
        let errored = Rig()
        try await errored.play(Self.playable("a"))
        await errored.engine.send(.failed(description: "x"))
        for (command, result) in expected { XCTAssertEqual(errored.spy.invoke(command), result, "errored: \(command)") }
        XCTAssertEqual(errored.coordinator.session.episodeId, "a")
        XCTAssertFalse(PlaybackRules.isLoaded(errored.coordinator.session))
    }

    // verifies: ios-contract-12（ios-test-086。ロック画面の表示: update / updateElapsed / clear）
    func testT086_lockScreenFollowsTheSessionNotifications() async throws {
        let rig = Rig()
        let a = Self.playable("a", serverPosition: 30, duration: 300)
        try rig.cached(a)
        XCTAssertNil(rig.spy.currentInfo)

        await rig.coordinator.startEpisode(a)  // loading
        XCTAssertEqual(rig.spy.currentInfo, NowPlayingSnapshot(
            title: a.content.displayTitle, subtitle: "sub:toeic_900", elapsed: 30, duration: 300, rate: 1.0, isPlaying: true
        ))

        await rig.engine.send(.ready)
        await rig.engine.send(.timeUpdate(seconds: 40, duration: 310))
        XCTAssertEqual(try XCTUnwrap(rig.spy.lastElapsedUpdate).elapsed, 40)
        XCTAssertEqual(try XCTUnwrap(rig.spy.lastElapsedUpdate).duration, 310)

        await rig.engine.send(.buffering)
        XCTAssertEqual(try XCTUnwrap(rig.spy.currentInfo).isPlaying, true, "buffering は再生中として表示する")
        rig.coordinator.togglePlayPause()  // buffering → paused
        let pausedInfo = try XCTUnwrap(rig.spy.currentInfo)
        XCTAssertFalse(pausedInfo.isPlaying)
        XCTAssertEqual(pausedInfo.elapsed, 40)
        XCTAssertEqual(pausedInfo.duration, 310)
        XCTAssertEqual(pausedInfo.title, a.content.displayTitle)

        rig.coordinator.togglePlayPause()  // paused → playing
        rig.coordinator.setSpeed(1.5)
        XCTAssertEqual(try XCTUnwrap(rig.spy.currentInfo).isPlaying, true)

        await rig.engine.send(.failed(description: "boom"))  // errored
        XCTAssertNil(rig.spy.currentInfo, "errored で clear")
    }

    // verifies: ios-contract-12（ios-test-086。idle と待機列が尽きた ended で clear。ended の間（次の準備中）は触らない）
    func testT086_lockScreenIsClearedOnIdleAndExhaustedEndedButNotWhileAdvancing() async throws {
        let idle = Rig()
        try await idle.play(Self.playable("a"))
        XCTAssertNotNil(idle.spy.currentInfo)
        idle.coordinator.removeFromQueue(id: "a")  // session.stop → idle
        XCTAssertNil(idle.spy.currentInfo, "idle で clear")

        let exhausted = Rig()
        try await exhausted.play(Self.playable("a"))
        await exhausted.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await exhausted.engine.send(.ended)
        await eventually("待機列が尽きた ended で clear") { exhausted.spy.currentInfo == nil }

        let advancing = Rig()
        let next = Self.playable("b")
        try await advancing.play(Self.playable("a"))
        advancing.fetch.respond("b", with: next)
        advancing.fetch.hold("b")
        await advancing.coordinator.addToQueue(next)
        await advancing.engine.send(.ended)
        await eventually("次の準備に入る") { advancing.coordinator.isAdvancing }
        XCTAssertNotNil(advancing.spy.currentInfo, "ended では clear を呼ばない（onEnded が決める）")
        advancing.fetch.release("b")
        await eventually("b が開始される") { advancing.coordinator.session.episodeId == "b" && advancing.coordinator.session != .idle }
    }

    // verifies: ios-contract-12（ios-test-086。登録は開始時に 1 回だけ、stopForLogout で解除）
    func testT086_remoteCommandRegistrationHappensOnceAndIsReleasedByLogout() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        XCTAssertEqual(rig.spy.activeRegistrationCount, 0, "開始前は登録しない")
        try await rig.play(a)
        XCTAssertEqual(rig.spy.activeRegistrationCount, 1)

        try rig.cached(b)
        await rig.coordinator.startEpisode(b)
        XCTAssertEqual(rig.spy.activeRegistrationCount, 1, "開始を 2 回しても登録は 1")
        XCTAssertEqual(rig.spy.registrations.count, 1)

        rig.coordinator.stopForLogout()
        XCTAssertEqual(rig.spy.activeRegistrationCount, 0)
        rig.coordinator.stopForLogout()
        XCTAssertEqual(rig.spy.activeRegistrationCount, 0, "二重の解除は無害")

        try await rig.play(a)
        XCTAssertEqual(rig.spy.activeRegistrationCount, 1, "ログアウト後の開始で登録し直す")
    }

    // verifies: ios-contract-12（ios-test-086。別の Coordinator の破棄で、生きている側の登録は残る。循環参照が無い）
    // kills: handler・Session の handler が Coordinator を強参照して deinit が走らない／deinit で解除しない
    func testT086_releasingAnotherCoordinatorUnregistersOnlyItsOwnCommands() async throws {
        let spy = NowPlayingCenterSpy()
        let alive = Rig(spy: spy)
        try await alive.play(Self.playable("a"))
        XCTAssertEqual(spy.activeRegistrationCount, 1)

        var other: Rig? = Rig(spy: spy)
        try await other?.play(Self.playable("z"))
        XCTAssertEqual(spy.activeRegistrationCount, 2)

        other = nil
        await settle()

        XCTAssertEqual(spy.activeRegistrationCount, 1, "破棄した側の登録は解除され、生きている側の登録が残る")
        XCTAssertEqual(spy.invoke(.pause), .success, "残っているのは生きている Coordinator の handler")
        XCTAssertTrue(alive.coordinator.session.isPausedForTest)
    }

    // MARK: - ios-test-087: 待ちの間の割り込み

    private func startedTask(_ rig: Rig, _ episode: Episode) -> Task<Void, Never> {
        Task { await rig.coordinator.startEpisode(episode) }
    }

    // verifies: ios-contract-12（ios-test-087 (1)(2)。後勝ちと、保留中は前のまま）
    func testT087_laterStartWinsAndNothingChangesWhileWaiting() async throws {
        let rig = Rig()
        let z = Self.playable("z")
        let a = Self.playable("a")
        let b = Self.playable("b")
        try await rig.play(z)
        rig.fetch.respond("a", with: a)
        rig.fetch.hold("a")
        try rig.cached(b)
        let queueBefore = rig.coordinator.queue
        let sessionBefore = rig.coordinator.session

        let waiting = startedTask(rig, a)
        await eventually("a の取得が保留に入る") { rig.fetch.calls.contains("a") }
        XCTAssertEqual(rig.coordinator.queue, queueBefore, "(2) 保留中はキューが前のまま")
        XCTAssertEqual(rig.coordinator.session, sessionBefore, "(2) 保留中は session が前のまま")
        assertSharedInvariant(rig.coordinator, "保留中")

        await rig.coordinator.startEpisode(b)  // (1) B（キャッシュ済み）
        rig.fetch.release("a")
        await waiting.value

        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.coordinator.session, loading(b), "(1) 後から始めた B が勝つ")
        XCTAssertFalse(queueIds(rig.coordinator).contains("a"), "捨てられた開始はキューにも足さない")
    }

    // verifies: ios-contract-12（ios-test-087 (3)。保留中に stopForLogout すると、解放しても何も始まらない）
    func testT087_logoutWhileWaitingDiscardsTheStart() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        rig.fetch.respond("a", with: a)
        rig.fetch.hold("a")

        let waiting = startedTask(rig, a)
        await eventually("a の取得が保留に入る") { rig.fetch.calls.contains("a") }
        rig.coordinator.stopForLogout()
        rig.fetch.release("a")
        await waiting.value

        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertTrue(rig.coordinator.queue.isEmpty)
        XCTAssertEqual(rig.coordinator.session, .idle)
        XCTAssertEqual(rig.spy.activeRegistrationCount, 0)
    }

    // verifies: ios-contract-12（ios-test-087 (4)(7)。自動で次へ進む途中の保留中に先頭を削除すると、新しい先頭が始まる）
    func testT087_removingTheHeadWhileAutoAdvancingStartsTheNewHead() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        let c = Self.playable("c")
        try await rig.play(a)
        try rig.cached(c)
        rig.fetch.respond("b", with: b)
        rig.fetch.hold("b")
        await rig.coordinator.addToQueue(b)
        await rig.coordinator.addToQueue(c)
        XCTAssertFalse(rig.coordinator.isAdvancing)

        await rig.engine.send(.ended)
        await eventually("b の取得が保留に入る") { rig.fetch.calls.contains("b") }
        XCTAssertTrue(rig.coordinator.isAdvancing, "(7) 自動の保留中だけ true")
        XCTAssertEqual(rig.coordinator.queue.current?.id, "a", "保留中はキューが前のまま")

        rig.coordinator.removeFromQueue(id: "b")  // 待機列の先頭を削除
        rig.fetch.release("b")
        await eventually("新しい先頭 c が始まる") { rig.coordinator.session == self.loading(c) }

        XCTAssertEqual(rig.coordinator.queue.current?.id, "c")
        XCTAssertFalse(rig.coordinator.isAdvancing)
        XCTAssertEqual(rig.gateway.marks, ["a"], "完聴は送り直さない")
        XCTAssertGreaterThanOrEqual(rig.environment.backgroundBegan, 1)
        XCTAssertEqual(rig.environment.backgroundBegan, rig.environment.backgroundEnded, "background task は開始と終了が対")
    }

    // verifies: ios-contract-12（ios-test-087 (5)。手動 B の保留中に ended: 自動は始まらず B が始まる）
    // MARK: shared-session-17
    func testT087SharedSession17_manualStartWaitingWhenEndedWinsOverAutoAdvance() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        let c = Self.playable("c")
        try await rig.play(a)
        try rig.cached(c)
        await rig.coordinator.addToQueue(c)
        rig.fetch.respond("b", with: b)
        rig.fetch.hold("b")

        let waiting = startedTask(rig, b)  // (5) 手動 B（未キャッシュ）を保留
        await eventually("b の取得が保留に入る") { rig.fetch.calls.contains("b") }
        await rig.engine.timeUpdateThenEnd()  // a が ended
        await eventually("完聴だけ送られる") { rig.gateway.marks == ["a"] }
        await settle()

        XCTAssertFalse(rig.coordinator.isAdvancing, "手動の保留中は自動の準備に入らない")
        XCTAssertEqual(rig.coordinator.queue.current?.id, "a", "自動で次へ進む処理は始まらない")
        XCTAssertNotEqual(rig.coordinator.session.episodeId, "c")

        rig.fetch.release("b")
        await waiting.value

        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.coordinator.session, loading(b), "B が始まる")
        assertSharedInvariant(rig.coordinator)
    }

    // verifies: ios-contract-12（ios-test-087 (6)。自動 C の保留中に手動 B を保留 → C は捨てられ、B が始まる）
    // MARK: shared-session-17
    func testT087SharedSession17_manualStartDuringAutoAdvanceDiscardsTheAutoSide() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        let c = Self.playable("c")
        try await rig.play(a)
        rig.fetch.respond("b", with: b)
        rig.fetch.respond("c", with: c)
        rig.fetch.hold("b")
        rig.fetch.hold("c")
        await rig.coordinator.addToQueue(c)

        await rig.engine.timeUpdateThenEnd()  // a が ended → 自動 C を保留
        await eventually("c の取得が保留に入る") { rig.fetch.calls.contains("c") }
        XCTAssertTrue(rig.coordinator.isAdvancing)

        let waiting = startedTask(rig, b)  // 手動 B（未キャッシュ）を保留
        await eventually("b の取得が保留に入る") { rig.fetch.calls.contains("b") }

        rig.fetch.release("c")  // C を先に解放
        await eventually("自動の待ちが終わる") { !rig.coordinator.isAdvancing }
        await settle()
        XCTAssertEqual(rig.coordinator.queue.current?.id, "a", "何も始まらない")
        XCTAssertTrue(rig.coordinator.session.isEnded)

        rig.fetch.release("b")
        await waiting.value

        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.coordinator.session, loading(b), "B が始まる")
        assertSharedInvariant(rig.coordinator)
    }

    // verifies: ios-contract-12（ios-test-087 (8)。保留中の fetchEpisode が cancel による error を投げたら何も変わらない）
    func testT087_cancellationErrorFromFetchChangesNothing() async throws {
        for cancellation in [CancellationError() as Error, URLError(.cancelled) as Error] {
            let rig = Rig()
            let a = Self.playable("a")
            rig.fetch.hold("a")

            let waiting = startedTask(rig, a)
            await eventually("a の取得が保留に入る") { rig.fetch.calls.contains("a") }
            rig.fetch.release("a", throwing: cancellation)
            await waiting.value

            XCTAssertFalse(rig.engine.isLoaded)
            XCTAssertTrue(rig.coordinator.queue.isEmpty)
            XCTAssertEqual(rig.coordinator.session, .idle)
            XCTAssertNil(rig.coordinator.notice)
            XCTAssertEqual(rig.coordinator.presentation, .hidden)
        }

        // startEpisode(id:) は受けた cancel の error をそのまま投げ、何も変えない。
        let byId = Rig()
        byId.fetch.hold("x")
        let throwing = Task { () -> Error? in
            do { try await byId.coordinator.startEpisode(id: "x"); return nil } catch { return error }
        }
        await eventually("x の取得が保留に入る") { byId.fetch.calls.contains("x") }
        byId.fetch.release("x", throwing: CancellationError())
        let thrown = await throwing.value
        XCTAssertTrue(thrown is CancellationError)
        XCTAssertEqual(byId.coordinator.session, .idle)
        XCTAssertTrue(byId.coordinator.queue.isEmpty)
        XCTAssertNil(byId.coordinator.notice)
    }

    // MARK: - ios-test-088: stopForLogout

    // verifies: ios-contract-12（ios-test-088）
    // kills: stopForLogout で flush する／2 回目で状態が変わる／token・notice・キューを残す
    func testT088_stopForLogoutResetsEverythingWithoutSendingAPositionAndIsIdempotent() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        try rig.cached(a)
        rig.engine.nextLoadWarning = "warn"
        await rig.coordinator.startEpisode(a)
        await rig.engine.send(.ready)
        await rig.engine.send(.timeUpdate(seconds: 40, duration: 300))
        await rig.coordinator.addToQueue(Self.playable("b"))
        XCTAssertEqual(rig.coordinator.notice, .loadWarning("warn"), "Given: notice がある")

        for _ in 0..<2 {
            rig.coordinator.stopForLogout()
            await settle()

            XCTAssertEqual(rig.gateway.updates, [], "位置の送信 0（主体離脱では送らない）")
            XCTAssertFalse(rig.engine.isLoaded)
            XCTAssertEqual(rig.coordinator.session, .idle)
            XCTAssertTrue(rig.coordinator.queue.isEmpty)
            XCTAssertEqual(rig.coordinator.presentation, .hidden)
            XCTAssertNil(rig.spy.currentInfo)
            XCTAssertNil(rig.coordinator.notice)
            XCTAssertFalse(rig.coordinator.isAdvancing)
            XCTAssertEqual(rig.spy.activeRegistrationCount, 0)
        }
        XCTAssertEqual(rig.gateway.marks, [])
    }

    // MARK: - ios-test-089: そのほかの操作

    // verifies: ios-contract-12（ios-test-089。skipToNext: 次が再生できる）
    // MARK: shared-session-14
    func testT089SharedSession14_skipToNextFlushesOnceStartsTheNextAndSendsNoCompletion() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        try await rig.play(a, expandsPlayer: false)
        try rig.cached(b)
        await rig.coordinator.addToQueue(b)
        await rig.engine.timeUpdate(40)

        await rig.coordinator.skipToNext()
        await eventually("位置を 1 回送る") { rig.gateway.updates == [Update(id: "a", seconds: 40)] }

        XCTAssertEqual(rig.coordinator.session, loading(b), "次が始まる")
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.gateway.marks, [], "完聴は送らない（markCompleted 0 回）")
        XCTAssertEqual(rig.coordinator.presentation, .mini, "表示形態は不変（expandsPlayer: false の規則）")
        await settle()
        XCTAssertEqual(rig.gateway.updates, [Update(id: "a", seconds: 40)])
        assertSharedInvariant(rig.coordinator)
    }

    // verifies: ios-contract-12（ios-test-089。skipToNext: 次が開始前に再生不可なら notice だけ）
    // MARK: shared-session-15
    func testT089SharedSession15_skipToNextThatFailsTheStartCheckOnlySetsTheNotice() async throws {
        for next in [generating("b"), Self.playable("b")] {
            let rig = Rig()
            try await rig.play(Self.playable("a"))
            await rig.coordinator.addToQueue(next)
            if next.isPlayable { rig.environment.online = false }
            let sessionBefore = rig.coordinator.session
            let queueBefore = rig.coordinator.queue

            await rig.coordinator.skipToNext()

            XCTAssertEqual(rig.coordinator.session, sessionBefore, "a の再生が続く")
            XCTAssertEqual(rig.coordinator.queue, queueBefore, "キューは進めない")
            XCTAssertEqual(rig.coordinator.notice, .failure(next.isPlayable ? .offlineUncached : .invalidSource))
            XCTAssertEqual(rig.gateway.marks, [])
        }
    }

    // verifies: ios-contract-12（ios-test-089。skipToNext: 待機列が空なら何もしない）
    // MARK: shared-session-16
    func testT089SharedSession16_skipToNextWithEmptyUpNextDoesNothing() async throws {
        let rig = Rig()
        try await rig.play(Self.playable("a"))
        let sessionBefore = rig.coordinator.session
        let queueBefore = rig.coordinator.queue

        await rig.coordinator.skipToNext()

        XCTAssertEqual(rig.coordinator.session, sessionBefore)
        XCTAssertEqual(rig.coordinator.queue, queueBefore)
        XCTAssertNil(rig.coordinator.notice)
        XCTAssertEqual(rig.gateway.updates, [])
        XCTAssertEqual(rig.fetch.calls, [])
    }

    // verifies: ios-contract-12（ios-test-089。togglePlayPause の状態ごとの表）
    func testT089_togglePlayPauseFollowsTheStateTable() async throws {
        let a = Self.playable("a")

        let loadingRig = Rig()
        try loadingRig.cached(a)
        await loadingRig.coordinator.startEpisode(a)
        loadingRig.coordinator.togglePlayPause()
        XCTAssertTrue(loadingRig.coordinator.session.isPausedForTest, "loading → pause")

        let playing = Rig()
        try await playing.play(a)
        playing.coordinator.togglePlayPause()
        XCTAssertTrue(playing.coordinator.session.isPausedForTest, "playing → pause")
        playing.coordinator.togglePlayPause()
        XCTAssertEqual(playing.coordinator.session.episodeId, "a")
        XCTAssertFalse(playing.coordinator.session.isPausedForTest, "paused → play")
        XCTAssertEqual(playing.engine.rate, 1.0)

        let buffering = Rig()
        try await buffering.play(a)
        await buffering.engine.send(.buffering)
        buffering.coordinator.togglePlayPause()
        XCTAssertTrue(buffering.coordinator.session.isPausedForTest, "buffering → pause")

        let ended = Rig()
        try await ended.play(a)
        await ended.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await ended.engine.send(.ended)
        await eventually("ended になる") { ended.coordinator.session.isEnded }
        let endedState = ended.coordinator.session
        ended.coordinator.togglePlayPause()
        await settle()
        XCTAssertEqual(ended.coordinator.session, endedState, "ended は何もしない")

        let idle = Rig()
        idle.coordinator.togglePlayPause()
        await settle()
        XCTAssertEqual(idle.coordinator.session, .idle, "idle は何もしない")
        XCTAssertEqual(idle.fetch.calls, [])

        let errored = Rig()
        try await errored.play(a)
        await errored.engine.send(.failed(description: "x"))
        errored.coordinator.togglePlayPause()  // retry
        await eventually("errored の togglePlayPause は retry") { errored.coordinator.session == self.loading(a) }
    }

    // verifies: ios-contract-12（ios-test-089。割り込み: 再生中に開始 → 終了（再開してよい）で再開する）
    func testT089_resumesAfterAnInterruptionThatBeganWhilePlaying() async throws {
        let rig = Rig()
        try await rig.play(Self.playable("a"))

        await rig.engine.send(.interrupted)
        XCTAssertTrue(rig.coordinator.session.isPausedForTest)
        await rig.engine.send(.interruptionEnded(shouldResume: true))

        XCTAssertFalse(rig.coordinator.session.isPausedForTest, "再開してよいので session.play() で再開する")
        XCTAssertEqual(rig.coordinator.session.episodeId, "a")
        XCTAssertEqual(rig.engine.rate, 1.0)
    }

    // verifies: ios-contract-12（ios-test-089。一時停止中の割り込み・再開してはいけない終了・記憶は 1 回で消える）
    func testT089_doesNotResumeWhenPausedBeforeOrNotAllowedAndTheMemoryIsConsumed() async throws {
        // 一時停止中に開始 → 再開しない
        let wasPaused = Rig()
        try await wasPaused.play(Self.playable("a"))
        wasPaused.coordinator.togglePlayPause()
        await wasPaused.engine.send(.interrupted)
        await wasPaused.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(wasPaused.coordinator.session.isPausedForTest, "一時停止中に始まった割り込みでは再開しない")

        // shouldResume が false → 再開しない
        let denied = Rig()
        try await denied.play(Self.playable("a"))
        await denied.engine.send(.interrupted)
        await denied.engine.send(.interruptionEnded(shouldResume: false))
        XCTAssertTrue(denied.coordinator.session.isPausedForTest)

        // 記憶は終了で消える: 再開した後に利用者が一時停止し、開始のない終了だけが来ても再開しない。
        let consumed = Rig()
        try await consumed.play(Self.playable("a"))
        await consumed.engine.send(.interrupted)
        await consumed.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(consumed.coordinator.session.isPausedForTest)
        consumed.coordinator.togglePlayPause()
        await consumed.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(consumed.coordinator.session.isPausedForTest, "覚えた値は消えているので再開しない")
    }

    // verifies: ios-contract-12（ios-test-089。dismissError は notice を消し errored を変えない）
    func testT089_dismissErrorClearsTheNoticeButKeepsTheErroredState() async throws {
        let rig = Rig()
        try await rig.play(Self.playable("a"))
        await rig.engine.send(.failed(description: "boom"))
        let erroredState = rig.coordinator.session
        XCTAssertNotNil(rig.coordinator.notice)

        rig.coordinator.dismissError()

        XCTAssertNil(rig.coordinator.notice)
        XCTAssertEqual(rig.coordinator.session, erroredState)
        XCTAssertEqual(rig.coordinator.queue.current?.id, "a")
    }

    // verifies: ios-contract-12（onEnded の古い通知（endedId != queue.current?.id）は無視）
    func testOnEndedIgnoresAStaleNotification() async throws {
        let rig = Rig()
        try await rig.play(Self.playable("a"))
        await rig.coordinator.addToQueue(Self.playable("b"))
        let sessionBefore = rig.coordinator.session
        let queueBefore = rig.coordinator.queue

        await rig.coordinator.onEnded(endedId: "not-current")

        XCTAssertEqual(rig.gateway.marks, [], "完聴を送らない")
        XCTAssertEqual(rig.coordinator.session, sessionBefore)
        XCTAssertEqual(rig.coordinator.queue, queueBefore)
        XCTAssertFalse(rig.coordinator.isAdvancing)
        XCTAssertEqual(rig.fetch.calls, [])
    }

    // MARK: - stop

    // verifies: ios-dec-40
    // kills: session.stop() の後に flush して位置が送られない／キューや表示形態を巻き込んで消す／flush を 2 回送る
    func testStopFlushesPositionThenStopsSessionKeepingQueueAndPresentation() async throws {
        let rig = Rig()
        let a = Self.playable("a")
        let b = Self.playable("b")
        try await rig.play(a, expandsPlayer: true)
        try rig.cached(b)
        await rig.coordinator.addToQueue(b)
        await rig.engine.timeUpdate(40)
        let queueBefore = rig.coordinator.queue
        let presentationBefore = rig.coordinator.presentation
        let noticeBefore = rig.coordinator.notice
        let registrationsBefore = rig.spy.activeRegistrationCount
        let clearsBefore = rig.spy.clearCallCount
        XCTAssertEqual(presentationBefore, .expanded, "Given: 展開表示")
        XCTAssertEqual(rig.gateway.updates, [], "Given: まだ送っていない")
        XCTAssertGreaterThan(registrationsBefore, 0, "Given: リモートコマンドが登録済み")

        rig.coordinator.stop()
        await eventually("位置を 1 回送る") { rig.gateway.updates == [Update(id: "a", seconds: 40)] }
        await settle()

        XCTAssertEqual(rig.gateway.updates, [Update(id: "a", seconds: 40)], "session.stop() より前に flush されたので、停止後でも 40 を 1 回だけ送る")
        XCTAssertEqual(rig.coordinator.session, .idle)
        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertEqual(rig.coordinator.queue, queueBefore)
        XCTAssertEqual(rig.coordinator.presentation, presentationBefore)
        XCTAssertEqual(rig.coordinator.notice, noticeBefore)
        XCTAssertEqual(rig.spy.activeRegistrationCount, registrationsBefore)
        XCTAssertGreaterThan(rig.spy.clearCallCount, clearsBefore, "ロック画面を clear する")
        XCTAssertNil(rig.spy.currentInfo)
        XCTAssertEqual(rig.gateway.marks, [])

        rig.coordinator.stop()
        await settle()
        XCTAssertEqual(rig.gateway.updates, [Update(id: "a", seconds: 40)], "2 回目の stop は送らない")
    }
}

private extension AudioEngineDouble {
    /// 現在の再生が終端に達した事象（総時間が分かっている）。
    func timeUpdateThenEnd() async {
        await send(.timeUpdate(seconds: 299, duration: 300))
        await send(.ended)
    }

    func timeUpdate(_ seconds: Double) async {
        await send(.timeUpdate(seconds: seconds, duration: 300))
    }
}

private extension PlaybackState {
    var isPausedForTest: Bool {
        if case .paused = self { return true }
        return false
    }
}
