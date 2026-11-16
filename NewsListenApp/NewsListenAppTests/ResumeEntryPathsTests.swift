import XCTest
@testable import NewsListenApp

/// 再開の入口ごとの確認の出し分け。画面の再生ボタン以外（ロック画面・制御画面・イヤホン・Bluetooth の車載機・割込み終了・開始）は、
/// 確認が出る条件が揃っていても尋ねず、この端末の位置（開始は新しい方の位置）から再開する。
/// どの否定形も、同じ fixture で画面のボタン（`toggleFromScreen`）が尋ねる正方向の対照と組にする。
@MainActor
final class ResumeEntryPathsTests: XCTestCase {

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t2: Date { t1.addingTimeInterval(1) }

    /// 確認が出る条件（一時停止中・別の端末の位置を取り込み済み・差 ≥ 15 秒）が、画面のボタン以外すべて揃った状態。
    private func readyToAsk() async throws -> PlaybackEntryRig {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        XCTAssertEqual(rig.coordinator.session.stateKind, "paused", "Given: 一時停止中")
        XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 200, "Given: 別の端末から取り込んだ印がある")
        return rig
    }

    /// 同じ fixture で、画面のボタンは尋ねる（fixture が確認の条件を満たしていることの証拠）。
    private func assertScreenButtonAsks(_ rig: PlaybackEntryRig, file: StaticString = #filePath, line: UInt = #line) {
        rig.coordinator.toggleFromScreen()
        XCTAssertEqual(
            rig.coordinator.resumeChoice,
            ResumeChoice(episodeId: "e", thisDeviceSeconds: 100, otherDeviceSeconds: 200),
            "対照: 同じ fixture で画面のボタンは尋ねる", file: file, line: line)
        XCTAssertEqual(rig.coordinator.session.stateKind, "paused", file: file, line: line)
    }

    // verifies: ios-contract-12, shared-sync-11, shared-dec-23
    // kills: リモートの再生・トグルが確認を通る（確認を置いて再生しない）
    func testRemotePlayAndTogglePlayPauseResumeFromThisDeviceWithoutAsking() async throws {
        for command in [RemoteCommand.play, .togglePlayPause] {
            let rig = try await readyToAsk()
            let seekBefore = rig.engine.lastSeekSeconds

            XCTAssertEqual(rig.spy.invoke(command), .success)

            XCTAssertEqual(rig.coordinator.session.stateKind, "playing", "\(command): 確認なしで再生")
            XCTAssertEqual(rig.coordinator.session.position, 100, "\(command): この端末の位置から")
            XCTAssertEqual(rig.engine.lastSeekSeconds, seekBefore, "\(command): seek しない")
            XCTAssertNil(rig.coordinator.resumeChoice, "\(command): 確認は置かない")
        }
        assertScreenButtonAsks(try await readyToAsk())
    }

    // verifies: ios-contract-12, shared-sync-11, shared-dec-23
    // kills: ヘッドセットのボタン（OS が写すリモートコマンド）の再生・一時停止・トグルのどれかが確認を通る
    func testHeadsetButtonsAreTheSameRemoteCommandsAndAskNothing() async throws {
        let rig = try await readyToAsk()

        XCTAssertEqual(rig.spy.invoke(.play), .success)
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing")
        XCTAssertNil(rig.coordinator.resumeChoice)

        XCTAssertEqual(rig.spy.invoke(.pause), .success)
        XCTAssertEqual(rig.coordinator.session.stateKind, "paused")
        rig.absorbOtherDevice("e", seconds: 300, after: 120)
        XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 300, "Given: 一時停止の記録で外れた印を、もう一度立てた")

        XCTAssertEqual(rig.spy.invoke(.togglePlayPause), .success)
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing", "トグルも確認なしで再生")
        XCTAssertNil(rig.coordinator.resumeChoice)

        // 対照: 同じ種類の fixture で、画面のボタンは尋ねる。
        assertScreenButtonAsks(try await readyToAsk())
    }

    // verifies: ios-contract-12, shared-sync-11
    // kills: 出力先の喪失で再開する／出力先の喪失が確認を置く
    func testOutputDeviceLostPausesAndNeverResumes() async throws {
        let rig = PlaybackEntryRig()
        try await rig.play("e")
        await rig.engine.send(.timeUpdate(seconds: 100, duration: 300))

        await rig.engine.send(.outputDeviceLost)
        XCTAssertEqual(rig.coordinator.session.stateKind, "paused", "出力先を失うと一時停止")
        rig.absorbOtherDevice("e", seconds: 200)
        XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 200, "Given: 確認が出る条件が揃っている")

        await rig.settle()
        XCTAssertEqual(rig.coordinator.session.stateKind, "paused", "再開しない")
        XCTAssertNil(rig.coordinator.resumeChoice, "確認も置かない")
        assertScreenButtonAsks(rig)
    }

    // verifies: ios-contract-12, shared-sync-11, shared-dec-23
    // kills: 割込みの終了が確認を通る（確認を置いて再生しない）
    func testInterruptionEndedResumesFromThisDeviceWithoutAsking() async throws {
        // 再生中 → 割込みの開始（一時停止し、Reporter がその位置を記録するので、それまでの印は外れる）→ その後に印を立てる。
        func interruptedWithOtherDevice() async throws -> PlaybackEntryRig {
            let rig = PlaybackEntryRig()
            try await rig.play("e")
            await rig.engine.send(.timeUpdate(seconds: 100, duration: 300))
            await rig.engine.send(.interrupted)
            XCTAssertEqual(rig.coordinator.session.stateKind, "paused", "Given: 割込みで一時停止した")
            rig.absorbOtherDevice("e", seconds: 200)
            XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 200, "Given: 割込みの開始の後に印を立てた")
            return rig
        }

        let rig = try await interruptedWithOtherDevice()
        let seekBefore = rig.engine.lastSeekSeconds
        await rig.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing", "確認なしで再開")
        XCTAssertEqual(rig.coordinator.session.position, 100, "この端末の位置から")
        XCTAssertEqual(rig.engine.lastSeekSeconds, seekBefore, "seek しない")
        XCTAssertNil(rig.coordinator.resumeChoice)

        // 正方向の対照: 同じ手順で印を立てた別の fixture に画面のボタンを使うと、確認が出る。
        assertScreenButtonAsks(try await interruptedWithOtherDevice())
    }

    // verifies: ios-rule-playback-10, shared-sync-11, shared-dec-39
    // kills: 再起動の後（一時停止中のセッションが無い）に確認を置く／開始が候補ではなくサーバーの値を使う
    func testAfterRelaunchNoSessionExistsAndStartUsesTheCandidateWithoutAsking() async throws {
        // 一時停止中のセッションが無ければ、条件（別の端末の印・差）が揃っていても、画面のボタンは何もしない。
        let idle = PlaybackEntryRig()
        idle.records.record(episodeId: "e", seconds: 100, at: t2)
        idle.records.absorb([EntryFixture.playable("e", serverPosition: 300, serverRecordedAt: t2.addingTimeInterval(1))])
        XCTAssertEqual(idle.records.otherDevicePosition(for: "e"), 300, "Given: 印も差もある")
        idle.coordinator.toggleFromScreen()
        XCTAssertEqual(idle.coordinator.session, .idle, "セッションが無ければ何も起きない")
        XCTAssertNil(idle.coordinator.resumeChoice)

        // 開始は、決定 10 の候補（端末の記録が新しい）から始まり、尋ねない。
        let rig = PlaybackEntryRig()
        rig.records.record(episodeId: "e", seconds: 100, at: t2)
        try rig.cached("e")
        await rig.coordinator.startEpisode(EntryFixture.playable("e", serverPosition: 30, serverRecordedAt: t1))
        XCTAssertEqual(rig.coordinator.session.loadingResumePosition, 100)
        XCTAssertNil(rig.coordinator.resumeChoice)
    }

    // verifies: ios-rule-playback-10, shared-sync-11, shared-dec-23
    // kills: 一覧の行・ディープリンク・次へ・自動で次へのどれかが確認を通る／どれかがサーバーの値だけで開始する
    func testStartFromListDeepLinkNextAndAutoAdvanceNeverAskAndUseTheNewerPosition() async throws {
        /// 端末の記録 (e, 100, t2) を持ち、`a` を再生中にした rig（`e` は保存済み）。サーバーの値は (30, t1)。
        func fixture() async throws -> PlaybackEntryRig {
            let rig = PlaybackEntryRig()
            try await rig.play("a")
            try rig.cached("e")
            rig.records.record(episodeId: "e", seconds: 100, at: t2)
            return rig
        }
        let server = EntryFixture.playable("e", serverPosition: 30, serverRecordedAt: t1)

        // 一覧の行
        let row = try await fixture()
        try await row.seed([EntryFixture.podcast("e", playbackPositionSeconds: 30, serverRecordedAt: t1)])
        await row.viewModel.startEpisode(episodeId: "e")
        XCTAssertEqual(row.coordinator.session.loadingResumePosition, 100, "一覧の行は新しい方の位置から")
        XCTAssertNil(row.coordinator.resumeChoice)

        // ディープリンク
        let link = try await fixture()
        link.serve(server)
        await link.viewModel.startEpisode(id: "e")
        XCTAssertEqual(link.coordinator.session.loadingResumePosition, 100, "ディープリンクは新しい方の位置から")
        XCTAssertNil(link.coordinator.resumeChoice)

        // 次へ
        let next = try await fixture()
        await next.coordinator.addToQueue(server)
        await next.coordinator.skipToNext()
        XCTAssertEqual(next.coordinator.session.episodeId, "e")
        XCTAssertEqual(next.coordinator.session.loadingResumePosition, 100, "次へは新しい方の位置から")
        XCTAssertNil(next.coordinator.resumeChoice)

        // 自動で次へ
        let auto = try await fixture()
        await auto.coordinator.addToQueue(server)
        await auto.coordinator.onEnded(endedId: "a")
        XCTAssertEqual(auto.coordinator.session.episodeId, "e")
        XCTAssertEqual(auto.coordinator.session.loadingResumePosition, 100, "自動で次へも新しい方の位置から")
        XCTAssertNil(auto.coordinator.resumeChoice)

        // 正方向の対照: 同じ種類の fixture を一時停止にして画面のボタンを使うと、尋ねる。
        assertScreenButtonAsks(try await readyToAsk())
    }
}
