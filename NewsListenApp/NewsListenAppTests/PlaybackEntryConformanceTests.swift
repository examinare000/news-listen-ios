import Combine
import XCTest
@testable import NewsListenApp

/// 再生の入口（`PodcastViewModel`）越しに、Coordinator・Session・Reporter・保存庫・ダウンロードの契約を観測する準拠テスト。
/// facade は中継するだけなので、期待値は下位の契約（shared-session-01〜10）そのもの。
/// 組み立てと double は `PlaybackEntryTestSupport.swift` を共用する。
@MainActor
final class PlaybackEntryConformanceTests: XCTestCase {
    private let uiInvalidAudio = "Invalid audio URL"
    private let uiOfflineUncached = "Offline and not cached"

    // MARK: - 共通の補助

    /// 条件が成り立つまで短く間隔を置いて待つ。非同期の完了（完聴の送信・世代付きの開始）に同期の合図が無いため。
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("待ち条件が満たされなかった: \(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    /// 「起きないこと」の確認の前に、保留中の Task を流す。不在には合図が無いので、必ず同じ入口の正方向対照と組にする。
    private func settle() async {
        for _ in 0..<25 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func url(_ id: String) -> URL { URL(string: "https://cdn.example.com/\(id).mp3")! }

    /// 保存庫に置いて、`ready` を送らずに開始する（`loading` で止める）。
    private func startCachedWithoutReady(_ rig: PlaybackEntryRig, _ id: String, duration: Int = 300) async throws {
        try rig.cached(id)
        await rig.viewModel.startEpisode(EntryFixture.podcast(id, durationSeconds: duration))
    }

    /// 否定形の確認の正方向対照: 同じ入口から、再生中なら位置が送られる。`before` 以降に送られたのが `id` の 1 件だけであること。
    private func assertPositionStillSent(
        _ rig: PlaybackEntryRig,
        id: String,
        since before: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await rig.play(id)
        await rig.engine.send(.timeUpdate(seconds: 7, duration: 300))
        rig.viewModel.flushPosition()
        await waitUntil("正方向対照の位置送信") { rig.gateway.updates.count > before }
        XCTAssertEqual(rig.gateway.updates.dropFirst(before).map(\.id), [id], file: file, line: line)
        XCTAssertEqual(rig.gateway.updates.last?.seconds, 7, file: file, line: line)
    }

    private struct SampleFailure: LocalizedError {
        var errorDescription: String? { "sample failure" }
    }

    private final class ViewModelBox {
        weak var target: PodcastViewModel?
    }

    /// `[a, b]` で a を再生中にし、b は未キャッシュ・取り直しが失敗する状態から a を終えて、b の読み込みまで進める。
    private func makeAutoAdvanceIntoUnresolvedNext() async throws -> PlaybackEntryRig {
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        await rig.viewModel.addToQueue(EntryFixture.podcast("b"))
        await rig.engine.send(.ended)
        await waitUntil("b の読み込み") { rig.engine.loadedURL == self.url("b") }
        return rig
    }

    // MARK: - 自動で次へ進んだ先の失敗（shared-session-01〜03）

    func testSharedSession01_autoAdvanceFailureStopsOnFailedEpisode() async throws {
        // verifies: ios-contract-11
        let rig = try await makeAutoAdvanceIntoUnresolvedNext()
        // 取り直しは失敗し、保持している URL の読み込みを engine も失敗させる。
        await rig.engine.send(.failed(description: "boom"))

        guard case .errored(let id, _, let reason) = rig.viewModel.session else {
            return XCTFail("errored になっていない: \(rig.viewModel.session)")
        }
        XCTAssertEqual(id, "b")
        XCTAssertEqual(reason, .engineFailed(description: "boom"))
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.coordinator.queue.items.map(\.id), ["a", "b"])
        XCTAssertFalse(rig.engine.isLoaded, "失敗の後に自動で次へ進んではならない")
        XCTAssertEqual(rig.viewModel.errorMessage, "boom")
        // 刺激が届いた証拠: b の取り直しを試みていた。
        XCTAssertEqual(rig.gateway.fetches, ["b"])
    }

    func testSharedSession02_manualRetryResolvesFailedEpisodeAgain() async throws {
        // verifies: ios-contract-11
        let rig = try await makeAutoAdvanceIntoUnresolvedNext()
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(rig.viewModel.session.kind, "errored")

        rig.serve(EntryFixture.playable("b"))
        await rig.viewModel.retry()
        await rig.engine.send(.ready)

        XCTAssertEqual(rig.viewModel.session.kind, "playing")
        XCTAssertEqual(rig.viewModel.session.episodeId, "b")
        XCTAssertTrue(rig.viewModel.isPlaying)
        XCTAssertNil(rig.viewModel.errorMessage)
        XCTAssertEqual(rig.gateway.fetches, ["b", "b"], "再試行は b を取り直し直す")
    }

    func testSharedSession03_offlineUncachedNextDoesNotFetch() async throws {
        // verifies: ios-contract-11
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        await rig.viewModel.addToQueue(EntryFixture.podcast("b"))
        rig.network.isOnline = false

        await rig.engine.send(.ended)
        await waitUntil("b で errored") { rig.viewModel.session.kind == "errored" }

        guard case .errored(let id, _, let reason) = rig.viewModel.session else {
            return XCTFail("errored になっていない")
        }
        XCTAssertEqual(id, "b")
        XCTAssertEqual(reason, .offlineUncached)
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(rig.viewModel.errorMessage, uiOfflineUncached)
        XCTAssertEqual(rig.gateway.fetches, [], "オフラインで未キャッシュなら取得を試みない")
    }

    // MARK: - 通知・一覧からの入口が 1 経路（shared-session-04）

    func testSharedSession04_playByIdGoesThroughQueue() async throws {
        // verifies: ios-contract-12
        let rig = PlaybackEntryRig(
            session: MockURLSession(data: try EntryFixture.podcastListJSON([EntryFixture.podcast("x")]), statusCode: 200))
        await rig.viewModel.loadPodcasts()
        rig.serve(EntryFixture.playable("x"))

        await rig.viewModel.startEpisode(id: "x")

        XCTAssertEqual(rig.coordinator.queue.current?.id, "x")
        XCTAssertEqual(rig.coordinator.queue.items.map(\.id), ["x"])
        XCTAssertEqual(rig.viewModel.nowPlaying()?.episodeId, "x")
        XCTAssertEqual(rig.engine.loadedURL, url("x"), "開始は取得の応答の後")
        XCTAssertEqual(rig.gateway.fetches, ["x"])
    }

    // MARK: - 位置の送信（shared-session-05〜07）

    func testSharedSession05_noPositionSentWhenErroredOrIdle() async throws {
        // verifies: ios-contract-13
        let rig = PlaybackEntryRig()
        // idle
        rig.viewModel.flushPosition()
        rig.viewModel.stop()
        // errored。失敗の後の周期更新は届かない（channel が閉じる）。
        try await rig.play("a")
        let channelA = try XCTUnwrap(rig.engine.currentChannel)
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        rig.clock.advance(60)
        XCTAssertEqual(channelA.yield(.timeUpdate(seconds: 20, duration: 300)), .dropped)
        rig.viewModel.stop()
        rig.viewModel.flushPosition()
        await settle()
        let before = rig.gateway.updates.count
        XCTAssertEqual(before, 0)

        try await assertPositionStillSent(rig, id: "c", since: before)
    }

    func testSharedSession05_backgroundFlushTwiceSendsOnce() async throws {
        // verifies: ios-contract-13
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        await rig.engine.send(.timeUpdate(seconds: 30, duration: 300))

        rig.viewModel.flushPosition()
        rig.viewModel.flushPosition()
        await waitUntil("位置の送信") { rig.gateway.updates.count >= 1 }
        await settle()

        XCTAssertEqual(rig.gateway.updates.count, 1)
        XCTAssertEqual(rig.gateway.updates.first?.id, "a")
        XCTAssertEqual(rig.gateway.updates.first?.seconds, 30)
    }

    func testSharedSession05_backgroundFlushSendsNothingInEndedErroredIdle() async throws {
        // verifies: ios-contract-13
        let rig = PlaybackEntryRig()
        // idle
        rig.viewModel.flushPosition()

        // ended。完聴の総時間書込が済んでから数える。
        try await rig.play("a")
        await rig.engine.send(.ended)
        await waitUntil("完聴の記録") { rig.completions.count == 1 }
        XCTAssertEqual(rig.viewModel.session.kind, "ended")
        rig.viewModel.flushPosition()

        // errored
        try await rig.play("b")
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        rig.viewModel.flushPosition()

        await settle()
        let before = rig.gateway.updates.count
        XCTAssertEqual(rig.gateway.updates.map(\.id), ["a"], "送られたのは a の完聴の総時間書込だけ")

        try await assertPositionStillSent(rig, id: "c", since: before)
    }

    func testSharedSession05_loadingSeekThenStopSendsNothing() async throws {
        // verifies: ios-contract-13
        // ready より前の読み込み中は、seek 先も保存しない（ios-dec-47）。
        let rig = PlaybackEntryRig()
        try await startCachedWithoutReady(rig, "a")
        XCTAssertEqual(rig.viewModel.session.kind, "loading")

        rig.viewModel.seek(to: 42)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 42, "seek が engine まで届いた")
        rig.viewModel.flushPosition()
        rig.viewModel.stop()
        await settle()
        let before = rig.gateway.updates.count
        XCTAssertEqual(before, 0)
        XCTAssertEqual(rig.viewModel.session.kind, "idle")

        try await assertPositionStillSent(rig, id: "c", since: before)
    }

    func testSharedSession06_pauseSendsOnceAndNoPeriodicWhilePaused() async throws {
        // verifies: ios-contract-13
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        await rig.engine.send(.timeUpdate(seconds: 10, duration: 300))

        rig.viewModel.togglePlayPause()
        await waitUntil("一時停止時の送信") { rig.gateway.updates.count == 1 }
        XCTAssertEqual(rig.gateway.updates.first?.seconds, 10)
        XCTAssertEqual(rig.viewModel.session.kind, "paused")

        // 一時停止中に周期の 15 秒が過ぎても送らない。
        rig.clock.advance(20)
        await rig.engine.send(.timeUpdate(seconds: 20, duration: 300))
        XCTAssertEqual(rig.viewModel.session.position, 20, "周期更新が届いた")
        await settle()
        XCTAssertEqual(rig.gateway.updates.count, 1)

        // 正方向対照: 再生に戻れば周期の送信は再開する。
        rig.viewModel.togglePlayPause()
        rig.clock.advance(16)
        await rig.engine.send(.timeUpdate(seconds: 30, duration: 300))
        await waitUntil("再生中の周期送信") { rig.gateway.updates.count == 2 }
        XCTAssertEqual(rig.gateway.updates.last?.seconds, 30)
    }

    func testSharedSession07_completionThenDurationWriteThenAdvance() async throws {
        // verifies: ios-contract-13
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        try rig.cached("b")
        await rig.viewModel.addToQueue(EntryFixture.podcast("b"))
        let channelA = try XCTUnwrap(rig.engine.currentChannel)

        await rig.engine.send(.ended)
        await waitUntil("完聴の記録") { rig.completions.count == 1 }
        await waitUntil("b の開始") { rig.viewModel.session.episodeId == "b" }

        // 同じ再生の 2 回目の終了は捨てられ、完聴は 1 回のまま。
        XCTAssertEqual(channelA.yield(.ended), .dropped)
        await settle()

        XCTAssertEqual(rig.gateway.events, [.markCompleted("a"), .updatePosition(id: "a", seconds: 300)])
        XCTAssertEqual(rig.completions.count, 1)
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
    }

    // MARK: - 再生できない行（shared-session-08・09）

    /// 何も変えずに拒否される: セッション・キュー・engine は不変で、通知だけが出る。
    private func assertTapIsRejected(
        _ rig: PlaybackEntryRig,
        _ podcast: Podcast,
        badge: PodcastViewModel.RowBadge,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let vm = rig.viewModel
        let sessionBefore = vm.session
        let queueBefore = rig.coordinator.queue.items.map(\.id)
        let indexBefore = rig.coordinator.queue.currentIndex
        let loadedBefore = rig.engine.loadedURL
        vm.dismissError()
        XCTAssertNil(vm.errorMessage, file: file, line: line)

        await vm.startEpisode(podcast)

        XCTAssertEqual(vm.errorMessage, uiInvalidAudio, file: file, line: line)
        XCTAssertEqual(vm.session, sessionBefore, file: file, line: line)
        XCTAssertEqual(rig.coordinator.queue.items.map(\.id), queueBefore, file: file, line: line)
        XCTAssertEqual(rig.coordinator.queue.currentIndex, indexBefore, file: file, line: line)
        XCTAssertEqual(rig.engine.loadedURL, loadedBefore, file: file, line: line)
        XCTAssertEqual(vm.rowBadge(for: podcast), badge, file: file, line: line)
    }

    func testSharedSession08_unplayableRowTapChangesNothing() async throws {
        // verifies: ios-contract-17
        let rig = PlaybackEntryRig()
        try await rig.play("base")
        await assertTapIsRejected(rig, EntryFixture.podcast("e1", errorMessage: "generation failed"), badge: .failed)
        await assertTapIsRejected(rig, EntryFixture.podcast("e2", audioUrl: ""), badge: .failed)
        await assertTapIsRejected(rig, EntryFixture.podcast("e3", status: "unknown_status"), badge: .failed)
        await assertTapIsRejected(rig, EntryFixture.podcast("e4", status: "processing"), badge: .generating)

        // 正方向対照: 再生できる行は同じ入口で開始され、バッジは付かない。
        let playable = EntryFixture.podcast("ok")
        try rig.cached("ok")
        XCTAssertEqual(rig.viewModel.rowBadge(for: playable), PodcastViewModel.RowBadge.none)
        await rig.viewModel.startEpisode(playable)
        XCTAssertEqual(rig.coordinator.queue.current?.id, "ok")
        XCTAssertNil(rig.viewModel.errorMessage)
    }

    func testSharedSession09_partialFailedWithAudioIsNotPlayable() async throws {
        // verifies: ios-contract-17
        let rig = PlaybackEntryRig()
        try await rig.play("base")
        await assertTapIsRejected(rig, EntryFixture.podcast("pf", status: "partial_failed"), badge: .failed)
    }

    // MARK: - 速度（shared-session-10）

    func testSharedSession10_eachStartResetsToDefaultSpeedAndApplies() async throws {
        // verifies: ios-contract-09
        let rig = PlaybackEntryRig(defaultSpeed: 1.5)
        try await rig.play("a")
        rig.viewModel.setSpeed(2.0)
        XCTAssertEqual(rig.viewModel.playbackSpeed, 2.0)
        XCTAssertEqual(rig.engine.rate, 2.0)

        try rig.cached("b")
        await rig.viewModel.startEpisode(EntryFixture.podcast("b"))
        await rig.engine.send(.ready)

        XCTAssertEqual(rig.viewModel.session.episodeId, "b")
        XCTAssertEqual(rig.viewModel.playbackSpeed, 1.5)
        XCTAssertEqual(rig.engine.rate, 1.5, "表示だけでなく engine の速度も既定に戻る")
    }

    func testSharedSession10_setSpeedOutsidePlaybackIsIgnored() async throws {
        // verifies: ios-dec-48
        let rig = PlaybackEntryRig(defaultSpeed: 1.25)
        // idle
        rig.viewModel.setSpeed(2.0)
        XCTAssertEqual(rig.viewModel.playbackSpeed, 1.25)

        // 正方向対照: 再生中なら効く。続けて ended。
        try await rig.play("a")
        rig.viewModel.setSpeed(2.0)
        XCTAssertEqual(rig.viewModel.playbackSpeed, 2.0)
        await rig.engine.send(.ended)
        await waitUntil("ended") { rig.viewModel.session.kind == "ended" }
        rig.viewModel.setSpeed(1.5)
        XCTAssertEqual(rig.viewModel.playbackSpeed, 1.25)

        // errored
        try await rig.play("b")
        rig.viewModel.setSpeed(2.0)
        XCTAssertEqual(rig.viewModel.playbackSpeed, 2.0)
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        rig.viewModel.setSpeed(1.5)
        XCTAssertEqual(rig.viewModel.playbackSpeed, 1.25)
    }

    // MARK: - engine の事象の反映

    func testBufferingBeforeReadyIsNotShown() async throws {
        // verifies: ios-dec-49
        let rig = PlaybackEntryRig()
        try await startCachedWithoutReady(rig, "a")
        XCTAssertEqual(rig.viewModel.session.kind, "loading")

        await rig.engine.send(.buffering)
        XCTAssertFalse(rig.viewModel.isBuffering)
        XCTAssertEqual(rig.viewModel.session.kind, "loading")

        // 正方向対照: ready の後の buffering は表示する。
        await rig.engine.send(.ready)
        await rig.engine.send(.buffering)
        XCTAssertTrue(rig.viewModel.isBuffering)
    }

    func testBufferingWhilePausedIsNotShown() async throws {
        // verifies: ios-dec-54
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        rig.viewModel.togglePlayPause()
        XCTAssertEqual(rig.viewModel.session.kind, "paused")

        await rig.engine.send(.buffering)
        XCTAssertFalse(rig.viewModel.isBuffering)
        XCTAssertEqual(rig.viewModel.session.kind, "paused")

        // 正方向対照: 再生中に戻れば表示する。
        rig.viewModel.togglePlayPause()
        await rig.engine.send(.buffering)
        XCTAssertTrue(rig.viewModel.isBuffering)
    }

    func testEngineStopWhileBufferingShowsPaused() async throws {
        // verifies: ios-contract-03
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        await rig.engine.send(.buffering)
        XCTAssertTrue(rig.viewModel.isBuffering)

        await rig.engine.send(.paused)

        XCTAssertEqual(rig.viewModel.session.kind, "paused")
        XCTAssertFalse(rig.viewModel.isPlaying)
        XCTAssertFalse(rig.viewModel.isBuffering)
    }

    func testTimeUpdateBeforeReadyDoesNotChangeDisplay() async throws {
        // verifies: ios-dec-53
        let rig = PlaybackEntryRig()
        try await startCachedWithoutReady(rig, "a", duration: 200)
        XCTAssertEqual(rig.viewModel.session.position, 0)
        XCTAssertEqual(rig.viewModel.session.duration, 200)

        await rig.engine.send(.timeUpdate(seconds: 10, duration: 300))
        XCTAssertEqual(rig.viewModel.session.position, 0)
        XCTAssertEqual(rig.viewModel.session.duration, 200)
        XCTAssertEqual(rig.viewModel.session.kind, "loading")

        // 正方向対照: ready の後は反映する。
        await rig.engine.send(.ready)
        await rig.engine.send(.timeUpdate(seconds: 10, duration: 300))
        XCTAssertEqual(rig.viewModel.session.position, 10)
        XCTAssertEqual(rig.viewModel.session.duration, 300)
    }

    func testFailureWhilePausedSurfacesOnNextPlay() async throws {
        // verifies: ios-dec-52
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        rig.viewModel.togglePlayPause()
        XCTAssertEqual(rig.viewModel.session.kind, "paused")

        await rig.engine.send(.failed(description: "boom"))
        XCTAssertNil(rig.viewModel.errorMessage)
        XCTAssertFalse(rig.viewModel.isPlaying)
        XCTAssertEqual(rig.viewModel.session.kind, "paused")

        rig.viewModel.togglePlayPause()
        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        XCTAssertEqual(rig.viewModel.errorMessage, "boom")
    }

    func testEndedWhilePausedCompletesOnNextPlay() async throws {
        // verifies: ios-dec-52
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        rig.viewModel.togglePlayPause()
        XCTAssertEqual(rig.viewModel.session.kind, "paused")

        await rig.engine.send(.ended)
        await settle()
        XCTAssertFalse(rig.viewModel.isFinished)
        XCTAssertEqual(rig.completions.count, 0)
        XCTAssertEqual(rig.gateway.marks, [])

        rig.viewModel.togglePlayPause()
        await waitUntil("完聴の記録") { rig.completions.count == 1 }
        XCTAssertEqual(rig.gateway.marks, ["a"])
        XCTAssertTrue(rig.viewModel.isFinished)
    }

    func testEventsAfterFailureAreDropped() async throws {
        // verifies: ios-dec-52
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        let channelA = try XCTUnwrap(rig.engine.currentChannel)
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        XCTAssertEqual(channelA.yield(.ended), .dropped)

        await settle()
        XCTAssertEqual(rig.viewModel.nowPlaying()?.episodeId, "a")
        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        XCTAssertEqual(rig.completions.count, 0)
        XCTAssertEqual(rig.gateway.marks, [])
    }

    func testFailureClearsLockScreenInfo() async throws {
        // verifies: ios-deriv-12
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        XCTAssertNotNil(rig.spy.currentInfo, "再生中はロック画面に出ている")

        await rig.engine.send(.failed(description: "boom"))

        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        XCTAssertNil(rig.spy.currentInfo)
    }

    // MARK: - 表示値

    func testEndedDisplaysTotalDurationAsPositionAndDuration() async throws {
        // verifies: ios-dec-50
        let rig = PlaybackEntryRig()
        try await rig.play("a", duration: 300)
        await rig.engine.send(.timeUpdate(seconds: 120, duration: 300))

        await rig.engine.send(.ended)
        await waitUntil("ended") { rig.viewModel.session.kind == "ended" }

        XCTAssertEqual(rig.viewModel.session.position, 300)
        XCTAssertEqual(rig.viewModel.session.duration, 300)
    }

    func testErroredDisplaysZeroDurationAndNoBuffering() async throws {
        // verifies: ios-dec-50
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        await rig.engine.send(.timeUpdate(seconds: 40, duration: 300))
        await rig.engine.send(.buffering)
        XCTAssertTrue(rig.viewModel.isBuffering)
        XCTAssertEqual(rig.viewModel.session.duration, 300)

        await rig.engine.send(.failed(description: "boom"))

        XCTAssertEqual(rig.viewModel.session.kind, "errored")
        XCTAssertEqual(rig.viewModel.session.duration, 0)
        XCTAssertFalse(rig.viewModel.isBuffering)
        XCTAssertEqual(rig.viewModel.session.position, 40)
    }

    func testDurationIsKnownFromStartAndSeekIsClamped() async throws {
        // verifies: ios-contract-05
        let rig = PlaybackEntryRig()
        try await startCachedWithoutReady(rig, "a", duration: 200)
        XCTAssertEqual(rig.viewModel.session.duration, 200, "開始直後から総時間が出る")
        rig.viewModel.seek(to: 500)
        XCTAssertEqual(rig.viewModel.session.position, 200)
        rig.viewModel.seek(to: -3)
        XCTAssertEqual(rig.viewModel.session.position, 0)

        await rig.engine.send(.ready)
        // engine が総時間を知らせない（0）間でも、総時間は 0 に戻らない。
        await rig.engine.send(.timeUpdate(seconds: 10, duration: 0))
        XCTAssertEqual(rig.viewModel.session.position, 10)
        XCTAssertEqual(rig.viewModel.session.duration, 200)
        rig.viewModel.seek(to: 40)
        XCTAssertEqual(rig.viewModel.session.position, 40)
        XCTAssertEqual(rig.viewModel.session.duration, 200)
        rig.viewModel.seek(to: 999)
        XCTAssertEqual(rig.viewModel.session.position, 200)
        rig.viewModel.seek(to: -5)
        XCTAssertEqual(rig.viewModel.session.position, 0)
        XCTAssertEqual(rig.viewModel.session.duration, 200)
    }

    // MARK: - 取り直し・位置の応答・キュー

    func testOnlineUncachedStartRefetchesBeforeLoading() async throws {
        // verifies: ios-contract-10
        let rig = PlaybackEntryRig()
        let fresh = "https://cdn.example.com/fresh-a.mp3"
        rig.serve(EntryFixture.playable("a", url: fresh, serverPosition: 77))
        rig.fetch.hold("a")

        let started = Task { await rig.viewModel.startEpisode(EntryFixture.podcast("a")) }
        await waitUntil("取り直しの待ち") { rig.fetch.parkedCount("a") == 1 }
        XCTAssertFalse(rig.engine.isLoaded, "応答の前に読み込みを始めてはならない")

        rig.fetch.release("a")
        await started.value

        XCTAssertEqual(rig.gateway.fetches, ["a"])
        XCTAssertEqual(rig.engine.loadedURL, URL(string: fresh))
        XCTAssertEqual(rig.engine.lastSeekSeconds, 77, "再開位置も取り直した値")
    }

    func testPositionResponseReplacesPodcastInList() async throws {
        // verifies: ios-contract-13
        let box = ViewModelBox()
        let liveClient = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(
                data: try JSONEncoder().encode(EntryFixture.podcast("a", playbackPositionSeconds: 42)), statusCode: 200))
        let live = PlaybackGateway.live(apiClient: liveClient, onPodcastUpdated: { box.target?.replacePodcast($0) })
        let list = [EntryFixture.podcast("a"), EntryFixture.podcast("other")]
        let rig = PlaybackEntryRig(
            session: MockURLSession(data: try EntryFixture.podcastListJSON(list), statusCode: 200),
            updatePosition: live.updatePosition)
        box.target = rig.viewModel
        await rig.viewModel.loadPodcasts()
        XCTAssertEqual(rig.viewModel.podcasts.map(\.playbackPositionSeconds), [0, 0])

        try await rig.play("a")
        await rig.engine.send(.timeUpdate(seconds: 42, duration: 300))
        rig.viewModel.flushPosition()

        await waitUntil("一覧の位置の置き換え") { rig.viewModel.podcasts.first?.playbackPositionSeconds == 42 }
        XCTAssertEqual(rig.viewModel.podcasts.map(\.id), ["a", "other"])
        XCTAssertEqual(rig.viewModel.podcasts.last?.playbackPositionSeconds, 0, "同じ id の要素だけを置き換える")
    }

    func testRemovingCurrentEpisodeStopsWithoutAutoStart() async throws {
        // verifies: ios-dec-40
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        try rig.cached("b")
        await rig.viewModel.addToQueue(EntryFixture.podcast("b"))
        XCTAssertNotNil(rig.viewModel.nowPlaying())

        rig.viewModel.removeFromQueue(id: "a")
        await settle()

        XCTAssertEqual(rig.viewModel.session.kind, "idle")
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertNil(rig.viewModel.nowPlaying())
        XCTAssertNil(rig.viewModel.nowPlaying())
        XCTAssertFalse(rig.engine.isLoaded, "次の要素は現在になるが自動では始まらない")
    }

    // MARK: - ダウンロード・エラー表示

    private func assertDownloadCancelWritesNothing(
        _ cancel: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let rig = PlaybackEntryRig()
        rig.serve(EntryFixture.playable("a"))
        rig.download.fail(with: cancel)

        await rig.viewModel.download(podcast: EntryFixture.podcast("a"))

        XCTAssertEqual(rig.gateway.downloads.count, 1, "音声の取得まで届いた", file: file, line: line)
        XCTAssertNil(rig.viewModel.listErrorMessage, file: file, line: line)
        XCTAssertNil(rig.viewModel.errorMessage, file: file, line: line)

        // 正方向対照: cancel 以外の失敗は文言になる。
        rig.serve(EntryFixture.playable("b"))
        rig.download.fail(with: SampleFailure())
        await rig.viewModel.download(podcast: EntryFixture.podcast("b"))
        XCTAssertEqual(rig.viewModel.listErrorMessage, "sample failure", file: file, line: line)
    }

    func testDownloadCancelledURLErrorWritesNothing() async {
        // verifies: ios-dec-36
        await assertDownloadCancelWritesNothing(URLError(.cancelled))
    }

    func testDownloadCancellationErrorWritesNothing() async {
        // verifies: ios-dec-36
        await assertDownloadCancelWritesNothing(CancellationError())
    }

    func testDownloadOfUnplayableRowIsRejectedWithoutFetchingAudio() async {
        // verifies: ios-dec-51
        let rig = PlaybackEntryRig()
        let content = EntryFixture.content("pf")
        rig.fetch.respond("pf", with: .failed(FailedEpisode(content: content, reportedMessage: nil)))

        await rig.viewModel.download(podcast: EntryFixture.podcast("pf", status: "partial_failed"))

        XCTAssertEqual(rig.gateway.fetches, ["pf"], "取り直しまでは届いた")
        XCTAssertFalse(rig.library.savedIds.contains("pf"))
        XCTAssertEqual(rig.viewModel.listErrorMessage, uiInvalidAudio)
        XCTAssertEqual(rig.gateway.downloads, [], "再生できない行の音声は取得しない")

        // 正方向対照: 再生できる行は同じ入口で保存される。
        rig.serve(EntryFixture.playable("ok"))
        await rig.viewModel.download(podcast: EntryFixture.podcast("ok"))
        XCTAssertEqual(rig.gateway.downloads, [url("ok")])
        XCTAssertTrue(rig.library.savedIds.contains("ok"))
    }

    func testClearingLibraryEmptiesDownloadedIdsImmediately() throws {
        // verifies: ios-dec-51
        let rig = PlaybackEntryRig()
        var changes = 0
        let subscription = rig.viewModel.objectWillChange.sink { changes += 1 }
        try rig.cached("a")
        XCTAssertEqual(rig.library.savedIds, ["a"])
        changes = 0

        try rig.library.clearAll()

        XCTAssertEqual(rig.library.savedIds, [])
        XCTAssertGreaterThan(changes, 0, "保存庫の変化で画面の再描画が起きる")
        subscription.cancel()
    }

    func testNoticeTakesPrecedenceOverListError() async throws {
        // verifies: ios-dec-55
        let rig = PlaybackEntryRig(online: false)
        await rig.viewModel.startEpisode(EntryFixture.podcast("a"))
        XCTAssertEqual(rig.viewModel.errorMessage, uiOfflineUncached)

        rig.serve(EntryFixture.playable("b"))
        let failure = SampleFailure()
        rig.download.fail(with: failure)
        await rig.viewModel.download(podcast: EntryFixture.podcast("b"))

        XCTAssertEqual(rig.gateway.downloads.count, 1, "保存の失敗まで届いた")
        XCTAssertEqual(rig.viewModel.listErrorMessage, failure.localizedDescription)
        XCTAssertEqual(rig.viewModel.errorMessage, uiOfflineUncached)

        // 両方を消せる。
        rig.viewModel.dismissError()
        XCTAssertNil(rig.viewModel.errorMessage)
        XCTAssertNil(rig.viewModel.listErrorMessage)
    }

    func testPlayByIdCancelWritesNothing() async {
        // verifies: ios-dec-36
        let rig = PlaybackEntryRig()
        rig.fetch.fail("x", with: CancellationError())
        rig.fetch.fail("y", with: URLError(.cancelled))
        rig.fetch.fail("z", with: SampleFailure())

        await rig.viewModel.startEpisode(id: "x")
        await rig.viewModel.startEpisode(id: "y")

        XCTAssertEqual(rig.gateway.fetches, ["x", "y"], "取得まで届いた")
        XCTAssertNil(rig.viewModel.listErrorMessage)
        XCTAssertNil(rig.viewModel.errorMessage)

        // 正方向対照: cancel 以外は文言になる。
        await rig.viewModel.startEpisode(id: "z")
        XCTAssertEqual(rig.viewModel.listErrorMessage, "sample failure")
    }

    // MARK: - isFinished・flushPosition

    func testIsFinishedStaysFalseWhileAdvancing() async throws {
        // verifies: ios-deriv-18
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        rig.serve(EntryFixture.playable("b"))
        rig.fetch.hold("b")
        await rig.viewModel.addToQueue(EntryFixture.podcast("b"))

        await rig.engine.send(.ended)
        await waitUntil("次の取り直しの待ち") { rig.fetch.parkedCount("b") == 1 }

        XCTAssertEqual(rig.viewModel.session.kind, "ended", "取り直しの待ちの間 a は終了のまま")
        XCTAssertFalse(rig.viewModel.isFinished)
        XCTAssertFalse(rig.viewModel.isFinished)

        rig.fetch.release("b")
        await waitUntil("b の開始") { rig.viewModel.session.episodeId == "b" }
        await rig.engine.send(.ready)

        // 正方向対照: 最後の要素が終われば true。
        await rig.engine.send(.ended)
        await waitUntil("ended") { rig.viewModel.session.kind == "ended" }
        XCTAssertTrue(rig.viewModel.isFinished)
        XCTAssertTrue(rig.viewModel.isFinished)
    }

    func testFlushPositionDelegatesToReporter() async throws {
        // verifies: ios-contract-13
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        rig.viewModel.seek(to: 42)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 42)

        rig.viewModel.flushPosition()

        await waitUntil("位置の送信") { rig.gateway.updates.count == 1 }
        XCTAssertEqual(rig.gateway.updates.first?.id, "a")
        XCTAssertEqual(rig.gateway.updates.first?.seconds, 42)
    }
}

// MARK: - 状態の種別

private extension PlaybackState {
    /// 状態の種別名。付随値を無視して種別だけを比べる。
    var kind: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .playing: return "playing"
        case .buffering: return "buffering"
        case .paused: return "paused"
        case .ended: return "ended"
        case .errored: return "errored"
        }
    }
}
