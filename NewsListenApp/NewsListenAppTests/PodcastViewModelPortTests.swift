import XCTest
@testable import NewsListenApp

// I-S3a: `PodcastViewModel` が port（`AudioEngine` / `NowPlayingCenter`）から事象を受けて派生値を更新する
// 新しい振る舞いのテスト（spec §7.3。T-N01〜T-N13）。AVFoundation / MediaPlayer を使わない（double 駆動）。
// 各テストの `kills` は、そのテストが RED にするミュータント。
@MainActor
final class PodcastViewModelPortTests: XCTestCase {

    // MARK: - 組み立て（`PodcastViewModelTests` の helper は private なので、同じ組み立てを別に持つ。W-6）

    private struct Rig {
        let vm: PodcastViewModel
        let engine: AudioEngineDouble
        let spy: NowPlayingCenterSpy
    }

    private func makeRig(
        isOnline: Bool = true,
        cache: AudioCacheManager? = nil
    ) -> Rig {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!, apiKey: "key",
            session: MockURLSession(data: Data("{}".utf8), statusCode: 200)
        )
        let engine = AudioEngineDouble()
        let spy = NowPlayingCenterSpy()
        let vm = PodcastViewModel(
            apiClient: client,
            cacheManager: cache ?? AudioCacheManager(fileManager: PodcastViewModelTests.MockFileManager()),
            networkMonitor: StubNetworkMonitor(isOnline: isOnline),
            refreshListeningStreak: {},
            engine: engine,
            nowPlaying: spy
        )
        return Rig(vm: vm, engine: engine, spy: spy)
    }

    private func podcast(_ id: String) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/\(id).mp3", title: "",
            japaneseIntroText: "i",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
    }

    private func playingRig() async -> Rig {
        let rig = makeRig()
        await rig.vm.play(podcast: podcast("a"))
        return rig
    }

    // MARK: - 事象 → 派生値（M1〜M11）

    // verifies: CI-V3, CI-N2（SG-2, SG-6）
    // kills: timeUpdate を適用しない／`updateElapsed` を呼ばない
    func testN01_timeUpdateSetsCurrentTimeAndDurationAndUpdatesElapsedOnly() async throws {
        let rig = await playingRig()

        await rig.engine.send(.timeUpdate(seconds: 12, duration: 300))

        XCTAssertEqual(rig.vm.currentTime, 12)
        XCTAssertEqual(rig.vm.duration, 300)
        let elapsed = try XCTUnwrap(rig.spy.lastElapsedUpdate)
        XCTAssertEqual(elapsed.elapsed, 12)
        XCTAssertEqual(elapsed.duration, 300)
    }

    // verifies: CI-V3（SG-3）
    // kills: paused で isBuffering を解除しない
    func testN02_pausedClearsIsBuffering() async {
        let rig = await playingRig()
        await rig.engine.send(.buffering)
        XCTAssertTrue(rig.vm.isBuffering)

        await rig.engine.send(.paused)

        XCTAssertFalse(rig.vm.isBuffering)
    }

    // verifies: CI-V11（SG-4）
    // kills: (a) 無視する /(b) `isPlaying` ガードを消して無条件に toggle する
    func testN03_outputDeviceLostPausesOnlyWhilePlaying() async {
        let playing = await playingRig()
        await playing.engine.send(.outputDeviceLost)
        XCTAssertFalse(playing.vm.isPlaying, "(a) 再生中は一時停止する")

        let paused = await playingRig()
        paused.vm.togglePlayPause()
        XCTAssertFalse(paused.vm.isPlaying)
        await paused.engine.send(.outputDeviceLost)
        XCTAssertFalse(paused.vm.isPlaying, "(b) 一時停止中は再開しない")
    }

    // verifies: CI-V11
    // kills: 割り込みで止めない／割り込み終了で再開しない
    func testN04_interruptionPausesAndResumeRestartsPlayback() async {
        let rig = await playingRig()

        await rig.engine.send(.interrupted)
        XCTAssertFalse(rig.vm.isPlaying)

        await rig.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(rig.vm.isPlaying)
    }

    // verifies: CI-V11
    // kills: (a) shouldResume を見ない /(b) 割り込み前に再生中だったかを見ない
    func testN05_interruptionEndResumesOnlyWhenShouldResumeAndWasPlaying() async {
        let notResume = await playingRig()
        await notResume.engine.send(.interrupted)
        await notResume.engine.send(.interruptionEnded(shouldResume: false))
        XCTAssertFalse(notResume.vm.isPlaying, "(a) shouldResume が偽なら再開しない")

        let wasPaused = await playingRig()
        wasPaused.vm.togglePlayPause()
        await wasPaused.engine.send(.interrupted)
        await wasPaused.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(wasPaused.vm.isPlaying, "(b) 割り込み前に一時停止中だったなら再開しない")
    }

    // verifies: CI-V2, CI-E1（SG-5）
    // kills: load の戻り値を捨てる／`errorMessage = nil` を load の後ろに置く
    func testN06_loadWarningBecomesErrorMessageAndPlaybackContinues() async {
        let rig = makeRig()
        rig.engine.nextLoadWarning = "session failed"

        await rig.vm.play(podcast: podcast("a"))

        XCTAssertEqual(rig.vm.errorMessage, "session failed")
        XCTAssertTrue(rig.vm.isPlaying)
    }

    // verifies: CI-V4, CI-E7, CI-D2
    // kills: handler 入口の `Task.isCancelled` ガードの削除。
    // 検出条件: 手渡された stale を handler に渡す Task A のジョブが、play(b) の `errorMessage = nil` の後で、
    // かつ assert の前に走ること。前半は、テストが yield から send の最初の中断まで MainActor を同期的に
    // 占有するので必ず満たされる。後半は main executor の FIFO に依存する推定（plan.md A-16）で、
    // 崩れた場合は偽 green の方向にだけ働く。
    func testN07_staleEventHandedOffBeforeStopIsNotAppliedToTheNextPlayback() async throws {
        let rig = makeRig()
        await rig.vm.play(podcast: podcast("a"))
        await rig.engine.send(.ready)  // a の消費者を unfolding の待機状態にする
        let oldChannel = try XCTUnwrap(rig.engine.currentChannel)

        let handedOff = oldChannel.yield(.failed(description: "stale"))
        XCTAssertEqual(handedOff, .handedOff, "Given の成立: 待機中の消費者へ直接手渡した")
        // await を挟まずに stop → 次の再生（手渡された事象を処理する Task A はまだ走っていない）
        rig.vm.stopPlayback()
        await rig.vm.play(podcast: podcast("b"))
        await rig.engine.send(.ready)  // b の channel で処理を待つ

        XCTAssertNil(rig.vm.errorMessage, "stale な failed が新しい再生に適用されない")
        XCTAssertTrue(rig.vm.isPlaying)

        // 正の対照: 同じ手渡しでも、stop しなければ適用される（本体の否定形が空振りしていないことの確認）
        let control = makeRig()
        await control.vm.play(podcast: podcast("a"))
        await control.engine.send(.ready)
        let liveChannel = try XCTUnwrap(control.engine.currentChannel)
        XCTAssertEqual(liveChannel.yield(.failed(description: "live")), .handedOff)
        await control.engine.send(.resumed)
        XCTAssertEqual(control.vm.errorMessage, "live", "現在の load の事象は適用される")
    }

    // verifies: CI-V9
    // kills: `isAudioLoaded` ガードの削除／戻り値の取り違え（`.noSuchContent` と `.commandFailed`）
    func testN08_remoteCommandsReturnTheDocumentedResultsForLoadedAndUnloadedStates() async {
        // (a) play → stopPlayback の後（読み込みなし。登録は残る）: 現行の `player == nil` と同じ戻り値。
        let unloaded = await playingRig()
        unloaded.vm.stopPlayback()
        XCTAssertEqual(unloaded.spy.activeRegistrationCount, 1, "Given: handler は有効なまま")
        let notLoaded: [(RemoteCommand, RemoteCommandResult)] = [
            (.play, .noSuchContent), (.pause, .noSuchContent), (.togglePlayPause, .noSuchContent),
            (.skipBackward, .noSuchContent), (.skipForward, .noSuchContent),
            (.changePosition(30), .commandFailed), (.changeRate(1.5), .noSuchContent),
        ]
        for (command, expected) in notLoaded {
            XCTAssertEqual(unloaded.spy.invoke(command), expected, "読み込みなし: \(command)")
        }
        XCTAssertFalse(unloaded.vm.isPlaying)
        XCTAssertEqual(unloaded.vm.currentTime, 0)
        XCTAssertEqual(unloaded.vm.playbackSpeed, 1.0)

        // (b) 再生中: `.success` で、状態が現行どおり変わる。
        let play = await playingRig()
        XCTAssertEqual(play.spy.invoke(.play), .success)
        XCTAssertTrue(play.vm.isPlaying, "再生中の play は何もしない")

        let pause = await playingRig()
        XCTAssertEqual(pause.spy.invoke(.pause), .success)
        XCTAssertFalse(pause.vm.isPlaying)

        let toggle = await playingRig()
        XCTAssertEqual(toggle.spy.invoke(.togglePlayPause), .success)
        XCTAssertFalse(toggle.vm.isPlaying)

        let back = await playingRig()
        back.vm.seek(to: 100)
        XCTAssertEqual(back.spy.invoke(.skipBackward), .success)
        XCTAssertEqual(back.vm.currentTime, 100 - PlaybackConstants.skipBackwardSeconds)
        back.vm.seek(to: 5)
        XCTAssertEqual(back.spy.invoke(.skipBackward), .success)
        XCTAssertEqual(back.vm.currentTime, 0, "0 未満には戻らない（clamp）")

        let forward = await playingRig()
        await forward.engine.send(.timeUpdate(seconds: 100, duration: 300))
        XCTAssertEqual(forward.spy.invoke(.skipForward), .success)
        XCTAssertEqual(forward.vm.currentTime, 100 + PlaybackConstants.skipForwardSeconds)
        forward.vm.seek(to: 290)
        XCTAssertEqual(forward.spy.invoke(.skipForward), .success)
        XCTAssertEqual(forward.vm.currentTime, 300, "duration を超えない（clamp）")

        let position = await playingRig()
        XCTAssertEqual(position.spy.invoke(.changePosition(42)), .success)
        XCTAssertEqual(position.vm.currentTime, 42)

        let rate = await playingRig()
        XCTAssertEqual(rate.spy.invoke(.changeRate(1.5)), .success)
        XCTAssertEqual(rate.vm.playbackSpeed, 1.5)
    }

    // verifies: CI-V2, CI-V8, CI-N1, CI-N3
    // kills: 全体更新をしない／tearDown で clear しない
    func testN09_nowPlayingInfoIsPublishedOnPlayAndClearedOnStop() async {
        let rig = makeRig()
        XCTAssertNil(rig.spy.currentInfo)

        await rig.vm.play(podcast: podcast("a"))
        XCTAssertNotNil(rig.spy.currentInfo)

        rig.vm.stopPlayback()
        XCTAssertNil(rig.spy.currentInfo)
    }

    // verifies: CI-V10
    // kills: play ごとに登録する／init で登録する
    func testN10_remoteCommandsAreRegisteredOnceOnFirstPlay() async {
        let rig = makeRig()
        XCTAssertEqual(rig.spy.activeRegistrationCount, 0, "init 直後は登録しない")

        await rig.vm.play(podcast: podcast("a"))
        await rig.vm.play(podcast: podcast("b"))

        XCTAssertEqual(rig.spy.activeRegistrationCount, 1, "2 回 play しても有効な登録は 1 つ")
    }

    // verifies: CI-V2, CI-V4, CI-E7（SR-9 / C1）
    // kills: 購読 Task の本体で `engine.events` を遅れて読む（cancel 済みの Task A が b の stream を
    // `onCancel` で終わらせ、send が XCTFail・`isBuffering == false`）。
    // main dispatch queue の FIFO に依存する（plan.md A-16 の範囲。崩れた場合は偽 green の方向にだけ働く）。
    func testN11_consecutivePlaysKeepTheLatestStreamSubscribed() async {
        let rig = makeRig()
        await rig.vm.play(podcast: podcast("a"))
        await rig.vm.play(podcast: podcast("b"))  // 間に中断を挟まない

        await rig.engine.send(.buffering)  // b の channel

        XCTAssertTrue(rig.vm.isBuffering)
    }

    // verifies: CI-V14（読み込み済みでない経路。G2）
    // kills: `guard isAudioLoaded` の削除（`seek(to: 0)` → 全体更新 → `currentInfo` が非 nil になる）
    func testN12_replayWhileNotLoadedAndOfflineDoesNotSeekOrPublishNowPlaying() async {
        let rig = makeRig(isOnline: false)
        rig.vm.currentPodcast = podcast("offline-episode")
        await rig.vm.handlePlaybackEnded()  // キュー空 → 収束（stopPlayback → clear を通る）
        XCTAssertNil(rig.spy.currentInfo)

        await rig.vm.replayCurrentEpisode()

        XCTAssertNil(rig.spy.currentInfo, "seek していないので全体更新も起きない")
        XCTAssertEqual(rig.vm.currentTime, 0)
        XCTAssertFalse(rig.engine.isLoaded)
    }

    // verifies: CI-V14（読み込み済みの経路。TV-4）
    // kills: 「今回の play が成功したときだけ seek する」（currentTime が 42 のまま）／
    // 早期 return の経路で `stopPlayback` / `engine.stop` を呼ぶ（isLoaded が偽）
    func testN13_replayWhenLoadedButUnresolvableKeepsEngineAndSeeksToZero() async throws {
        let cache = AudioCacheManager(fileManager: PodcastViewModelTests.MockFileManager())
        try cache.cache(Data("x".utf8), for: "a")
        let rig = makeRig(isOnline: false, cache: cache)
        await rig.vm.play(podcast: podcast("a"))  // キャッシュから解決して読み込む
        XCTAssertTrue(rig.engine.isLoaded)
        XCTAssertNil(rig.vm.errorMessage)
        rig.vm.seek(to: 42)
        XCTAssertEqual(rig.vm.currentTime, 42)
        try cache.remove("a")

        await rig.vm.replayCurrentEpisode()

        XCTAssertEqual(rig.vm.errorMessage, "Offline and not cached")
        XCTAssertTrue(rig.engine.isLoaded, "URL を解決できずに return しても engine は止めない")
        XCTAssertEqual(rig.vm.currentTime, 0, "読み込み済みなので seek(to: 0) する")
        XCTAssertTrue(rig.vm.isPlaying)
    }
}
