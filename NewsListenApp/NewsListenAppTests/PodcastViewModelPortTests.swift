import XCTest
@testable import NewsListenApp

// ios-slice-playback-01: `PodcastViewModel` が port（`AudioEngine` / `NowPlayingCenter`）から事象を受けて派生値を更新する
// 新しい振る舞いのテスト（spec §7.3。T-N01〜T-N13）。AVFoundation / MediaPlayer を使わない（double 駆動）。
// 各テストの `kills` は、そのテストが RED にするミュータント。
@MainActor
final class PodcastViewModelPortTests: XCTestCase {

    // MARK: - 組み立て（共用の `PlaybackEntryRig` を使う）

    private func podcast(_ id: String) -> Podcast {
        EntryFixture.podcast(id)
    }

    /// キャッシュ済みの "a" を開始し、`ready`（再生中）まで進めた組み立て。
    private func playingRig() async throws -> PlaybackEntryRig {
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        return rig
    }

    /// 非同期に走る後始末（キュー末尾の完聴後の ロック画面の消去）が終わるのを待つ。
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - 事象 → 派生値（M1〜M11）

    // verifies: CI-V3, CI-N2（SG-2, SG-6）
    // kills: timeUpdate を適用しない／`updateElapsed` を呼ばない
    func testN01_timeUpdateSetsCurrentTimeAndDurationAndUpdatesElapsedOnly() async throws {
        let rig = try await playingRig()

        await rig.engine.send(.timeUpdate(seconds: 12, duration: 300))

        XCTAssertEqual(rig.viewModel.currentTime, 12)
        XCTAssertEqual(rig.viewModel.duration, 300)
        let elapsed = try XCTUnwrap(rig.spy.lastElapsedUpdate)
        XCTAssertEqual(elapsed.elapsed, 12)
        XCTAssertEqual(elapsed.duration, 300)
    }

    // verifies: CI-V3（SG-3）
    // kills: paused で isBuffering を解除しない
    func testN02_pausedClearsIsBuffering() async throws {
        let rig = try await playingRig()
        await rig.engine.send(.buffering)
        XCTAssertTrue(rig.viewModel.isBuffering)

        await rig.engine.send(.paused)

        XCTAssertFalse(rig.viewModel.isBuffering)
    }

    // verifies: CI-V11（SG-4）
    // kills: (a) 無視する /(b) `isPlaying` ガードを消して無条件に toggle する
    func testN03_outputDeviceLostPausesOnlyWhilePlaying() async throws {
        let playing = try await playingRig()
        await playing.engine.send(.outputDeviceLost)
        XCTAssertFalse(playing.viewModel.isPlaying, "(a) 再生中は一時停止する")

        let paused = try await playingRig()
        paused.viewModel.togglePlayPause()
        XCTAssertFalse(paused.viewModel.isPlaying)
        await paused.engine.send(.outputDeviceLost)
        XCTAssertFalse(paused.viewModel.isPlaying, "(b) 一時停止中は再開しない")
    }

    // verifies: CI-V11
    // kills: 割り込みで止めない／割り込み終了で再開しない
    func testN04_interruptionPausesAndResumeRestartsPlayback() async throws {
        let rig = try await playingRig()

        await rig.engine.send(.interrupted)
        XCTAssertFalse(rig.viewModel.isPlaying)

        await rig.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertTrue(rig.viewModel.isPlaying)
    }

    // verifies: CI-V11
    // kills: (a) shouldResume を見ない /(b) 割り込み前に再生中だったかを見ない
    func testN05_interruptionEndResumesOnlyWhenShouldResumeAndWasPlaying() async throws {
        let notResume = try await playingRig()
        await notResume.engine.send(.interrupted)
        await notResume.engine.send(.interruptionEnded(shouldResume: false))
        XCTAssertFalse(notResume.viewModel.isPlaying, "(a) shouldResume が偽なら再開しない")

        let wasPaused = try await playingRig()
        wasPaused.viewModel.togglePlayPause()
        await wasPaused.engine.send(.interrupted)
        await wasPaused.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(wasPaused.viewModel.isPlaying, "(b) 割り込み前に一時停止中だったなら再開しない")
    }

    // verifies: CI-V2, CI-E1（SG-5）
    // kills: load の戻り値を捨てる／`errorMessage = nil` を load の後ろに置く
    func testN06_loadWarningBecomesErrorMessageAndPlaybackContinues() async throws {
        let rig = PlaybackEntryRig()
        rig.engine.nextLoadWarning = "session failed"
        try rig.cached("a")

        await rig.viewModel.startEpisode(podcast("a"))

        XCTAssertEqual(rig.viewModel.errorMessage, "session failed")
        XCTAssertTrue(rig.viewModel.isPlaying)
    }

    // verifies: CI-V4, CI-E7, CI-D2
    // kills: handler 入口の `Task.isCancelled` ガードの削除。
    // 検出条件: 手渡された stale を handler に渡す Task A のジョブが、b の開始の `errorMessage = nil` の後で、
    // かつ assert の前に走ること。前半は、テストが yield から send の最初の中断まで MainActor を同期的に
    // 占有するので必ず満たされる。後半は main executor の FIFO に依存する推定（plan.md A-16）で、
    // 崩れた場合は偽 green の方向にだけ働く。
    func testN07_staleEventHandedOffBeforeStopIsNotAppliedToTheNextPlayback() async throws {
        let rig = PlaybackEntryRig()
        try await rig.play("a")  // a の消費者を unfolding の待機状態にする
        try rig.cached("b")
        let oldChannel = try XCTUnwrap(rig.engine.currentChannel)

        let handedOff = oldChannel.yield(.failed(description: "stale"))
        XCTAssertEqual(handedOff, .handedOff, "Given の成立: 待機中の消費者へ直接手渡した")
        // await を挟まずに stop → 次の再生（手渡された事象を処理する Task A はまだ走っていない）
        rig.viewModel.stopPlayback()
        await rig.viewModel.startEpisode(podcast("b"))
        await rig.engine.send(.ready)  // b の channel で処理を待つ

        XCTAssertNil(rig.viewModel.errorMessage, "stale な failed が新しい再生に適用されない")
        XCTAssertTrue(rig.viewModel.isPlaying)

        // 正の対照: 同じ手渡しでも、stop しなければ適用される（本体の否定形が空振りしていないことの確認）
        let control = PlaybackEntryRig()
        try await control.play("a")
        let liveChannel = try XCTUnwrap(control.engine.currentChannel)
        XCTAssertEqual(liveChannel.yield(.failed(description: "live")), .handedOff)
        // 失敗は channel を閉じる（失敗後の事象は届かない）ので、後続の事象ではなく結果の表示を待つ。
        await eventually { control.viewModel.errorMessage != nil }
        XCTAssertEqual(control.viewModel.errorMessage, "live", "現在の load の事象は適用される")
    }

    // verifies: CI-V9
    // kills: `isAudioLoaded` ガードの削除／戻り値の取り違え（`.noSuchContent` と `.commandFailed`）
    func testN08_remoteCommandsReturnTheDocumentedResultsForLoadedAndUnloadedStates() async throws {
        // (a) 開始 → stopPlayback の後（読み込みなし。登録は残る）: 現行の `player == nil` と同じ戻り値。
        let unloaded = try await playingRig()
        unloaded.viewModel.stopPlayback()
        XCTAssertEqual(unloaded.spy.activeRegistrationCount, 1, "Given: handler は有効なまま")
        let notLoaded: [(RemoteCommand, RemoteCommandResult)] = [
            (.play, .noSuchContent), (.pause, .noSuchContent), (.togglePlayPause, .noSuchContent),
            (.skipBackward, .noSuchContent), (.skipForward, .noSuchContent),
            (.changePosition(30), .commandFailed), (.changeRate(1.5), .noSuchContent),
        ]
        for (command, expected) in notLoaded {
            XCTAssertEqual(unloaded.spy.invoke(command), expected, "読み込みなし: \(command)")
        }
        XCTAssertFalse(unloaded.viewModel.isPlaying)
        XCTAssertEqual(unloaded.viewModel.currentTime, 0)
        XCTAssertEqual(unloaded.viewModel.playbackSpeed, 1.0)

        // (b) 再生中: `.success` で、状態が現行どおり変わる。
        let play = try await playingRig()
        XCTAssertEqual(play.spy.invoke(.play), .success)
        XCTAssertTrue(play.viewModel.isPlaying, "再生中の play は何もしない")

        let pause = try await playingRig()
        XCTAssertEqual(pause.spy.invoke(.pause), .success)
        XCTAssertFalse(pause.viewModel.isPlaying)

        let toggle = try await playingRig()
        XCTAssertEqual(toggle.spy.invoke(.togglePlayPause), .success)
        XCTAssertFalse(toggle.viewModel.isPlaying)

        let back = try await playingRig()
        back.viewModel.seek(to: 100)
        XCTAssertEqual(back.spy.invoke(.skipBackward), .success)
        XCTAssertEqual(back.viewModel.currentTime, 100 - PlaybackConstants.skipBackwardSeconds)
        back.viewModel.seek(to: 5)
        XCTAssertEqual(back.spy.invoke(.skipBackward), .success)
        XCTAssertEqual(back.viewModel.currentTime, 0, "0 未満には戻らない（clamp）")

        let forward = try await playingRig()
        await forward.engine.send(.timeUpdate(seconds: 100, duration: 300))
        XCTAssertEqual(forward.spy.invoke(.skipForward), .success)
        XCTAssertEqual(forward.viewModel.currentTime, 100 + PlaybackConstants.skipForwardSeconds)
        forward.viewModel.seek(to: 290)
        XCTAssertEqual(forward.spy.invoke(.skipForward), .success)
        XCTAssertEqual(forward.viewModel.currentTime, 300, "duration を超えない（clamp）")

        let position = try await playingRig()
        XCTAssertEqual(position.spy.invoke(.changePosition(42)), .success)
        XCTAssertEqual(position.viewModel.currentTime, 42)

        let rate = try await playingRig()
        XCTAssertEqual(rate.spy.invoke(.changeRate(1.5)), .success)
        XCTAssertEqual(rate.viewModel.playbackSpeed, 1.5)
    }

    // verifies: CI-V2, CI-V8, CI-N1, CI-N3
    // kills: 全体更新をしない／tearDown で clear しない
    func testN09_nowPlayingInfoIsPublishedOnPlayAndClearedOnStop() async throws {
        let rig = PlaybackEntryRig()
        try rig.cached("a")
        XCTAssertNil(rig.spy.currentInfo)

        await rig.viewModel.startEpisode(podcast("a"))
        XCTAssertNotNil(rig.spy.currentInfo)

        rig.viewModel.stopPlayback()
        XCTAssertNil(rig.spy.currentInfo)
    }

    // verifies: CI-V10
    // kills: play ごとに登録する／init で登録する
    func testN10_remoteCommandsAreRegisteredOnceOnFirstPlay() async throws {
        let rig = PlaybackEntryRig()
        try rig.cached("a")
        try rig.cached("b")
        XCTAssertEqual(rig.spy.activeRegistrationCount, 0, "init 直後は登録しない")

        await rig.viewModel.startEpisode(podcast("a"))
        await rig.viewModel.startEpisode(podcast("b"))

        XCTAssertEqual(rig.spy.activeRegistrationCount, 1, "2 回開始しても有効な登録は 1 つ")
    }

    // verifies: CI-V2, CI-V4, CI-E7（SR-9 / C1）
    // kills: 購読 Task の本体で `engine.events` を遅れて読む（cancel 済みの Task A が b の stream を
    // `onCancel` で終わらせ、send が XCTFail・`isBuffering == false`）。
    // main dispatch queue の FIFO に依存する（plan.md A-16 の範囲。崩れた場合は偽 green の方向にだけ働く）。
    func testN11_consecutivePlaysKeepTheLatestStreamSubscribed() async throws {
        let rig = PlaybackEntryRig()
        try rig.cached("a")
        try rig.cached("b")
        await rig.viewModel.startEpisode(podcast("a"))
        await rig.viewModel.startEpisode(podcast("b"))  // 間に中断を挟まない
        await rig.engine.send(.ready)  // b の channel（buffering は ready の後でだけ表示される）

        await rig.engine.send(.buffering)  // b の channel

        XCTAssertTrue(rig.viewModel.isBuffering)
    }

    // verifies: CI-V14（読み込み済みでない経路。G2）
    // kills: `guard isAudioLoaded` の削除（`seek(to: 0)` → 全体更新 → `currentInfo` が非 nil になる）
    func testN12_replayWhileNotLoadedAndOfflineDoesNotSeekOrPublishNowPlaying() async throws {
        let rig = PlaybackEntryRig()
        // オンラインの未キャッシュで開始 → 完聴（キュー末尾）→ 接続が切れる。
        rig.serve(EntryFixture.playable("offline-episode"))
        await rig.viewModel.startEpisode(podcast("offline-episode"))
        await rig.engine.send(.ready)
        await rig.engine.send(.ended)
        rig.network.isOnline = false
        await eventually { rig.spy.currentInfo == nil }  // キュー空 → 収束（ロック画面を消す）
        XCTAssertNil(rig.spy.currentInfo)

        await rig.viewModel.replayCurrentEpisode()

        XCTAssertNil(rig.spy.currentInfo, "seek していないので全体更新も起きない")
        XCTAssertEqual(rig.viewModel.currentTime, 300)
        XCTAssertNil(rig.engine.lastSeekSeconds, "オフラインで未キャッシュなら engine に seek しない")
    }

    // verifies: CI-V14（読み込み済みの経路。TV-4）
    // kills: 「今回の play が成功したときだけ seek する」（currentTime が 42 のまま）／
    // 早期 return の経路で `stopPlayback` / `engine.stop` を呼ぶ（isLoaded が偽）
    func testN13_replayWhenLoadedButUnresolvableKeepsEngineAndSeeksToZero() async throws {
        let rig = PlaybackEntryRig(online: false)
        try await rig.play("a")  // キャッシュから解決して読み込む
        XCTAssertTrue(rig.engine.isLoaded)
        XCTAssertNil(rig.viewModel.errorMessage)
        rig.viewModel.seek(to: 42)
        XCTAssertEqual(rig.viewModel.currentTime, 42)
        try rig.library.remove("a")

        await rig.viewModel.replayCurrentEpisode()

        XCTAssertEqual(rig.viewModel.errorMessage, "Offline and not cached")
        XCTAssertTrue(rig.engine.isLoaded, "URL を解決できずに return しても engine は止めない")
        XCTAssertEqual(rig.viewModel.currentTime, 42, "開始できない replay は通知だけで、位置を動かさない")
        XCTAssertTrue(rig.viewModel.isPlaying)
    }

    // verifies: ios-contract-03
    // kills: subtitle に難易度の生コードを渡す／title に表示名ではなく紹介文（intro）を渡す／
    // elapsed と duration の取り違え／rate に固定値を渡す／isPlaying を反映しない
    func testN14_nowPlayingSnapshotMapsTheViewModelState() async throws {
        let rig = PlaybackEntryRig(lockScreenSubtitle: { DifficultyLabel.text(for: $0) })
        let episode = Podcast(
            id: "a", type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/a.mp3", title: "速報タイトル",
            japaneseIntroText: "i",
            durationSeconds: 300, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: 0, segments: nil
        )
        try rig.cached("a")
        await rig.viewModel.startEpisode(episode)
        await rig.engine.send(.ready)
        // timeUpdate は経過時間だけを更新するので、全体更新は setSpeed で起こす。
        await rig.engine.send(.timeUpdate(seconds: 12, duration: 300))

        rig.viewModel.setSpeed(1.5)

        XCTAssertEqual(episode.displayTitle, "速報タイトル", "title が intro より優先される前提")
        XCTAssertNotEqual(DifficultyLabel.text(for: episode.difficulty), episode.difficulty, "表示ラベルは生コードと違う")
        XCTAssertEqual(
            rig.spy.currentInfo,
            NowPlayingSnapshot(
                title: episode.displayTitle,
                subtitle: DifficultyLabel.text(for: episode.difficulty),
                elapsed: 12, duration: 300, rate: 1.5, isPlaying: true
            )
        )

        rig.viewModel.togglePlayPause()
        XCTAssertEqual(rig.spy.currentInfo?.isPlaying, false, "一時停止は snapshot に反映される")
    }
}
