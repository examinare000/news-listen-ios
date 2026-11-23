import XCTest
@testable import NewsListenApp

/// ios-slice-oracle-02 （2）: 再開の確認・構造の oracle。
@MainActor
final class PlaybackContractOracle2Tests: XCTestCase {

    private func codeLines(_ relative: String) -> [String] {
        SourceGrep.content(of: SourceGrep.appRoot.appendingPathComponent(relative))
            .components(separatedBy: "\n").filter { !SourceGrep.isCommentLine($0) }
    }

    // verifies: shared-sync-12（seek してから再生する）
    // kills: 別の端末の位置の選択で、先に再生して後から seek する
    func testChoosingOtherDeviceSeeksBeforePlay() async throws {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        rig.coordinator.toggleFromScreen()
        XCTAssertNotNil(rig.coordinator.resumeChoice, "前提: 確認が出ている")
        let before = rig.engine.opLog.count
        rig.coordinator.resolveResume(.otherDevice)
        XCTAssertEqual(Array(rig.engine.opLog.dropFirst(before)), ["seek", "setRate"], "seek してから再生の再開（setRate）")
        XCTAssertEqual(rig.engine.seekLog.last, 200)
    }

    // verifies: shared-sync-10（差 14.999 秒は確認を出さず、この端末の位置のまま再生する）
    // kills: 確認の閾値を 15 秒より小さくする／他の端末の位置へ seek する
    func testJustUnderThresholdKeepsThisDevicePositionWithoutSeek() async throws {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 114.999)
        let seeksBefore = rig.engine.seekLog
        rig.coordinator.toggleFromScreen()
        XCTAssertNil(rig.coordinator.resumeChoice)
        XCTAssertEqual(rig.coordinator.session.stateKind, "playing")
        XCTAssertEqual(rig.coordinator.session.position, 100)
        XCTAssertEqual(rig.engine.seekLog, seeksBefore, "seek しない")
        let edge = PlaybackEntryRig()
        try await edge.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 115)
        edge.coordinator.toggleFromScreen()
        XCTAssertNotNil(edge.coordinator.resumeChoice, "正方向の対照: ちょうど 15 秒は確認が出る")
    }

    // verifies: shared-sync-15（閉じた確認の選択は位置を記録・送信しない）
    // kills: 閉じた確認の .thisDevice で recordNow する
    func testSelectionOfAnAlreadyClosedChoiceRecordsNothing() async throws {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        rig.coordinator.toggleFromScreen()
        XCTAssertEqual(rig.spy.invoke(.play), .success)  // 別の入口の再生で確認が閉じる
        XCTAssertNil(rig.coordinator.resumeChoice)
        await rig.settle()
        let sent = rig.gateway.updates.count
        let stored = rig.storedRecord("e")
        rig.coordinator.resolveResume(.thisDevice)
        await rig.settle()
        XCTAssertEqual(rig.gateway.updates.count, sent, "送信が増えない")
        XCTAssertEqual(rig.storedRecord("e"), stored, "記録が変わらない")
        let open = PlaybackEntryRig()
        try await open.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        open.coordinator.toggleFromScreen()
        let openSent = open.gateway.updates.count
        open.coordinator.resolveResume(.thisDevice)
        await open.waitUntil("正方向の対照: 開いた確認の .thisDevice は記録して送る") { open.gateway.updates.count > openSent }
    }

    // verifies: shared-sync-05 C6（Reporter は時間で再送する仕組みを持たない）
    // kills: PositionReporter に Timer・sleep・asyncAfter 等の再送の仕組みを足す（mut-22 型）
    func testReporterHasNoTimerOrSchedulerMachinery() {
        let pattern = #"\bTimer\b|\.sleep\(|asyncAfter|DispatchSource|\.debounce\(|\.throttle\(|\bClock\b|schedule\("#
        let isViolation: (String) -> Bool = { $0.range(of: pattern, options: .regularExpression) != nil }
        for synthetic in ["    Timer.publish(every: 60, on: .main, in: .common)", "    try await Task.sleep(nanoseconds: 1)",
                          "    DispatchQueue.main.asyncAfter(deadline: .now())", "    .debounce(for: 1, scheduler: q)"] {
            XCTAssertTrue(isViolation(synthetic), "正の対照: \(synthetic)")
        }
        XCTAssertFalse(isViolation("    let now: () -> Date"), "負の対照")
        let lines = codeLines("Podcast/Playback/PositionReporter.swift")
        XCTAssertFalse(lines.isEmpty, "走査対象が読めた")
        XCTAssertTrue(lines.contains { $0.contains("periodStart") }, "周期は時計の差で数える（正方向の対照）")
        XCTAssertEqual(lines.filter(isViolation), [])
    }

    // verifies: ios-contract-09・shared-session-10（既定速度を書く入口は Settings の外に無い）
    // kills: Podcast/ などの外から既定速度の保存先・書込 API を呼ぶ
    func testDefaultSpeedIsWrittenOnlyFromSettings() {
        let pattern = #"setDefaultPlaybackSpeed\(|default_playback_speed|defaultPlaybackSpeedKey"#
        let isHit: (String) -> Bool = { $0.range(of: pattern, options: .regularExpression) != nil }
        XCTAssertTrue(isHit("    try await preferencesStore.setDefaultPlaybackSpeed(speed)"), "正の対照")
        XCTAssertFalse(isHit("    let defaultSpeed: () -> Float"), "負の対照")
        var settingsHits = 0
        var outside: [String] = []
        for file in SourceGrep.swiftFiles() {
            let rel = SourceGrep.relativePath(file)
            let hits = SourceGrep.content(of: file).components(separatedBy: "\n").filter { !SourceGrep.isCommentLine($0) && isHit($0) }
            if rel.hasPrefix("Settings/") { settingsHits += hits.count; continue }
            if rel.hasPrefix("Networking/") || rel.hasPrefix("Models/") { continue }
            outside += hits.map { "\(rel): \($0)" }
        }
        XCTAssertGreaterThan(settingsHits, 0, "Settings に書込がある（正方向の対照）")
        XCTAssertEqual(outside, [])
    }
    // verifies: shared-sync-15（同じ episode の再生し直しでも確認を閉じる）
    func testReplayOfTheSameEpisodeClosesTheChoice() async throws {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        rig.coordinator.toggleFromScreen()
        XCTAssertNotNil(rig.coordinator.resumeChoice)
        await rig.coordinator.replayCurrent()
        XCTAssertNil(rig.coordinator.resumeChoice)
        XCTAssertEqual(rig.coordinator.session.episodeId, "e")
    }

}
