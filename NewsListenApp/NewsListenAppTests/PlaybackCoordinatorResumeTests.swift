import XCTest
@testable import NewsListenApp

/// 再開位置の候補（端末の記録とサーバーの値の新しい方）・取得の取り込み・再開時の確認の保留（`PlaybackCoordinator`）。
/// `PlaybackEntryRig`（Coordinator・Reporter・記録の持ち主を実物で組み、engine とロック画面だけを double にする）越しに、
/// `coordinator.session`・`resumeChoice`・engine の seek・保存庫の記録だけを oracle にする。
@MainActor
final class PlaybackCoordinatorResumeTests: XCTestCase {

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t2: Date { t1.addingTimeInterval(1) }
    private var t3: Date { t1.addingTimeInterval(2) }

    private enum Branch: CaseIterable {
        case cached
        case networkSuccess
        case networkFailure
    }

    /// `branch` の経路で `e` を開始し、開始直後（`loading`）の再開位置を返す。
    /// `networkSuccess` は、保持している値（10・時刻なし）とは別の値（`server`）を取り直して使う。
    private func start(
        _ branch: Branch,
        record: (seconds: Double, at: Date)? = nil,
        server: (seconds: Double, at: Date?),
        duration: Int = 300
    ) async throws -> (rig: PlaybackEntryRig, position: Double?) {
        let rig = PlaybackEntryRig()
        if let record { rig.records.record(episodeId: "e", seconds: record.seconds, at: record.at) }
        let serverValue = EntryFixture.playable(
            "e", serverPosition: server.seconds, duration: duration, serverRecordedAt: server.at)
        let held: Episode
        switch branch {
        case .cached:
            try rig.cached("e")
            held = serverValue
        case .networkSuccess:
            held = EntryFixture.playable("e", serverPosition: 10, duration: duration)
            rig.serve(serverValue)
        case .networkFailure:
            rig.fetch.fail("e", with: ApiFailure.server(status: 500))
            held = serverValue
        }
        await rig.coordinator.startEpisode(held)
        return (rig, rig.coordinator.session.loadingResumePosition)
    }

    /// 確認が出ている状態（一時停止中・別の端末の位置を取り込み済み・差 ≥ 15 秒）にする。
    private func askingRig(
        _ id: String = "e", thisDevice: Double = 100, otherDevice: Double = 200, duration: Int = 300
    ) async throws -> PlaybackEntryRig {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice(id, thisDevice: thisDevice, otherDevice: otherDevice, duration: duration)
        rig.coordinator.toggleFromScreen()
        XCTAssertEqual(
            rig.coordinator.resumeChoice,
            ResumeChoice(episodeId: id, thisDeviceSeconds: thisDevice, otherDeviceSeconds: otherDevice),
            "Given: 確認が出ている")
        return rig
    }

    // MARK: - 取得の取り込み

    // verifies: ios-cmd-playback-26, ios-rule-playback-09, shared-sync-06
    // kills: 取り込みがセッションの位置を動かす／取り込みで engine を seek する
    func testAbsorbNeverMovesTheLiveSessionPosition() async throws {
        let rig = PlaybackEntryRig()
        try await rig.play("e")
        await rig.engine.send(.timeUpdate(seconds: 100, duration: 300))
        rig.records.record(episodeId: "e", seconds: 100, at: rig.clock.now)

        // 再生中
        let playingBefore = rig.coordinator.session
        let seekBefore = rig.engine.lastSeekSeconds
        XCTAssertEqual(playingBefore.stateKind, "playing")
        rig.absorbOtherDevice("e", seconds: 250)
        XCTAssertEqual(rig.coordinator.session, playingBefore, "再生中のセッションは不変")
        XCTAssertEqual(rig.engine.lastSeekSeconds, seekBefore, "取り込みで seek しない")
        XCTAssertEqual(rig.storedRecord("e")?.seconds, 250, "対照: 同じ入口で記録は置き換わる")

        // 一時停止中
        rig.coordinator.togglePlayPause()
        let pausedBefore = rig.coordinator.session
        XCTAssertEqual(pausedBefore.stateKind, "paused")
        let pausedSeekBefore = rig.engine.lastSeekSeconds
        rig.absorbOtherDevice("e", seconds: 300, after: 120)
        XCTAssertEqual(rig.coordinator.session, pausedBefore, "一時停止中のセッションも不変")
        XCTAssertEqual(rig.engine.lastSeekSeconds, pausedSeekBefore)
        XCTAssertEqual(rig.storedRecord("e")?.seconds, 300, "対照: 一時停止中でも記録は置き換わる")
    }

    // MARK: - 開始位置の候補

    // verifies: ios-rule-playback-02, ios-rule-playback-10, shared-resume-08, shared-resume-09
    // kills: 候補がサーバーの値だけ／3 つの開始の経路のどれかが旧い値（サーバーの値）を使う／
    //        取り直しの結果の取り込みをしない／保持している値（取り直す前の値）で候補を作る
    func testStartUsesTheNewerOfDeviceRecordAndServerValueOnAllThreePrepareBranches() async throws {
        for branch in Branch.allCases {
            let (_, device) = try await start(branch, record: (100, t2), server: (30, t1))
            XCTAssertEqual(device, 100, "\(branch): 端末の記録が新しいので 100")

            let (rig, server) = try await start(branch, record: (100, t2), server: (30, t3))
            XCTAssertEqual(server, 30, "\(branch): 対照: サーバーが新しければ 30")
            if branch == .networkSuccess {
                XCTAssertEqual(
                    rig.storedRecord("e"),
                    PositionRecord(subject: subjectA, episodeId: "e", seconds: 30, recordedAt: t3, isSent: true),
                    "取り直した新しい値は、記録を置き換える（送信済み）")
                XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 30, "取り込んだ印が立つ")
            } else {
                XCTAssertEqual(
                    rig.storedRecord("e")?.seconds, 100, "\(branch): 取り直さない経路では記録を置き換えない")
            }
        }
    }

    // verifies: ios-rule-playback-02, shared-dec-32, shared-resume-10
    // kills: 時刻の無いサーバーの値を新しいとみなす
    func testServerResponseWithoutTimeLosesToAnyDeviceRecord() async throws {
        for branch in [Branch.cached, .networkSuccess] {
            let (rig, position) = try await start(branch, record: (100, t1), server: (30, nil))
            XCTAssertEqual(position, 100, "\(branch): 時刻の無いサーバーの値は最古")
            XCTAssertEqual(rig.storedRecord("e")?.seconds, 100, "\(branch): 記録は置き換わらない")
        }
    }

    // verifies: ios-rule-playback-02, shared-dec-32, shared-resume-11
    // kills: 同時刻をサーバー側へ倒す／同時刻の取り込みで記録を置き換える
    func testEqualTimesKeepTheDeviceRecordEvenIfServerPositionDiffers() async throws {
        for branch in [Branch.cached, .networkSuccess] {
            let (rig, position) = try await start(branch, record: (100, t2), server: (30, t2))
            XCTAssertEqual(position, 100, "\(branch): 同時刻は端末の記録")
            XCTAssertEqual(
                rig.storedRecord("e"),
                PositionRecord(subject: subjectA, episodeId: "e", seconds: 100, recordedAt: t2, isSent: false),
                "\(branch): 記録は不変（未送信のまま）")
            XCTAssertNil(rig.records.otherDevicePosition(for: "e"), "\(branch): 印は立たない")
        }
    }

    // verifies: ios-rule-playback-02, shared-resume-01, shared-resume-04
    // kills: 候補を末尾 2 秒の規則に通さない／候補を通して replayCurrent の先頭を上書きする
    func testCandidateGoesThroughTheTailTwoSecondWindow() async throws {
        let (tail, tailPosition) = try await start(.cached, record: (299, t2), server: (0, nil), duration: 300)
        XCTAssertEqual(tailPosition, 0, "記録 299・総時間 300 は先頭から")
        XCTAssertEqual(tail.storedRecord("e")?.seconds, 299, "記録そのものは変えない")

        let (_, insidePosition) = try await start(.cached, record: (297, t2), server: (0, nil), duration: 300)
        XCTAssertEqual(insidePosition, 297, "対照: 窓の外はそのまま")

        let (rig, _) = try await start(.cached, record: (150, t2), server: (0, nil))
        await rig.coordinator.replayCurrent()
        XCTAssertEqual(rig.coordinator.session.loadingResumePosition, 0, "replayCurrent は記録に依らず先頭")
    }

    // verifies: ios-rule-playback-02, shared-dec-32
    // kills: 版・時刻の無い旧い形の記録を、再開位置の候補として読む
    func testLegacyShapedFileNeverBecomesAResumeCandidate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("resume-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = PositionRecordFiles(directory: directory)
        let server = EntryFixture.playableValue("e", serverPosition: 30, serverRecordedAt: t1)

        // 旧い形（版なし・時刻なし）のファイル。
        try Data(#"{"records":[{"episodeId":"e","seconds":100.0,"isSent":false}]}"#.utf8)
            .write(to: directory.appendingPathComponent("\(subjectA.rawValue).json"))
        let legacy = PositionRecords(store: .live(files: files))
        legacy.bind(subject: subjectA)
        XCTAssertEqual(legacy.candidate(for: server), 30, "旧い形の記録は候補にならず、サーバーの値")

        // 対照: 実物の形で書いた、より新しい記録は候補になる。
        try files.write(
            [PositionRecord(subject: subjectA, episodeId: "e", seconds: 100, recordedAt: t2, isSent: false)], for: subjectA)
        let current = PositionRecords(store: .live(files: files))
        current.bind(subject: subjectA)
        XCTAssertEqual(current.candidate(for: server), 100)
    }

    // verifies: ios-dec-143
    // kills: 合成 root が Coordinator に、Reporter と同じ記録の持ち主を渡さない
    func testCompositionRootPassesTheSamePositionRecordsToTheCoordinator() {
        let root = SourceGrep.appRoot.appendingPathComponent("NewsListenAppApp.swift")
        let coordinator = ResumeWiringSource.constructionLines(in: root, opening: "PlaybackCoordinator(")
        XCTAssertFalse(coordinator.isEmpty, "Coordinator の構築を読めた")
        XCTAssertTrue(
            coordinator.contains { $0.contains("positionRecords: positionRecords") },
            "Coordinator に Reporter と同じ positionRecords を渡す")
    }

    // MARK: - 再開時の確認

    // verifies: ios-cmd-playback-27, ios-rule-playback-10, shared-sync-10
    // kills: 常に再生する／常に尋ねる／一時停止以外でも尋ねる／印が無くても尋ねる／差 15 秒未満でも尋ねる／リモートの入口でも尋ねる
    func testToggleFromScreenAsksOnlyWhenAllFourConditionsHold() async throws {
        // 全部成立: 確認を置き、再生しない。
        let all = try await askingRig()
        XCTAssertEqual(all.coordinator.session.stateKind, "paused", "確認が出ている間は一時停止のまま")

        // 再生中: 一時停止にするだけで、確認は出ない。
        let playing = PlaybackEntryRig()
        try await playing.play("e")
        await playing.engine.send(.timeUpdate(seconds: 100, duration: 300))
        playing.records.record(episodeId: "e", seconds: 100, at: playing.clock.now)
        playing.absorbOtherDevice("e", seconds: 200)
        XCTAssertEqual(playing.records.otherDevicePosition(for: "e"), 200, "Given: 印も差もあるが再生中")
        playing.coordinator.toggleFromScreen()
        XCTAssertEqual(playing.coordinator.session.stateKind, "paused", "再生中のボタンは一時停止")
        XCTAssertNil(playing.coordinator.resumeChoice)

        // 印なし（別の端末の値を取り込んでいない）: 再生する。
        let noMark = PlaybackEntryRig()
        try await noMark.play("e")
        await noMark.engine.send(.timeUpdate(seconds: 100, duration: 300))
        noMark.coordinator.togglePlayPause()
        XCTAssertNil(noMark.records.otherDevicePosition(for: "e"), "Given: 印が無い")
        noMark.coordinator.toggleFromScreen()
        XCTAssertEqual(noMark.coordinator.session.stateKind, "playing", "印が無ければ尋ねずに再生")
        XCTAssertNil(noMark.coordinator.resumeChoice)

        // 差 15 秒未満: 再生する。
        let near = PlaybackEntryRig()
        try await near.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 114.9)
        XCTAssertEqual(near.records.otherDevicePosition(for: "e"), 114.9, "Given: 印はあるが差が 15 秒未満")
        near.coordinator.toggleFromScreen()
        XCTAssertEqual(near.coordinator.session.stateKind, "playing", "差 14.9 秒は尋ねずに再生")
        XCTAssertNil(near.coordinator.resumeChoice)

        // 画面のボタン以外の入口（リモートのトグル）: 4 条件のうち 3 つが揃っていても尋ねない。
        let remote = PlaybackEntryRig()
        try await remote.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        XCTAssertEqual(remote.spy.invoke(.togglePlayPause), .success)
        XCTAssertEqual(remote.coordinator.session.stateKind, "playing", "リモートは尋ねずに再生")
        XCTAssertNil(remote.coordinator.resumeChoice)
    }

    // verifies: ios-cmd-playback-28, shared-sync-12, shared-dec-40
    // kills: 別の端末の位置を末尾 2 秒の規則に通さずに seek する／seek せずに再生する
    func testChoosingOtherDeviceSeeksThroughTheTailWindowThenPlays() async throws {
        let tail = try await askingRig(otherDevice: 299)
        tail.coordinator.resolveResume(.otherDevice)
        XCTAssertEqual(tail.engine.lastSeekSeconds, 0, "別の端末の位置 299・総時間 300 は先頭へ")
        XCTAssertEqual(tail.coordinator.session.stateKind, "playing")
        XCTAssertEqual(tail.coordinator.session.position, 0)
        XCTAssertNil(tail.coordinator.resumeChoice)

        let inside = try await askingRig(otherDevice: 200)
        inside.coordinator.resolveResume(.otherDevice)
        XCTAssertEqual(inside.engine.lastSeekSeconds, 200, "対照: 窓の外はその位置へ")
        XCTAssertEqual(inside.coordinator.session.stateKind, "playing")
        XCTAssertEqual(inside.coordinator.session.position, 200)
    }

    // verifies: ios-cmd-playback-28, ios-cmd-playback-29, shared-sync-13, shared-dec-40
    // kills: この端末を選んだとき記録・送信しない／同じ位置を記録しない／印を外さない／seek する／選んだ時点でない時刻で記録する
    func testChoosingThisDevicePlaysWithoutSeekAndRecordsAndSendsTheCurrentPositionNow() async throws {
        let rig = try await askingRig()
        await rig.settle()
        rig.clock.advance(30)
        let chosenAt = rig.clock.now
        let seekBefore = rig.engine.lastSeekSeconds
        let updatesBefore = rig.gateway.updates.count
        XCTAssertEqual(rig.storedRecord("e")?.seconds, 200, "Given: 取り込みで記録は別の端末の値に置き換わっている")

        rig.coordinator.resolveResume(.thisDevice)

        // 選んだ直後（送信の完了を待つ前）。
        XCTAssertEqual(rig.engine.lastSeekSeconds, seekBefore, "seek しない")
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing")
        XCTAssertNil(rig.coordinator.resumeChoice)
        XCTAssertEqual(
            rig.storedRecord("e"),
            PositionRecord(subject: subjectA, episodeId: "e", seconds: 100, recordedAt: chosenAt, isSent: false),
            "この端末の位置を、選んだ時点の時刻で記録する（同じ位置でも）")
        XCTAssertNil(rig.records.otherDevicePosition(for: "e"), "記録したので印は外れる")

        // 送信（記録と同じ位置・同じ時刻が 1 件）。
        await rig.waitUntil("位置の送信") { rig.gateway.updates.count == updatesBefore + 1 }
        XCTAssertEqual(rig.gateway.updates.last?.id, "e")
        XCTAssertEqual(rig.gateway.updates.last?.seconds, 100)
        XCTAssertEqual(rig.gateway.recordedAts.last, chosenAt)
        await rig.waitUntil("送信済みの印") { rig.storedRecord("e")?.isSent == true }
        await rig.settle()
        XCTAssertEqual(rig.gateway.updates.count, updatesBefore + 1, "送信は 1 件だけ")
    }

    // verifies: ios-cmd-playback-28, shared-sync-12, shared-dec-40
    // kills: 閉じたら再生する／閉じたら印を外す／閉じても確認が残る
    func testClosingTheChoiceKeepsPausedAndNeverPlays() async throws {
        let rig = try await askingRig()
        let before = rig.coordinator.session

        rig.coordinator.resolveResume(nil)

        XCTAssertEqual(rig.coordinator.session, before, "一時停止のまま（再生も seek もしない）")
        XCTAssertNil(rig.coordinator.resumeChoice)
        XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 200, "印は残る")
        rig.coordinator.toggleFromScreen()
        XCTAssertEqual(
            rig.coordinator.resumeChoice,
            ResumeChoice(episodeId: "e", thisDeviceSeconds: 100, otherDeviceSeconds: 200),
            "次の再生ボタンで、また尋ねる")
    }

    // MARK: - 確認の保留の解除

    // verifies: ios-dec-141, ios-contract-12, shared-sync-15
    // kills: stop・別のエピソードの開始・ログアウトで確認が残る
    func testChoiceIsClearedByStopSwitchAndLeave() async throws {
        let stopped = try await askingRig()
        stopped.coordinator.stop()
        XCTAssertNil(stopped.coordinator.resumeChoice, "stop で消える")

        let switched = try await askingRig()
        try switched.cached("f")
        await switched.coordinator.startEpisode(EntryFixture.playable("f"))
        XCTAssertNil(switched.coordinator.resumeChoice, "別のエピソードの開始で消える")

        let loggedOut = try await askingRig()
        loggedOut.coordinator.stopForLogout()
        XCTAssertNil(loggedOut.coordinator.resumeChoice, "ログアウトで消える")
    }

    // verifies: ios-dec-141, ios-contract-12, shared-sync-15
    // kills: 確認中に別の入口で再生が始まっても確認が残る（選んでも何も起きない確認が残る）／
    //        一時停止中の engine の失敗の保留を、確認の解除とみなす
    func testChoiceIsClearedWhenTheSessionLeavesPausedByAnotherEntry() async throws {
        // (1) リモートの再生。
        let remote = try await askingRig()
        XCTAssertEqual(remote.spy.invoke(.play), .success)
        XCTAssertNil(remote.coordinator.resumeChoice, "リモートの再生で消える")
        XCTAssertEqual(remote.coordinator.session.stateKind, "playing")
        let seekAfterRemote = remote.engine.lastSeekSeconds
        let sessionAfterRemote = remote.coordinator.session
        remote.coordinator.resolveResume(.otherDevice)
        XCTAssertEqual(remote.engine.lastSeekSeconds, seekAfterRemote, "消えた確認の選択は seek しない")
        XCTAssertEqual(remote.coordinator.session, sessionAfterRemote, "消えた確認の選択は何も起こさない")

        // (2) 割込みの終了（再生中に始まった割込みの後に確認を出した状態）。
        let interrupted = PlaybackEntryRig()
        try await interrupted.play("e")
        await interrupted.engine.send(.timeUpdate(seconds: 100, duration: 300))
        await interrupted.engine.send(.interrupted)
        interrupted.absorbOtherDevice("e", seconds: 200)
        interrupted.coordinator.toggleFromScreen()
        XCTAssertNotNil(interrupted.coordinator.resumeChoice, "Given: 割込みで一時停止した後に確認が出ている")
        await interrupted.engine.send(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(interrupted.coordinator.session.stateKind, "playing")
        XCTAssertNil(interrupted.coordinator.resumeChoice, "割込みの終了の再開で消える")

        // (3) 一時停止中の engine の失敗は保留されるだけで、確認は残る。次の再生が `errored` へ進めたときに消える。
        let failing = try await askingRig()
        await failing.engine.send(.failed(description: "boom"))
        XCTAssertEqual(failing.coordinator.session.stateKind, "paused", "一時停止中の失敗は保留される")
        XCTAssertNotNil(failing.coordinator.resumeChoice, "保留されただけなので確認は残る")
        XCTAssertEqual(failing.spy.invoke(.play), .success)
        XCTAssertEqual(failing.coordinator.session.stateKind, "errored", "次の再生で保留の失敗が反映される")
        XCTAssertNil(failing.coordinator.resumeChoice, "再生の通知で消える")
    }

    // verifies: ios-dec-141, ios-cmd-playback-28, shared-sync-15
    // kills: 確認中の seek（同じエピソードの一時停止の通知）で確認を消す／消した後に選択が効かない
    func testChoiceSurvivesASeekWhilePausedAndTheSelectionStillApplies() async throws {
        let rig = try await askingRig()
        let choice = rig.coordinator.resumeChoice

        rig.coordinator.seek(to: 50)

        XCTAssertEqual(rig.coordinator.session.stateKind, "paused")
        XCTAssertEqual(rig.coordinator.session.position, 50, "Given: 一時停止のまま位置だけ動いた")
        XCTAssertEqual(rig.coordinator.resumeChoice, choice, "確認は残り、持ち越した 2 つの位置も変わらない")

        rig.coordinator.resolveResume(.otherDevice)
        XCTAssertEqual(rig.engine.lastSeekSeconds, 200, "その後の選択は効く")
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing")
        XCTAssertEqual(rig.coordinator.session.position, 200)
    }
}
