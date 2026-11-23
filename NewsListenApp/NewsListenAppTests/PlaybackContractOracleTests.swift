import XCTest
@testable import NewsListenApp

/// ios-slice-oracle-02: 再生・位置同期の契約のうち、条件を観測する oracle が無かった行（再受入 ios-acceptance-03 の unobserved）に足したテスト。
@MainActor
final class PlaybackContractOracleTests: XCTestCase {

    private let url = URL(string: "https://storage.example.com/a.mp3")!

    // MARK: - ios-contract-08（sync-008）

    // verifies: ios-contract-08（再開位置の seek は start の中で 1 回だけで、ready の後に増えない）
    // kills: start の中で 2 回 seek する／ready の後に再 seek する
    func testResumeSeekHappensOnceInsideStartAndNotAfterReady() async {
        let engine = AudioEngineDouble()
        let session = PlaybackSession(engine: engine)
        let a = EntryFixture.playableValue("a")
        session.start(episode: a, url: url, resumePosition: 12, speed: 1.0)
        XCTAssertEqual(engine.seekLog, [12], "start の中で再開位置へちょうど 1 回")
        await engine.send(.ready)
        await engine.send(.timeUpdate(seconds: 12, duration: 300))
        XCTAssertEqual(engine.seekLog, [12], "ready と時刻の更新の後に seek が増えない")
        session.start(episode: a, url: url, resumePosition: 0, speed: 1.0)
        XCTAssertEqual(engine.seekLog, [], "再開位置 0 では seek しない（load で履歴が消える）")
    }

    // MARK: - ios-contract-12・shared-session-04（sync-012・sync-040）

    // verifies: ios-contract-12・shared-session-04（shared-inv-01: session が idle でないとき session.episodeId == queue.current?.id）
    // kills: retry が現在と別のエピソード（次）で再開する／公開操作の後に待機列と session が食い違う
    func testSharedInvariantHoldsAfterEveryPublicOperation() async throws {
        let rig = PlaybackEntryRig()
        let c = rig.coordinator
        func check(_ operation: String, file: StaticString = #filePath, line: UInt = #line) {
            if c.session != .idle {
                XCTAssertEqual(c.session.episodeId, c.queue.current?.id, operation, file: file, line: line)
            }
        }
        try await rig.play("a")
        try rig.cached("b")
        await c.addToQueue(EntryFixture.playable("b"))
        check("startEpisode・addToQueue")
        _ = c.nowPlaying(); check("nowPlaying")
        _ = c.upNext(); check("upNext")
        _ = c.presentation; check("presentation")
        c.togglePlayPause(); check("togglePlayPause（一時停止）")
        c.toggleFromScreen(); check("toggleFromScreen（再開）")
        c.seek(to: 10); check("seek")
        c.setSpeed(1.5); check("setSpeed")
        c.minimizePlayer(); check("minimizePlayer")
        c.expandPlayer(); check("expandPlayer")
        await rig.engine.send(.failed(description: "boom"))
        XCTAssertEqual(c.session.stateKind, "errored")
        await c.retry()
        check("retry")
        XCTAssertEqual(c.session.episodeId, "a", "retry は現在のエピソードを再開する（次のエピソードではない）")
        await c.replayCurrent(); check("replayCurrent")
        await c.skipToNext(); check("skipToNext")
        XCTAssertEqual(c.session.episodeId, "b")
        c.stop(); check("stop")
        c.stopForLogout(); check("stopForLogout")
    }

    // MARK: - ios-contract-12（sync-012 C3・C4）

    // verifies: ios-contract-12（「何が再生中か」の読出口は nowPlaying() の読み取り専用の値だけ）
    // kills: NowPlaying に field を足す
    func testNowPlayingIsAReadOnlyValueWithAClosedFieldSet() async throws {
        let rig = PlaybackEntryRig()
        try await rig.play("a")
        let nowPlaying = try XCTUnwrap(rig.coordinator.nowPlaying())
        let fields: Set<String> = ["episodeId", "displayTitle", "japaneseIntroText", "segments", "vocabulary", "quiz", "difficulty", "sourceArticles", "sourceKind"]
        let derived: Set<String> = ["hasTranscript", "hasVocabulary", "hasQuiz", "hasSourceArticles", "showsCcBySaLicense", "queueEntry"]
        XCTAssertTrue(fields.isDisjoint(with: derived))
        XCTAssertEqual(Set(Mirror(reflecting: nowPlaying).children.compactMap(\.label)), fields.union(derived), "Spec の field 9 と導出値 6 の集合")
    }

    // MARK: - ios-contract-16（sync-016）

    // verifies: ios-contract-16（has / url はファイル実体が正本。savedIds にあっても実体が無ければ false / nil）
    // kills: url を savedIds だけで決める
    func testUrlFollowsTheFileNotTheSavedIds() throws {
        let fileManager = AudioCacheManagerTests.MockFileManager()
        let library = OfflineLibrary(store: .live(cacheManager: AudioCacheManager(fileManager: fileManager)))
        library.bind(subject: subjectA)
        try library.save(Data([1, 2, 3]), for: "a", subject: subjectA)
        XCTAssertNotNil(library.url("a"))
        XCTAssertTrue(library.has("a"))

        fileManager.files.removeAll()  // 実体だけが消える（savedIds はそのまま）
        XCTAssertEqual(library.savedIds, ["a"], "前提: savedIds には残っている")
        XCTAssertFalse(library.has("a"))
        XCTAssertNil(library.url("a"), "実体が無ければ url は nil")
    }

    // MARK: - ios-contract-18（sync-018）

    // verifies: ios-contract-18（失敗は ApiFailure だけ。全 endpoint が 1 つの入口 performData を通る）
    // kills: 入口の外で別の error を投げる／入口を複数にする
    func testEveryFailureKindSurfacesAsApiFailureThroughOneFunnel() async throws {
        func failure(of mode: MockURLSession.Mode) async -> Error? {
            let client = APIClient(
                baseURL: URL(string: "https://api.example.com")!, apiKey: "k", sessionToken: nil,
                session: MockURLSession(data: Data("{}".utf8), mode: mode))
            do { _ = try await client.fetchPodcasts(); return nil } catch { return error }
        }
        let modes: [MockURLSession.Mode] = [
            .http(statusCode: 401, headerFields: nil), .http(statusCode: 403, headerFields: nil), .http(statusCode: 404, headerFields: nil),
            .http(statusCode: 409, headerFields: nil), .http(statusCode: 422, headerFields: nil),
            .http(statusCode: 429, headerFields: ["Retry-After": "3"]), .http(statusCode: 500, headerFields: nil),
            .http(statusCode: 503, headerFields: nil), .http(statusCode: 418, headerFields: nil),
            .transportError(URLError(.timedOut)), .nonHTTPResponse,
        ]
        for mode in modes {
            let error = await failure(of: mode)
            XCTAssertTrue(error is ApiFailure, "ApiFailure 以外が出た: \(String(describing: error)) / \(mode)")
        }
        let positive = await failure(of: .http(statusCode: 200, headerFields: nil))
        XCTAssertTrue(positive is ApiFailure, "正方向の対照: 200 でも本文が読めなければ ApiFailure（decoding）")
        let source = SourceGrep.content(of: SourceGrep.appRoot.appendingPathComponent("Networking/APIClient.swift"))
        let calls = source.components(separatedBy: "\n").filter { !SourceGrep.isCommentLine($0) && $0.contains("session.data(for:") }
        XCTAssertEqual(calls.count, 1, "通信の入口は 1 つ（performData）")
    }

    // MARK: - shared-session-05（sync-041）

    // verifies: shared-session-05（error・ended・idle では、周期・停止・背景遷移の契機でも位置を送らない）
    // kills: ended や errored の状態でも位置を送る／idle の停止で送る
    func testNoPositionIsSentFromErroredEndedOrIdle() async throws {
        for terminal in ["errored", "ended", "idle"] {
            for trigger in ["周期", "背景", "即時記録", "停止"] {
                let rig = PlaybackEntryRig()
                if terminal == "idle" {
                    // loading から停止する。直前の flush の同位置抑制で誤実装が隠れないようにする。
                    try rig.cached("a")
                    try await rig.seed([EntryFixture.podcast("a", playbackPositionSeconds: 20)])
                    await rig.viewModel.startEpisode(episodeId: "a")
                    XCTAssertEqual(rig.coordinator.session.stateKind, "loading")
                    rig.coordinator.stop()
                } else {
                    try await rig.play("a")
                    await rig.engine.send(.timeUpdate(seconds: 20, duration: 300))
                    if terminal == "errored" {
                        await rig.engine.send(.failed(description: "boom"))
                    } else {
                        await rig.engine.send(.ended)
                    }
                }
                await rig.settle()
                XCTAssertEqual(rig.coordinator.session.stateKind, terminal)
                let before = rig.gateway.updates.map { "\($0.id):\($0.seconds)" }
                rig.clock.advance(300)
                switch trigger {
                case "周期":
                    let tick = PlaybackTransition.next(
                        state: rig.coordinator.session, pending: .none,
                        input: .engineTimeUpdate(21, 300))
                    XCTAssertEqual(tick.effects, [], "\(terminal): 時刻の入力は位置変更を発行しない")
                    if rig.engine.isLoaded {
                        await rig.engine.send(.timeUpdate(seconds: 21, duration: 300))
                    } else {
                        XCTAssertEqual(rig.engine.currentChannel?.yield(.timeUpdate(seconds: 21, duration: 300)), .dropped,
                                       "\(terminal): 終了した engine channel は実際の時刻の入力も捨てる")
                    }
                case "背景": rig.reporter.flush()
                case "即時記録": rig.reporter.recordNow()
                default: rig.coordinator.stop()
                }
                await rig.settle()
                XCTAssertEqual(rig.gateway.updates.map { "\($0.id):\($0.seconds)" }, before,
                               "\(terminal) × \(trigger): 位置を送らない")
            }
        }
        // 正方向の対照: 同じ公開入口の周期・背景・即時記録・停止は playing なら記録して送る。
        for trigger in ["周期", "背景", "即時記録", "停止"] {
            let rig = PlaybackEntryRig()
            try await rig.play("a")
            await rig.engine.send(.timeUpdate(seconds: 20, duration: 300))
            rig.clock.advance(300)
            switch trigger {
            case "周期":
                let tick = PlaybackTransition.next(
                    state: rig.coordinator.session, pending: .none,
                    input: .engineTimeUpdate(21, 300))
                XCTAssertTrue(tick.effects.contains(.notify(.positionChanged(seconds: 21, duration: 300))))
                await rig.engine.send(.timeUpdate(seconds: 21, duration: 300))
            case "背景": rig.reporter.flush()
            case "即時記録": rig.reporter.recordNow()
            default: rig.coordinator.stop()
            }
            let seconds = trigger == "周期" ? 21.0 : 20.0
            await rig.waitUntil("\(trigger): playing の位置が保存される") { rig.storedRecord("a")?.isSent == true }
            XCTAssertEqual(rig.gateway.updates.map(\.id), ["a"])
            XCTAssertEqual(rig.gateway.updates.map(\.seconds), [seconds])
            XCTAssertEqual(rig.storedRecord("a")?.seconds, seconds)
        }
    }

    // MARK: - shared-session-07（sync-043）

    // verifies: shared-session-07（完聴の値は engine の総時間 > DTO の総時間 > 現在位置の順）
    // kills: 現在位置を先に使う／DTO の値を無視する／engine の値を無視する
    func testCompletionValueFollowsEngineThenDtoThenPosition() async throws {
        func completionSeconds(engineDuration: Double, dtoDuration: Int, position: Double) async throws -> Double? {
            let rig = PlaybackEntryRig()
            try await rig.play("a", duration: dtoDuration)
            await rig.engine.send(.timeUpdate(seconds: position, duration: engineDuration))
            await rig.engine.send(.ended)
            await rig.waitUntil("完聴位置の書込が完了する") { rig.completions.count == 1 }
            return rig.gateway.updates.last?.seconds
        }
        let engineFirst = try await completionSeconds(engineDuration: 305, dtoDuration: 300, position: 299)
        XCTAssertEqual(engineFirst, 305, "engine の総時間が先")
        let dtoSecond = try await completionSeconds(engineDuration: 0, dtoDuration: 300, position: 290)
        XCTAssertEqual(dtoSecond, 300, "engine の値が無ければ DTO の総時間")
        let positionLast = try await completionSeconds(engineDuration: 0, dtoDuration: 0, position: 42)
        XCTAssertEqual(positionLast, 42, "総時間が無ければ現在位置")
    }

    // verifies: shared-session-07（完聴の書込の応答を待たずに次のエピソードへ進む）
    // kills: 完聴の処理が終わるまで advance を遅らせる
    func testAdvanceDoesNotWaitForTheCompletionWriteResponse() async throws {
        let gate = HoldOpenGate()
        let rig = PlaybackEntryRig(markCompleted: { _ in await gate.wait() })
        try await rig.play("a")
        try rig.cached("b")
        await rig.coordinator.addToQueue(EntryFixture.playable("b"))
        await rig.engine.send(.ended)
        await rig.waitUntil("a の完聴応答が保留のまま b へ進む", timeout: 1) {
            rig.gateway.marks == ["a"] && rig.coordinator.session.episodeId == "b"
        }
        XCTAssertEqual(rig.gateway.marks, ["a"])
        XCTAssertEqual(rig.completions.count, 0)
        XCTAssertEqual(rig.coordinator.session.episodeId, "b")
        await gate.open()
        await rig.waitUntil("応答を返すと完聴の処理が完了する") { rig.completions.count == 1 }
    }
    // verifies: ios-contract-18（キャンセル以外の失敗は ApiFailure に揃える）
    func testApiClientThrowsOnlyApiFailureCancellationOrTheCancelledUrlError() {
        func allowed(_ line: String) -> Bool {
            line.range(of: #"^\s*throw (ApiFailure\.|CancellationError\(\)|urlError\b)"#, options: .regularExpression) != nil
        }
        XCTAssertTrue(allowed("    throw ApiFailure.decoding"))
        XCTAssertTrue(allowed("    throw CancellationError()"))
        XCTAssertTrue(allowed("    throw urlError"))
        XCTAssertFalse(allowed("    throw URLError(.timedOut)"))
        let text = SourceGrep.content(of: SourceGrep.appRoot.appendingPathComponent("Networking/APIClient.swift"))
        XCTAssertFalse(text.isEmpty, "走査対象が読める")
        let throwsLines = text.components(separatedBy: "\n").filter { !SourceGrep.isCommentLine($0) && $0.range(of: #"\bthrow\s+"#, options: .regularExpression) != nil }
        XCTAssertFalse(throwsLines.isEmpty, "実際の throw を走査する")
        XCTAssertEqual(throwsLines.filter { !allowed($0) }, [])
    }

    // verifies: shared-sync-08（完聴の位置も失敗したら同じ記録を再送する）
    func testFailedCompletionPositionWriteStaysUnsentAndIsResentOnTheNextTrigger() async throws {
        var shouldFail = true
        let rig = PlaybackEntryRig(updatePosition: { id, seconds, _ in
            if shouldFail { throw ApiFailure.network(URLError(.notConnectedToInternet)) }
            return EntryFixture.playable(id, serverPosition: seconds)
        })
        try await rig.play("a")
        await rig.engine.send(.timeUpdate(seconds: 299, duration: 300))
        await rig.engine.send(.ended)
        await rig.waitUntil("完聴の書込の失敗が確定する") { rig.completions.count == 1 }
        let expected = PositionRecord(subject: subjectA, episodeId: "a", seconds: 300, recordedAt: rig.clock.now, isSent: false)
        XCTAssertEqual(rig.records.unsent(), [expected])
        shouldFail = false
        rig.network.isOnline = false
        rig.network.isOnline = true
        await rig.waitUntil("接続復帰による再送の成功") { rig.storedRecord("a")?.isSent == true }
        XCTAssertEqual(rig.records.unsent(), [])
        XCTAssertEqual(rig.gateway.updates.map(\.id), ["a", "a"])
        XCTAssertEqual(rig.gateway.updates.map(\.seconds), [300, 300])
        XCTAssertEqual(rig.gateway.recordedAts, [expected.recordedAt, expected.recordedAt])
        XCTAssertEqual(rig.storedRecord("a"), expected.markedSent())
    }

    // verifies: shared-sync-07（一覧の同時刻・時刻なし・古い値では端末の記録を変えない）
    func testLoadPodcastsKeepsTheRecordForEqualMissingOrOlderServerValues() async throws {
        for sent in [false, true] {
            let rig = PlaybackEntryRig()
            let at = rig.clock.now
            let record = try XCTUnwrap(rig.records.record(episodeId: "e", seconds: 100, at: at))
            if sent { rig.records.settleRejected(record) }
            let expected = sent ? record.markedSent() : record
            for serverTime in [at, nil, at.addingTimeInterval(-1)] {
                try await rig.loadList([EntryFixture.podcast("e", playbackPositionSeconds: 200, serverRecordedAt: serverTime)])
                XCTAssertNil(rig.viewModel.listErrorMessage)
                XCTAssertEqual(rig.storedRecord("e"), expected, "古くない場合だけ取り込む")
            }
            let newer = at.addingTimeInterval(1)
            try await rig.loadList([EntryFixture.podcast("e", playbackPositionSeconds: 200, serverRecordedAt: newer)])
            XCTAssertEqual(rig.storedRecord("e"), PositionRecord(subject: subjectA, episodeId: "e", seconds: 200, recordedAt: newer, isSent: true))
        }
    }

    // verifies: sync-017 C5（item-20 の暫定の読み。受入の合否には使わない）
    func testStartEntryRejectsNonPlayableEpisodes() async {
        let episodes: [Episode] = [
            .failed(FailedEpisode(content: EntryFixture.playableValue("f").content, reportedMessage: nil)),
            .generating(GeneratingEpisode(content: EntryFixture.content("g")))
        ]
        for episode in episodes {
            let rig = PlaybackEntryRig()
            let queue = rig.coordinator.queue
            XCTAssertNil(rig.coordinator.notice)
            await rig.coordinator.startEpisode(episode)
            XCTAssertEqual(rig.coordinator.notice, .failure(.invalidSource))
            XCTAssertEqual(rig.coordinator.session, .idle)
            XCTAssertEqual(rig.coordinator.queue, queue)
        }
    }

}

/// `markCompleted` の応答を保留するための門（open で一斉に再開する）。
private actor HoldOpenGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}
