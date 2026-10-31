import XCTest
import os
@testable import NewsListenApp

// PodcastViewModel は @MainActor 分離のため、
// テストクラスも @MainActor にして init / メソッド呼び出しの分離コンテキストを揃える。
//
// facade（PodcastViewModel）越しに、Coordinator・Reporter・保存庫・ダウンロードを `PlaybackEntryRig` の double で観測する。
// 再生の事象は engine double から送る（`play` の後に `.ready`、終端は `.ended`）。
@MainActor
final class PodcastViewModelTests: XCTestCase {

    // WHY: 完了ハンドラの順序入れ替え（Coordinator の終端処理）以降、
    //      markCompleted と stop() 由来の /position 同期 Task が並行して
    //      `data(for:)` を呼び得るため、`requests` への追記を `OSAllocatedUnfairLock` で直列化する
    //      （actor 化すると呼び出し側の同期アクセス `session.requests.last` が壊れるため不採用。
    //      `NSLock` は async 文脈からの直接呼び出しが Swift 6 で警告/エラーになるため使わない）。
    private final class RequestRecordingSession: URLSessionProtocol {
        private let storage = OSAllocatedUnfairLock(initialState: [URLRequest]())
        var requests: [URLRequest] { storage.withLock { $0 } }
        let statusCode: Int

        init(statusCode: Int = 200) {
            self.statusCode = statusCode
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            storage.withLock { $0.append(request) }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("{}".utf8), response)
        }
    }

    // WHY: 一覧の取得を 2 回行い、1 回目の成功の後に失敗へ切り替える（失敗しても既存の一覧が残ることを観測する）。
    private final class SwitchableListSession: URLSessionProtocol, @unchecked Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (data: Data(), statusCode: 200))

        func respond(_ data: Data, statusCode: Int) {
            state.withLock { $0 = (data, statusCode) }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let (data, statusCode) = state.withLock { ($0.data, $0.statusCode) }
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }

    // WHY: 一覧の読込が終わらない間の `isLoading` を観測する。`release` が先に呼ばれても応答できるよう、解放は持続する。
    private final class HeldListSession: URLSessionProtocol, @unchecked Sendable {
        private struct State {
            var released = false
            var parked: [CheckedContinuation<Void, Never>] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())

        func release() {
            let waiting: [CheckedContinuation<Void, Never>] = state.withLock { state in
                state.released = true
                let waiting = state.parked
                state.parked = []
                return waiting
            }
            waiting.forEach { $0.resume() }
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let immediate: Bool = state.withLock { state in
                    if state.released { return true }
                    state.parked.append(continuation)
                    return false
                }
                if immediate { continuation.resume() }
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"podcasts":[]}"#.utf8), response)
        }
    }

    // MARK: - helper

    /// 条件が満たされるまで待つ。非同期に走る完聴の記録・自動遷移・位置の送信を、固定の sleep ではなく結果で待つ。
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("条件が時間内に満たされなかった", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 保存済みにして開始する（取得を挟まず、再生の流れだけを観測する）。
    private func start(_ rig: PlaybackEntryRig, _ podcast: Podcast) async throws {
        try rig.cached(podcast.id)
        try await rig.seed([podcast])
        await rig.viewModel.startEpisode(episodeId: podcast.id)
    }

    /// 保存済みにしてキューへ載せる（再生中でなければそのまま開始される）。
    private func enqueue(_ rig: PlaybackEntryRig, _ podcast: Podcast) async throws {
        try rig.cached(podcast.id)
        try await rig.seed([podcast])
        await rig.viewModel.addToQueue(episodeId: podcast.id)
    }

    /// 現在のエピソードの終端を engine から届け、終端の処理（完聴の記録・次への遷移の開始）に主 actor を譲る。
    private func endCurrent(_ rig: PlaybackEntryRig) async {
        await rig.engine.send(.ended)
        for _ in 0..<5 { await Task.yield() }
    }

    /// 再生中（`ready` 済み）の状態にする。
    private func playingRig() async throws -> PlaybackEntryRig {
        let rig = PlaybackEntryRig()
        try await rig.play("p1")
        return rig
    }

    // MARK: - issue #81: 再生キュー（連続再生）

    // WHY: 位置復元テスト（末尾/途中/duration=0 境界）で playbackPositionSeconds / durationSeconds を
    //      個別に指定する必要があるため、既定値付き引数へ拡張する（既存呼び出しは無変更で通る）。
    private func queuePodcast(
        _ id: String,
        playbackPositionSeconds: Double = 0,
        durationSeconds: Int = 60
    ) -> Podcast {
        Podcast(
            id: id, type: "single", articleIds: [], difficulty: "toeic_900",
            audioUrl: "https://storage.example.com/\(id).mp3", title: "",
            japaneseIntroText: "i",
            durationSeconds: durationSeconds, createdAt: "2026-05-31T06:00:00Z", status: "completed",
            errorMessage: nil, playbackPositionSeconds: playbackPositionSeconds, segments: nil
        )
    }

    func testAddToQueueStartsPlaybackWhenIdle() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "a")
        XCTAssertEqual(rig.coordinator.queue.current?.id, "a")
    }

    func testAutoAdvancePlaysNextOnEnd() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))   // a を再生
        try await enqueue(rig, queuePodcast("b"))   // b をキュー
        await rig.engine.send(.ready)
        await endCurrent(rig)                       // a 終了 → 自動で b へ
        await waitUntil { vm.nowPlaying()?.episodeId == "b" }
        XCTAssertEqual(rig.coordinator.queue.current?.id, "b")
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "b")
    }

    func testStopsWhenQueueExhaustedOnEnd() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))   // a を再生（キューは [a] のみ）
        await rig.engine.send(.ready)
        await endCurrent(rig)                       // 次が無い → 停止しつつ nowPlaying() は保持
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "a")
        XCTAssertFalse(vm.isPlaying)
        XCTAssertTrue(vm.isFinished)
    }

    func testPlaybackEndedPreservesPodcastForQuizWhenQueueExhausted() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        let podcast = queuePodcast("completed-podcast")
        try await enqueue(rig, podcast)
        await rig.engine.send(.ready)

        await endCurrent(rig)

        // 自然終端後も nowPlaying() が保持されているため、語彙/クイズ導線が残る
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "completed-podcast")
        // 再生は停止
        XCTAssertFalse(vm.isPlaying)
        // キューは末尾要素を指したまま（再聴・ジャンプ可能な状態を保つ）
        XCTAssertEqual(rig.coordinator.queue.current?.id, "completed-podcast")
        XCTAssertTrue(vm.isFinished)
    }

    func testPlaybackEndedMarksCapturedPodcastBeforeAutoAdvanceAndRefreshesStreak() async throws {
        let session = RequestRecordingSession()
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        var refreshCount = 0
        var completedSentBeforeRefresh = false
        let rig = PlaybackEntryRig(
            markCompleted: { id in try await client.markCompleted(id: id) },
            onCompletion: {
                refreshCount += 1
                // WHY: /position 同期 Task が並行して混ざり得るため requests.last では
                //      順序依存になる。「refresh 時点で /completed が送信済み」という
                //      本来の順序保証だけを内容ベースで捕捉する。
                completedSentBeforeRefresh = session.requests.contains {
                    $0.url?.path == "/podcasts/completed-id/completed"
                }
            }
        )
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("completed-id"))
        try await enqueue(rig, queuePodcast("next-id"))
        await rig.engine.send(.ready)

        await endCurrent(rig)
        // 完聴の記録は待たれない非同期 Task で走るので、ストリーク更新まで済んだ後を観測する。
        await waitUntil { rig.completions.count == 1 }
        await waitUntil { vm.nowPlaying()?.episodeId == "next-id" }

        // WHY: 終端処理の順序入れ替え（UI収束を先行させる）により、
        //      stop() 由来の /position 同期 Task が /completed より先に
        //      enqueue され得るため、リクエスト**順序**ではなく含有で検証する。
        let completedRequest = try XCTUnwrap(
            session.requests.first { $0.url?.path == "/podcasts/completed-id/completed" }
        )
        XCTAssertEqual(completedRequest.httpMethod, "POST")
        XCTAssertNil(completedRequest.httpBody)
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "next-id")
        XCTAssertEqual(refreshCount, 1)
        // 順序非依存: ストリーク更新は完聴記録の後、という契約のみを検証する。
        XCTAssertTrue(completedSentBeforeRefresh)
    }

    func testCompletionFailureDoesNotBlockQueueAutoAdvance() async throws {
        let session = RequestRecordingSession(statusCode: 500)
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            apiKey: "key",
            session: session
        )
        let rig = PlaybackEntryRig(markCompleted: { id in try await client.markCompleted(id: id) })
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("failed-completion"))
        try await enqueue(rig, queuePodcast("still-plays"))
        await rig.engine.send(.ready)

        await endCurrent(rig)
        // 完聴の記録は待たれない非同期 Task で走るので、失敗して終わった後を観測する。
        await waitUntil { rig.completions.count == 1 }
        await waitUntil { vm.nowPlaying()?.episodeId == "still-plays" }

        // 順序非依存: /completed リクエストが送られたことのみを検証する（§理由は上記テスト参照）。
        XCTAssertTrue(session.requests.contains { $0.url?.path == "/podcasts/failed-completion/completed" })
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "still-plays")
    }

    func testPlayNextInsertsAfterCurrent() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))   // a を再生
        try await enqueue(rig, queuePodcast("b"))   // [a, b]
        try await rig.seed([queuePodcast("c")])
        await vm.playNext(episodeId: "c")           // a の次に c

        XCTAssertEqual(rig.coordinator.queue.upNext.map { $0.id }, ["c", "b"])
    }

    func testRemoveFromQueue() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        try await enqueue(rig, queuePodcast("b"))

        vm.removeFromQueue(id: "b")
        XCTAssertEqual(rig.coordinator.queue.items.map { $0.id }, ["a"])
    }

    func testLoadPodcastsPopulatesList() async throws {
        let mockJSON = #"""
        {"podcasts": [
            {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"今日は...","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"}
        ]}
        """#.data(using: .utf8)!

        let rig = PlaybackEntryRig(session: MockURLSession(data: mockJSON, statusCode: 200))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.rows.count, 1)
        XCTAssertEqual(vm.rows[0].episodeId, "p1")
        XCTAssertFalse(vm.isLoading)
    }

    func testLoadPodcastsSetsErrorMessageOnFailure() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(), statusCode: 500))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertTrue(vm.rows.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    // MARK: - T-T12c-04 / T-T12c-05（verifies: CI-T12c, R4-S1g / R4-S1c）
    // T-T12c-04: SG-S1-6: 射程外・挙動不変の固定（order.md:66）。文言の良し悪しは主張しない。
    // T-T12c-05: 現行表示の固定。置換後も期待値を変えない。11 箇所の `ApiFailure` 節の付け忘れを検出する。

    func testLoadPodcastsCancelledURLErrorKeepsCurrentDisplay() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(mode: .transportError(URLError(.cancelled))))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.errorMessage, URLError(.cancelled).localizedDescription)
    }

    func testLoadPodcastsRawCancellationErrorKeepsCurrentDisplay() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(mode: .transportError(CancellationError())))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.errorMessage, CancellationError().localizedDescription)
    }

    func testDownloadCancelledURLErrorKeepsCurrentDisplay() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        rig.fetch.fail("p1", with: URLError(.cancelled))

        try await rig.seed([queuePodcast("p1")])
        await vm.download(episodeId: "p1")

        // 中断は利用者に見せる失敗ではないので、何も書かない。
        XCTAssertNil(vm.errorMessage)
    }

    func testPlayByIdCancelledURLErrorKeepsCurrentDisplay() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        rig.fetch.fail("p1", with: URLError(.cancelled))

        await vm.startEpisode(id: "p1")

        XCTAssertNil(vm.errorMessage)
    }

    func testLoadPodcasts500SetsHTTPErrorMessage() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(), statusCode: 500))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testDownload500SetsHTTPErrorMessage() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        rig.fetch.fail("p1", with: ApiFailure.server(status: 500))

        try await rig.seed([queuePodcast("p1")])
        await vm.download(episodeId: "p1")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testPlayById500SetsHTTPErrorMessage() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        rig.fetch.fail("p1", with: ApiFailure.server(status: 500))

        await vm.startEpisode(id: "p1")

        XCTAssertEqual(vm.errorMessage, "HTTP Error 500")
    }

    func testLoadPodcastsTransportFailureSetsURLErrorMessage() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(mode: .transportError(URLError(.notConnectedToInternet))))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.errorMessage, URLError(.notConnectedToInternet).localizedDescription)
    }

    // MARK: - issue #53: ロード失敗と「本当に空」の空状態を区別する

    func testDisplayStateIsErrorWhenLoadPodcastsFailsWithEmptyList() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(), statusCode: 500))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
    }

    func testDisplayStateIsContentWhenLoadPodcastsFailsButListRemains() async throws {
        // リフレッシュ失敗時は既存の一覧を残す。その場合は空状態ではなく一覧を優先して表示する。
        let session = SwitchableListSession()
        session.respond(try EntryFixture.podcastListJSON([queuePodcast("p1")]), statusCode: 200)
        let rig = PlaybackEntryRig(session: session)
        let vm = rig.viewModel
        await vm.loadPodcasts()
        XCTAssertEqual(vm.rows.map(\.episodeId), ["p1"])
        session.respond(Data(), statusCode: 500)

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .content)
    }

    func testDisplayStateIsEmptyWhenLoadPodcastsSucceedsWithNoPodcasts() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(#"{"podcasts": []}"#.utf8), statusCode: 200))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .empty)
    }

    func testDisplayStateIsLoadingWhileInitialLoadInProgress() async {
        let session = HeldListSession()
        let rig = PlaybackEntryRig(session: session)
        let vm = rig.viewModel
        let load = Task { await vm.loadPodcasts() }
        await waitUntil { vm.isLoading }

        XCTAssertEqual(vm.displayState, .loading)

        session.release()
        await load.value
    }

    func testSetSpeedUpdatesPlaybackSpeed() {
        // 再生していない間の速度変更は無効で、表示は既定速度のまま。
        let rig = PlaybackEntryRig(defaultSpeed: 1.25)
        let vm = rig.viewModel

        vm.setSpeed(1.5)

        XCTAssertEqual(vm.playbackSpeed, 1.25)
    }

    // MARK: - 再読込で消えた id への操作（一覧に無い id は何もしない）

    // verifies: ios-dec-66
    // kills: 無い id で remote 取得・通知・保存状態の更新をする／View が持つスナップショットで動く
    func testOperationsOnIdRemovedByReloadDoNothing() async throws {
        let session = SwitchableListSession()
        session.respond(try EntryFixture.podcastListJSON([queuePodcast("a"), queuePodcast("b")]), statusCode: 200)
        let rig = PlaybackEntryRig(session: session)
        let vm = rig.viewModel
        await vm.loadPodcasts()
        try rig.cached("a")
        try rig.cached("b")
        session.respond(try EntryFixture.podcastListJSON([queuePodcast("b")]), statusCode: 200)
        await vm.loadPodcasts()
        XCTAssertEqual(vm.rows.map(\.episodeId), ["b"], "Given: 2 回目の読込で a が一覧から消えている")
        let queueBefore = rig.coordinator.queue.upNext.map(\.id)
        let sessionBefore = vm.session
        let loadedBefore = rig.engine.loadedURL
        let eventsBefore = rig.gateway.events
        let savedBefore = rig.library.savedIds
        let errorBefore = vm.errorMessage

        await vm.startEpisode(episodeId: "a")
        await vm.playNext(episodeId: "a")
        await vm.addToQueue(episodeId: "a")
        await vm.download(episodeId: "a")
        await vm.removeDownload(episodeId: "a")

        XCTAssertEqual(rig.coordinator.queue.upNext.map(\.id), queueBefore)
        XCTAssertEqual(vm.session, sessionBefore)
        XCTAssertEqual(rig.engine.loadedURL, loadedBefore)
        XCTAssertEqual(rig.gateway.events, eventsBefore)
        XCTAssertEqual(rig.library.savedIds, savedBefore)
        XCTAssertEqual(vm.errorMessage, errorBefore)
        XCTAssertNil(vm.nowPlaying())
        XCTAssertTrue(rig.library.has("a"), "removeDownload は一覧に無い id の音声を消さない")

        // 正方向の対照: 一覧に有る id は同じ入口から開始できる。
        await vm.startEpisode(episodeId: "b")
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "b")
    }

    // MARK: - 一覧の読込と保存済みの集合

    // verifies: ios-dec-66
    // kills: 一覧の更新より前の id を渡す／refresh を呼ばない／isLoading を戻さない
    func testLoadPodcastsRefreshesLibraryWithNewRowIds() async throws {
        let session = SwitchableListSession()
        session.respond(try EntryFixture.podcastListJSON([queuePodcast("p0")]), statusCode: 200)
        let rig = PlaybackEntryRig(session: session)
        try rig.cached("p1")
        await rig.viewModel.loadPodcasts()
        XCTAssertTrue(rig.library.savedIds.isEmpty, "Given: p1 は保存庫にあるが、この一覧の id に無いので保存済みの集合に入らない")
        session.respond(try EntryFixture.podcastListJSON([queuePodcast("p1")]), statusCode: 200)

        await rig.viewModel.loadPodcasts()

        XCTAssertEqual(rig.library.savedIds, ["p1"], "refresh は更新後の一覧の id を受ける")
        XCTAssertFalse(rig.viewModel.isLoading)
    }

    // MARK: - 開始時の再生 URL の解決（保存済み／オンライン／オフライン）

    func testStartEpisodeLoadsSavedFileWhenCached() async throws {
        let rig = PlaybackEntryRig(online: true)
        let vm = rig.viewModel
        try rig.cached("p1")

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        let loaded = try XCTUnwrap(rig.engine.loadedURL)
        XCTAssertEqual(loaded, rig.library.url("p1"))
        XCTAssertTrue(loaded.isFileURL)
        XCTAssertTrue(loaded.path.hasSuffix("audio-cache/p1.mp3"))
    }

    func testStartEpisodeLoadsAudioURLWhenOnlineAndNotCached() async throws {
        let rig = PlaybackEntryRig(online: true)
        let vm = rig.viewModel
        rig.serve(EntryFixture.playable("p1", url: "https://storage.example.com/p1.mp3"))

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        XCTAssertEqual(rig.engine.loadedURL?.absoluteString, "https://storage.example.com/p1.mp3")
    }

    func testStartEpisodeLoadsNothingWhenOfflineAndNotCached() async throws {
        let rig = PlaybackEntryRig(online: false)
        let vm = rig.viewModel

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        XCTAssertNil(rig.engine.loadedURL)
        XCTAssertNotNil(vm.errorMessage)
    }

    // MARK: - T5: Download & State

    func testDownloadFetchesPodcastAndCachesAudio() async throws {
        let podcast = queuePodcast("p1", durationSeconds: 300)
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        // fetchPodcast のレスポンス（署名付き新鮮な audioUrl）
        rig.serve(EntryFixture.playable("p1", url: "https://storage.example.com/p1-signed.mp3?token=xxx"))

        try await rig.seed([podcast])
        await vm.download(episodeId: podcast.id)

        XCTAssertTrue(rig.library.savedIds.contains("p1"))
        XCTAssertFalse(rig.downloads.downloadingIds.contains("p1"))
    }

    func testDownloadStateReturnsCorrectState() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        rig.serve(EntryFixture.playable("p1"))
        rig.download.hold()

        XCTAssertEqual(vm.downloadState(for: "p1"), .notDownloaded)

        try await rig.seed([queuePodcast("p1")])
        let running = Task { await vm.download(episodeId: "p1") }
        await waitUntil { rig.download.parkedCount == 1 }
        XCTAssertEqual(vm.downloadState(for: "p1"), .downloading)

        rig.download.release()
        await running.value
        XCTAssertEqual(vm.downloadState(for: "p1"), .downloaded)

        // downloading が downloaded より優先される（取得の待機中に保存庫へ直接書いた id）。
        let other = PlaybackEntryRig()
        let otherVM = other.viewModel
        other.serve(EntryFixture.playable("p1"))
        other.download.hold()
        try await other.seed([queuePodcast("p1")])
        let racing = Task { await otherVM.download(episodeId: "p1") }
        await waitUntil { other.download.parkedCount == 1 }
        try other.cached("p1")
        XCTAssertEqual(otherVM.downloadState(for: "p1"), .downloading)

        other.download.release()
        await racing.value
    }

    func testSyncDownloadedState() async throws {
        let mockJSON = #"""
        {"podcasts": [
            {"id":"p1","type":"single","article_ids":["a1"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p1.mp3","japanese_intro_text":"test","duration_seconds":300,"created_at":"2026-05-31T06:00:00Z","status":"completed"},
            {"id":"p2","type":"single","article_ids":["a2"],"difficulty":"toeic_900","audio_url":"https://storage.example.com/p2.mp3","japanese_intro_text":"test2","duration_seconds":200,"created_at":"2026-05-30T06:00:00Z","status":"completed"}
        ]}
        """#.data(using: .utf8)!

        let rig = PlaybackEntryRig(session: MockURLSession(data: mockJSON, statusCode: 200))
        let vm = rig.viewModel

        // p1 の音声は保存庫にあるが、保存済み集合は空（loadPodcasts が写し直すことを観測する）。
        try rig.cached("p1")
        rig.library.refresh(candidateIds: [])
        XCTAssertTrue(rig.library.savedIds.isEmpty)

        await vm.loadPodcasts()

        // loadPodcasts の末尾で保存済みの集合が一覧に合わせて写し直される
        XCTAssertTrue(rig.library.savedIds.contains("p1"))
        XCTAssertFalse(rig.library.savedIds.contains("p2"))
    }

    // MARK: - T6: play()

    func testPlayOfflineNoCachedSetsErrorMessage() async throws {
        let rig = PlaybackEntryRig(online: false)
        let vm = rig.viewModel

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertNil(vm.nowPlaying())
    }

    func testPlayOnlineNoCachedResolvesAudioURL() async throws {
        let rig = PlaybackEntryRig(online: true)
        let vm = rig.viewModel
        rig.serve(EntryFixture.playable("p1"))

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        // オンライン + キャッシュなし = 再生開始（nowPlaying() が podcast）
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "p1")
    }

    // MARK: - issue #58: play() 成功時に前回のエラーメッセージを持ち越さない

    func testPlaySuccessClearsStaleErrorMessage() async throws {
        let rig = PlaybackEntryRig(online: false)
        let vm = rig.viewModel
        // 前回の再生失敗が残っている状態を再現する（オフラインで未キャッシュの開始は通知を立てる）。
        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")
        XCTAssertNotNil(vm.errorMessage)
        rig.network.isOnline = true
        rig.serve(EntryFixture.playable("p1"))

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        XCTAssertNil(vm.errorMessage)
    }

    func testPlayOfflineNoCachedOverwritesStaleErrorMessage() async throws {
        // ガードに引っかかる経路では、クリアより前に新しいメッセージが設定されること
        // （クリアを挿入した際に既存のガード動作を壊していないこと）を確認する。
        let rig = PlaybackEntryRig(online: false)
        let vm = rig.viewModel
        // 前回とは別の失敗（再生できない行の拒否）を残す。
        try await rig.seed([EntryFixture.podcast("bad", status: "processing")])
        await vm.startEpisode(episodeId: "bad")
        XCTAssertEqual(vm.errorMessage, "Invalid audio URL")

        try await rig.seed([queuePodcast("p1", durationSeconds: 300)])
        await vm.startEpisode(episodeId: "p1")

        XCTAssertEqual(vm.errorMessage, "Offline and not cached")
    }

    // MARK: - issue #58: インラインエラー表示（displayState .error）とアラートの二重表示防止

    func testShouldPresentErrorAlertFalseWhenListEmptyAndDisplayStateIsError() async throws {
        // 一覧が空でロード失敗＝インラインエラー表示中は、同じエラーのアラートを重ねて出さない。
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(), statusCode: 500))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertTrueWhenListNonEmptyAndErrorMessageSet() async throws {
        // 一覧が非空のまま発生したエラー（再生失敗等）はインライン表示が無いのでアラートを出す。
        let rig = PlaybackEntryRig(
            online: false,
            session: MockURLSession(data: try EntryFixture.podcastListJSON([queuePodcast("p1")]), statusCode: 200))
        let vm = rig.viewModel
        await vm.loadPodcasts()
        await vm.startEpisode(episodeId: "p1")

        XCTAssertEqual(vm.displayState, .content)
        XCTAssertTrue(vm.shouldPresentErrorAlert)
    }

    func testShouldPresentErrorAlertFalseWhenNoErrorMessage() {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel

        XCTAssertFalse(vm.shouldPresentErrorAlert)
    }

    // MARK: - alert の文言（facade の読み取り専用の値）

    // verifies: ios-deriv-31
    // kills: 一覧が非空なのに通知の文言を返さない／errorMessage と別の文言を作る
    func testAlertMessageIsNoticeTextWhenListIsShown() async throws {
        let rig = PlaybackEntryRig(
            online: false,
            session: MockURLSession(data: try EntryFixture.podcastListJSON([queuePodcast("p1")]), statusCode: 200))
        let vm = rig.viewModel
        await vm.loadPodcasts()
        await vm.startEpisode(episodeId: "p1")

        XCTAssertEqual(vm.displayState, .content)
        XCTAssertEqual(vm.alertMessage, "Offline and not cached")
        XCTAssertEqual(vm.alertMessage, vm.errorMessage)
    }

    // verifies: ios-dec-60
    // kills: インラインエラーの間も alert の文言を返す（二重表示）
    func testAlertMessageIsNilWhileInlineErrorIsShown() async throws {
        let rig = PlaybackEntryRig(session: MockURLSession(data: Data(), statusCode: 500))
        let vm = rig.viewModel

        await vm.loadPodcasts()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(vm.displayState, .error(message: vm.errorMessage ?? ""))
        XCTAssertNil(vm.alertMessage)
    }

    // verifies: ios-dec-60
    func testAlertMessageIsNilWhenNothingToReport() {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel

        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.alertMessage)
    }

    // MARK: - リモートコマンド経路と同じ再生制御メソッドの状態遷移（issue #79）

    func testTogglePlayPauseFlipsIsPlayingAfterPlay() async throws {
        let vm = try await playingRig().viewModel
        XCTAssertTrue(vm.isPlaying)

        // ロック画面の一時停止コマンドは togglePlayPause を経由する。
        vm.togglePlayPause()
        XCTAssertFalse(vm.isPlaying)

        vm.togglePlayPause()
        XCTAssertTrue(vm.isPlaying)
    }

    func testSeekUpdatesCurrentTimeAfterPlay() async throws {
        let vm = try await playingRig().viewModel

        // スキップコマンドは seek(to:) を経由する。
        vm.seek(to: 42)
        XCTAssertEqual(vm.session.position, 42)
    }

    func testSetSpeedUpdatesPlaybackSpeedAfterPlay() async throws {
        let vm = try await playingRig().viewModel

        // 速度変更コマンドは setSpeed(_:) を経由する。
        vm.setSpeed(1.75)
        XCTAssertEqual(vm.playbackSpeed, 1.75)
    }

    func testStopPlaybackResetsState() async throws {
        let vm = try await playingRig().viewModel

        vm.stop()
        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.session.position, 0)
    }

    // MARK: - issue #54: オフライン時の事前無効化

    func testIsOnlineReflectsInjectedNetworkMonitor() {
        let vm = PlaybackEntryRig(online: false).viewModel

        XCTAssertFalse(vm.isOnline)
    }

    func testIsPlayableWhileOfflineTrueOnlyWhenDownloaded() {
        XCTAssertTrue(PodcastViewModel.isPlayableWhileOffline(downloadState: .downloaded))
        XCTAssertFalse(PodcastViewModel.isPlayableWhileOffline(downloadState: .downloading))
        XCTAssertFalse(PodcastViewModel.isPlayableWhileOffline(downloadState: .notDownloaded))
    }

    // MARK: - T7: AVPlayer 状態監視（issue #51: ストリーミング失敗検出とバッファリング表示）

    func testHandlePlayerItemStatusChangeFailedSetsErrorMessageAndStopsPlaying() async throws {
        let rig = try await playingRig()
        let vm = rig.viewModel

        await rig.engine.send(.failed(description: "The network connection was lost"))

        XCTAssertEqual(vm.errorMessage, "The network connection was lost")
        XCTAssertFalse(vm.isPlaying)
    }

    func testHandlePlayerItemStatusChangeFailedUsesDefaultMessageWhenDescriptionMissing() async throws {
        let rig = try await playingRig()
        let vm = rig.viewModel

        await rig.engine.send(.failed(description: nil))

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isPlaying)
    }

    func testHandlePlayerItemStatusChangeIgnoresNonFailedStatus() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await start(rig, EntryFixture.podcast("p1"))

        await rig.engine.send(.ready)

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.isPlaying)
    }

    func testHandleTimeControlStatusChangeWaitingSetsIsBuffering() async throws {
        let rig = try await playingRig()
        let vm = rig.viewModel
        XCTAssertFalse(vm.isBuffering)

        await rig.engine.send(.buffering)

        XCTAssertTrue(vm.isBuffering)
    }

    func testHandleTimeControlStatusChangePlayingClearsIsBuffering() async throws {
        let rig = try await playingRig()
        let vm = rig.viewModel
        await rig.engine.send(.buffering)
        XCTAssertTrue(vm.isBuffering)

        await rig.engine.send(.resumed)

        XCTAssertFalse(vm.isBuffering)
    }

    func testStopPlaybackResetsIsBuffering() async throws {
        let rig = try await playingRig()
        let vm = rig.viewModel
        await rig.engine.send(.buffering)
        XCTAssertTrue(vm.isBuffering)

        vm.stop()

        XCTAssertFalse(vm.isBuffering)
    }

    // MARK: - issue #50: stop() 時の再生位置同期が 0 で上書きされる不具合

    func testStopPlaybackSyncsPositionAtStopTimeNotZero() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await start(rig, EntryFixture.podcast("p1"))
        // seek の位置が送られるのは再生が始まった（ready の）後。
        await rig.engine.send(.ready)
        vm.seek(to: 42)

        vm.stop()

        // 位置の送信は非同期 Task で行うため、記録されるまで待つ。
        await waitUntil { rig.gateway.updates.contains { $0.seconds == 42 } }

        XCTAssertEqual(rig.gateway.updates.last?.id, "p1")
        XCTAssertEqual(rig.gateway.updates.last?.seconds, 42)
    }

    // MARK: - グローバルミニプレイヤー: プレイヤー表示状態遷移

    func testPresentationIsHiddenUntilFirstPlay() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        XCTAssertEqual(vm.presentation, .hidden)

        try rig.cached("a")
        try await rig.seed([queuePodcast("a")])
        await vm.startEpisode(episodeId: "a")

        XCTAssertEqual(vm.presentation, .expanded)
    }

    func testMinimizeThenExpandRoundTrip() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await start(rig, queuePodcast("a"))

        vm.minimizePlayer()
        XCTAssertEqual(vm.presentation, .mini)

        vm.expandPlayer()
        XCTAssertEqual(vm.presentation, .expanded)
    }

    func testQueueEndKeepsMiniPresentationForFinishedState() async throws {
        // WHY: キュー終端でも nowPlaying() は保持される（語彙/クイズ導線）ため、
        //      ミニプレイヤーも finished 状態のまま残す（hidden へ落とさない）。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        await rig.engine.send(.ready)
        vm.minimizePlayer()

        await endCurrent(rig)

        XCTAssertEqual(vm.presentation, .mini)
        XCTAssertTrue(vm.isFinished)
    }

    func testAutoAdvanceKeepsCurrentPresentation() async throws {
        // WHY: キュー自動遷移で表示形態が勝手に切り替わるとミニ再生中の閲覧を妨げるため、
        //      次エピソードへの遷移では presentation を変更しない。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        try await enqueue(rig, queuePodcast("b"))
        await rig.engine.send(.ready)
        vm.minimizePlayer()

        await endCurrent(rig)                       // a 終了 → 自動で b へ
        await waitUntil { vm.nowPlaying()?.episodeId == "b" }

        XCTAssertEqual(vm.nowPlaying()?.episodeId, "b")
        XCTAssertEqual(vm.presentation, .mini)
    }

    // MARK: - タブ間再生継続: scenePhase 離脱時の位置フラッシュ

    func testFlushPlaybackPositionSyncsCurrentPositionWithoutStopping() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await start(rig, queuePodcast("p1", durationSeconds: 300))
        // seek の位置が送られるのは再生が始まった（ready の）後。
        await rig.engine.send(.ready)
        vm.seek(to: 42)

        vm.flushPosition()

        // 位置の送信は非同期 Task で行うため、記録されるまで待つ。
        await waitUntil { rig.gateway.updates.contains { $0.seconds == 42 } }

        XCTAssertEqual(rig.gateway.updates.last?.id, "p1")
        XCTAssertEqual(rig.gateway.updates.last?.seconds, 42)
        // stop() と異なり再生状態は解放しない（バックグラウンド再生を継続させる）。
        XCTAssertTrue(rig.engine.isLoaded)
        XCTAssertEqual(vm.session.position, 42)
    }

    func testFlushPlaybackPositionWithoutCurrentPodcastSendsNothing() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel

        vm.flushPosition()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(rig.gateway.updates.isEmpty)
    }

    // MARK: - 完了時自動収束

    func testQueueEndSetsFinishedState() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))   // キューは [a] のみ
        await rig.engine.send(.ready)

        await endCurrent(rig)

        XCTAssertTrue(vm.isFinished)
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "a")
        XCTAssertFalse(vm.isPlaying)
    }

    func testAutoAdvanceDoesNotSetFinishedState() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        try await enqueue(rig, queuePodcast("b"))
        await rig.engine.send(.ready)

        await endCurrent(rig)                       // a 終了 → 自動で b へ
        await waitUntil { vm.nowPlaying()?.episodeId == "b" }

        XCTAssertFalse(vm.isFinished)
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "b")
    }

    func testReplayCurrentEpisodeClearsFinishedStateAndPlaysFromZero() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        await rig.engine.send(.ready)
        await endCurrent(rig)
        XCTAssertTrue(vm.isFinished)

        await vm.replayCurrent()

        XCTAssertFalse(vm.isFinished)
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "a")
        XCTAssertTrue(vm.isPlaying)
        XCTAssertEqual(vm.session.position, 0)
    }

    func testReplayCurrentEpisodeOverridesMidPositionRestore() async throws {
        // WHY: finished 状態への復帰時に、サーバーから復元された途中位置（playbackPositionSeconds: 120）
        //      を replayCurrent() が seek(to: 0) で明示的に上書きすることを検証。
        //      修正対象: replayCurrent() 内の seek(to: 0) を削ると、このテストは RED になる。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        let podcast = queuePodcast("mid-position", playbackPositionSeconds: 120, durationSeconds: 300)
        try await start(rig, podcast)
        await rig.engine.send(.ready)
        await endCurrent(rig)
        XCTAssertTrue(vm.isFinished)

        await vm.replayCurrent()

        XCTAssertFalse(vm.isFinished)
        XCTAssertEqual(vm.session.position, 0)  // 途中位置 120s を上書き
    }

    func testReplayCurrentEpisodeIsNoOpWithoutCurrentPodcast() async throws {
        let vm = PlaybackEntryRig().viewModel

        await vm.replayCurrent()

        XCTAssertNil(vm.nowPlaying())
        XCTAssertFalse(vm.isPlaying)
    }

    func testReplayWhileOfflineNotCachedKeepsFinishedStateAndSetsError() async throws {
        // 保存していないエピソードをオンラインで聴き終えた後に、オフラインへ切り替えて再聴する。
        let rig = PlaybackEntryRig(online: true)
        let vm = rig.viewModel
        rig.serve(EntryFixture.playable("offline-episode"))
        try await rig.seed([queuePodcast("offline-episode")])
        await vm.startEpisode(episodeId: "offline-episode")
        await rig.engine.send(.ready)
        await endCurrent(rig)                       // キュー空 → 収束
        XCTAssertTrue(vm.isFinished)
        rig.network.isOnline = false

        await vm.replayCurrent()

        XCTAssertNotNil(vm.errorMessage)
        XCTAssertTrue(vm.isFinished)
    }

    func testStopPlaybackDoesNotSetFinishedState() async throws {
        let vm = try await playingRig().viewModel

        vm.stop()

        XCTAssertFalse(vm.isFinished)
    }

    func testStopPlaybackAfterFinishPreservesFinishedState() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        await rig.engine.send(.ready)
        await endCurrent(rig)
        XCTAssertTrue(vm.isFinished)

        vm.stop()                        // タブ離脱を想定

        XCTAssertFalse(vm.isFinished)
        XCTAssertNil(vm.nowPlaying())
    }

    func testPlayDifferentEpisodeClearsFinishedState() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        await rig.engine.send(.ready)
        await endCurrent(rig)
        XCTAssertTrue(vm.isFinished)

        try rig.cached("b")
        try await rig.seed([queuePodcast("b")])
        await vm.startEpisode(episodeId: "b")

        XCTAssertFalse(vm.isFinished)
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "b")
    }

    func testPlayWithEndPositionStartsFromZero() async throws {
        // 保存位置が末尾±2秒 → 完聴済みの記録とみなし、復元せず先頭から再生する
        // （再タップ即完了ループの回帰防止）。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        let podcast = queuePodcast("resumed", playbackPositionSeconds: 58, durationSeconds: 60)

        try await start(rig, podcast)

        XCTAssertEqual(vm.session.position, 0)
    }

    func testPlayWithMidPositionRestoresPosition() async throws {
        // 対のテスト: 末尾ガードが途中位置の復元まで巻き込んで殺していないことを確認する。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        let podcast = queuePodcast("mid", playbackPositionSeconds: 120, durationSeconds: 300)

        try await start(rig, podcast)

        XCTAssertEqual(vm.session.position, 120)
    }

    func testPlayWithZeroDurationRestoresPosition() async throws {
        // durationSeconds == 0（メタデータ欠損）で isAtEnd が常に true にならず、
        // レジューム自体が無効化されない境界を確認する。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        let podcast = queuePodcast("zero-duration", playbackPositionSeconds: 30, durationSeconds: 0)

        try await start(rig, podcast)

        XCTAssertEqual(vm.session.position, 30)
    }

    func testEndOfPlaybackObserverCapturesEndedIdAtRegistrationNotAtFireTime() async throws {
        // PR #74 レビュー指摘: 終了通知(didPlayToEndTimeNotification)は queue: .main 経由で
        // 非同期配信されるため、クロージャ発火時点で現在の episode を読むと、
        // 登録〜発火の間に利用者が別エピソードへ切り替えた場合、新しい現在の episode の ID を
        // 「終了した episode の ID」として誤って渡してしまい、終端処理側の
        // stale ガード（現在の episode の id と終了した id の不一致）が素通りする。
        // ここでは a の channel に終了事象を手渡した直後（消費者が処理する前）に b を開始することで、
        // 「観測は a の item を指したまま、現在のエピソードだけ b に変わった」状況を再現する。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await rig.play("a")
        let channelA = try XCTUnwrap(rig.engine.currentChannel)
        try rig.cached("b")
        try await rig.seed([queuePodcast("b")])

        // 手渡しが成立していること（Given）。間に await を挟まず b を開始し、a の channel を閉じる。
        XCTAssertEqual(channelA.yield(.ended), .handedOff)
        await vm.startEpisode(episodeId: "b")
        try await Task.sleep(nanoseconds: 300_000_000)

        // a の stale な終了通知が b に誤適用されていないこと。
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "b")
        XCTAssertFalse(vm.isFinished)
        XCTAssertFalse(rig.gateway.marks.contains("b"))
    }

    func testEndOfPlaybackObserverTriggersConvergenceForCurrentEpisode() async throws {
        // 上の stale テストの正方向対照（positive control）。これが無いと、オブザーバが
        // 終端処理を一切呼ばないミュータントでも stale テストは green のまま通り、
        // 「ガードが効いている」ことと「オブザーバが死んでいる」ことを区別できない
        // （敵対的検証のミューテーションテストで実証済み）。
        // engine の終了事象が、現エピソードの収束と完聴記録を起こすことを固定する。
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        await rig.engine.send(.ready)

        await endCurrent(rig)
        await waitUntil { rig.gateway.marks.contains("a") }

        // キュー終端: 収束フラグが立ち、a の完聴が記録される。
        XCTAssertTrue(vm.isFinished)
        XCTAssertEqual(vm.nowPlaying()?.episodeId, "a")
        XCTAssertTrue(rig.gateway.marks.contains("a"))
    }

    // MARK: - 主体離脱（ios-contract-21.7・ios-slice-auth-01）

    // `PlaybackLifecycle` は `PlaybackCoordinator` が実装し、facade の `stopForLogout()` はそれを中継するだけ。
    // `stopForLogout()` は位置同期を送らずに停止する（`stop()` の同期部分を呼ばない）。

    // verifies: ios-contract-21.7
    func testTT15_09_stopForLogoutResetsPlaybackWithoutSyncingPosition() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        try await enqueue(rig, queuePodcast("b"))
        // 再生が始まっていれば、flush されると位置が送られる状態にしておく。
        await rig.engine.send(.ready)
        vm.seek(to: 12)

        vm.stopForLogout()
        for _ in 0..<3 { await Task.yield() }

        XCTAssertNil(vm.nowPlaying())
        XCTAssertTrue(rig.coordinator.queue.isEmpty)
        XCTAssertEqual(vm.presentation, .hidden)
        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertTrue(
            rig.gateway.updates.filter { $0.id == "a" }.isEmpty,
            "stopForLogout() は再生位置を同期してはならない（C1）"
        )
    }

    // verifies: ios-contract-21.7
    func testTT15_10_stopForLogoutIsIdempotent() async throws {
        let rig = PlaybackEntryRig()
        let vm = rig.viewModel
        try await enqueue(rig, queuePodcast("a"))
        await rig.engine.send(.ready)
        vm.seek(to: 12)
        vm.stopForLogout()
        for _ in 0..<3 { await Task.yield() }

        vm.stopForLogout()
        for _ in 0..<3 { await Task.yield() }

        XCTAssertNil(vm.nowPlaying())
        XCTAssertTrue(rig.coordinator.queue.isEmpty)
        XCTAssertEqual(vm.presentation, .hidden)
        XCTAssertFalse(rig.engine.isLoaded)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertTrue(rig.gateway.updates.filter { $0.id == "a" }.isEmpty)
    }
}

// MARK: - Mock FileManager

extension PodcastViewModelTests {
    final class MockFileManager: FileManagerProtocol {
        var files: [String: Data] = [:]
        var directories: Set<String> = []

        func fileExists(atPath: String) -> Bool {
            files[atPath] != nil || directories.contains(atPath)
        }

        func createDirectory(at: URL, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws {
            directories.insert(at.path)
        }

        func removeItem(at: URL) throws {
            files.removeValue(forKey: at.path)
        }

        func write(_ data: Data, to: URL) throws {
            files[to.path] = data
        }

        func fileSize(atPath: String) -> Int64? {
            files[atPath]?.count.int64 ?? nil
        }

        func cachesDirectory() -> URL {
            URL(fileURLWithPath: "/mock-caches")
        }

        func contentsOfDirectory(atPath path: String) throws -> [String] {
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return files.keys.compactMap { key in
                guard key.hasPrefix(prefix) else { return nil }
                let name = String(key.dropFirst(prefix.count))
                return name.contains("/") ? nil : name
            }
        }
    }
}
