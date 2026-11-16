import XCTest
@testable import NewsListenApp

/// 一覧の再読込での取り込み（`loadPodcasts`）と、再開時の確認の写し・中継（`PodcastViewModel`）。
@MainActor
final class PodcastViewModelResumeTests: XCTestCase {

    private let t1 = Date(timeIntervalSince1970: 1_700_000_000)
    private var t2: Date { t1.addingTimeInterval(1) }
    private var t3: Date { t1.addingTimeInterval(2) }

    private func serverPosition(_ rig: PlaybackEntryRig, _ id: String) -> Double? {
        if case .playable(let playable) = rig.catalog.episode(id: id) { return playable.serverPosition }
        return nil
    }

    // verifies: ios-cmd-playback-26, shared-sync-07, shared-dec-37
    // kills: 一覧の再読込の成功で取り込まない／失敗したときにも（保持している一覧の値を）取り込む
    func testLoadPodcastsAbsorbsFetchedValuesAndSkipsOnFailure() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(), statusCode: 500))
        rig.records.record(episodeId: "e", seconds: 100, at: t1)

        // (1) 成功: 届いた値が記録より新しければ、記録を置き換える（送信済み）。
        try await rig.loadList([EntryFixture.podcast("e", playbackPositionSeconds: 200, serverRecordedAt: t2)])
        XCTAssertNil(rig.viewModel.listErrorMessage, "Given: 読み込みは成功した")
        XCTAssertEqual(
            rig.storedRecord("e"),
            PositionRecord(subject: subjectA, episodeId: "e", seconds: 200, recordedAt: t2, isSent: true))
        XCTAssertEqual(rig.records.otherDevicePosition(for: "e"), 200)

        // (2) 一覧だけを、記録より新しい値にする（`seed` は `loadPodcasts` を通らないので取り込まない）。
        try await rig.seed([EntryFixture.podcast("e", playbackPositionSeconds: 300, serverRecordedAt: t3)])
        XCTAssertEqual(serverPosition(rig, "e"), 300, "Given: 一覧は新しい値を持っている")
        XCTAssertEqual(rig.storedRecord("e")?.seconds, 200, "Given: 記録はまだ取り込んでいない")

        // (3) 失敗: 一覧は保持されたまま、記録は置き換えない。
        await rig.viewModel.loadPodcasts()
        XCTAssertNotNil(rig.viewModel.listErrorMessage, "読み込みは失敗した")
        XCTAssertEqual(serverPosition(rig, "e"), 300, "失敗しても一覧の値は保持される")
        XCTAssertEqual(
            rig.storedRecord("e"),
            PositionRecord(subject: subjectA, episodeId: "e", seconds: 200, recordedAt: t2, isSent: true),
            "失敗したときは取り込まない")
    }

    // verifies: ios-cmd-playback-27, ios-cmd-playback-28, ios-query-playback-09, ios-dec-143
    // kills: 画面のボタンが Coordinator の確認の入口を通らない／確認の写しが Coordinator と食い違う／選択を Coordinator へ中継しない／
    //        合成 root が VM に Coordinator と同じ記録の持ち主を渡さない／ミニ・シートに確認の表示を付けない
    func testViewModelMirrorsResumeChoiceAndRoutesTheButtonToToggleFromScreen() async throws {
        let rig = PlaybackEntryRig()
        try await rig.pausedWithOtherDevice("e", thisDevice: 100, otherDevice: 200)
        XCTAssertNil(rig.viewModel.resumeChoice, "Given: まだ確認は出ていない")

        rig.viewModel.togglePlayPause()

        XCTAssertNotNil(rig.coordinator.resumeChoice, "画面の再生ボタンは確認を出す")
        XCTAssertEqual(rig.viewModel.resumeChoice, rig.coordinator.resumeChoice, "VM の写しは Coordinator と同じ")
        XCTAssertEqual(rig.viewModel.session.stateKind, "paused", "確認中は一時停止のまま")

        rig.viewModel.resolveResume(.thisDevice)

        XCTAssertNil(rig.coordinator.resumeChoice)
        XCTAssertNil(rig.viewModel.resumeChoice, "選んだ後は両方 nil")
        XCTAssertEqual(rig.viewModel.session.stateKind, "playing", "選択は Coordinator へ中継されて再生する")

        // 字面: 合成 root と 2 つの View の配線。
        let root = SourceGrep.appRoot.appendingPathComponent("NewsListenAppApp.swift")
        let viewModelConstruction = ResumeWiringSource.constructionLines(in: root, opening: "PodcastViewModel(")
        XCTAssertFalse(viewModelConstruction.isEmpty, "VM の構築を読めた")
        XCTAssertTrue(
            viewModelConstruction.contains { $0.contains("positionRecords: positionRecords") },
            "VM に Coordinator と同じ positionRecords を渡す")
        for name in ["MiniPlayerView.swift", "PlayerSheetView.swift"] {
            let lines = ResumeWiringSource.codeLines(in: SourceGrep.appRoot.appendingPathComponent("Podcast/\(name)"))
            XCTAssertFalse(lines.isEmpty, "\(name) を読めた")
            XCTAssertTrue(lines.contains { $0.contains("resumeChoiceDialog(") }, "\(name) に確認の表示を付ける")
        }
    }
}
